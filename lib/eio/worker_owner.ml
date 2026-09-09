module Thread = Thread
open! Base
module D = Duckdb
type database = Database of D.database
type slot = Slot of D.connection
let active = Thread.TLS.new_key (fun () -> false)
let is_in_callback () = Thread.TLS.get active
let open_database c = Result.map (D.open_database c) ~f:(fun x -> Database x)
let connect (Database d) = Result.map (D.connect d) ~f:(fun x -> Slot x)
let close_slot (Slot s) = D.close_connection s
let close_database (Database d) = D.close_database d
let execute (Slot s) r sql = D.Bridge.run r s ~f:(fun c -> D.execute c sql)
let transaction (Slot s) r ~f =
  D.Bridge.run r s ~f:(fun c ->
    D.with_transaction c ~f:(fun tx ->
      let old = Thread.TLS.get active in
      Thread.TLS.set active true;
      Exn.protect ~f:(fun () -> f tx) ~finally:(fun () -> Thread.TLS.set active old)))
