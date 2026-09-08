open! Base
module D = Duckdb
let ok = function Ok value -> value | Error _ -> failwith "DuckDB example failed"
let () =
  let config = ok (D.Config.create Memory) in
  let values = ok (D.with_database config ~f:(fun database ->
    D.with_connection database ~f:(fun connection ->
      ok (D.execute connection "create table example(value bigint, note varchar)");
      ok (D.with_transaction connection ~f:(fun transaction ->
        D.with_prepared_transaction transaction "insert into example values (?, ?)" ~f:(fun statement ->
          ok (D.bind statement 1 (D.Scalar.Required D.Scalar.Int64) 42L);
          ok (D.bind statement 2 (D.Scalar.Required D.Scalar.String) "owned\000text");
          D.close_result (ok (D.execute_prepared statement)))));
      ok (D.with_appender connection "example" ~f:(fun appender ->
        D.append_rows appender [[D.Cell (D.Scalar.Required D.Scalar.Int64, 9007199254740993L);
          D.Cell (D.Scalar.Required D.Scalar.String, "bulk\000row")]]));
      let file = Stdlib.Filename.temp_file "duckdb-synchronous-" ".parquet" in
      Stdlib.Sys.remove file;
      Exn.protect ~finally:(fun () -> if Stdlib.Sys.file_exists file then Stdlib.Sys.remove file)
        ~f:(fun () ->
          let path = ok (D.Parquet.path file) in
          ok (D.Parquet.export connection ~query:"select value, note from example order by value" path);
          let decoder = D.Row.(Map (Column (D.Scalar.Required D.Scalar.Int64,
            Column (D.Scalar.Required D.Scalar.String, Empty)), fun (value, (note, ())) -> value, note)) in
          D.Parquet.fold_rows connection [path] decoder ~init:[]
            ~f:(fun row rows -> Ok (D.Continue (row :: rows))))))) in
  List.iter values ~f:(fun (value, note) -> Stdlib.Printf.printf "owned row: %Ld, %d bytes\n" value (String.length note));
  Stdlib.print_endline "synchronous prepared/appender transaction and local Parquet roundtrip complete"
