(** UNSAFE low-level bridge, not the safe API contract. No concurrent calls
    (except independently lifetime/identity-synchronized [interrupt]), use after
    owner release, or database close with children is allowed. Callers establish
    async exception boundaries and cleanup before acquisition/work.
    Owners start empty; open/connect each at most once. [close_*] clears native
    resources but retains the shell; [finish_*_close] also releases that shell and
    clears the custom slot, idempotently. Status/message require a live shell.
    Execute's boolean is true only for internal transaction-control SQL; false
    applies the safe layer's single-statement/type allowlist. Status 0 is success,
    1 a native error, and 2 an unsupported statement. *)
type database
type connection
val database_owner : unit -> database
val connection_owner : database -> connection
val open_database : database -> string -> int -> int -> bool -> unit
val connect : connection -> unit
val execute : connection -> string -> bool -> unit
val database_status : database -> int
val database_message : database -> string
val connection_status : connection -> int
val connection_message : connection -> string
val clear_work : connection -> unit
val close_database : database -> unit
val close_connection : connection -> unit

(** Nonallocating held-runtime-lock completion, after exclusive draining only.
    May block. Used on interrupted close entry and as finalizer fallback. *)
val finish_database_close : database -> unit
val finish_connection_close : connection -> unit

(** Internal seam, not cancellation: caller must independently synchronize
    lifetime and operation identity. Never expose as a public cancellation API. *)
val interrupt : connection -> unit
val live_resources : unit -> int
val fallback_reclaims : unit -> int

(** Unsafe prepared/result/chunk owner. Retains a native connection shell, not
    permission to use a closed connection. Caller exclusively serializes the
    entire child tree. All statuses/messages require a live owner. *)
type prepared
val prepared_owner : connection -> prepared
val prepare : prepared -> string -> unit
val prepared_status : prepared -> int
val prepared_message : prepared -> string
val parameter_count : prepared -> int
val parameter_type : prepared -> int -> int
val bind_null : prepared -> int -> unit
val bind_int64 : prepared -> int -> int -> int64 -> unit
val bind_float : prepared -> int -> int -> float -> unit
val bind_string : prepared -> int -> int -> string -> unit
val reset : prepared -> unit
val execute_prepared : prepared -> unit
val fetch : prepared -> int
val close_result : prepared -> unit
val finish_result_close : prepared -> unit
val close_prepared : prepared -> unit
val finish_prepared_close : prepared -> unit
val clear_prepared_input : prepared -> unit
val column_count : prepared @ local -> int
val column_type : prepared @ local -> int -> int
val chunk_length : prepared @ local -> int
val chunk_valid : prepared @ local -> int -> int -> bool
val chunk_int64 : prepared @ local -> int -> int -> int64#
val box_int64 : int64# -> int64
val chunk_float : prepared @ local -> int -> int -> float
val chunk_string : prepared @ local -> int -> int -> string
