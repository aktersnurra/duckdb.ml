type t = { native : Duckdb_ffi.prepared }
val length : t @ local -> int
val column : t @ local -> column:int -> row:int -> ('a, _) Codec.t -> ('a, Resource.error) result
