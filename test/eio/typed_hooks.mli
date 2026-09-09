(** Test-only native observers for typed Eio query and ingestion requests. *)
val initialize : int -> unit
val select : int -> int -> unit
val release : unit -> unit
val counter : int -> int
val reset : unit -> unit
val hold_execute : bool -> unit
val execute_entries : int -> int
val hold_ingest : bool -> unit
val ingest_entries : unit -> int
val appender_end_rows : unit -> int
val appender_flushes : unit -> int
