(** Private synchronous owner capsule. Native operations run only on reserved
    workers, never the Eio scheduler. *)
include Duckdb_worker.S
