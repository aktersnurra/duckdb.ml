val submit : Duckdb_async.t -> (string Duckdb_async.request, Duckdb_async.error) result
val observe : 'a Duckdb_async.request -> (('a, Duckdb_async.failure) result Async.Deferred.t, Duckdb_async.error) result
val lifecycle : Duckdb_async.Limits.t -> Duckdb.Config.t -> unit Async.Deferred.t
val failures : Duckdb_async.failure -> exn list
