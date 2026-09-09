(** Focused Eio cancellation, terminal-race and transaction-isolation harness. *)
val run_if_selected : < clock : _ Eio.Time.clock; backend_id : string; .. > -> string -> bool
val run : < clock : _ Eio.Time.clock; backend_id : string; .. > -> unit
