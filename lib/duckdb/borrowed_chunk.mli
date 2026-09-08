type t = { native : Duckdb_ffi.prepared }
val length : t @ local -> int
val column : t @ local -> column:int -> row:int -> 'a Scalar.field -> ('a, Resource.error) result
val validate_schema : Duckdb_ffi.prepared -> 'row Row.t -> (unit, Resource.error) result
val decode : t @ local -> int -> 'row Row.t -> ('row, Resource.error) result
