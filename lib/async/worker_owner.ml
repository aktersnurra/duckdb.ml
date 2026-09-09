module System_thread = Thread
open! Base
module D = Duckdb
type database = Database of D.database
type slot = Slot of D.connection
let active = System_thread.TLS.new_key (fun () -> false)
let is_in_callback () = System_thread.TLS.get active
let open_database config = Result.map (D.open_database config) ~f:(fun db -> Database db)
let connect (Database db) = Result.map (D.connect db) ~f:(fun c -> Slot c)
let close_slot (Slot c) = D.close_connection c
let close_database (Database db) = D.close_database db
let execute (Slot c) request sql = D.Bridge.run request c ~f:(fun facade -> D.execute facade sql)
let transaction (Slot c) request ~f =
  D.Bridge.run request c ~f:(fun facade -> D.with_transaction facade ~f:(fun tx ->
    System_thread.TLS.set active true;
    Exn.protect ~f:(fun () -> f tx) ~finally:(fun () -> System_thread.TLS.set active false)))
