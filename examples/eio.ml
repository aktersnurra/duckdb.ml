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
          let inserted = ok (E.transaction pool ~f:(fun tx ->
            Result.bind (Duckdb.execute_transaction tx "INSERT INTO example VALUES (40)") ~f:(fun () ->
              Result.map (Duckdb.execute_transaction tx "INSERT INTO example VALUES (2)") ~f:(fun () -> 42)))) in
          if inserted <> 42 then failwith "transaction did not return its owned result";
          Stdlib.Printf.printf "duckdb-eio: SQL and two-statement transaction completed and shutdown settled\n%!")))

let () = run ()
