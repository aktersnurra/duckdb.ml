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
  type non_null = private Non_null_codec
  type nullable = private Nullable_codec

  (** One column of a table's shape: its value type and nullability. *)
  type ('a, 'n) slot = private Slot
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
      [Migration] a migration step;
      [Parquet] the file path involved ([path]'s argument; for a fold, the
      failing file; for an empty path list, ["read_parquet"]). *)
  type context =
    | Database | Connection | Transaction
    | Query of string | Table of { schema : string; name : string } | Parquet of string
    | Migration of { version : int; name : string }

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
        typed requests, adapter queries and [Bulk.collect]; chunk-relative for
        [Statement.column] and [Statement.Column.view]; the row within the
        batch or input columns for [Table.append] and [append_columns]. *)
    | Index of { index : int; length : int }
    (** An out-of-range position. Only from the low-level statement API:
        positional [bind], chunk [column] access, [Statement.Column.view],
        and [Bulk.collect]/[collect_strings]. *)
    | Length_mismatch of { column : int; expected : int; actual : int }
    (** [Table.append_columns]: this zero-based column (or its NULL mask) has
        [actual] rows where the first column has [expected]. *)
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
    | Unknown_table of { schema : string; name : string }
    (** [Table.verify]: the declared table does not exist. *)
    | Constraint_mismatch of { constraint_kind : string; expected : string; actual : string }
    (** [Table.verify]: a declared constraint (["PRIMARY KEY"], ["UNIQUE"],
        ["FOREIGN KEY"], ["CHECK"], ["DEFAULT"] or ["NOT NULL"]) differs from
        the catalog. [expected] or [actual] is ["none"] for a constraint on one
        side only. *)
    | Migration_mismatch of { version : int; expected : string; actual : string }
    (** [Migration.apply]: the applied history differs from the step list at
        this version; each side renders as ["<version> <name> (<checksum>)"]
        or ["none"]. *)
    | Encode_rejected of { index : int; reason : Base.Error.t }
    (** A codec's encoder rejected the value at this one-based position: the
        parameter, or the column of an appended row or [append_columns]. *)
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

  (** Typed views of one column of a chunk, type-checked once per chunk. A
      view is local to the chunk callback. Plain accessors exist only on
      non-null views; nullable views offer [is_null] and accessors with an
      explicit [default]. Numeric accessors never allocate ([@zero_alloc],
      checked by the build). A row index outside [0, length) raises
      [Invalid_argument]. Strings are owned copies. [view] rejects with
      [Type_mismatch] unless the column's engine type equals the scalar's
      exactly (e.g. [Int64] on an INTEGER column is rejected), and with
      [Index] for a column outside the result. Dates read through [int32]
      (days) and timestamps through [int64] (ticks). *)
  module Column : sig
    type ('a, 'n) t
    type _ nulls =
      | Non_null : Codec.non_null nulls
      (** The view is rejected with [Null] (chunk-relative row) if the
          column has a NULL in this chunk. *)
      | Nullable : Codec.nullable nulls
    type ('a, 'n) opened = Opened of ('a, 'n) t | Rejected of Error.t @@ global
    val view : chunk @ local -> int -> 'a Scalar.t -> 'n nulls -> ('a, 'n) opened @ local
    val length : _ t @ local -> int
    val int64 : (int64, Codec.non_null) t @ local -> int -> int64# [@@zero_alloc]
    val float : (float, Codec.non_null) t @ local -> int -> float# [@@zero_alloc]
    val int32 : (int32, Codec.non_null) t @ local -> int -> int32# [@@zero_alloc]
    val float32 : (float32, Codec.non_null) t @ local -> int -> float32# [@@zero_alloc]
    val int16 : (int16, Codec.non_null) t @ local -> int -> int16 [@@zero_alloc]
    val int8 : (int8, Codec.non_null) t @ local -> int -> int8 [@@zero_alloc]
    val bool : (bool, Codec.non_null) t @ local -> int -> bool [@@zero_alloc]
    val string : (string, Codec.non_null) t @ local -> int -> string
    val is_null : (_, Codec.nullable) t @ local -> int -> bool [@@zero_alloc]

    (** The number of NULL rows in the view (this chunk), counted a word of
        the validity mask at a time; 0 when the chunk has no mask. *)
    val null_count : (_, Codec.nullable) t @ local -> int [@@zero_alloc]

    val int64_or : (int64, Codec.nullable) t @ local -> default:int64# -> int -> int64# [@@zero_alloc]
    val float_or : (float, Codec.nullable) t @ local -> default:float# -> int -> float# [@@zero_alloc]
    val int32_or : (int32, Codec.nullable) t @ local -> default:int32# -> int -> int32# [@@zero_alloc]
    val float32_or : (float32, Codec.nullable) t @ local -> default:float32# -> int -> float32# [@@zero_alloc]
    val int16_or : (int16, Codec.nullable) t @ local -> default:int16 -> int -> int16 [@@zero_alloc]
    val int8_or : (int8, Codec.nullable) t @ local -> default:int8 -> int -> int8 [@@zero_alloc]
    val bool_or : (bool, Codec.nullable) t @ local -> default:bool -> int -> bool [@@zero_alloc]
    val string_opt : (string, Codec.nullable) t @ local -> int -> string option
  end
end

(** Whole columns as Bigarrays: one native copy per chunk, nothing on the
    OCaml heap per value. *)
module Bulk : sig
  (** ['a] is the view's type, ['k]/['e] the Bigarray element. Dates and
      timestamps share int32/int64 and carry their scalar. *)
  type ('a, 'k, 'e) kind =
    | Int64 : int64 Scalar.t -> (int64, int64, Bigarray.int64_elt) kind
    | Int32 : int32 Scalar.t -> (int32, int32, Bigarray.int32_elt) kind
    | Int16 : (int16, int, Bigarray.int16_signed_elt) kind
    | Int8 : (int8, int, Bigarray.int8_signed_elt) kind
    | Bool : (bool, int, Bigarray.int8_unsigned_elt) kind
    (** DuckDB's bytes: 0 or 1 for engine-produced values. *)
    | Float64 : (float, float, Bigarray.float64_elt) kind
    | Float32 : (float32, float, Bigarray.float32_elt) kind
  (** One byte per row: 1 valid, 0 NULL. *)
  type mask = (int, Bigarray.int8_unsigned_elt, Bigarray.c_layout) Bigarray.Array1.t
  type 'n validity = All_valid : Codec.non_null validity | Mask : mask -> Codec.nullable validity
  (** NULL rows hold 0. *)
  type ('k, 'e, 'n) t = { data : ('k, 'e, Bigarray.c_layout) Bigarray.Array1.t; validity : 'n validity }
  type _ strings =
    | Strings : string array -> Codec.non_null strings
    | Strings_opt : string option array -> Codec.nullable strings

  (** Copy one chunk's column into [into] at [pos]; raises [Invalid_argument]
      if [into] is too short. *)
  val blit : ('a, _) Statement.Column.t @ local -> ('a, 'k, 'e) kind ->
    into:('k, 'e, Bigarray.c_layout) Bigarray.Array1.t @ local -> pos:int -> unit [@@zero_alloc]
  val blit_validity : ('a, Codec.nullable) Statement.Column.t @ local -> into:mask @ local -> pos:int -> unit [@@zero_alloc]

  (** Executes the statement and collects one column. The column index and
      its exact engine type are checked against the result before any chunk,
      so an empty result is rejected with [Index] or [Type_mismatch] too. A
      NULL in a [Non_null] collect is [Null] with the row absolute within the
      result. [data] is a [sub] of a buffer grown by doubling, so it may keep
      up to about twice its length of backing storage. [collect_strings]
      takes [Scalar.String] or [Scalar.Blob]. *)
  val collect : Statement.prepared @ local -> column:int -> ('a, 'k, 'e) kind ->
    'n Statement.Column.nulls -> (('k, 'e, 'n) t, Error.t) result
  val collect_strings : Statement.prepared @ local -> column:int -> string Scalar.t ->
    'n Statement.Column.nulls -> ('n strings, Error.t) result

  (** Whole columns for [Table.append_columns], indexed by the table's declared
      column types. [Nullable] pairs a column with its mask (1 valid, 0 NULL). *)
  module Columns : sig
    type _ col =
      | Int64 : int64 Scalar.t * (int64, Bigarray.int64_elt, Bigarray.c_layout) Bigarray.Array1.t -> int64 col
      | Int32 : int32 Scalar.t * (int32, Bigarray.int32_elt, Bigarray.c_layout) Bigarray.Array1.t -> int32 col
      | Int16 : (int, Bigarray.int16_signed_elt, Bigarray.c_layout) Bigarray.Array1.t -> int16 col
      | Int8 : (int, Bigarray.int8_signed_elt, Bigarray.c_layout) Bigarray.Array1.t -> int8 col
      | Bool : (int, Bigarray.int8_unsigned_elt, Bigarray.c_layout) Bigarray.Array1.t -> bool col
      | Float64 : (float, Bigarray.float64_elt, Bigarray.c_layout) Bigarray.Array1.t -> float col
      | Float32 : (float, Bigarray.float32_elt, Bigarray.c_layout) Bigarray.Array1.t -> float32 col
      | Strings : string Scalar.t * string array -> string col
      | Nullable : 'a col * mask -> 'a option col
    type _ t = [] : unit t | (::) : 'a col * 'l t -> ('a * 'l) t
  end
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
  type ('columns, 'shape, 'row) table

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
    val ingest : [ `Connection ] owner @ local -> ('columns, _, _) table -> 'columns Args.t list list -> flush:bool ->
      (unit, error) result future
  end

  (** One operation set over both session kinds. *)
  module Session : CONNECTION
    with type 'k owner = 'k session and type error = Error.t and type 'a future = 'a
end

(** Typed single-table SELECT queries. A query is built from typed
    expressions and compiles to an ordinary [Request.t]:

    {[
      let adults = Sql.(
        query Params.[int32] (fun [min_age] ->
          from users (fun [id; name; age] ->
            select Exprs.[id; name] ~row:(fun id name -> (id, name))
              ~where:(is_true Null.(age >= nullable (param min_age)))
              ~order_by:[asc id] ~limit:100)))
    ]}

    Binder patterns such as [fun [id; name; age]] select their constructors
    by type (warnings 40/42, off by default in Dune). A local open
    [Sql.( … )] shadows the comparison and arithmetic operators. An
    expression used outside the query that bound it (smuggled out through a
    reference) raises [Invalid_argument] when the other query is built.
    Checked on first prepare: names against the catalog, a declared parameter
    the query never uses ([Parameter_count]), operators the base type does
    not support (a custom codec over another type, or a BLOB), an empty
    select list, and a negative [~limit] or [~offset]. [~having] on a
    [select] outside [group_by] is rejected there too unless the select list
    holds only literals and parameters, in which case DuckDB treats the table
    as one group (0 or 1 rows, which [many] admits). *)
module Sql : sig
  (** Expression kinds: a value per table row, or per group. *)
  type row
  type grouped

  (** An expression decoding to ['a] when selected, with nullability ['n]
      ([Codec.non_null] or [Codec.nullable]) and kind ['k]. *)
  type ('a, 'n, +'k) expr

  (** A declared table column, as [Table.declare ~constraints] binds it;
      [column] makes it a row expression, e.g. for a CHECK. *)
  type ('a, 'n) column
  val column : ('a, 'n) column -> ('a, 'n, row) expr

  (** A bound query parameter; [param] makes it an expression of any kind. *)
  type ('a, 'n) param
  type 'k order

  (** Parameter declarations, e.g. [Params.[int32; nullable string]]. *)
  module Params : sig
    include module type of Codec.Values
    type ('list, 'shape) t =
      | [] : (unit, unit) t
      | (::) : ('a, 'n) Codec.t * ('list, 'shape) t -> ('a * 'list, ('a, 'n) Codec.slot * 'shape) t
  end

  (** Bound parameters, as [query] passes them to its callback. *)
  module Bound : sig
    type 'shape t =
      | [] : unit t
      | (::) : ('a, 'n) param * 'shape t -> (('a, 'n) Codec.slot * 'shape) t
  end

  (** Bound columns or group keys, as [from] and [group_by] pass them. *)
  module Binders : sig
    type ('shape, 'k) t =
      | [] : (unit, 'k) t
      | (::) : ('a, 'n, 'k) expr * ('shape, 'k) t -> (('a, 'n) Codec.slot * 'shape, 'k) t
  end

  (** [group_by] keys: row expressions. *)
  module Keys : sig
    type 'shape t =
      | [] : unit t
      | (::) : ('a, 'n, row) expr * 'shape t -> (('a, 'n) Codec.slot * 'shape) t
  end

  (** A select list; all elements share one kind. *)
  module Exprs : sig
    type ('list, 'fn, 'result, 'k) t =
      | [] : (unit, 'result, 'result, 'k) t
      | (::) : ('a, _, 'k) expr * ('list, 'fn, 'result, 'k) t -> ('a * 'list, 'a -> 'fn, 'result, 'k) t
  end

  (** What a [from] callback returns: rows ['row] of select-list kind ['k]
      and multiplicity ['m]. *)
  type ('row, 'k, 'm) body
  type ('row, 'm) source

  (** Parameters render as [$1], [$2], … in declaration order. *)
  val query : ('params, 'shape) Params.t -> ('shape Bound.t -> ('row, 'm) source) -> ('params, 'row, 'm) Request.t

  (** Binds the table's columns as row expressions, in declaration order. *)
  val from : (_, 'shape, _) Request.table -> (('shape, row) Binders.t -> ('row, row, 'm) body) -> ('row, 'm) source

  (** Any number of rows. [~where] filters rows; [~having] filters groups and
      belongs inside [group_by]. The select list is non-empty (by type); a
      negative [~limit] or [~offset] raises [Invalid_argument]. *)
  val select : ?where:(bool, Codec.non_null, row) expr -> ?having:(bool, Codec.non_null, grouped) expr ->
    ?order_by:'k order list -> ?limit:int -> ?offset:int -> ('a * 'list, 'fn, 'row, 'k) Exprs.t -> row:'fn ->
    ('row, 'k, Request.many) body

  (** Aggregates without GROUP BY: exactly one row. A select list without
      any aggregate raises [Invalid_argument] when built (it would return a
      row per table row). *)
  val aggregate : ?where:(bool, Codec.non_null, row) expr -> ('a * 'list, 'fn, 'row, grouped) Exprs.t -> row:'fn ->
    ('row, row, Request.one) body

  (** Rebinds the keys as grouped expressions for a grouped [select]. *)
  val group_by : 'shape Keys.t -> (('shape, grouped) Binders.t -> ('row, grouped, Request.many) body) ->
    ('row, row, Request.many) body

  val param : ('a, 'n) param -> ('a, 'n, 'k) expr
  val asc : (_, _, 'k) expr -> 'k order
  val desc : (_, _, 'k) expr -> 'k order

  (** Literals render as typed SQL ([CAST(… AS …)]). Values of custom-codec
      types enter a query as parameters: comparing a custom-codec column with
      a literal of its OCaml type compares the unencoded literal with the
      encoded column. A [string] containing NUL fails with [Embedded_nul];
      pass such values as parameters. *)
  val bool : bool -> (bool, Codec.non_null, 'k) expr
  val int8 : int8 -> (int8, Codec.non_null, 'k) expr
  val int16 : int16 -> (int16, Codec.non_null, 'k) expr
  val int32 : int32 -> (int32, Codec.non_null, 'k) expr
  val int64 : int64 -> (int64, Codec.non_null, 'k) expr
  val float32 : float32 -> (float32, Codec.non_null, 'k) expr
  val float64 : float -> (float, Codec.non_null, 'k) expr
  val string : string -> (string, Codec.non_null, 'k) expr

  (** Comparisons of non-null operands; on a custom codec they compare the
      base values. [Null] holds the three-valued versions. *)
  val ( = ) : ('a, Codec.non_null, 'k) expr -> ('a, Codec.non_null, 'k) expr -> (bool, Codec.non_null, 'k) expr
  val ( <> ) : ('a, Codec.non_null, 'k) expr -> ('a, Codec.non_null, 'k) expr -> (bool, Codec.non_null, 'k) expr
  val ( < ) : ('a, Codec.non_null, 'k) expr -> ('a, Codec.non_null, 'k) expr -> (bool, Codec.non_null, 'k) expr
  val ( <= ) : ('a, Codec.non_null, 'k) expr -> ('a, Codec.non_null, 'k) expr -> (bool, Codec.non_null, 'k) expr
  val ( > ) : ('a, Codec.non_null, 'k) expr -> ('a, Codec.non_null, 'k) expr -> (bool, Codec.non_null, 'k) expr
  val ( >= ) : ('a, Codec.non_null, 'k) expr -> ('a, Codec.non_null, 'k) expr -> (bool, Codec.non_null, 'k) expr
  val ( && ) : (bool, Codec.non_null, 'k) expr -> (bool, Codec.non_null, 'k) expr -> (bool, Codec.non_null, 'k) expr
  val ( || ) : (bool, Codec.non_null, 'k) expr -> (bool, Codec.non_null, 'k) expr -> (bool, Codec.non_null, 'k) expr
  val not : (bool, Codec.non_null, 'k) expr -> (bool, Codec.non_null, 'k) expr
  val like : (string, Codec.non_null, 'k) expr -> (string, Codec.non_null, 'k) expr -> (bool, Codec.non_null, 'k) expr

  val nullable : ('a, Codec.non_null, 'k) expr -> ('a option, Codec.nullable, 'k) expr
  val coalesce : ('a option, Codec.nullable, 'k) expr -> default:('a, Codec.non_null, 'k) expr -> ('a, Codec.non_null, 'k) expr
  val is_null : (_ option, Codec.nullable, 'k) expr -> (bool, Codec.non_null, 'k) expr

  (** SQL [IS TRUE]: NULL becomes false. *)
  val is_true : (bool option, Codec.nullable, 'k) expr -> (bool, Codec.non_null, 'k) expr

  (** Aggregates. [min], [max], [sum] and [avg] are NULL over no rows. *)
  val count_star : (int64, Codec.non_null, grouped) expr
  val count : (_, _, row) expr -> (int64, Codec.non_null, grouped) expr
  val min : ('a, Codec.non_null, row) expr -> ('a option, Codec.nullable, grouped) expr
  val max : ('a, Codec.non_null, row) expr -> ('a option, Codec.nullable, grouped) expr

  (** Arithmetic keeps the operand type; overflow is a native error. Integer
      [/] truncates, and a zero divisor yields NULL. *)
  module type INTEGRAL = sig
    type t
    val ( + ) : (t, Codec.non_null, 'k) expr -> (t, Codec.non_null, 'k) expr -> (t, Codec.non_null, 'k) expr
    val ( - ) : (t, Codec.non_null, 'k) expr -> (t, Codec.non_null, 'k) expr -> (t, Codec.non_null, 'k) expr
    val ( * ) : (t, Codec.non_null, 'k) expr -> (t, Codec.non_null, 'k) expr -> (t, Codec.non_null, 'k) expr
    val ( / ) : (t, Codec.non_null, 'k) expr -> (t, Codec.non_null, 'k) expr -> (t option, Codec.nullable, 'k) expr
    val sum : (t, Codec.non_null, row) expr -> (t option, Codec.nullable, grouped) expr
    val avg : (t, Codec.non_null, row) expr -> (float option, Codec.nullable, grouped) expr
    module Null : sig
      val ( + ) : (t option, Codec.nullable, 'k) expr -> (t option, Codec.nullable, 'k) expr -> (t option, Codec.nullable, 'k) expr
      val ( - ) : (t option, Codec.nullable, 'k) expr -> (t option, Codec.nullable, 'k) expr -> (t option, Codec.nullable, 'k) expr
      val ( * ) : (t option, Codec.nullable, 'k) expr -> (t option, Codec.nullable, 'k) expr -> (t option, Codec.nullable, 'k) expr
      val ( / ) : (t option, Codec.nullable, 'k) expr -> (t option, Codec.nullable, 'k) expr -> (t option, Codec.nullable, 'k) expr
      val sum : (t option, Codec.nullable, row) expr -> (t option, Codec.nullable, grouped) expr
      val avg : (t option, Codec.nullable, row) expr -> (float option, Codec.nullable, grouped) expr
    end
  end

  (** As [INTEGRAL], but [/] is IEEE division (a zero divisor gives an infinity or NaN). *)
  module type FRACTIONAL = sig
    type t
    val ( + ) : (t, Codec.non_null, 'k) expr -> (t, Codec.non_null, 'k) expr -> (t, Codec.non_null, 'k) expr
    val ( - ) : (t, Codec.non_null, 'k) expr -> (t, Codec.non_null, 'k) expr -> (t, Codec.non_null, 'k) expr
    val ( * ) : (t, Codec.non_null, 'k) expr -> (t, Codec.non_null, 'k) expr -> (t, Codec.non_null, 'k) expr
    val ( / ) : (t, Codec.non_null, 'k) expr -> (t, Codec.non_null, 'k) expr -> (t, Codec.non_null, 'k) expr
    val sum : (t, Codec.non_null, row) expr -> (t option, Codec.nullable, grouped) expr
    val avg : (t, Codec.non_null, row) expr -> (float option, Codec.nullable, grouped) expr
    module Null : sig
      val ( + ) : (t option, Codec.nullable, 'k) expr -> (t option, Codec.nullable, 'k) expr -> (t option, Codec.nullable, 'k) expr
      val ( - ) : (t option, Codec.nullable, 'k) expr -> (t option, Codec.nullable, 'k) expr -> (t option, Codec.nullable, 'k) expr
      val ( * ) : (t option, Codec.nullable, 'k) expr -> (t option, Codec.nullable, 'k) expr -> (t option, Codec.nullable, 'k) expr
      val ( / ) : (t option, Codec.nullable, 'k) expr -> (t option, Codec.nullable, 'k) expr -> (t option, Codec.nullable, 'k) expr
      val sum : (t option, Codec.nullable, row) expr -> (t option, Codec.nullable, grouped) expr
      val avg : (t option, Codec.nullable, row) expr -> (float option, Codec.nullable, grouped) expr
    end
  end
  module I64 : INTEGRAL with type t := int64
  module I32 : INTEGRAL with type t := int32
  module I16 : INTEGRAL with type t := int16
  module I8 : INTEGRAL with type t := int8
  module F64 : FRACTIONAL with type t := float
  module F32 : FRACTIONAL with type t := float32

  (** [I64]'s arithmetic and aggregates, and [F64]'s arithmetic as [+.] …. *)
  val ( + ) : (int64, Codec.non_null, 'k) expr -> (int64, Codec.non_null, 'k) expr -> (int64, Codec.non_null, 'k) expr
  val ( - ) : (int64, Codec.non_null, 'k) expr -> (int64, Codec.non_null, 'k) expr -> (int64, Codec.non_null, 'k) expr
  val ( * ) : (int64, Codec.non_null, 'k) expr -> (int64, Codec.non_null, 'k) expr -> (int64, Codec.non_null, 'k) expr
  val ( / ) : (int64, Codec.non_null, 'k) expr -> (int64, Codec.non_null, 'k) expr -> (int64 option, Codec.nullable, 'k) expr
  val sum : (int64, Codec.non_null, row) expr -> (int64 option, Codec.nullable, grouped) expr
  val avg : (int64, Codec.non_null, row) expr -> (float option, Codec.nullable, grouped) expr
  val ( +. ) : (float, Codec.non_null, 'k) expr -> (float, Codec.non_null, 'k) expr -> (float, Codec.non_null, 'k) expr
  val ( -. ) : (float, Codec.non_null, 'k) expr -> (float, Codec.non_null, 'k) expr -> (float, Codec.non_null, 'k) expr
  val ( *. ) : (float, Codec.non_null, 'k) expr -> (float, Codec.non_null, 'k) expr -> (float, Codec.non_null, 'k) expr
  val ( /. ) : (float, Codec.non_null, 'k) expr -> (float, Codec.non_null, 'k) expr -> (float, Codec.non_null, 'k) expr

  (** Three-valued versions over nullable operands. *)
  module Null : sig
    val ( = ) : ('a option, Codec.nullable, 'k) expr -> ('a option, Codec.nullable, 'k) expr -> (bool option, Codec.nullable, 'k) expr
    val ( <> ) : ('a option, Codec.nullable, 'k) expr -> ('a option, Codec.nullable, 'k) expr -> (bool option, Codec.nullable, 'k) expr
    val ( < ) : ('a option, Codec.nullable, 'k) expr -> ('a option, Codec.nullable, 'k) expr -> (bool option, Codec.nullable, 'k) expr
    val ( <= ) : ('a option, Codec.nullable, 'k) expr -> ('a option, Codec.nullable, 'k) expr -> (bool option, Codec.nullable, 'k) expr
    val ( > ) : ('a option, Codec.nullable, 'k) expr -> ('a option, Codec.nullable, 'k) expr -> (bool option, Codec.nullable, 'k) expr
    val ( >= ) : ('a option, Codec.nullable, 'k) expr -> ('a option, Codec.nullable, 'k) expr -> (bool option, Codec.nullable, 'k) expr
    val ( && ) : (bool option, Codec.nullable, 'k) expr -> (bool option, Codec.nullable, 'k) expr -> (bool option, Codec.nullable, 'k) expr
    val ( || ) : (bool option, Codec.nullable, 'k) expr -> (bool option, Codec.nullable, 'k) expr -> (bool option, Codec.nullable, 'k) expr
    val not : (bool option, Codec.nullable, 'k) expr -> (bool option, Codec.nullable, 'k) expr
    val min : ('a option, Codec.nullable, row) expr -> ('a option, Codec.nullable, grouped) expr
    val max : ('a option, Codec.nullable, row) expr -> ('a option, Codec.nullable, grouped) expr
    val ( + ) : (int64 option, Codec.nullable, 'k) expr -> (int64 option, Codec.nullable, 'k) expr -> (int64 option, Codec.nullable, 'k) expr
    val ( - ) : (int64 option, Codec.nullable, 'k) expr -> (int64 option, Codec.nullable, 'k) expr -> (int64 option, Codec.nullable, 'k) expr
    val ( * ) : (int64 option, Codec.nullable, 'k) expr -> (int64 option, Codec.nullable, 'k) expr -> (int64 option, Codec.nullable, 'k) expr
    val ( / ) : (int64 option, Codec.nullable, 'k) expr -> (int64 option, Codec.nullable, 'k) expr -> (int64 option, Codec.nullable, 'k) expr
    val sum : (int64 option, Codec.nullable, row) expr -> (int64 option, Codec.nullable, grouped) expr
    val avg : (int64 option, Codec.nullable, row) expr -> (float option, Codec.nullable, grouped) expr
    val ( +. ) : (float option, Codec.nullable, 'k) expr -> (float option, Codec.nullable, 'k) expr -> (float option, Codec.nullable, 'k) expr
    val ( -. ) : (float option, Codec.nullable, 'k) expr -> (float option, Codec.nullable, 'k) expr -> (float option, Codec.nullable, 'k) expr
    val ( *. ) : (float option, Codec.nullable, 'k) expr -> (float option, Codec.nullable, 'k) expr -> (float option, Codec.nullable, 'k) expr
    val ( /. ) : (float option, Codec.nullable, 'k) expr -> (float option, Codec.nullable, 'k) expr -> (float option, Codec.nullable, 'k) expr
  end
end

(** A declared table: name, column names with codecs, and a row constructor. *)
module Table : sig
  (** ['shape] records each column's value type and nullability, from which
      [Sql.from] types its column binders. *)
  type ('columns, 'shape, 'row) t = ('columns, 'shape, 'row) Request.table
  module Columns : sig
    include module type of Codec.Values
    type ('list, 'fn, 'result, 'shape) t =
      | [] : (unit, 'result, 'result, unit) t
      | (::) : (string * ('a, 'n) Codec.t) * ('list, 'fn, 'result, 'shape) t ->
        ('a * 'list, 'a -> 'fn, 'result, ('a, 'n) Codec.slot * 'shape) t
  end

  (** A column as [~constraints] binds it. *)
  type ('a, 'n) column = ('a, 'n) Sql.column

  (** The declaration's columns, as [~constraints] and [lookup] bind them. *)
  module Binders : sig
    type 'shape t =
      | [] : unit t
      | (::) : ('a, 'n) column * 'shape t -> (('a, 'n) Codec.slot * 'shape) t
  end

  (** A key: non-null columns. ['key] is the tuple of their values, a
      [lookup]'s parameters. *)
  module Key : sig
    type 'key t =
      | [] : unit t
      | (::) : ('a, Codec.non_null) column * 'key t -> ('a * 'key) t
  end

  (** Table constraints. NOT NULL is not declared: a non-null codec makes a
      NOT NULL column. Misuse that types cannot express raises
      [Invalid_argument] when the declaration is built: two primary keys, a
      column from another declaration, a default that mentions a column, a
      foreign key to an undeclared key or to another schema. *)
  module Constraint : sig
    type t
    val primary_key : _ Key.t -> t
    val unique : _ Key.t -> t

    (** [references] binds the referenced table's columns and names its
        declared primary or unique key, in the same schema. DuckDB rejects
        any UPDATE of a referenced row, even of non-key columns, while it is
        referenced. A table cannot reference itself. *)
    val foreign_key : 'key Key.t -> references:((_, 'shape, _) Request.table * ('shape Binders.t -> 'key Key.t)) -> t

    (** A literal at the column's type and nullability, e.g.
        [Sql.(nullable (int32 18l))] for a nullable column. *)
    val default : ('a, 'n) column -> ('a, 'n, Sql.row) Sql.expr -> t

    (** Fails on false and on NULL. *)
    val check : (bool, Codec.non_null, Sql.row) Sql.expr -> t

    (** SQL's own rule: fails on false, NULL passes. *)
    val check_null : (bool option, Codec.nullable, Sql.row) Sql.expr -> t
  end

  (** Names are quoted, never spliced unquoted, and must be NUL-free (checked on
      use). Columns are matched to the catalog by name in any order; omitted
      catalog columns must have a default. Checked when an appender opens or a
      generated request is first prepared.
      [~constraints] binds the columns and lists the table's constraints. *)
  val declare : ?schema:string -> ?constraints:('shape Binders.t -> Constraint.t list) -> string ->
    ('columns, 'fn, 'row, 'shape) Columns.t -> row:'fn -> ('columns, 'shape, 'row) t

  (** SELECT of exactly the declared columns, decoded by the declared row. *)
  val select : (_, _, 'row) t -> (unit, 'row, Request.many) Request.t

  (** INSERT of exactly the declared columns; omitted columns take defaults. *)
  val insert : ('columns, _, _) t -> ('columns, unit, Request.zero) Request.t

  (** The declared columns of the row whose key equals the parameters. The
      key must be the declared primary key or a declared unique key
      ([Invalid_argument] otherwise). *)
  val lookup : (_, 'shape, 'row) t -> ('shape Binders.t -> 'key Key.t) -> ('key, 'row, Request.zero_or_one) Request.t

  (** CREATE TABLE with the declared columns and constraints; an existing
      table is a native error. *)
  val create : _ session @ local -> (_, _, _) t -> (unit, Error.t) result

  (** Read-only check of an existing table against the declaration, in the
      session's snapshot; the first difference wins: [Unknown_table]; column
      names ([Unknown_column], [Missing_column]) and types ([Type_mismatch]);
      then [Constraint_mismatch] for nullability, PRIMARY KEY and UNIQUE
      (exact column sets, both ways), FOREIGN KEY (exact column pairs, both
      ways), CHECK (by column set; the expression is not compared) and
      DEFAULT (by presence). Names compare byte-exactly, and unique indexes
      are not constraints. *)
  val verify : _ session @ local -> (_, _, _) t -> (unit, Error.t) result

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
  val with_appender : _ session @ local -> ('columns, _, 'row) t ->
    f:(('columns, 'row) appender @ local -> ('a, Error.t) result) -> ('a, Error.t) result

  (** One admission for a complete batch, validated before any native row
      mutation. A codec rejection rejects the batch without native work. An
      engine error (including an automatic flush), invalid UTF-8 in a VARCHAR
      value, interrupted native work, or a [None] in a NOT NULL column poisons
      this appender and the transaction;
      later operations return the first error. *)
  val append : ('columns, _) appender @ local -> 'columns Args.t list -> (unit, Error.t) result

  (** Appends whole columns. The column list is typed by the declaration;
      columns with a custom codec are rejected at runtime. Checks run column
      by column in column order, and within a column: length
      ([Length_mismatch] against the first column), mask length, custom codec
      ([Encode_rejected]), engine type other than the catalog's
      ([Type_mismatch]), a NULL mask entry in a NOT NULL column ([Null], with
      the zero-based row). All run before any native work and leave the
      appender usable (the enclosing scope still rolls back if [f] returns the
      error). The rows are then staged and appended slice by slice (one
      vector each) in one admission; an engine failure, invalid UTF-8 in a
      VARCHAR value or interrupted native work poisons as [append]. *)
  val append_columns : ('columns, _) appender @ local -> 'columns Bulk.Columns.t -> (unit, Error.t) result

  (** Explicit flush; an engine error poisons as [append]. *)
  val flush : (_, _) appender @ local -> (unit, Error.t) result
end

(** Versioned migrations: an ordered list of numbered steps, applied forward
    only, each in its own transaction with its bookkeeping row in
    ["main"."duckdb_ml_migrations"]. Run them on a synchronous connection,
    e.g. at startup before opening an adapter pool. Two connections
    migrating one database conflict on the bookkeeping key; the second gets
    the native error and finds the steps applied when rerun (DuckDB's file
    lock keeps a second process out). *)
module Migration : sig
  type kind
  type step

  (** A declaration's column, for [add_column]. *)
  type column = Column : ('a, 'n) Table.column -> column

  (** A declaration to verify after applying. *)
  type table

  (** [step version name kind]. Versions must be strictly increasing
      ([Invalid_argument] from [apply]). The checksum covers a SQL step's
      text and a [run] step's name only, so an edited [run] step is not
      detected. *)
  val step : int -> string -> kind -> step

  (** The declaration's CREATE TABLE, as [Table.create]. *)
  val create : (_, _, _) Table.t -> kind

  (** ADD COLUMN with the declared type and default; a non-null column is
      then set NOT NULL, which fails on a non-empty table without a default.
      A column in a declared key, CHECK or foreign key, or whose default is
      not a literal, raises [Invalid_argument]: DuckDB cannot add either.
      Pass the declaration as it was when the step was written (a frozen
      copy, e.g. [users_v2]), not the current one: the step's checksum
      covers the declaration's structure, so a later change to the current
      declaration would read as an edited step. The same holds for
      [create]. *)
  val add_column : (_, 'shape, _) Table.t -> ('shape Table.Binders.t -> column) -> kind

  (** Name-based steps; identifiers are quoted, [schema] defaults to ["main"]. *)
  val drop_table : ?schema:string -> string -> kind
  val drop_column : ?schema:string -> table:string -> string -> kind
  val rename_table : ?schema:string -> string -> to_:string -> kind
  val rename_column : ?schema:string -> table:string -> string -> to_:string -> kind

  (** One statement as written. *)
  val sql : string -> kind

  (** Code in the step's transaction, e.g. a data backfill. *)
  val run : ([ `Transaction ] session @ local -> (unit, Error.t) result) -> kind

  val table : (_, _, _) Table.t -> table

  (** Creates the bookkeeping table if missing; checks that the applied
      history is exactly a prefix of [steps] (version, name, checksum;
      otherwise [Migration_mismatch]); applies the pending steps in order,
      stopping at the first failure (context [Migration]); then verifies each
      [verify] declaration with [Table.verify]. Returns the versions applied
      by this call. *)
  val apply : [ `Connection ] session @ local -> ?verify:table list -> step list -> (int list, Error.t) result
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
val fold_table : connection @ local -> path list -> (_, _, 'row) Table.t -> init:'a ->
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
