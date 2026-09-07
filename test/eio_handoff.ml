open! Base
let ok = function Ok value -> value | Error _ -> failwith "duckdb handoff"
let () =
  let db = ok (Duckdb.open_database (ok (Duckdb.Config.create Memory))) in
  let c = ok (Duckdb.connect db) in
  Eio_main.run (fun _ ->
    Eio_unix.run_in_systhread (fun () -> ok (Duckdb.execute c "select 42"));
    Eio_unix.run_in_systhread (fun () -> ok (Duckdb.close_connection c); ok (Duckdb.close_database db)));
  Stdlib.print_endline "duckdb: Eio handoff=ok"
