open! Base
open Duckdb
module S = Scalar
let ok = function Ok x -> x | Error { Error.cause = Native s; _ } -> failwith s | Error _ -> failwith "unexpected error"
let rejected = function
  | Error { Error.cause = Parameter_schema_changed; _ } -> ()
  | _ -> failwith "expected Parameter_schema_changed"
let count c = ok (with_prepared c "SELECT count(*)::BIGINT FROM t" ~f:(fun p ->
  Result.bind (execute_prepared p) ~f:(fun r ->
    fold_chunks r ~init:0L ~f:(fun chunk _ ->
      match column chunk ~column:0 ~row:0 Codec.Values.int64 with
      | Ok n -> Ok (Continue n)
      | Error e -> Error e))))
let config = ok (Config.create Memory)
let clean () = assert (Duckdb_ffi.live_resources () = 0); assert (Duckdb_ffi.fallback_reclaims () = 0)
let () =
  List.iter [false; true] ~f:(fun other_connection ->
    List.iter ["before-bind"; "after-bind"; "reuse"] ~f:(fun phase ->
      ok (with_database config ~f:(fun db -> with_connection db ~f:(fun c ->
        with_connection db ~f:(fun other ->
          ok (execute c "CREATE TABLE t(x BIGINT)");
          ok (with_prepared c "INSERT INTO t VALUES (?)" ~f:(fun p ->
            let alter () = ok (execute (if other_connection then other else c)
              "ALTER TABLE t ALTER x TYPE DOUBLE") in
            if String.equal phase "before-bind" then alter ();
            ok (bind p 1 (Codec.Values.int64) 9007199254740993L);
            if String.equal phase "reuse" then (
              ok (close_result (ok (execute_prepared p)));
              ok (execute c "DELETE FROM t"));
            if not (String.equal phase "before-bind") then alter ();
            rejected (execute_prepared p);
            rejected (execute_prepared p);
            assert (Int64.equal (count c) 0L);
            ok (reset p); ok (close_prepared p);
            ok (with_prepared c "INSERT INTO t VALUES (?)" ~f:(fun fresh ->
              ok (bind fresh 1 (Codec.Values.float64) 42.0);
              Result.bind (execute_prepared fresh) ~f:close_result));
            assert (Int64.equal (count c) 1L);
            Ok ()));
          Ok ()))));
      clean ();
      Stdlib.Printf.printf "schema: %s other-connection=%b rejects without insert; cleanup/reuse=ok\n%!" phase other_connection))

let () =
  ok (with_database config ~f:(fun db -> with_connection db ~f:(fun c ->
    ok (execute c "CREATE TABLE t(x BIGINT)");
    (match with_transaction c ~f:(fun tx ->
      with_prepared_transaction tx "INSERT INTO t VALUES (?)" ~f:(fun p ->
        ok (bind p 1 (Codec.Values.int64) 9007199254740993L);
        ok (close_result (ok (execute_prepared p)));
        ok (execute_transaction tx "DELETE FROM t");
        ok (execute_transaction tx "ALTER TABLE t ALTER x TYPE DOUBLE");
        rejected (execute_prepared p);
        ok (execute_transaction tx "INSERT INTO t VALUES (42.0)");
        Error { context = Transaction; cause = Effects_not_allowed })) with
     | Error { cause = Effects_not_allowed; _ } -> () | _ -> failwith "outer transaction outcome changed");
    assert (Int64.equal (count c) 0L);
    (* Outer rollback restores BIGINT, not just rows; no internal COMMIT occurred. *)
    ok (with_prepared c "INSERT INTO t VALUES (?)" ~f:(fun p ->
      ok (bind p 1 (Codec.Values.int64) 9007199254740993L);
      ok (close_result (ok (execute_prepared p))); Ok ()));
    Ok ())));
  clean ();
  Stdlib.print_endline "schema: explicit transaction reuse/rejection/outer rollback ownership=ok"

let () =
  let path = Stdlib.Filename.temp_file "duckdb-schema-copy" ".csv" in
  Exn.protect ~finally:(fun () -> Stdlib.Sys.remove path) ~f:(fun () ->
    ok (with_database config ~f:(fun db -> with_connection db ~f:(fun c ->
      let run sql = Stdlib.Printf.printf "statement: %s\n%!" sql; ok (with_prepared c sql ~f:(fun p ->
        Result.bind (execute_prepared p) ~f:close_result)) in
      List.iter ["CREATE TABLE t(x BIGINT)"; "INSERT INTO t VALUES (1)";
        "UPDATE t SET x=2"; "DELETE FROM t"; "ALTER TABLE t ADD y BIGINT";
        "MERGE INTO t USING (SELECT 3::BIGINT AS x) s ON t.x=s.x WHEN NOT MATCHED THEN INSERT (x) VALUES (s.x)";
        "SELECT * FROM t"] ~f:run;
      (* Pinned DuckDB classifies SQL ANALYZE as VACUUM, outside the existing
         engine-type allowlist. Do not expand it in a schema-safety fix. *)
      (match prepare c "ANALYZE t" with Error { cause = Unsupported_statement; _ } -> () | _ -> assert false);
      run ("COPY t TO '" ^ String.substr_replace_all path ~pattern:"'" ~with_:"''" ^ "' (FORMAT CSV)");
      assert (Int64.equal (count c) 1L);
      run "DROP TABLE t";
      Ok ()))));
  clean ();
  Stdlib.print_endline "schema: allowed SQL classes (ANALYZE remains engine-rejected)/materialized result after internal commit=ok"
