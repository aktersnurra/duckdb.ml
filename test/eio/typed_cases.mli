(** Source-named Eio typed-query and ingestion evidence. *)
val run_if_selected : < clock : _ Eio.Time.clock; .. > -> string -> bool
val run : < clock : _ Eio.Time.clock; .. > -> unit
