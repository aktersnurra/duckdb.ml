(** Direct-style Eio adapter. Pools and their producers belong to [sw]; native
    owners never leave synchronous workers. No scheduler is started on import. *)
type phase = Operation | Connect | Close_connection | Close_database
type cause = Core_failure of Duckdb.error | Raised_failure of exn * Printexc.raw_backtrace
type failure = { phase : phase; cause : cause }
type error =
  | Invalid_connections of int
  | Invalid_queue_capacity of int
  | Queue_full
  | Pool_shutdown
  | Reentrant_call
  | Core of Duckdb.error
  | Lifecycle_errors of failure list

(** A raised worker failure alone is reraised with its original raw backtrace.
    When additional failures occur, all constituents (including their raw
    backtraces) are retained here, in operation/cleanup order. Also used for
    exceptional cleanup and unobserved automatic switch cleanup failures. *)
exception Lifecycle_failure of failure list

(** Ordinary cancellation reraises the original [Eio.Cancel.Cancelled]. If
    settlement also fails, this retains that cancellation, its raw backtrace,
    and all failure constituents instead of silently dropping cleanup. A lone
    operation [Cancelled] or [Native_error] (the engine's interruption outcome)
    does not wrap ordinary cancellation; cleanup/raised failures always do. *)
exception Cancelled_with_failures of exn * Printexc.raw_backtrace * failure list

type limits
type t
val limits : connections:int -> queue_capacity:int -> (limits, error) result

(** Opens off-scheduler, cleaning the acquired prefix on failure. A single
    switch-owned daemon is armed before return; on switch cancellation it
    latches requests BEFORE joining protected native producers, then drains
    and closes. Explicit/repeated shutdown shares this same drain. Checks the
    caller's cancellation context independently of [sw], before acquisition and
    after protected initialization; cancellation disposes acquired owners before
    propagating the original exception, retaining cleanup failures. Like all
    public pool operations, callback reentry returns [Reentrant_call] before
    any scheduler/context effects. *)
val create : sw:Eio.Switch.t -> limits -> Duckdb.Config.t -> (t, error) result

(** One bounded producer owns admission, native completion and settlement.
    Queued cancellation removes the semaphore waiter and releases admission
    without leasing a connection or running native work. Once dispatched,
    caller cancellation interrupts the Bridge and waits protected for cleanup.
    Only successful, uncancelled SQL-only [execute] requests reuse their
    connection. Complete typed requests conservatively retire their connection.
    Cancellation does not prove a write did not commit. *)
val execute : t -> string -> (unit, error) result

(** Synchronous worker callback; token revoked on return. Adapter reentry is
    rejected before scheduler effects. EVERY transaction retires its connection,
    including success. Nonreturning callbacks prevent shutdown completion. *)
val transaction : t -> f:(Duckdb.transaction -> ('a, Duckdb.error) result) -> ('a, error) result

(** Materializes owned rows on one worker. The fields, row constructor and SQL evaluation do not
    let a result, chunk, or connection owner cross back to the Eio scheduler.
    The [~row] constructor also runs on the worker and, like [f], must not touch
    the scheduler. *)
val query : t -> string -> (_, 'fn, 'row) Duckdb.Fields.t -> row:'fn -> ('row list, error) result

(** Folds owned decoded rows synchronously on one worker. [Stop] returns its
    accumulator; callback reentry into this adapter is rejected. *)
val fold_rows : t -> string -> (_, 'fn, 'row) Duckdb.Fields.t -> row:'fn -> init:'a ->
  f:('row -> 'a -> ('a Duckdb.step, Duckdb.error) result) -> ('a, error) result

(** Reads exact local filenames in order and folds owned rows on one worker.
    Path construction, including relative-path resolution, occurs on that worker. *)
val parquet_fold_rows : t -> string list -> (_, 'fn, 'row) Duckdb.Fields.t -> row:'fn -> init:'a ->
  f:('row -> 'a -> ('a Duckdb.step, Duckdb.error) result) -> ('a, error) result

(** Exports through DuckDB's connection-level temporary/publication protocol on
    one worker. The destination is converted to a local path on that worker. *)
val parquet_export : t -> query:string -> destination:string -> (unit, error) result

(** Stops admission, settles queued requests as [Pool_shutdown], interrupts and
    drains active work, closes all independent owners before publication. A
    failed replacement initiates the same single drain, without retry. Waiter
    cancellation cannot abandon it; repeated callers see the shared outcome. *)
val shutdown : t -> (unit, error) result

(** Typed requests over the pool, with the admission, retirement, cancellation
    and shutdown rules of [query]. A typed request always retires its
    connection, so the statement cache never applies. A request error is
    [Request]; an adapter error is [Adapter]; caller cancellation raises as for
    every other operation. *)
module Request : sig
  type nonrec error = Adapter of error | Request of Duckdb.Request.request_error
  val exec : t -> ('p, unit, [< `Zero ]) Duckdb.Request.t -> 'p Duckdb.Args.t -> (unit, error) result
  val find : t -> ('p, 'row, [< `One ]) Duckdb.Request.t -> 'p Duckdb.Args.t -> ('row, error) result
  val find_opt : t -> ('p, 'row, [< `Zero | `One ]) Duckdb.Request.t -> 'p Duckdb.Args.t -> ('row option, error) result
  val collect : t -> ('p, 'row, [< `Zero | `One | `Many ]) Duckdb.Request.t -> 'p Duckdb.Args.t ->
    ('row list, error) result
  val fold : t -> ('p, 'row, [< `Zero | `One | `Many ]) Duckdb.Request.t -> 'p Duckdb.Args.t -> init:'a ->
    f:('row -> 'a -> ('a Duckdb.step, Duckdb.Request.request_error) result) -> ('a, error) result
  val with_transaction : t -> f:(Duckdb.transaction -> ('a, Duckdb.Request.request_error) result) -> ('a, error) result
  val ingest : t -> ('c, _) Duckdb.Table.t -> 'c Duckdb.Args.t list list -> flush:bool -> (unit, error) result

  (** The same operations as an instance, for code generic over backends. *)
  module Generic : Duckdb.Request.CONNECTION with type owner = t and type error = error and type 'a future = 'a
end
