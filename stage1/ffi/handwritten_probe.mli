(** Owned-copy experiments only. SQL with embedded NUL is rejected. *)
val query_int64 : string -> (int64 array, Probe_error.t) result
val query_int64_unboxed : string -> (int64 array, Probe_error.t) result
val slow : unit -> unit
val slow_locked : unit -> unit
val active : unit -> int
val live_results : unit -> int
