type database
type slot
val open_database : Duckdb.Config.t -> (database, Duckdb.error) result
val connect : database -> (slot, Duckdb.error) result
val close_slot : slot -> (unit, Duckdb.error) result
val close_database : database -> (unit, Duckdb.error) result
val execute : slot -> Duckdb.Bridge.request -> string -> (unit, Duckdb.error) result
val transaction : slot -> Duckdb.Bridge.request -> f:(Duckdb.transaction -> ('a, Duckdb.error) result) -> ('a, Duckdb.error) result
val is_in_callback : unit -> bool
