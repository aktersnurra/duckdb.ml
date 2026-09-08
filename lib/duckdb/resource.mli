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


(* Private child admission seam. Only Query can turn this into public owners. *)
type child
val transaction_connection : transaction -> connection
val with_admission : connection -> transaction option -> (unit -> ('a, error) result) -> ('a, error) result
val register_child : connection -> transaction option -> cleanup:(unit -> unit) -> child
val child_operation : child -> allow_result:bool -> (unit -> ('a, error) result) -> ('a, error) result
val child_is_closed : child -> bool
val unregister_child : child -> unit
val reserve_result : child -> unit
val release_result : child -> unit
val native_connection : connection -> Duckdb_ffi.connection
val scope : (unit -> ('a, error) result) -> (unit -> unit) -> ('a, error) result
val force_close_child : child -> unit

(* Called only inside an admitted child operation. Reuses the token's transaction,
   otherwise settles an internal snapshot before returning. Failed rollback
   destroys the exclusively admitted connection and its children. *)
val with_child_snapshot : child -> (unit -> ('a, error) result) -> ('a, error) result
