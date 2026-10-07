open! Base
module D = Duckdb
module R = D.Request
module T = D.Table
module S = D.Sql
let rec describe (e : D.Error.t) = match e.cause with
  | Native s -> "Native: " ^ s
  | Parameter_count { expected; actual } -> Printf.sprintf "Parameter_count %d/%d" expected actual
  | Column_count _ -> "Column_count" | Type_mismatch { expected; actual; _ } -> "Type_mismatch " ^ expected ^ "/" ^ actual
  | Rollback_failed { primary; _ } -> "Rollback_failed: " ^ describe primary
  | _ -> "other cause"
let ok = function Ok x -> x | Error e -> failwith ("unexpected error: " ^ describe e)
let core_ok = function Ok x -> x | Error e -> failwith ("unexpected core error: " ^ describe e)
let clean () = assert (Duckdb_ffi.live_resources () = 0); assert (Duckdb_ffi.fallback_reclaims () = 0)
(* Owned handles are global: callbacks may capture them. *)
let connected f =
  let db = core_ok (D.Owned.open_database (core_ok (D.Config.create Memory))) in
  Exn.protect ~finally:(fun () -> core_ok (D.Owned.close_database db)) ~f:(fun () ->
    let c = core_ok (D.Owned.connect db) in
    Exn.protect ~finally:(fun () -> core_ok (D.Owned.close_connection c)) ~f:(fun () -> f c));
  clean ()
let ddl c sql = ok (R.Session.exec c (R.exec D.Fields.[] sql) D.Args.[])
let expect_sql name request expected =
  if String.( <> ) (R.query request) expected then
    failwith (Printf.sprintf "%s: rendered\n  %s\nexpected\n  %s" name (R.query request) expected)


let users = T.(declare "users" Columns.["id", int64; "name", string; "age", nullable int32]
  ~row:(fun id name age -> (id, name, age)))
let seed c =
  ddl c "CREATE TABLE users(id BIGINT NOT NULL, name VARCHAR NOT NULL, age INTEGER)";
  ddl c "INSERT INTO users VALUES (1, 'ada', 36), (2, 'bob', NULL), (3, 'cy', 17), (4, 'ada', 50)"

let adults = S.(
  query Params.[int32] (fun [min_age] ->
    from users (fun [id; name; age] ->
      select Exprs.[id; name] ~row:(fun id name -> (id, name))
        ~where:(is_true Null.(age >= nullable (param min_age)))
        ~order_by:[asc id] ~limit:100)))
let by_name = S.(
  query Params.[] (fun [] ->
    from users (fun [_; name; age] ->
      group_by Keys.[name] (fun [name] ->
        select Exprs.[name; count_star; Null.max age] ~row:(fun n c m -> (n, c, m))
          ~having:(count_star > int64 1L)))))
let total = S.(
  query Params.[] (fun [] -> from users (fun [id; _; _] -> aggregate Exprs.[count id] ~row:Fn.id)))

let () =
  expect_sql "adults" adults
    "SELECT t0.\"id\", t0.\"name\" FROM \"main\".\"users\" AS t0 \
     WHERE ((t0.\"age\" >= CAST($1 AS INTEGER)) IS TRUE) ORDER BY t0.\"id\" ASC LIMIT 100";
  expect_sql "by_name" by_name
    "SELECT t0.\"name\", count(*), max(t0.\"age\") FROM \"main\".\"users\" AS t0 \
     GROUP BY t0.\"name\" HAVING (count(*) > CAST(1 AS BIGINT))";
  expect_sql "total" total "SELECT count(t0.\"id\") FROM \"main\".\"users\" AS t0";
  connected (fun c ->
    seed c;
    assert (List.equal (fun (a, b) (c, d) -> Int64.equal a c && String.equal b d)
      (ok (R.Session.collect c adults D.Args.[18l])) [ (1L, "ada"); (4L, "ada") ]);
    (match ok (R.Session.collect c by_name D.Args.[]) with
     | [ ("ada", 2L, Some 50l) ] -> ()
     | _ -> failwith "by_name");
    assert (Int64.equal (ok (R.Session.find c total D.Args.[])) 4L));
  Stdlib.print_endline "sql: README examples render and run=ok"

(* Three-valued logic: a NULL operand gives None; is_true filters it out;
   coalesce substitutes; is_null tests. *)
let nulls = S.(
  query Params.[] (fun [] ->
    from users (fun [id; _; age] ->
      select Exprs.[id; Null.(age >= nullable (int32 18l)); coalesce age ~default:(int32 0l); is_null age]
        ~row:(fun id adult age missing -> (id, adult, age, missing)) ~order_by:[asc id])))
let () =
  connected (fun c ->
    seed c;
    match ok (R.Session.collect c nulls D.Args.[]) with
    | [ (1L, Some true, 36l, false); (2L, None, 0l, true); (3L, Some false, 17l, false); (4L, Some true, 50l, false) ] -> ()
    | _ -> failwith "nulls");
  Stdlib.print_endline "sql: Null comparisons, coalesce, is_null=ok"

(* Strings: literal escaping, like, desc order, limit and offset, a quoted
   column name. *)
let quoted = T.(declare "odd \"names\"" Columns.["the \"key\"", string] ~row:Fn.id)
let matching = S.(
  query Params.[string] (fun [pattern] ->
    from quoted (fun [key] ->
      select Exprs.[key] ~row:Fn.id ~where:(like key (param pattern) || key = string "it's")
        ~order_by:[desc key] ~limit:2 ~offset:1)))
let () =
  expect_sql "matching" matching
    "SELECT t0.\"the \"\"key\"\"\" FROM \"main\".\"odd \"\"names\"\"\" AS t0 \
     WHERE ((t0.\"the \"\"key\"\"\" LIKE CAST($1 AS VARCHAR)) OR (t0.\"the \"\"key\"\"\" = 'it''s')) \
     ORDER BY t0.\"the \"\"key\"\"\" DESC LIMIT 2 OFFSET 1";
  connected (fun c ->
    ddl c "CREATE TABLE \"odd \"\"names\"\"\"(\"the \"\"key\"\"\" VARCHAR NOT NULL)";
    ddl c "INSERT INTO \"odd \"\"names\"\"\" VALUES ('apple'), ('apricot'), ('avocado'), ('it''s'), ('banana')";
    assert (List.equal String.equal (ok (R.Session.collect c matching D.Args.["a%"])) [ "avocado"; "apricot" ]));
  Stdlib.print_endline "sql: quoting, string literals, like, desc, limit, offset=ok"

(* Arithmetic keeps the operand type; integer division by zero is NULL;
   floats use IEEE division; literals round-trip. *)
let numbers = T.(declare "numbers"
  Columns.["i8", int8; "i16", int16; "i32", int32; "i64", int64; "f32", float32; "f64", float64]
  ~row:(fun _ _ _ _ _ _ -> ()))
let arithmetic = S.(
  query Params.[] (fun [] ->
    from numbers (fun [i8; i16; i32; i64; f32; f64] ->
      select ~order_by:[asc i64]
        Exprs.[ I8.(i8 + int8 1s); I16.(i16 * int16 2S); I32.(i32 - int32 1l); i64 / int64 0L; i64 / int64 2L;
                F32.(f32 / float32 2.0s); f64 /. float64 0.0; f64 +. float64 Float.nan ]
        ~row:(fun a b c d e f g h -> (a, b, c, d, e, f, g, h)))))
let () =
  connected (fun c ->
    ddl c "CREATE TABLE numbers(i8 TINYINT NOT NULL, i16 SMALLINT NOT NULL, i32 INTEGER NOT NULL, \
           i64 BIGINT NOT NULL, f32 FLOAT NOT NULL, f64 DOUBLE NOT NULL)";
    ddl c "INSERT INTO numbers VALUES (1, 2, 3, 7, 1.5, 2.0)";
    match ok (R.Session.collect c arithmetic D.Args.[]) with
    | [ (a, b, c', None, Some 3L, f, g, h) ] ->
      assert (Stdlib_stable.Int8.to_int a = 2 && Stdlib_stable.Int16.to_int b = 4 && Int32.equal c' 2l);
      assert (Float.equal (Stdlib_stable.Float32.to_float f) 0.75);
      assert (Float.is_inf g && Float.is_nan h)
    | _ -> failwith "arithmetic");
  Stdlib.print_endline "sql: per-type arithmetic, integer division by zero is NULL, float literals=ok"

(* Aggregates over no rows are NULL, count is zero; sum is cast back to
   the input type. *)
let summary = S.(
  query Params.[int64] (fun [floor] ->
    from numbers (fun [_; _; i32; i64; _; f64] ->
      aggregate Exprs.[count_star; sum i64; I32.sum i32; min i64; max f64; avg i64; F64.avg f64]
        ~where:(i64 > param floor)
        ~row:(fun n s s32 lo hi a af -> (n, s, s32, lo, hi, a, af)))))
let () =
  expect_sql "summary" summary
    "SELECT count(*), CAST(sum(t0.\"i64\") AS BIGINT), CAST(sum(t0.\"i32\") AS INTEGER), min(t0.\"i64\"), \
     max(t0.\"f64\"), CAST(avg(t0.\"i64\") AS DOUBLE), CAST(avg(t0.\"f64\") AS DOUBLE) \
     FROM \"main\".\"numbers\" AS t0 WHERE (t0.\"i64\" > CAST($1 AS BIGINT))";
  connected (fun c ->
    ddl c "CREATE TABLE numbers(i8 TINYINT NOT NULL, i16 SMALLINT NOT NULL, i32 INTEGER NOT NULL, \
           i64 BIGINT NOT NULL, f32 FLOAT NOT NULL, f64 DOUBLE NOT NULL)";
    (match ok (R.Session.find c summary D.Args.[0L]) with
     | (0L, None, None, None, None, None, None) -> ()
     | _ -> failwith "empty summary");
    ddl c "INSERT INTO numbers VALUES (1, 2, 3, 7, 1.5, 2.0), (1, 2, 5, 9, 1.5, 4.0)";
    match ok (R.Session.find c summary D.Args.[0L]) with
    | (2L, Some 16L, Some 8l, Some 7L, Some 4.0, Some 8.0, Some 3.0) -> ()
    | _ -> failwith "summary");
  Stdlib.print_endline "sql: aggregate is one row, empty aggregates are NULL, sum keeps its type=ok"

(* A parameter is reusable and serves row and grouped contexts; a custom
   codec column and parameter compare through the base type. *)
let user_id = D.Codec.Values.custom ~encode:(fun (`User n) -> Or_error.return n)
  ~decode:(fun n -> Or_error.return (`User n)) D.Codec.Values.int64
let owners = T.(declare "users" Columns.["id", user_id; "name", string; "age", nullable int32]
  ~row:(fun id name age -> (id, name, age)))
let shared = S.(
  query Params.[user_id; int64] (fun [who; n] ->
    from owners (fun [id; name; _] ->
      group_by Keys.[name] (fun [name] ->
        select Exprs.[name; count_star] ~row:(fun name n -> (name, n))
          ~where:(id <> param who) ~having:(count_star >= param n)))))
let () =
  connected (fun c ->
    seed c;
    match ok (R.Session.collect c shared D.Args.[`User 4L; 1L]) with
    | rows ->
      let rows = List.sort rows ~compare:(fun (a, _) (b, _) -> String.compare a b) in
      assert (List.equal (fun (a, b) (c, d) -> String.equal a c && Int64.equal b d) rows
        [ ("ada", 1L); ("bob", 1L); ("cy", 1L) ]));
  Stdlib.print_endline "sql: custom codecs, one parameter in row and grouped contexts=ok"

(* Generated requests share the statement cache and validation of
   hand-written ones: twice on one connection, and a declaration the
   catalog disagrees with reports the same error as Table.select. *)
let () =
  connected (fun c ->
    seed c;
    assert (List.length (ok (R.Session.collect c adults D.Args.[18l])) = 2);
    assert (List.length (ok (R.Session.collect c adults D.Args.[40l])) = 1);
    let wrong = T.(declare "users" Columns.["id", int32] ~row:Fn.id) in
    let generated = S.(query Params.[] (fun [] -> from wrong (fun [id] -> select Exprs.[id] ~row:Fn.id))) in
    let mismatch r = match R.Session.collect c r D.Args.[] with
      | Error { D.Error.cause = Type_mismatch { expected = "INTEGER"; actual = "BIGINT"; _ }; _ } -> ()
      | Error e -> failwith ("mismatch: " ^ describe e)
      | Ok _ -> failwith "mismatch: accepted" in
    mismatch (T.select wrong);
    mismatch generated);
  Stdlib.print_endline "sql: statement cache reuse, catalog mismatch as Table.select=ok"
