open! Base
let ok = function Ok value -> value | Error _ -> failwith "DuckDB example failed"
let () =
  let config = ok (Duckdb.Config.create Memory) in
  ok (Duckdb.with_database config ~f:(fun database ->
    Duckdb.with_connection database ~f:(fun connection ->
      ok (Duckdb.execute connection "create table example(value integer)");
      Duckdb.with_transaction connection ~f:(fun transaction ->
        Duckdb.execute_transaction transaction "insert into example values (42)"))));
  Stdlib.print_endline "synchronous transaction complete"
