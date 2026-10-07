open! Base
module D = Duckdb
module R = D.Request
module T = D.Table
module S = D.Sql
module M = D.Migration
let rec describe (e : D.Error.t) =
  let context = match e.context with
    | Migration { version; name } -> Printf.sprintf "[migration %d %s] " version name
    | Table { schema; name } -> Printf.sprintf "[table %s.%s] " schema name
    | _ -> "" in
  context ^ match e.cause with
  | Native s -> "Native: " ^ s
  | Migration_mismatch { version; expected; actual } ->
    Printf.sprintf "Migration_mismatch %d: expected %s, actual %s" version expected actual
  | Constraint_mismatch { constraint_kind; expected; actual } ->
    Printf.sprintf "Constraint_mismatch %s: expected %s, actual %s" constraint_kind expected actual
  | Unknown_table { schema; name } -> "Unknown_table " ^ schema ^ "." ^ name
  | Rollback_failed { primary; _ } -> "Rollback_failed: " ^ describe primary
  | _ -> "other cause"
let ok = function Ok x -> x | Error e -> failwith ("unexpected error: " ^ describe e)
let clean () = assert (Duckdb_ffi.live_resources () = 0); assert (Duckdb_ffi.fallback_reclaims () = 0)
(* Owned handles are global: callbacks may capture them. *)
let connected f =
  let db = ok (D.Owned.open_database (ok (D.Config.create Memory))) in
  Exn.protect ~finally:(fun () -> ok (D.Owned.close_database db)) ~f:(fun () ->
    let c = ok (D.Owned.connect db) in
    Exn.protect ~finally:(fun () -> ok (D.Owned.close_connection c)) ~f:(fun () -> f c));
  clean ()
let count c sql = ok (R.Session.find c (R.one D.Fields.[] D.Fields.[int64] ~row:Fn.id sql) D.Args.[])
let versions = List.equal Int.equal
let invalid name f = match f () with
  | exception Invalid_argument _ -> ()
  | _ -> failwith (name ^ ": accepted")

let users = T.(declare "users"
  Columns.["id", int64; "email", string; "age", nullable int32; "nick", string]
  ~row:(fun id email age nick -> (id, email, age, nick))
  ~constraints:(fun [id; email; _; nick] -> Constraint.[
    primary_key Key.[id]; unique Key.[email]; default nick (S.string "anon") ]))
(* The declaration as it was before step 3 added [nick]. *)
let users_v1 = T.(declare "users"
  Columns.["id", int64; "email", string; "age", nullable int32]
  ~row:(fun id email age -> (id, email, age))
  ~constraints:(fun [id; email; _] -> Constraint.[ primary_key Key.[id]; unique Key.[email] ]))
let backfill = R.exec D.Fields.[] "UPDATE users SET nick = email WHERE nick = 'anon'"
let base = M.[
  step 1 "create users" (create users_v1);
  step 2 "seed" (sql "INSERT INTO users VALUES (1, 'ada@x', 36), (2, 'bob@x', NULL)");
  step 3 "add nick" (add_column users (fun [_; _; _; nick] -> Column nick));
  step 4 "backfill nicks" (run (fun tx -> R.Session.exec tx backfill D.Args.[])) ]

(* From empty: every step, verified; then nothing; then only a new step. *)
let () =
  connected (fun c ->
    assert (versions (ok (M.apply c base ~verify:M.[ table users ])) [ 1; 2; 3; 4 ]);
    assert (Int64.equal (count c "SELECT count(*) FROM users WHERE nick = email") 2L);
    assert (versions (ok (M.apply c base)) []);
    let extended = base @ M.[ step 5 "legacy" (sql "CREATE TABLE legacy(i INTEGER)");
                             step 6 "rename legacy" (rename_table "legacy" ~to_:"old");
                             step 7 "drop old column" (sql "ALTER TABLE old ADD COLUMN j INTEGER");
                             step 8 "drop j" (drop_column ~table:"old" "j");
                             step 9 "rename i" (rename_column ~table:"old" "i" ~to_:"k");
                             step 10 "drop old" (drop_table "old") ] in
    assert (versions (ok (M.apply c extended ~verify:M.[ table users ])) [ 5; 6; 7; 8; 9; 10 ]);
    assert (Int64.equal (count c "SELECT count(*) FROM duckdb_tables() WHERE table_name IN ('legacy', 'old')") 0L);
    assert (Int64.equal (count c "SELECT count(*) FROM duckdb_ml_migrations") 10L));
  Stdlib.print_endline "migration: apply from empty, idempotent rerun, extension, name-based steps=ok"

(* add_column: a non-null column with a default on a table with rows gets the
   default and NOT NULL; a non-null column without a default fails on rows
   and leaves no trace; a constrained column is rejected when built. *)
let () =
  connected (fun c ->
    ignore (ok (M.apply c (List.take base 3)));
    assert (Int64.equal (count c "SELECT count(*) FROM users WHERE nick = 'anon'") 2L);
    assert (Int64.equal (count c "SELECT count(*) FROM duckdb_columns() WHERE table_name = 'users' \
      AND column_name = 'nick' AND NOT is_nullable") 1L);
    let strict = T.(declare "users" Columns.["id", int64; "email", string; "age", nullable int32; "nick", string;
      "score", int64] ~row:(fun _ _ _ _ _ -> ())) in
    (match M.apply c (List.take base 3 @ M.[ step 4 "add score" (add_column strict (fun [_; _; _; _; s] -> Column s)) ]) with
     | Error { D.Error.context = Migration { version = 4; name = "add score" }; cause = Native _ } -> ()
     | Error e -> failwith ("add score: " ^ describe e)
     | Ok _ -> failwith "add score: applied");
    assert (Int64.equal (count c "SELECT count(*) FROM duckdb_columns() WHERE table_name = 'users' AND column_name = 'score'") 0L);
    assert (Int64.equal (count c "SELECT count(*) FROM duckdb_ml_migrations") 3L));
  invalid "constrained column" (fun () -> M.add_column users (fun [_; email; _; _] -> M.Column email));
  Stdlib.print_endline "migration: add_column defaults, NOT NULL, failure leaves no trace, constrained column rejected=ok"

(* A failing step keeps earlier steps; its run-step work rolls back with it;
   a fixed rerun applies it. *)
let () =
  connected (fun c ->
    let failing = List.take base 3 @ M.[ step 4 "backfill nicks" (run (fun tx ->
      match R.Session.exec tx backfill D.Args.[] with
      | Error e -> Error e
      | Ok () -> R.Session.exec tx (R.exec D.Fields.[] "SELECT * FROM missing") D.Args.[])) ] in
    (match M.apply c failing with
     | Error { D.Error.context = Migration { version = 4; name = "backfill nicks" }; _ } -> ()
     | Error e -> failwith ("failing step: " ^ describe e)
     | Ok _ -> failwith "failing step: applied");
    assert (Int64.equal (count c "SELECT count(*) FROM users WHERE nick = email") 0L);
    assert (Int64.equal (count c "SELECT max(version) FROM duckdb_ml_migrations") 3L);
    assert (versions (ok (M.apply c base)) [ 4 ]));
  Stdlib.print_endline "migration: failing step rolls back alone, rerun applies it=ok"

(* History checks: each difference by its exact cause. *)
let () =
  let mismatch name steps ~after expected =
    connected (fun c ->
      ignore (ok (M.apply c steps));
      match M.apply c after with
      | Ok _ -> failwith (name ^ ": applied")
      | Error e -> if String.( <> ) (describe e) expected then
          failwith (Printf.sprintf "%s: %s\nexpected %s" name (describe e) expected)) in
  let sum s = Stdlib.Digest.to_hex (Stdlib.Digest.string s) in
  let create_t = "CREATE TABLE t(i INTEGER)" in
  let one = M.[ step 1 "create t" (sql create_t) ] in
  mismatch "edited" one ~after:M.[ step 1 "create t" (sql "CREATE TABLE t(i BIGINT)") ]
    (Printf.sprintf "[migration 1 create t] Migration_mismatch 1: expected 1 create t (%s), actual 1 create t (%s)"
       (sum "CREATE TABLE t(i BIGINT)") (sum create_t));
  mismatch "renamed" one ~after:M.[ step 1 "make t" (sql create_t) ]
    (Printf.sprintf "[migration 1 create t] Migration_mismatch 1: expected 1 make t (%s), actual 1 create t (%s)"
       (sum create_t) (sum create_t));
  mismatch "database ahead" one ~after:[]
    (Printf.sprintf "[migration 1 create t] Migration_mismatch 1: expected none, actual 1 create t (%s)" (sum create_t));
  mismatch "gap" M.[ step 2 "create t" (sql create_t) ] ~after:M.[ step 1 "first" (sql "SELECT 1"); step 2 "create t" (sql create_t) ]
    (Printf.sprintf "[migration 1 first] Migration_mismatch 1: expected 1 first (%s), actual none" (sum "SELECT 1"));
  Stdlib.print_endline "migration: edited, renamed, ahead and gap histories rejected=ok"

(* Versions must increase; a verify difference is reported after applying. *)
let () =
  connected (fun c ->
    invalid "duplicate versions" (fun () -> M.apply c M.[ step 1 "a" (sql "SELECT 1"); step 1 "b" (sql "SELECT 2") ]);
    invalid "decreasing versions" (fun () -> M.apply c M.[ step 2 "a" (sql "SELECT 1"); step 1 "b" (sql "SELECT 2") ]);
    (match M.apply c (List.take base 2) ~verify:M.[ table users ] with
     | Error { D.Error.context = Table { name = "users"; _ }; _ } -> ()
     | Error e -> failwith ("verify: " ^ describe e)
     | Ok _ -> failwith "verify: passed");
    assert (Int64.equal (count c "SELECT count(*) FROM duckdb_ml_migrations") 2L));
  Stdlib.print_endline "migration: version order checked, verify after applying=ok"
