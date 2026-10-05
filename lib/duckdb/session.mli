(* Public handles. Payloads are global so that a facade function receiving a
   local handle can reach the global internals. *)
type database = { database : Resource.database @@ global }
type _ t =
  | Connection : Resource.connection @@ global -> [ `Connection ] t
  | Transaction : Resource.transaction @@ global -> [ `Transaction ] t

(* The session's connection, and its transaction when it is one. *)
val connection : _ t @ local -> Resource.connection
val within : _ t @ local -> Resource.transaction option
