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
    let batches =
      [ [ [ Duckdb.Cell (Duckdb.Scalar.Required Duckdb.Scalar.Int64, 1L) ]
        ; [ Duckdb.Cell (Duckdb.Scalar.Required Duckdb.Scalar.Int64, 2L) ]
        ] ]
    in
    await (A.ingest pool ~schema:None ~table:"example" ~batches ~flush:true) >>= fun () ->
    let row = Duckdb.Row.(Column (Duckdb.Scalar.Required Duckdb.Scalar.Int64, Empty)) in
    await (A.query pool "SELECT i FROM example ORDER BY i" row) >>= fun values ->
    await (A.fold_rows pool "SELECT i FROM example ORDER BY i" row ~init:0L
      ~f:(fun (value, ()) total -> Ok (Duckdb.Continue Int64.(total + value)))) >>= fun sum ->
    let parquet = Stdlib.Filename.temp_file "duckdb_async_example" ".parquet" in
    Stdlib.Sys.remove parquet;
    Monitor.protect
      ~finally:(fun () -> if Stdlib.Sys.file_exists parquet then Stdlib.Sys.remove parquet; return ())
      (fun () ->
        await (A.parquet_export pool ~query:"SELECT i FROM example ORDER BY i" ~destination:parquet) >>= fun () ->
        await (A.parquet_fold_rows pool [parquet] row ~init:[]
          ~f:(fun value values -> Ok (Duckdb.Continue (value :: values)))) >>= fun parquet_values ->
        Stdlib.Printf.printf "ingested %d rows; query/fold sum=%Ld; Parquet read %d owned rows\n%!"
          (List.length values) sum (List.length parquet_values);
        return ()))
  >>| fun () -> Stdlib.print_endline "duckdb-async: example completed and shutdown settled"
let run () =
  don't_wait_for (Monitor.try_with example >>= function
    | Ok () -> Shutdown.exit 0
    | Error exn -> Stdlib.prerr_endline (Exn.to_string exn); Shutdown.exit 1);
  never_returns (Scheduler.go ())
let () = run ()
