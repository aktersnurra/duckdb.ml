(** Ctypes-owned SQL storage and copied BIGINT results; no borrowed views. *)
val query_int64 : string -> (int64 array, Probe_error.t) result
val slow : unit -> unit
