(** Synchronous resources. No scheduler is started. Handles may move between
    system threads, but are not portable/domain-safe. Busy operations fail fast.
    Scoped callbacks cannot send effects to an outer handler. *)

(* Private operations fail with a bare cause; the facade attaches context. *)
type error = Failure.cause

(* How a scope's body reports errors, and so how a core cause, a failed
   rollback and a cleanup exception are given context. [Cause ctx]: the body
   returns bare causes, and pairings are reported in [ctx] (rollbacks in
   [Transaction]). [Flat ctx]: the body returns flat errors, passed through
   unchanged; core causes of the scope itself are lifted into [ctx]. *)
type 'e lifting = Cause : Failure.context -> error lifting | Flat : Failure.context -> Failure.t lifting

(** Result binding operators shared by the private modules. *)
module Syntax : sig
  val ( let* ) : ('a, 'e) result -> ('a -> ('b, 'e) result) -> ('b, 'e) result
  val ( let+ ) : ('a, 'e) result -> ('a -> 'b) -> ('b, 'e) result
end

module Config : sig
  type t
  type storage = Memory | File of string
  type access = Read_write | Read_only

  (** [threads] defaults to 1 and must be positive. [memory_limit_bytes]
      defaults to 0 (engine default); negative values are rejected. File paths
      must be nonempty, NUL-free and colon-free (no special/remote URI paths).
      Read-only mode requires a file. *)
  val create : ?threads:int -> ?memory_limit_bytes:int -> ?statement_cache:int -> ?access:access ->
    storage -> (t, error) result
end
type database
type connection
type transaction

(** Runs one synchronous callback under a cancellable request; see the public
    [Duckdb.Bridge] documentation for the contract. *)
(* Private lifecycle: exclusive admission precedes native allocation and
   binding. Cancellation publication shares request synchronization with
   binding; native detach/disposal precedes lease release or discard disconnect.
   One owned system-thread controller services raw/Query work, Appender metadata
   and flushing, and named BEGIN/COMMIT. Scalar/reset/file decisions admit the
   persistent latch without delivery; rollback remains noninterruptible cleanup.
   Recoverable ordinary rollback retains that controller with delivery excluded;
   cancellation-driven/terminal cleanup joins before destruction or lease release.
   Any actual native delivery makes the owner discard-only. *)
module Bridge : sig
  (* A canceller is shareable and latches every request bound to it; cancelling
     after its requests settled is a no-op. A handle is a request's state; it runs once.
     [settlement] is [Settled] once at least one request is bound and every
     bound request finished. *)
  type canceller
  type handle
  type settlement = Pending | Settled
  val canceller : unit -> canceller
  val request : canceller -> handle
  val cancel : canceller -> unit
  val settlement : canceller -> settlement
  (* Bridge failures are in the [Connection] context; callback errors pass through.
     A handle runs once; a second run is a runtime [Closed]/[Busy] (the public
     facade makes it a type error). *)
  val run : handle -> connection ->
    f:(connection -> ('a, Failure.t) result) -> ('a, Failure.t) result
end
val open_database : Config.t -> (database, error) result

(** Repeated close succeeds; live children reject parent close (Busy). *)
val close_database : database -> (unit, error) result
val connect : database -> (connection, error) result
val close_connection : connection -> (unit, error) result

(** Exactly one engine-parsed statement. Only engine-prepared SELECT, INSERT,
    UPDATE, DELETE, CREATE, ALTER, DROP, COPY, ANALYZE and MERGE are
    executed. Other types (notably transaction control and SQL PREPARE/EXECUTE)
    are rejected. Engine rewrites such as PRAGMA version to SELECT are allowed.
    Results discarded. *)
val execute : connection -> string -> (unit, error) result
val execute_transaction : transaction -> string -> (unit, error) result

(** Scoped cleanup revokes escaped aliases and drains operations/leases before
    destruction. There is no termination deadline. Acquisition/OOM and arbitrary
    repeated asynchronous interruption do not have a deterministic guarantee. *)
val with_database : Config.t -> f:(database -> ('a, Failure.t) result) -> ('a, Failure.t) result
val with_connection : database -> f:(connection -> ('a, Failure.t) result) -> ('a, Failure.t) result

(** Exclusive for the complete callback and commit/rollback. Reentrant/nested use
    of the original connection returns Busy. The token is revoked on exit.
    Error/exception/Break rolls back; failed rollback preserves both outcomes.
    Interruption does not establish that writes did not commit. DuckDB's
    transaction semantics apply: external effects such as COPY output files
    are not rolled back. Failed/exceptional rollback discards the connection. *)
val with_transaction : lifting:'e lifting -> connection -> f:(transaction -> ('a, 'e) result) -> ('a, 'e) result


(* Private child admission seam. Query and Appender turn this into public owners. *)
type child
val transaction_connection : transaction -> connection
val with_admission : connection -> transaction option -> (unit -> ('a, error) result) -> ('a, error) result
val register_child : connection -> transaction option -> cleanup:(unit -> unit) -> child
(* [cleanup] bypasses only the cancellation latch, never identity/admission. *)
val child_operation : ?cleanup:bool -> child -> allow_result:bool -> (unit -> ('a, error) result) -> ('a, error) result
val child_is_closed : child -> bool
val unregister_child : child -> unit
val reserve_result : child -> unit
val release_result : child -> unit
val native_connection : connection -> Duckdb_ffi.connection

(* Embeds a core cause in the body's error type. *)
val lift : 'e lifting -> error -> 'e

(* Runs [work] effect-free, then [cleanup] on every exit. A cleanup exception
   is paired with the result error it would otherwise hide. *)
val scope : lifting:'e lifting -> (unit -> ('a, 'e) result) -> (unit -> unit) -> ('a, 'e) result
val force_close_child : child -> unit

(* Called only inside an admitted child operation. Reuses the token's transaction,
   otherwise settles an internal snapshot before returning. Failed rollback
   destroys the exclusively admitted connection and its children. *)
val with_child_snapshot : child -> (unit -> ('a, error) result) -> ('a, error) result

(* First appender failure prevents transaction commit even if ignored. *)
val poison_transaction : transaction -> error -> unit

(* ML user-work boundary; cleanup must remain available after cancellation.
   Does not arm native interruption or hold a lock across work. *)
val checkpoint : connection -> (unit, error) result

(* Only inside exclusive admission, after foreign completion. Cancellation-driven
   cleanup retires/joins before destruction; ordinary cleanup retains the
   same controller, with native delivery excluded throughout destruction. *)
val admit_cleanup : connection -> unit

(* Exception capture. [capture] runs inside the runtime boundary so a callback
   backtrace survives; [capture_all] also catches what the boundary raises. *)
type raised = exn * Stdlib.Printexc.raw_backtrace
val capture : (unit -> 'a) -> ('a, raised) result
val capture_all : (unit -> 'a) -> ('a, raised) result
val reraise : raised -> 'a

(* Runs [setup] on a freshly acquired native owner; an error or exception
   releases it before being returned or re-raised. *)
val acquiring : release:(unit -> unit) -> (unit -> ('a, 'e) result) -> ('a, 'e) result

(* Decodes an owner status code; [message] is read only for a native failure. *)
val native_status : int -> message:(unit -> string) -> (unit, error) result

(* SQL and identifiers cross the C boundary as NUL-terminated strings. *)
val reject_nul : string -> (unit, error) result

(* [close] releases native resources; [finish] then releases the shell even
   when [close] was interrupted. *)
val release_native : close:('a -> unit) -> finish:('a -> unit) -> 'a -> unit

(* Per-connection statement cache, most recently used first, bounded by the
   database's [statement_cache] (0 on request facades). Entries are children
   that are not live children of the connection; the connection closes them
   when it is destroyed. [cache_add] and [cache_remove] close evicted entries,
   so they must not be called while holding admission. *)
val cache_capacity : connection -> int
val register_cached_child : connection -> cleanup:(unit -> unit) -> child
val cache_find : connection -> 'a Base.Type_equal.Id.t -> key:int -> 'a option
val cache_add : connection -> 'a Base.Type_equal.Id.t -> key:int -> 'a -> child -> unit
val cache_remove : connection -> key:int -> unit

(* A cached child runs one operation as a child of [transaction]. *)
val lend_child : child -> transaction option -> (unit -> 'a) -> 'a
val child_transaction : child -> transaction option
