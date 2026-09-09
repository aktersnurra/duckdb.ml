open! Core
open! Async
module A = Duckdb_async
let ok = function Ok value -> value | Error _ -> failwith "asynchronous example failed"
let await request = ok (A.completion (ok request)) >>| ok
let example () =
  let limits = ok (A.Limits.create ~connections:2 ~queue_capacity:4) in
  let config = ok (Duckdb.Config.create Memory) in
  A.create limits config >>= fun created ->
  let pool = ok created in
  Monitor.protect ~finally:(fun () -> ok (A.shutdown pool) >>| ok) (fun () ->
    await (A.execute pool "CREATE TABLE example(i BIGINT)") >>= fun () ->
    await (A.transaction pool ~f:(fun tx ->
      Result.bind (Duckdb.execute_transaction tx "INSERT INTO example VALUES (1)") ~f:(fun () ->
        Result.map (Duckdb.execute_transaction tx "INSERT INTO example VALUES (2)") ~f:(fun () -> "two owned rows committed"))))
    >>| fun message -> Stdlib.print_endline message)
  >>| fun () -> Stdlib.print_endline "duckdb-async: example completed and shutdown settled"
let run () =
  don't_wait_for (Monitor.try_with example >>= function
    | Ok () -> Shutdown.exit 0
    | Error exn -> Stdlib.prerr_endline (Exn.to_string exn); Shutdown.exit 1);
  never_returns (Scheduler.go ())
let () = run ()
