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

type error =
  | Type_mismatch of { index : int; expected : string; actual : int }
  | Null of { column : int; row : int }
  | Index of { index : int; length : int }
  | Column_count of { expected : int; actual : int }
  | Unbound_parameter of int
  | Parameter_schema_changed
  | Encode_rejected of { index : int; reason : Base.Error.t }
  | Decode_rejected of { column : int; row : int; reason : Base.Error.t }

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

(** Synchronous resources. No scheduler is started. Handles may move between
    system threads, but are not portable/domain-safe. Busy operations fail fast.
    Scoped callbacks cannot send effects to an outer handler. *)
type error = Invalid_configuration of string | Embedded_nul | Closed
  | Busy | Cancelled | Live_children | Native_error of string | Unsupported_statement
  | Data_error of Scalar.error
  | Destination_exists | Unsupported_parquet_type of { column : int; actual : int }
  | Effects_not_allowed | Rollback_failed of error * error

(** Raised when a callback exception is followed by a failed rollback. *)
exception Rollback_exception of exn * error

(** A result error and exceptional cleanup are retained together. Ordinary
    primary and cleanup exceptions are paired as [Base.Exn.Finally]. *)
exception Cleanup_exception of error * exn

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
    storage -> (t, error) result
end
type database
type connection
type transaction

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
    Facades/children are revoked at settlement; owned values may escape.
    The owner is Busy throughout [run]; facade close is Busy while active and
    Closed after revocation, never an owner disconnect. Live children cannot
    be imported. Requests are single-use, including failed admission: overlapping
    [run] is Busy, later [run]/[cancel] is Closed. [cancel] latches a request,
    not its outcome; repeated cancellation before settlement succeeds. Pending
    includes never-run requests. Cancellation replaces only an otherwise
    successful outcome, not primary errors or exceptions. *)
module Bridge : sig
  type request
  type settlement = Pending | Settled
  val create : unit -> request
  val cancel : request -> (unit, error) result
  val settlement : request -> settlement
  val run : request -> connection ->
    f:(connection -> ('a, error) result) -> ('a, error) result
end
val open_database : Config.t -> (database, error) result

(** Repeated close succeeds; live children reject parent close. *)
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
val with_database : Config.t -> f:(database -> ('a, error) result) -> ('a, error) result
val with_connection : database -> f:(connection -> ('a, error) result) -> ('a, error) result

(** Runs [f] between BEGIN and COMMIT; any error or exception rolls back.
    Exclusive for the complete callback and commit/rollback. Reentrant/nested use
    of the original connection returns Busy. The token is revoked on exit.
    Error/exception/Break rolls back; failed rollback preserves both outcomes.
    Interruption does not establish that writes did not commit. DuckDB's
    transaction semantics apply: external effects such as COPY output files
    are not rolled back. Failed/exceptional rollback discards the connection. *)
val with_transaction : connection -> f:(transaction -> ('a, error) result) -> ('a, error) result

(** Prepared statements retain their parent. Bindings persist across execution;
    [reset] clears all of them. SQL policy is identical to [execute]. Manual
    parent close rejects live children; scopes drain and close them. A statement
    prepared through a transaction is revoked/closed before its settlement. *)
type prepared
type query_result
type chunk
type 'a step = Continue of 'a | Stop of 'a
val prepare : connection -> string -> (prepared, error) result
val prepare_transaction : transaction -> string -> (prepared, error) result
val close_prepared : prepared -> (unit, error) result
val parameter_count : prepared -> (int, error) result

(** One-based parameter indices; known engine parameter types must match exactly.
    Unresolved ANY/INVALID parameters accept the supplied witness. Rebinding is
    allowed; NULL is supplied as [None] to a nullable codec. The codec's encoder
    runs first, outside connection admission, so an [Encode_rejected] takes
    precedence over index/Busy/Closed/type errors. Encode/index/type/range errors
    leave previous bindings unchanged; native bind failure/interruption marks
    that parameter unbound. Reset failure/interruption marks all unbound. *)
val bind : prepared -> int -> ('a, _) Codec.t -> 'a -> (unit, error) result
val reset : prepared -> (unit, error) result

(** Executes with the current bindings and materializes the result.
    All parameters must be bound. The result exclusively leases the connection
    until closed; reset/reexecute/prepared close return Live_children.
    Parameter types inferred now must equal those at preparation, otherwise
    Data_error Parameter_schema_changed is returned and nothing is published.
    They are re-inferred only when a CREATE/ALTER/DROP (on any connection in
    the process) may have become visible since the last check; parameterless
    statements need no check. Reset does not update that schema; prepare anew
    to accept a changed schema.
    Validation and execution share a DuckDB transaction snapshot. Outside an
    explicit transaction, an internal transaction is settled before returning
    the materialized result; no hidden transaction spans result callbacks.
    Failed rollback discards the connection. Interruption does not prove that
    writes did not commit. Explicit SQL casts/expressions retain SQL semantics. *)
val execute_prepared : prepared -> (query_result, error) result
val close_result : query_result -> (unit, error) result
val with_prepared : connection -> string -> f:(prepared -> ('a, error) result) -> ('a, error) result
val with_prepared_transaction : transaction -> string -> f:(prepared -> ('a, error) result) -> ('a, error) result

(** Streams borrowed chunks to [f] until exhaustion or [Stop].
    After admission, consumes/closes the result on every exit. Busy admission
    rejects without consuming it. The callback is synchronous, local,
    and guarded against outward effects. No owner transition is exposed through
    a chunk. Aliases attempting mutation/fetch/close during a callback get Busy.
    Non-null codecs reject NULL on access, not on empty-result schema validation. *)
val fold_chunks : query_result -> init:'a -> f:(chunk @ local -> 'a -> ('a step, error) result) -> ('a, error) result
val chunk_length : chunk @ local -> int

(** Zero-based column and row indices, checked before reading. Each access
    validates the exact engine type; returned strings/blobs/scalars are owned. *)
val column : chunk @ local -> column:int -> row:int -> ('a, _) Codec.t -> ('a, error) result

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

  (** [Transaction]: BEGIN/COMMIT of a request-layer transaction. *)
  type context = Query of string | Table of { schema : string; name : string } | Transaction
  type cause =
    | Core of error
    | Parameter_count of { expected : int; actual : int }
    | Row_count of { expected : [ `One | `Zero_or_one ]; actual : [ `Zero | `More_than_one ] }
    | Unknown_column of { name : string }
    | Missing_column of { name : string }
    | Encode_rejected of { index : int; reason : Base.Error.t }
    | Decode_rejected of { column : int; row : int; reason : Base.Error.t }
    | Rollback_failed of { primary : request_error; rollback : error }
  and request_error = { context : context; cause : cause }
  val query_of_context : context -> string

  (** A request error followed by an exceptional rollback; both are retained. *)
  exception Cleanup_exception of request_error * exn

  (** Operations over one synchronous owner, or one adapter pool. A request is
      validated against engine metadata when first prepared on a connection. *)
  module type QUERY = sig
    type owner
    type error
    type 'a future
    val exec : owner -> ('params, unit, [< `Zero ]) t -> 'params Args.t -> (unit, error) result future
    val find : owner -> ('params, 'row, [< `One ]) t -> 'params Args.t -> ('row, error) result future
    val find_opt : owner -> ('params, 'row, [< `Zero | `One ]) t -> 'params Args.t ->
      ('row option, error) result future
    val collect : owner -> ('params, 'row, [< `Zero | `One | `Many ]) t -> 'params Args.t ->
      ('row list, error) result future

    (** [f] runs synchronously on the owning thread or worker. *)
    val fold : owner -> ('params, 'row, [< `Zero | `One | `Many ]) t -> 'params Args.t ->
      init:'a -> f:('row -> 'a -> ('a step, request_error) result) -> ('a, error) result future
  end

  module type CONNECTION = sig
    include QUERY

    (** [with_transaction] semantics; the callback is synchronous. *)
    val with_transaction : owner -> f:(transaction -> ('a, request_error) result) -> ('a, error) result future

    (** A complete transaction and typed appender lifecycle. [flush] requests an
        additional explicit flush after all batches. *)
    val ingest : owner -> ('columns, _) table -> 'columns Args.t list list -> flush:bool ->
      (unit, error) result future
  end

  module Connection : CONNECTION
    with type owner = connection and type error = request_error and type 'a future = 'a
  module Transaction : QUERY
    with type owner = transaction and type error = request_error and type 'a future = 'a
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
      than one native chunk) tables are rejected. The connection scope owns
      BEGIN/COMMIT/ROLLBACK; the transaction scope never settles its caller.
      Callback errors/exceptions/effect denial poison settlement. On success
      the scope flushes and closes; it never commits a transaction it does not
      own. Unjoined admitted work is drained on exit; a Busy implicit close
      discards the appender: the connection scope rolls back rather than
      committing, and the caller's transaction can no longer commit. *)
  val with_appender : connection -> ('columns, 'row) t ->
    f:(('columns, 'row) appender -> ('a, Request.request_error) result) -> ('a, Request.request_error) result
  val with_appender_transaction : transaction -> ('columns, 'row) t ->
    f:(('columns, 'row) appender -> ('a, Request.request_error) result) -> ('a, Request.request_error) result

  (** One admission for a complete batch, validated before any native row
      mutation. A codec rejection rejects the batch without native work. An
      engine error (including an automatic flush), interrupted native work, or
      a [None] in a NOT NULL column poisons this appender and the transaction;
      later operations return the first error. *)
  val append : ('columns, _) appender -> 'columns Args.t list -> (unit, Request.request_error) result

  (** Explicit flush; an engine error poisons as [append]. *)
  val flush : (_, _) appender -> (unit, Request.request_error) result
end

module Parquet : sig

type path

(** Exact local filenames only: nonempty, NUL/colon/backslash/glob-free.
    Relative names are made absolute at construction; tilde is not expanded.
    No URI, remote storage, glob expansion or extension management. *)
val path : string -> (path, error) result

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
val export : connection -> query:string -> path -> (unit, error) result

(** Reads each file separately in order, validating the schema of each (even an
    empty file) before fetching; no cross-file type coercion. Decodes through
    [Fields] or a declared table's columns (matched by position; the file must
    have exactly those). An empty list is rejected. Earlier callbacks may run
    before a later file fails; external file mutation is not a transaction
    snapshot guarantee. *)
val fold : connection -> path list -> (_, 'fn, 'row) Fields.t -> row:'fn -> init:'a ->
  f:('row -> 'a -> ('a step, Request.request_error) result) -> ('a, Request.request_error) result
val fold_table : connection -> path list -> (_, 'row) Table.t -> init:'a ->
  f:('row -> 'a -> ('a step, Request.request_error) result) -> ('a, Request.request_error) result
end
