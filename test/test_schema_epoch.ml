open! Base
open Duckdb
let ( let* ) x f = Result.bind x ~f
module S = Scalar
external prepares : unit -> int = "epoch_test_prepares" [@@noalloc]
let ok = function Ok x -> x | Error (Native_error s) -> failwith s | Error _ -> failwith "unexpected error"
let rejected = function
  | Error (Data_error S.Parameter_schema_changed) -> ()
  | _ -> failwith "expected Parameter_schema_changed"
let config = ok (Config.create Memory)
let clean () = assert (Duckdb_ffi.live_resources () = 0); assert (Duckdb_ffi.fallback_reclaims () = 0)
let insert p x = ok (bind p 1 (Codec.Values.int64) x); Result.bind (execute_prepared p) ~f:close_result
let connected f = ok (with_database config ~f:(fun db -> with_connection db ~f:(fun c ->
  with_connection db ~f:(fun other -> f c other; Ok ()))))
let advanced f =
  let before = Duckdb_ffi.schema_epoch () in
  f ();
  Duckdb_ffi.schema_epoch () > before

(* Only CREATE/ALTER/DROP and settlement of a transaction that ran them advance the epoch. *)
let () =
  connected (fun c _ ->
    assert (advanced (fun () -> ok (execute c "CREATE TABLE t(x BIGINT)")));
    assert (not (advanced (fun () -> ok (execute c "INSERT INTO t VALUES (1)"))));
    assert (not (advanced (fun () -> ok (execute c "SELECT * FROM t"))));
    assert (advanced (fun () -> ok (execute c "ALTER TABLE t ADD y BIGINT")));
    assert (not (advanced (fun () -> ok (with_transaction c ~f:(fun tx -> execute_transaction tx "DELETE FROM t")))));
    (* Settlement of a transaction that ran DDL advances again after the DDL itself. *)
    let after_ddl = ref 0 in
    assert (advanced (fun () -> ok (with_transaction c ~f:(fun tx ->
      let* () = execute_transaction tx "DROP TABLE t" in
      after_ddl := Duckdb_ffi.schema_epoch (); Ok ()))));
    ok (execute c "CREATE TABLE r(x BIGINT)");
    let before = Duckdb_ffi.schema_epoch () in
    (match with_transaction c ~f:(fun tx ->
       let* () = execute_transaction tx "DROP TABLE r" in
       after_ddl := Duckdb_ffi.schema_epoch (); Error Busy) with
     | Error Busy -> () | _ -> failwith "rollback outcome");
    assert (!after_ddl > before && Duckdb_ffi.schema_epoch () > !after_ddl));
  clean ();
  Stdlib.print_endline "epoch: DDL and DDL-transaction settlement advance; DML/SELECT/plain transactions do not=ok"

(* An unchanged epoch skips the per-execution re-prepare. *)
let () =
  connected (fun c _ ->
    ok (execute c "CREATE TABLE t(x BIGINT)");
    ok (with_prepared c "INSERT INTO t VALUES (?)" ~f:(fun p ->
      ok (insert p 1L);
      let start = prepares () in
      for i = 2 to 6 do ok (insert p (Int64.of_int i)) done;
      Stdlib.Printf.printf "epoch: prepares for five unchanged executions=%d\n%!" (prepares () - start);
      assert (prepares () = start);
      Ok ())));
  clean ();
  Stdlib.print_endline "epoch: unchanged schema executes without re-prepare=ok"

(* A changed epoch still detects real type changes, from either connection. *)
let () =
  List.iter [false; true] ~f:(fun other_connection ->
    connected (fun c other ->
      ok (execute c "CREATE TABLE t(x BIGINT)");
      ok (with_prepared c "INSERT INTO t VALUES (?)" ~f:(fun p ->
        ok (insert p 1L);
        ok (execute (if other_connection then other else c) "ALTER TABLE t ALTER x TYPE DOUBLE");
        rejected (insert p 9007199254740993L);
        Ok ())));
    clean ());
  Stdlib.print_endline "epoch: type change after a skipped validation is rejected=ok"

(* Unrelated DDL forces one re-check, which succeeds and is then recorded. *)
let () =
  connected (fun c other ->
    ok (execute c "CREATE TABLE t(x BIGINT)");
    ok (with_prepared c "INSERT INTO t VALUES (?)" ~f:(fun p ->
      ok (insert p 1L);
      ok (execute other "CREATE TABLE unrelated(y BIGINT)");
      let start = prepares () in
      ok (insert p 2L);
      assert (prepares () = start + 1);
      ok (insert p 3L);
      assert (prepares () = start + 1);
      Ok ())));
  clean ();
  Stdlib.print_endline "epoch: unrelated DDL re-checks once and re-records=ok"

(* A rolled-back type change restores the original schema: still accepted. *)
let () =
  connected (fun c _ ->
    ok (execute c "CREATE TABLE t(x BIGINT)");
    ok (with_prepared c "INSERT INTO t VALUES (?)" ~f:(fun p ->
      ok (insert p 1L);
      (match with_transaction c ~f:(fun tx ->
         let* () = execute_transaction tx "ALTER TABLE t ALTER x TYPE DOUBLE" in Error Busy) with
       | Error Busy -> () | _ -> failwith "rollback outcome");
      ok (insert p 9007199254740993L);
      Ok ())));
  clean ();
  Stdlib.print_endline "epoch: rolled-back DDL keeps accepting the original types=ok"
