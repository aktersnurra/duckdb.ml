(** Test-generated worker observations; ordinary target leaves these disabled. *)
val cancellation_latched : unit -> unit
val cancellations : unit -> int
val enabled : bool
val operation_entry : unit -> unit
val operations : unit -> int
val callback_cleanup : bool -> unit
val callbacks : unit -> int
val tls_clear : unit -> bool
val explicit_flush : unit -> unit
val flushes : unit -> int
