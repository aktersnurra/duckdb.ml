type database
type connection
external database_owner : unit -> database = "ml_duckdb_database_owner"
external connection_owner : database -> connection = "ml_duckdb_connection_owner"
external open_database : database -> string -> int -> int -> bool -> unit = "ml_duckdb_open"
external connect : connection -> unit = "ml_duckdb_connect"
external execute : connection -> string -> bool -> unit = "ml_duckdb_execute"
external database_status : database -> int = "ml_duckdb_database_status" [@@noalloc]
external database_message : database -> string = "ml_duckdb_database_message"
external connection_status : connection -> int = "ml_duckdb_connection_status" [@@noalloc]
external connection_message : connection -> string = "ml_duckdb_connection_message"
external clear_work : connection -> unit = "ml_duckdb_clear_work" [@@noalloc]
external close_database : database -> unit = "ml_duckdb_close_database"
external close_connection : connection -> unit = "ml_duckdb_close_connection"
external finish_database_close : database -> unit = "ml_duckdb_finish_database_close" [@@noalloc]
external finish_connection_close : connection -> unit = "ml_duckdb_finish_connection_close" [@@noalloc]
external interrupt : connection -> unit = "ml_duckdb_interrupt" [@@noalloc]
external live_resources : unit -> int = "ml_duckdb_live_resources" [@@noalloc]
external fallback_reclaims : unit -> int = "ml_duckdb_fallback_reclaims" [@@noalloc]

type prepared
external prepared_owner : connection -> prepared = "ml_duckdb_prepared_owner"
external prepare : prepared -> string -> unit = "ml_duckdb_prepare"
external prepared_status : prepared -> int = "ml_duckdb_prepared_status" [@@noalloc]
external prepared_message : prepared -> string = "ml_duckdb_prepared_message"
external parameter_count : prepared -> int = "ml_duckdb_parameter_count" [@@noalloc]
external parameter_type : prepared -> int -> int = "ml_duckdb_parameter_type" [@@noalloc]
external bind_null : prepared -> int -> unit = "ml_duckdb_bind_null"
external bind_int64 : prepared -> int -> int -> int64 -> unit = "ml_duckdb_bind_int64"
external bind_float : prepared -> int -> int -> float -> unit = "ml_duckdb_bind_float"
external bind_string : prepared -> int -> int -> string -> unit = "ml_duckdb_bind_string"
external reset : prepared -> unit = "ml_duckdb_reset"
external execute_prepared : prepared -> unit = "ml_duckdb_execute_prepared"
external fetch : prepared -> int = "ml_duckdb_fetch"
external close_result : prepared -> unit = "ml_duckdb_close_result"
external finish_result_close : prepared -> unit = "ml_duckdb_finish_result_close" [@@noalloc]
external close_prepared : prepared -> unit = "ml_duckdb_close_prepared"
external finish_prepared_close : prepared -> unit = "ml_duckdb_finish_prepared_close" [@@noalloc]
external clear_prepared_input : prepared -> unit = "ml_duckdb_clear_prepared_input" [@@noalloc]
external column_count : prepared @ local -> int = "ml_duckdb_column_count" [@@noalloc]
external column_type : prepared @ local -> int -> int = "ml_duckdb_column_type" [@@noalloc]
external chunk_length : prepared @ local -> int = "ml_duckdb_chunk_length" [@@noalloc]
external chunk_valid : prepared @ local -> int -> int -> bool = "ml_duckdb_chunk_valid" [@@noalloc]
external chunk_int64 : prepared @ local -> int -> int -> int64#
  = "ml_duckdb_chunk_int64" "ml_duckdb_chunk_int64_unboxed" [@@noalloc]
external box_int64 : int64# -> int64 = "%box_int64"
external chunk_float : prepared @ local -> int -> int -> float = "ml_duckdb_chunk_float"
external chunk_string : prepared @ local -> int -> int -> string = "ml_duckdb_chunk_string"
