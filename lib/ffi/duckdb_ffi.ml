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
