(** Private synchronous owner capsule. Native operations run only on reserved
    workers, never the Async scheduler. *)
include Duckdb_worker.S
