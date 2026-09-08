module Scalar : sig

(** Native values: dates are signed days since 1970-01-01; timestamps are signed
    ticks since that epoch. Timestamp_* are timezone-free; Timestamp_tz is a UTC
    instant in microseconds (no original timezone retained). Native infinity
    sentinels are preserved. No calendar or float-time conversion is performed. *)
type _ t =
  | Bool : bool t | Int8 : int t | Int16 : int t | Int32 : int32 t | Int64 : int64 t
  | Float32 : float t | Float64 : float t | String : string t | Blob : string t
  | Date : int32 t | Timestamp_s : int64 t | Timestamp_ms : int64 t
  | Timestamp_us : int64 t | Timestamp_ns : int64 t | Timestamp_tz : int64 t

type _ field = Required : 'a t -> 'a field | Nullable : 'a t -> 'a option field

type error =
  | Range of { expected : string; value : string }
  | Type_mismatch of { index : int; expected : string; actual : int }
  | Null of { column : int; row : int }
  | Index of { index : int; length : int }
  | Column_count of { expected : int; actual : int }
  | Unbound_parameter of int
  | Parameter_schema_changed

val name : 'a t -> string

(** Int8/16 bounds and lossless Float32 conversion are checked before binding.
    Float32 accepts NaN, infinities and signed zero. Finite values must roundtrip
    exactly through binary32; use [round_float32] for explicit rounding. *)
val validate : 'a t -> 'a -> (unit, error) result
val round_float32 : float -> float
end
module Row : sig

(** An owned decoder describes every result column in order. Schema types are
    checked before fetching (even for an empty result). Required fields reject
    NULL per row; DuckDB arbitrary-SQL metadata does not prove non-nullability. *)
type _ t =
  | Empty : unit t
  | Column : 'a Scalar.field * 'b t -> ('a * 'b) t
  | Map : 'a t * ('a -> 'b) -> 'b t
end

(** Synchronous resources. No scheduler is started. Handles may move between
    system threads, but are not portable/domain-safe. Busy operations fail fast.
    Scoped callbacks cannot send effects to an outer handler. *)
type error = Invalid_configuration of string | Embedded_nul | Closed
  | Busy | Live_children | Native_error of string | Unsupported_statement
  | Data_error of Scalar.error
  | Effects_not_allowed | Rollback_failed of error * error
exception Rollback_exception of exn * error
exception Cleanup_exception of error * exn

(** A result error and exceptional cleanup are retained together. Ordinary
    primary and cleanup exceptions are paired as [Base.Exn.Finally]. *)

module Config : sig
  type t
  type storage = Memory | File of string
  type access = Read_write | Read_only

  (** [threads] defaults to 1 and must be positive. [memory_limit_bytes]
      defaults to 0 (engine default); negative values are rejected. File paths
      must be nonempty, NUL-free and colon-free (no special/remote URI paths).
      Read-only mode requires a file. *)
  val create : ?threads:int -> ?memory_limit_bytes:int -> ?access:access -> storage -> (t, error) result
end
type database
type connection
type transaction
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

(** Exclusive for the complete callback and commit/rollback. Reentrant/nested use
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
    allowed; NULL is supplied as [Nullable witness, None]. Index/type/range errors
    leave previous bindings unchanged; native bind failure/interruption marks
    that parameter unbound. Reset failure/interruption marks all unbound. *)
val bind : prepared -> int -> 'a Scalar.field -> 'a -> (unit, error) result
val reset : prepared -> (unit, error) result

(** All parameters must be bound. The result exclusively leases the connection
    until closed; reset/reexecute/prepared close return Live_children.
    Before execution, freshly inferred parameter types must equal those at
    preparation, otherwise Data_error Parameter_schema_changed is returned.
    Reset does not update that schema; prepare anew to accept a changed schema.
    Validation and execution share a DuckDB transaction snapshot. Outside an
    explicit transaction, an internal transaction is settled before returning
    the materialized result; no hidden transaction spans result callbacks.
    Failed rollback discards the connection. Interruption does not prove that
    writes did not commit. Explicit SQL casts/expressions retain SQL semantics. *)
val execute_prepared : prepared -> (query_result, error) result
val close_result : query_result -> (unit, error) result
val with_prepared : connection -> string -> f:(prepared -> ('a, error) result) -> ('a, error) result
val with_prepared_transaction : transaction -> string -> f:(prepared -> ('a, error) result) -> ('a, error) result

(** After admission, consumes/closes the result on every exit. Busy admission
    rejects without consuming it. The callback is synchronous, local,
    and guarded against outward effects. No owner transition is exposed through
    a chunk. Aliases attempting mutation/fetch/close during a callback get Busy.
    Required NULL fields fail on access, not on empty-result schema validation. *)
val fold_chunks : query_result -> init:'a -> f:(chunk @ local -> 'a -> ('a step, error) result) -> ('a, error) result
val chunk_length : chunk @ local -> int

(** Zero-based column and row indices, checked before reading. Each access
    validates the exact engine type; returned strings/blobs/scalars are owned. *)
val column : chunk @ local -> column:int -> row:int -> 'a Scalar.field -> ('a, error) result
val fold_rows : query_result -> 'row Row.t -> init:'a -> f:('row -> 'a -> ('a step, error) result) -> ('a, error) result
