type database = { database : Resource.database @@ global }
type _ t =
  | Connection : Resource.connection @@ global -> [ `Connection ] t
  | Transaction : Resource.transaction @@ global -> [ `Transaction ] t
let connection (type k) (s : k t @ local) = match s with
  | Connection c -> c
  | Transaction tx -> Resource.transaction_connection tx
let within (type k) (s : k t @ local) = match s with
  | Connection _ -> None
  | Transaction tx -> Some tx
