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
