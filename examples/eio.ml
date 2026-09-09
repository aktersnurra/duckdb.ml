open! Base

module E = Duckdb_eio

let ok = function
  | Ok value -> value
  | Error _ -> failwith "Eio example failed"

let run () =
  Eio_main.run (fun _env ->
    Eio.Switch.run (fun sw ->
      let limits = ok (E.limits ~connections:1 ~queue_capacity:1) in
      let config = ok (Duckdb.Config.create Duckdb.Config.Memory) in
      let pool = ok (E.create ~sw limits config) in
      Exn.protect
        ~finally:(fun () -> ignore (E.shutdown pool : (unit, E.error) result))
        ~f:(fun () ->
          ok (E.execute pool "CREATE TABLE example(i BIGINT)");
          let batches = [ [ [ Duckdb.Cell (Duckdb.Scalar.Required Duckdb.Scalar.Int64, 40L) ]
                            ; [ Duckdb.Cell (Duckdb.Scalar.Required Duckdb.Scalar.Int64, 2L) ] ] ] in
          ok (E.ingest pool ~schema:None ~table:"example" ~batches ~flush:true);
          let rows = Duckdb.Row.(Column (Duckdb.Scalar.Required Duckdb.Scalar.Int64, Empty)) in
          (match E.query pool "SELECT i FROM example ORDER BY i" rows with
           | Ok values when List.length values = 2 -> ()
           | _ -> failwith "typed query did not materialize owned rows");
          let path = Stdlib.Filename.temp_file "duckdb_eio_example" ".parquet" in
          Stdlib.Sys.remove path;
          Exn.protect
            ~finally:(fun () -> if Stdlib.Sys.file_exists path then Stdlib.Sys.remove path)
            ~f:(fun () ->
              ok (E.parquet_export pool ~query:"SELECT i FROM example ORDER BY i" ~destination:path);
              let values = ok (E.parquet_fold_rows pool [path] rows ~init:[]
                ~f:(fun row rows -> Ok (Duckdb.Continue (row :: rows)))) in
              if List.length values <> 2 then failwith "typed Parquet fold failed");
          Stdlib.Printf.printf "duckdb-eio: typed ingestion, query, local Parquet export/read, and shutdown settled\n%!")))

let () = run ()
