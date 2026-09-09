(** Test-only native seams; no scheduler API or safe-handle representation. *)
type seam = Execute | Rollback | Result | Prepared | Extracted | Chunk
          | Appender_clear | Appender_destroy | Disconnect | Database_close
          | Publication | Unlink
val seams : seam list
val name : seam -> string
val is_interrupted : seam -> bool
val reset : unit -> unit
val hold : seam -> unit
val release : seam -> unit
val release_all : unit -> unit
val entered : seam -> int
val interrupts : unit -> int
val interrupted_connections : unit -> int
val native_errors : unit -> int
val executions : unit -> int
val joins : unit -> int
val finish_calls : unit -> int
val locked_engine_calls : unit -> int
val work : seam -> Duckdb.Bridge.request -> (unit, Duckdb.error) result
val suppressed_work : Duckdb.Bridge.request -> (unit, Duckdb.error) result
val reused_work : Duckdb.Bridge.request -> Duckdb.Bridge.request -> (unit, Duckdb.error) result
val check_outcome : seam -> (unit, Duckdb.error) result -> unit
val check_settled : Duckdb.Bridge.request -> unit
val check_inventory : unit -> unit

exception Worker_failure
exception Cleanup_failure

(** Real Bridge callback exception, followed by native rollback; the optional
    cleanup exception is injected at the ordinary rollback ABI on that worker.
    The callback's named source frame and composite must survive transport. *)
val exceptional_work : fail_cleanup:bool -> Duckdb.Bridge.request -> unit
val check_exception : fail_cleanup:bool -> unit Evidence_support.outcome -> unit
