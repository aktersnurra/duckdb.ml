(* [sql] is the statement's text, for the facade's error context. *)
type t = { native : Duckdb_ffi.prepared; sql : string @@ global }
val length : t @ local -> int
val column : t @ local -> column:int -> row:int -> ('a, _) Codec.t -> ('a, Resource.error) result
