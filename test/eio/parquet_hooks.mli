(** Test-only selected native/syscall gates; no native handles cross into OCaml. *)
val select : int -> string -> string -> string -> unit
val release : unit -> unit
val counter : int -> int
val worker_entry : unit -> unit
val fail_unlink : bool -> unit
