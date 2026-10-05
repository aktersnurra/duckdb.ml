val copy_length : Duckdb.query_result -> (int, Duckdb.Error.t) result
val deferred_value : Duckdb_async.t -> (int Async.Deferred.t Duckdb_async.request, Duckdb_async.error) result
