open! Base
let ok = function Ok value -> value | Error _ -> failwith "duckdb handoff"
let () =
  let db = ok (Duckdb.Owned.open_database (ok (Duckdb.Config.create Memory))) in
  let c = ok (Duckdb.Owned.connect db) in
  Eio_main.run (fun _ ->
    Eio_unix.run_in_systhread (fun () -> ok (Duckdb.execute c "select 42"));
    Eio_unix.run_in_systhread (fun () -> ok (Duckdb.Owned.close_connection c); ok (Duckdb.Owned.close_database db)));
  Stdlib.print_endline "duckdb: Eio handoff=ok"
