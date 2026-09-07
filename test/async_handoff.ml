open! Core
open! Async
let ok = function Ok value -> value | Error _ -> failwith "duckdb handoff"
let () =
  let db = ok (Duckdb.open_database (ok (Duckdb.Config.create Memory))) in
  let c = ok (Duckdb.connect db) in
  don't_wait_for (In_thread.run (fun () -> ok (Duckdb.execute c "select 42"))
    >>= fun () ->
    In_thread.run (fun () -> ok (Duckdb.close_connection c); ok (Duckdb.close_database db))
    >>= fun () -> Stdlib.print_endline "duckdb: Async handoff=ok"; Shutdown.exit 0);
  never_returns (Scheduler.go ())
