module Scalar : sig

(** Native values: dates are signed days since 1970-01-01; timestamps are signed
    ticks since that epoch. Timestamp_* are timezone-free; Timestamp_tz is a UTC
    instant in microseconds (no original timezone retained). Native infinity
    sentinels are preserved. No calendar or float-time conversion is performed. *)
type _ t =
  | Bool : bool t | Int8 : int8 t | Int16 : int16 t | Int32 : int32 t | Int64 : int64 t
  | Float32 : float32 t | Float64 : float t | String : string t | Blob : string t
  | Date : int32 t | Timestamp_s : int64 t | Timestamp_ms : int64 t
  | Timestamp_us : int64 t | Timestamp_ns : int64 t | Timestamp_tz : int64 t

val name : 'a t -> string

end

(** Typed values for request parameters, result columns and table columns.
    A codec is a base scalar witness, optionally NULL-able, optionally mapped
    to a user type. The nullability index rules out [nullable (nullable _)]
    and keeps NULL away from custom conversions. *)
module Codec : sig
  type non_null
  type nullable
  type ('a, 'nullability) t

  (** Shorthands; included by [Fields] and [Table.Columns] for list literals. *)
  module Values : sig
    val bool : (bool, non_null) t
    val int8 : (int8, non_null) t
    val int16 : (int16, non_null) t
    val int32 : (int32, non_null) t
    val int64 : (int64, non_null) t
    val float32 : (float32, non_null) t
    val float64 : (float, non_null) t
    val string : (string, non_null) t
    val blob : (string, non_null) t
    val date : (int32, non_null) t
    val timestamp_s : (int64, non_null) t
    val timestamp_ms : (int64, non_null) t
    val timestamp_us : (int64, non_null) t
    val timestamp_ns : (int64, non_null) t
    val timestamp_tz : (int64, non_null) t
    val of_scalar : 'a Scalar.t -> ('a, non_null) t

    (** NULL is [None]. Only a non-null codec can be made nullable. *)
    val nullable : ('a, non_null) t -> ('a option, nullable) t

    (** [encode] runs before binding/appending, [decode] after the base value
        is read; their errors are reported as [Encode_rejected]/[Decode_rejected]. *)
    val custom : encode:('a -> 'b Base.Or_error.t) -> decode:('b -> 'a Base.Or_error.t) ->
      ('b, non_null) t -> ('a, non_null) t
  end
end

(** One flat error for every operation: where it happened and why. *)
module Error : sig
  (** Where: [Transaction] is BEGIN/COMMIT/ROLLBACK of a scope, or admission of an adapter transaction;
      [Query] carries the statement's SQL (prepared statements, typed requests,
      raw queries); [Table] a declared table's appender or catalog check;
      [Parquet] the file path involved ([path]'s argument; for a fold, the
      failing file; for an empty path list, ["read_parquet"]). *)
  type context =
    | Database | Connection | Transaction
    | Query of string | Table of { schema : string; name : string } | Parquet of string

  type cause =
    | Invalid_configuration of string | Embedded_nul | Closed
    | Busy
    (** The owner is in use by another operation, a transaction, an open
        result or appender, a Bridge request, or (on close) still has live
        children: open connections or prepared statements. *)
    | Cancelled
    | Native of string (** An engine or filesystem failure message. *)
    | Unsupported_statement
    | Effects_not_allowed
    (** A scoped callback performed an effect handled outside its scope. *)
    | Type_mismatch of { index : int; expected : string; actual : string }
    (** [actual] is the engine type's SQL name (["type <id>"] if unsupported). *)
    | Null of { column : int; row : int }
    (** A NULL in a non-null position. Rows are absolute within the result for
        typed requests and adapter queries; chunk-relative for [Statement.column]. *)
    | Index of { index : int; length : int }
    (** An out-of-range position. Only from the low-level statement API:
        positional [bind] and chunk [column] access. *)
    | Unbound_parameter of int
    (** [Statement.fold_chunks] with this one-based parameter unbound. Only from the
        low-level statement API; typed requests bind every parameter. *)
    | Parameter_count of { expected : int; actual : int }
    | Column_count of { expected : int; actual : int }
    | Parameter_schema_changed
    (** The engine's parameter types changed since preparation. *)
    | Row_count of { expected : [ `One | `Zero_or_one ]; actual : [ `Zero | `More_than_one ] }
    | Unknown_column of { name : string }
    (** A declared table column absent from the catalog. *)
    | Missing_column of { name : string }
    (** A catalog column without a default absent from the declaration. *)
    | Encode_rejected of { index : int; reason : Base.Error.t }
    (** A codec's encoder rejected the value at this zero-based position. *)
    | Decode_rejected of { column : int; row : int; reason : Base.Error.t }
    (** A codec's decoder rejected a value; [row] as for [Null]. *)
    | Destination_exists
    | Unsupported_parquet_type of { column : int; actual : string }
    | Rollback_failed of { primary : t; rollback : t }
    (** The primary failure and the failed rollback, both retained; the
        connection is discarded. *)
  and t = { context : context; cause : cause }
end

(** An error retained together with an exception raised after it.
    - A body (callback or scoped work) failed with an error, then cleanup or
      rollback raised: the error is the body's (the primary) and the exception
      is the cleanup's.
    - A transaction callback raised, then its rollback failed: the exception is
      the callback's (the primary, raised with its backtrace) and the error is
      the rollback failure, in the [Transaction] context.
    Ordinary primary and cleanup exceptions are paired as [Base.Exn.Finally]. *)
exception Cleanup_exception of Error.t * exn

module Config : sig
  type t
  type storage = Memory | File of string
  type access = Read_write | Read_only

  (** [threads] defaults to 1 and must be positive. [memory_limit_bytes]
      defaults to 0 (engine default); negative values are rejected. File paths
      must be nonempty, NUL-free and colon-free (no special/remote URI paths).
      Read-only mode requires a file. [statement_cache] bounds each connection's
      typed-request statement cache (default 64; 0 disables; negative is
      rejected). *)
  val create : ?threads:int -> ?memory_limit_bytes:int -> ?statement_cache:int -> ?access:access ->
    storage -> (t, Error.t) result
end

(** Handles. A session is a connection or a transaction on one; operations
    valid on either take [_ session]. *)
type database
type _ session
type connection = [ `Connection ] session
type transaction = [ `Transaction ] session

(** Runs one synchronous callback on a connection under a cancellable request.
    Synchronous callbacks only, under the no-outward-effect barrier. Cancellation
    persists across admitted native boundaries, with one independent controller
    per admitted request. Under the supported ordinary-cancellation contract,
    [run] settles owned work and joins that controller before returning/raising;
    actual interrupt delivery discards the owner. No scheduler or bounded shutdown
    promise. Ordinary cleanup and filesystem calls are noninterruptible; native
    finalizer/signal backstops have more limited responsiveness. Cancellation can
    suppress an unadmitted COMMIT/publication, not undo already-admitted durable
    effects. OOM, arbitrary/repeated asynchronous exceptions, nonreturning work
    and process failure remain outside these settlement guarantees.
    The facade is local to the callback; owned values may escape.
    The owner is Busy throughout [run], never disconnected by it. Live children
    cannot be imported (Busy). A request is unique: [run] consumes it, so it
    runs at most once (including failed admission). A canceller is shareable
    across threads; [cancel] latches it and every request bound to it, so a
    request created from a cancelled canceller starts cancelled. [cancel]
    latches requests, not their outcomes; it is idempotent, and a no-op once
    every bound request settled. [settlement] is [Pending] until at least one
    request is bound and all bound requests (including never-run ones) have
    finished. Cancellation replaces only an otherwise
    successful outcome, not primary errors or exceptions. Bridge failures are
    in the [Connection] context; callback errors are returned unchanged.
    A request that is created but never run keeps its canceller [Pending]
    (the state stays bound), so run or drop cancellers accordingly. *)
module Bridge : sig
  type canceller
  type request
  type settlement = Pending | Settled
  val canceller : unit -> canceller
  val request : canceller -> request @ unique
  val cancel : canceller -> unit
  val settlement : canceller -> settlement
  val run : request @ unique -> connection @ local ->
    f:(connection @ local -> ('a, Error.t) result) -> ('a, Error.t) result
end

(** Exactly one engine-parsed statement. Only engine-prepared SELECT, INSERT,
    UPDATE, DELETE, CREATE, ALTER, DROP, COPY, ANALYZE and MERGE are
    executed. Other types (notably transaction control and SQL PREPARE/EXECUTE)
    are rejected. Engine rewrites such as PRAGMA version to SELECT are allowed.
    Results discarded. *)
val execute : _ session @ local -> string -> (unit, Error.t) result

(** Scoped cleanup drains operations/leases before destruction. There is no termination deadline. Acquisition/OOM and arbitrary
    repeated asynchronous interruption do not have a deterministic guarantee. *)
val with_database : Config.t -> f:(database @ local -> ('a, Error.t) result) -> ('a, Error.t) result
val with_connection : database @ local -> f:(connection @ local -> ('a, Error.t) result) -> ('a, Error.t) result

(** Runs [f] between BEGIN and COMMIT; any error or exception rolls back.
    Exclusive for the complete callback and commit/rollback. The token is local
    to the callback. Reentrant/nested use of the original connection (reachable
    through an [Owned] connection) returns Busy.
    Error/exception/Break rolls back; failed rollback preserves both outcomes.
    Interruption does not establish that writes did not commit. DuckDB's
    transaction semantics apply: external effects such as COPY output files
    are not rolled back. Failed/exceptional rollback discards the connection. *)
val with_transaction : connection @ local -> f:(transaction @ local -> ('a, Error.t) result) -> ('a, Error.t) result

type 'a step = Continue of 'a | Stop of 'a

(** The low-level statement API: positional binding and borrowed chunks.
    Bindings persist across execution; [reset] clears all of them. SQL policy
    is identical to [execute]. A statement prepared through a transaction is
    closed before its settlement. Statement errors are in the context
    [Query sql] of the statement's SQL; scoped callbacks' errors are returned
    unchanged. *)
module Statement : sig
  type prepared
  type chunk
  val with_prepared : _ session @ local -> string -> f:(prepared @ local -> ('a, Error.t) result) -> ('a, Error.t) result
  val parameter_count : prepared @ local -> (int, Error.t) result

  (** One-based parameter indices; known engine parameter types must match exactly.
      Unresolved ANY/INVALID parameters accept the supplied witness. Rebinding is
      allowed; NULL is supplied as [None] to a nullable codec. The codec's encoder
      runs first, outside connection admission, so an [Encode_rejected] takes
      precedence over index/Busy/Closed/type errors. Encode/index/type/range errors
      leave previous bindings unchanged; native bind failure/interruption marks
      that parameter unbound. Reset failure/interruption marks all unbound. *)
  val bind : prepared @ local -> int -> ('a, _) Codec.t -> 'a -> (unit, Error.t) result
  val reset : prepared @ local -> (unit, Error.t) result

  (** Executes with the current bindings and streams borrowed chunks to [f]
      until exhaustion or [Stop]. All parameters must be bound. The result
      exclusively leases the connection for the whole fold: other operations on
      the connection (reachable through an [Owned] connection) return Busy. The
      statement is local, so the callback cannot reach it. No result handle
      exists outside the fold.
      Parameter types inferred now must equal those at preparation, otherwise
      [Parameter_schema_changed] is returned and nothing is published.
      They are re-inferred only when a CREATE/ALTER/DROP (on any connection in
      the process) may have become visible since the last check; parameterless
      statements need no check. Reset does not update that schema; prepare anew
      to accept a changed schema.
      Validation and execution share a DuckDB transaction snapshot. Outside an
      explicit transaction, an internal transaction is settled before the
      materialized result is folded; no hidden transaction spans the callback.
      Failed rollback discards the connection. Interruption does not prove that
      writes did not commit. Explicit SQL casts/expressions retain SQL semantics.
      The callback is synchronous, local, and guarded against outward effects.
      No owner transition is exposed through a chunk. Non-null codecs reject
      NULL on access, not on empty-result schema validation. *)
  val fold_chunks : prepared @ local -> init:'a -> f:(chunk @ local -> 'a -> ('a step, Error.t) result) -> ('a, Error.t) result

  (** [fold_chunks] that executes and discards every row. *)
  val execute : prepared @ local -> (unit, Error.t) result
  val chunk_length : chunk @ local -> int

  (** Zero-based column and row indices, checked before reading. Each access
      validates the exact engine type; returned strings/blobs/scalars are owned.
      [Null] and [Decode_rejected] rows are chunk-relative here. *)
  val column : chunk @ local -> column:int -> row:int -> ('a, _) Codec.t -> ('a, Error.t) result
end

(** Declared parameters or result columns, e.g. [Fields.[int64; nullable string]].
    ['list] identifies the values; ['fn] is the curried row constructor type
    returning ['result]. *)
module Fields : sig
  include module type of Codec.Values
  type ('list, 'fn, 'result) t =
    | [] : (unit, 'result, 'result) t
    | (::) : ('a, _) Codec.t * ('list, 'fn, 'result) t -> ('a * 'list, 'a -> 'fn, 'result) t
end

(** Parameter values or appended rows, e.g. [Args.[42L; Some "x"]]. *)
module Args : sig
  type 'list t = [] : unit t | (::) : 'a * 'list t -> ('a * 'list) t
end

module Request : sig
  type zero = [ `Zero ]
  type one = [ `One ]
  type zero_or_one = [ `Zero | `One ]
  type many = [ `Zero | `One | `Many ]

  (** SQL text, typed parameters, typed rows and a multiplicity. Pure data:
      safe to share across connections, workers and adapters. *)
  type ('params, 'row, 'multiplicity) t

  (** A declared table; built and used through [Table]. *)
  type ('columns, 'row) table

  (** [oneshot] (default false) bypasses the connection's statement cache. *)
  val exec : ?oneshot:bool -> ('params, _, _) Fields.t -> string -> ('params, unit, zero) t
  val one : ?oneshot:bool -> ('params, _, _) Fields.t -> (_, 'fn, 'row) Fields.t -> row:'fn ->
    string -> ('params, 'row, one) t
  val zero_or_one : ?oneshot:bool -> ('params, _, _) Fields.t -> (_, 'fn, 'row) Fields.t -> row:'fn ->
    string -> ('params, 'row, zero_or_one) t
  val many : ?oneshot:bool -> ('params, _, _) Fields.t -> (_, 'fn, 'row) Fields.t -> row:'fn ->
    string -> ('params, 'row, many) t
  val query : (_, _, _) t -> string

  (** Operations over one synchronous owner, or one adapter pool. A request is
      validated against engine metadata when first prepared on a connection. *)
  module type QUERY = sig
    type _ owner
    type error
    type 'a future
    val exec : _ owner @ local -> ('params, unit, [< `Zero ]) t -> 'params Args.t -> (unit, error) result future
    val find : _ owner @ local -> ('params, 'row, [< `One ]) t -> 'params Args.t -> ('row, error) result future
    val find_opt : _ owner @ local -> ('params, 'row, [< `Zero | `One ]) t -> 'params Args.t ->
      ('row option, error) result future
    val collect : _ owner @ local -> ('params, 'row, [< `Zero | `One | `Many ]) t -> 'params Args.t ->
      ('row list, error) result future

    (** [f] runs synchronously on the owning thread or worker. *)
    val fold : _ owner @ local -> ('params, 'row, [< `Zero | `One | `Many ]) t -> 'params Args.t ->
      init:'a -> f:('row -> 'a -> ('a step, Error.t) result) -> ('a, error) result future
  end

  module type CONNECTION = sig
    include QUERY

    (** [with_transaction] semantics; the callback is synchronous. *)
    val with_transaction : [ `Connection ] owner @ local -> f:(transaction @ local -> ('a, Error.t) result) ->
      ('a, error) result future

    (** A complete transaction and typed appender lifecycle. [flush] requests an
        additional explicit flush after all batches. *)
    val ingest : [ `Connection ] owner @ local -> ('columns, _) table -> 'columns Args.t list list -> flush:bool ->
      (unit, error) result future
  end

  (** One operation set over both session kinds. *)
  module Session : CONNECTION
    with type 'k owner = 'k session and type error = Error.t and type 'a future = 'a
end

(** A declared table: name, column names with codecs, and a row constructor. *)
module Table : sig
  type ('columns, 'row) t = ('columns, 'row) Request.table
  module Columns : sig
    include module type of Codec.Values
    type ('list, 'fn, 'result) t =
      | [] : (unit, 'result, 'result) t
      | (::) : (string * ('a, _) Codec.t) * ('list, 'fn, 'result) t -> ('a * 'list, 'a -> 'fn, 'result) t
  end

  (** Names are quoted, never spliced unquoted, and must be NUL-free (checked on
      use). Columns are matched to the catalog by name in any order; omitted
      catalog columns must have a default. Checked when an appender opens or a
      generated request is first prepared. *)
  val declare : ?schema:string -> string -> ('columns, 'fn, 'row) Columns.t -> row:'fn -> ('columns, 'row) t

  (** SELECT of exactly the declared columns, decoded by the declared row. *)
  val select : (_, 'row) t -> (unit, 'row, Request.many) Request.t

  (** INSERT of exactly the declared columns; omitted columns take defaults. *)
  val insert : ('columns, _) t -> ('columns, unit, Request.zero) Request.t

  type ('columns, 'row) appender

  (** Opens an appender on the declared columns and checks them against the
      catalog before any row is accepted. The appender holds the transaction
      snapshot and reserves the connection until the scope exits; other token
      operations return Busy. Generated-column or very wide (metadata larger
      than one native chunk) tables are rejected. Given a connection, the scope
      owns BEGIN/COMMIT/ROLLBACK; given a transaction, it never settles it.
      Callback errors/exceptions/effect denial poison settlement. On success
      the scope flushes and closes; it never commits a transaction it does not
      own. *)
  val with_appender : _ session @ local -> ('columns, 'row) t ->
    f:(('columns, 'row) appender @ local -> ('a, Error.t) result) -> ('a, Error.t) result

  (** One admission for a complete batch, validated before any native row
      mutation. A codec rejection rejects the batch without native work. An
      engine error (including an automatic flush), interrupted native work, or
      a [None] in a NOT NULL column poisons this appender and the transaction;
      later operations return the first error. *)
  val append : ('columns, _) appender @ local -> 'columns Args.t list -> (unit, Error.t) result

  (** Explicit flush; an engine error poisons as [append]. *)
  val flush : (_, _) appender @ local -> (unit, Error.t) result
end

module Parquet : sig

type path

(** Exact local filenames only: nonempty, NUL/colon/backslash/glob-free.
    Relative names are made absolute at construction; tilde is not expanded.
    No URI, remote storage, glob expansion or extension management. *)
val path : string -> (path, Error.t) result

(** Writes the rows of [query] to a new Parquet file at the destination.
    Export one engine-parsed, parameter-free SELECT through DuckDB COPY.
    Omit a trailing statement terminator. The destination is a bound parameter.
    Only supported scalar types are accepted; TIMESTAMP_S/MS are rejected
    because this pinned writer/reader normalizes them to microseconds. Explicit
    SQL conversion opts into that change. No implicit overwrite: a same-parent
    private temporary file is copied, then hard-linked without replacing an
    existing destination. Only that owned temporary file is cleaned up.
    Filesystem effects are not rolled back by DuckDB transactions. A failure or
    interruption during/after publication can follow a published output. No
    crash durability, hostile-directory or atomic transaction/file claim. *)
val export : connection @ local -> query:string -> path -> (unit, Error.t) result

(** Reads each file separately in order, validating the schema of each (even an
    empty file) before fetching; no cross-file type coercion. Decodes through
    [Fields] or a declared table's columns (matched by position; the file must
    have exactly those). An empty list is rejected. Earlier callbacks may run
    before a later file fails; external file mutation is not a transaction
    snapshot guarantee. *)
val fold : connection @ local -> path list -> (_, 'fn, 'row) Fields.t -> row:'fn -> init:'a ->
  f:('row -> 'a -> ('a step, Error.t) result) -> ('a, Error.t) result
val fold_table : connection @ local -> path list -> (_, 'row) Table.t -> init:'a ->
  f:('row -> 'a -> ('a step, Error.t) result) -> ('a, Error.t) result
end

(** Runtime-checked lifecycle for scheduler adapters (Async/Eio pools): owned
    handles, with use-after-close and live-children checks at run time. *)
module Owned : sig
  val open_database : Config.t -> (database, Error.t) result

  (** Repeated close succeeds; live children reject parent close (Busy). *)
  val close_database : database -> (unit, Error.t) result
  val connect : database -> (connection, Error.t) result
  val close_connection : connection -> (unit, Error.t) result

  (** What a run returns: [Exec] discards rows, [Find] and [Find_opt] admit one and at most one, [Collect] and [Fold]
      any number. *)
  type ('row, 'out) shape =
    | Exec : (unit, unit) shape
    | Find : ('row, 'row) shape
    | Find_opt : ('row, 'row option) shape
    | Collect : ('row, 'row list) shape
    | Fold : { init : 'a; f : 'row -> 'a -> ('a step, Error.t) result } -> ('row, 'a) shape

  (** One execution entry point per shape, used by the adapters. Prefer the named operations, which carry the
      row-count guards: [run] accepts any multiplicity. *)
  val run : _ session @ local -> ('row, 'out) shape -> ('params, 'row, _) Request.t -> 'params Args.t ->
    ('out, Error.t) result
end
