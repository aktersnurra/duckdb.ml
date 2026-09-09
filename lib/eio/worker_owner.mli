type database
type slot
val open_database : Duckdb.Config.t -> (database, Duckdb.error) result
val connect : database -> (slot, Duckdb.error) result
val close_slot : slot -> (unit, Duckdb.error) result
val close_database : database -> (unit, Duckdb.error) result
val execute : slot -> Duckdb.Bridge.request -> string -> (unit, Duckdb.error) result
val transaction : slot -> Duckdb.Bridge.request -> f:(Duckdb.transaction -> ('a, Duckdb.error) result) -> ('a, Duckdb.error) result
val query : slot -> Duckdb.Bridge.request -> string -> 'row Duckdb.Row.t -> ('row list, Duckdb.error) result
val fold_rows : slot -> Duckdb.Bridge.request -> string -> 'row Duckdb.Row.t -> init:'a ->
  f:('row -> 'a -> ('a Duckdb.step, Duckdb.error) result) -> ('a, Duckdb.error) result
val ingest : slot -> Duckdb.Bridge.request -> schema:string option -> table:string ->
  batches:Duckdb.cell list list list -> flush:bool -> (unit, Duckdb.error) result
val parquet_fold_rows : slot -> Duckdb.Bridge.request -> string list -> 'row Duckdb.Row.t -> init:'a ->
  f:('row -> 'a -> ('a Duckdb.step, Duckdb.error) result) -> ('a, Duckdb.error) result
val parquet_export : slot -> Duckdb.Bridge.request -> query:string -> destination:string -> (unit, Duckdb.error) result
val is_in_callback : unit -> bool
