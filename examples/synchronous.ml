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
      D.with_prepared connection "select value, note from example" ~f:(fun statement ->
        let decoder = D.Row.(Map (Column (D.Scalar.Required D.Scalar.Int64,
          Column (D.Scalar.Required D.Scalar.String, Empty)), fun (value, (note, ())) -> value, note)) in
        D.fold_rows (ok (D.execute_prepared statement)) decoder ~init:[]
          ~f:(fun row rows -> Ok (D.Continue (row :: rows))))))) in
  List.iter values ~f:(fun (value, note) -> Stdlib.Printf.printf "owned row: %Ld, %d bytes\n" value (String.length note));
  Stdlib.print_endline "synchronous prepared transaction complete"
