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
  | Null { column; row } -> Printf.sprintf "Null column %d row %d" column row
  | Unknown_column { name } -> "Unknown_column " ^ name
  | Constraint_mismatch { constraint_kind; expected; actual } ->
    Printf.sprintf "Constraint_mismatch %s: expected %s, actual %s" constraint_kind expected actual
  | Decode_rejected { column; _ } -> Printf.sprintf "Decode_rejected column %d" column
  | Unsupported_statement -> "Unsupported_statement"
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

(* An expression smuggled out of its query is rejected when another query
   is built, even where the other table has a column of that name or the
   other query a parameter of that number. *)
let () =
  let leaked = ref None and parameter = ref None in
  ignore (S.(query Params.[int64] (fun [p] -> from users (fun [id; _; _] ->
    Stdlib.(leaked := Some id; parameter := Some (param p)); select Exprs.[id] ~row:Fn.id))));
  let other = T.(declare "others" Columns.["id", int64] ~row:Fn.id) in
  let rejected name build =
    match build () with
    | exception Invalid_argument _ -> ()
    | (_ : (int64 * unit, int64, R.many) R.t) -> failwith (name ^ ": accepted a foreign expression") in
  rejected "column" (fun () -> S.(query Params.[int64] (fun [p] -> from other (fun [id] ->
    select Exprs.[id] ~row:Fn.id ~where:(Option.value_exn !leaked = param p)))));
  rejected "parameter" (fun () -> S.(query Params.[int64] (fun [_] -> from other (fun [id] ->
    select Exprs.[id] ~row:Fn.id ~where:(id = Option.value_exn !parameter)))));
  Stdlib.print_endline "sql: an expression from another query is rejected when built=ok"

(* Review findings: a select list without an aggregate is not one row;
   operands must share a codec, so a string literal cannot meet a BLOB and a
   plain literal cannot meet a custom codec's column. *)
let () =
  let rejected name build = match build () with
    | exception Invalid_argument _ -> ()
    | (_ : (unit, _, _) R.t) -> failwith (name ^ ": accepted") in
  rejected "aggregate without an aggregate" (fun () ->
    S.(query Params.[] (fun [] -> from users (fun [_; _; _] -> aggregate Exprs.[int64 7L] ~row:Fn.id))));
  let blobs = T.(declare "blobs" Columns.["b", blob] ~row:Fn.id) in
  rejected "string literal against a BLOB" (fun () ->
    S.(query Params.[] (fun [] -> from blobs (fun [b] -> select Exprs.[b] ~row:Fn.id ~where:(b = string "\\xAA")))));
  let cents = D.Codec.Values.custom ~encode:(fun n -> Or_error.return (Int64.( * ) n 100L))
    ~decode:(fun n -> Or_error.return (Int64.( / ) n 100L)) D.Codec.Values.int64 in
  let prices = T.(declare "prices" Columns.["price", cents] ~row:Fn.id) in
  rejected "plain literal against a custom codec" (fun () ->
    S.(query Params.[] (fun [] -> from prices (fun [p] -> select Exprs.[p] ~row:Fn.id ~where:(p = int64 2L)))));
  rejected "coalesce of a custom codec with a plain literal" (fun () ->
    let nullable_prices = T.(declare "prices" Columns.["price", nullable cents] ~row:Fn.id) in
    S.(query Params.[] (fun [] -> from nullable_prices (fun [p] ->
      select Exprs.[coalesce p ~default:(int64 0L)] ~row:Fn.id))));
  (* The same custom codec on both sides, through a parameter, is accepted. *)
  ignore (S.(query Params.[cents] (fun [limit] -> from prices (fun [p] ->
    select Exprs.[p] ~row:Fn.id ~where:(p <= param limit)))));
  Stdlib.print_endline "sql: aggregate needs an aggregate; operands share a codec=ok"

(* Documented limitations, closed: a negative limit or offset is rejected
   when the query is built, not when DuckDB prepares it. *)
let () =
  let rejected name build = match build () with
    | exception Invalid_argument _ -> ()
    | (_ : (unit, _, _) R.t) -> failwith (name ^ ": accepted") in
  rejected "negative limit" (fun () ->
    S.(query Params.[] (fun [] -> from users (fun [id; _; _] -> select Exprs.[id] ~row:Fn.id ~limit:(-1)))));
  rejected "negative offset" (fun () ->
    S.(query Params.[] (fun [] -> from users (fun [id; _; _] -> select Exprs.[id] ~row:Fn.id ~offset:(-1)))));
  ignore (S.(query Params.[] (fun [] -> from users (fun [id; _; _] -> select Exprs.[id] ~row:Fn.id ~limit:0 ~offset:0))));
  Stdlib.print_endline "sql: negative limit and offset rejected when built=ok"

(* Query composition (sub-project 4a). Joins: aliases t0, t1, … in order of
   appearance; a LEFT JOIN's right columns decode as options through
   [outer]/[Null.outer]. *)
let posts = T.(declare "posts" Columns.["id", int64; "owner", int64; "title", string; "score", nullable int32]
  ~row:(fun id owner title score -> (id, owner, title, score)))
let comments = T.(declare "comments" Columns.["id", int64; "post", int64; "body", nullable string]
  ~row:(fun id post body -> (id, post, body)))
let seed_posts c =
  seed c;
  ddl c "CREATE TABLE posts(id BIGINT NOT NULL, owner BIGINT NOT NULL, title VARCHAR NOT NULL, score INTEGER)";
  ddl c "INSERT INTO posts VALUES (10, 1, 'intro', 5), (11, 1, 'more', NULL), (12, 3, 'hello', 2)";
  ddl c "CREATE TABLE comments(id BIGINT NOT NULL, post BIGINT NOT NULL, body VARCHAR)";
  ddl c "INSERT INTO comments VALUES (100, 10, 'nice'), (101, 10, NULL), (102, 12, 'hi')"
let titles = S.(
  query Params.[] (fun [] ->
    from users (fun [uid; name; _] ->
      join posts ~on:(fun [_; owner; _; _] -> owner = uid) (fun [pid; _; title; _] ->
        select Exprs.[name; title] ~row:(fun n t -> (n, t)) ~order_by:[asc pid]))))
let with_posts = S.(
  query Params.[] (fun [] ->
    from users (fun [uid; name; _] ->
      left_join posts ~on:(fun [_; owner; _; _] -> owner = uid) (fun [pid; _; title; score] ->
        select Exprs.[name; outer title; Null.outer score] ~row:(fun n t s -> (n, t, s))
          ~order_by:[asc uid; asc (outer pid)]))))
let threads = S.(
  query Params.[] (fun [] ->
    from users (fun [uid; name; _] ->
      join posts ~on:(fun [_; owner; _; _] -> owner = uid) (fun [pid; _; title; _] ->
        left_join comments ~on:(fun [_; post; _] -> post = pid) (fun [cid; _; body] ->
          select Exprs.[name; title; Null.outer body] ~row:(fun n t b -> (n, t, b))
            ~order_by:[asc pid; asc (outer cid)])))))
let pairs = S.(
  query Params.[] (fun [] ->
    from users (fun [_; _; _] -> cross_join posts (fun [_; _; _; _] -> aggregate Exprs.[count_star] ~row:Fn.id))))
let names = S.(
  query Params.[] (fun [] ->
    from users (fun [_; name; _] -> select Exprs.[name] ~distinct:true ~row:Fn.id ~order_by:[asc name])))
let () =
  expect_sql "titles" titles
    "SELECT t0.\"name\", t1.\"title\" FROM \"main\".\"users\" AS t0 \
     INNER JOIN \"main\".\"posts\" AS t1 ON (t1.\"owner\" = t0.\"id\") ORDER BY t1.\"id\" ASC";
  expect_sql "threads" threads
    "SELECT t0.\"name\", t1.\"title\", t2.\"body\" FROM \"main\".\"users\" AS t0 \
     INNER JOIN \"main\".\"posts\" AS t1 ON (t1.\"owner\" = t0.\"id\") \
     LEFT JOIN \"main\".\"comments\" AS t2 ON (t2.\"post\" = t1.\"id\") ORDER BY t1.\"id\" ASC, t2.\"id\" ASC";
  expect_sql "pairs" pairs
    "SELECT count(*) FROM \"main\".\"users\" AS t0 CROSS JOIN \"main\".\"posts\" AS t1";
  expect_sql "names" names "SELECT DISTINCT t0.\"name\" FROM \"main\".\"users\" AS t0 ORDER BY t0.\"name\" ASC";
  connected (fun c ->
    seed_posts c;
    (match ok (R.Session.collect c titles D.Args.[]) with
     | [ ("ada", "intro"); ("ada", "more"); ("cy", "hello") ] -> ()
     | _ -> failwith "titles");
    (match ok (R.Session.collect c with_posts D.Args.[]) with
     | [ ("ada", Some "intro", Some 5l); ("ada", Some "more", None); ("bob", None, None);
         ("cy", Some "hello", Some 2l); ("ada", None, None) ] -> ()
     | _ -> failwith "with_posts");
    (match ok (R.Session.collect c threads D.Args.[]) with
     | [ ("ada", "intro", Some "nice"); ("ada", "intro", None); ("ada", "more", None); ("cy", "hello", Some "hi") ] -> ()
     | _ -> failwith "threads");
    (* Inside a join an aggregate is [many] by type; it returns one row. *)
    (match ok (R.Session.collect c pairs D.Args.[]) with [ 12L ] -> () | _ -> failwith "pairs");
    (match ok (R.Session.collect c names D.Args.[]) with
     | [ "ada"; "bob"; "cy" ] -> ()
     | _ -> failwith "names"));
  (* Aliases do not depend on scope ids: building twice gives one text. *)
  let build () = S.(query Params.[] (fun [] -> from users (fun [uid; _; _] ->
    join posts ~on:(fun [_; owner; _; _] -> owner = uid) (fun [pid; _; _; _] -> select Exprs.[pid] ~row:Fn.id)))) in
  assert (String.equal (R.query (build ())) (R.query (build ())));
  (* A join binder smuggled into another query is foreign there. *)
  let leaked = ref None in
  ignore (S.(query Params.[] (fun [] -> from users (fun [uid; _; _] ->
    join posts ~on:(fun [_; owner; _; _] -> owner = uid) (fun [pid; _; _; _] ->
      Stdlib.(leaked := Some pid); select Exprs.[pid] ~row:Fn.id)))));
  (match S.(query Params.[] (fun [] -> from users (fun [id; _; _] ->
     select Exprs.[id] ~row:Fn.id ~where:(id = Option.value_exn !leaked)))) with
   | exception Invalid_argument _ -> ()
   | _ -> failwith "leaked join binder accepted");
  Stdlib.print_endline "sql: inner, left (outer), cross and nested joins; distinct; stable aliases=ok"

(* value: literals of any codec, encoded when built; a custom codec's value
   meets its column; an encode error is rejected when built. Dates and
   timestamps: test_sql_time_zone.ml, run under a non-UTC TZ. *)
let () =
  let module V = D.Codec.Values in
  let cents = V.custom ~encode:(fun n -> Or_error.return (Int64.( * ) n 100L))
    ~decode:(fun n -> Or_error.return (Int64.( / ) n 100L)) V.int64 in
  let prices = T.(declare "prices" Columns.["price", cents] ~row:Fn.id) in
  let cheap = S.(query Params.[] (fun [] -> from prices (fun [p] -> select Exprs.[p] ~row:Fn.id ~where:(p = value cents 2L)))) in
  expect_sql "cheap" cheap
    "SELECT t0.\"price\" FROM \"main\".\"prices\" AS t0 WHERE (t0.\"price\" = CAST(200 AS BIGINT))";
  connected (fun c ->
    ddl c "CREATE TABLE prices(price BIGINT NOT NULL)";
    ddl c "INSERT INTO prices VALUES (200), (300)";
    match ok (R.Session.collect c cheap D.Args.[]) with [ 2L ] -> () | _ -> failwith "cheap");
  let refusing = V.custom ~encode:(fun (_ : int64) -> Or_error.error_string "no") ~decode:Or_error.return V.int64 in
  (match S.value refusing 1L with
   | exception Invalid_argument _ -> ()
   | (_ : (int64, D.Codec.non_null, S.row) S.expr) -> failwith "encode error accepted");
  (* As a table default: a timestamp value is an expression (create accepts
     it; add_column, which needs a constant, rejects it); a blob value is a
     constant. *)
  let events = T.(declare "events" Columns.["id", int64; "at", timestamp_us; "tag", blob]
    ~row:(fun id at tag -> (id, at, tag))
    ~constraints:(fun [_; at; tag] -> Constraint.[
      default at (S.value V.timestamp_us 1700000000123456L); default tag (S.value V.blob "\x01'") ])) in
  connected (fun c ->
    ok (T.create c events);
    ddl c "INSERT INTO events (id) VALUES (1)";
    (match ok (R.Session.collect c (T.select events) D.Args.[]) with
     | [ (1L, 1700000000123456L, "\x01'") ] -> ()
     | _ -> failwith "event defaults");
    ok (T.verify c events));
  (match D.Migration.add_column events (fun [_; at; _] -> D.Migration.Column at) with
   | exception Invalid_argument _ -> ()
   | _ -> failwith "add_column with an expression default accepted");
  ignore (D.Migration.add_column events (fun [_; _; tag] -> D.Migration.Column tag));
  Stdlib.print_endline "sql: value literals of every scalar and custom codecs=ok"

(* Subqueries: correlated exists and scalar; in_ is three-valued; misuse
   rejected when built. *)
let active = S.(
  query Params.[] (fun [] ->
    from users (fun [uid; name; _] ->
      select Exprs.[name; scalar (from posts (fun [_; owner; _; _] ->
                             aggregate Exprs.[count_star] ~row:Fn.id ~where:(owner = uid)))]
        ~row:(fun n c -> (n, c)) ~order_by:[asc uid]
        ~where:(exists (from posts (fun [_; owner; _; _] -> select Exprs.[owner] ~row:Fn.id ~where:(owner = uid)))))))
let best = S.(
  query Params.[] (fun [] ->
    from users (fun [uid; _; _] ->
      select Exprs.[uid; Null.scalar (from posts (fun [_; owner; _; score] ->
                             aggregate Exprs.[Null.max score] ~row:Fn.id ~where:(owner = uid)))]
        ~row:(fun u s -> (u, s)) ~order_by:[asc uid])))
let scored = S.(
  query Params.[] (fun [] ->
    from users (fun [uid; _; age] ->
      select Exprs.[uid; in_ age (from posts (fun [_; _; _; score] -> select Exprs.[score] ~row:Fn.id))]
        ~row:(fun u m -> (u, m)) ~order_by:[asc uid])))
let () =
  expect_sql "active" active
    "SELECT t0.\"name\", (SELECT count(*) FROM \"main\".\"posts\" AS t1 WHERE (t1.\"owner\" = t0.\"id\")) \
     FROM \"main\".\"users\" AS t0 WHERE EXISTS (SELECT t2.\"owner\" FROM \"main\".\"posts\" AS t2 \
     WHERE (t2.\"owner\" = t0.\"id\")) ORDER BY t0.\"id\" ASC";
  connected (fun c ->
    seed_posts c;
    (match ok (R.Session.collect c active D.Args.[]) with
     | [ ("ada", Some 2L); ("cy", Some 1L) ] -> ()
     | _ -> failwith "active");
    (match ok (R.Session.collect c best D.Args.[]) with
     | [ (1L, Some 5l); (2L, None); (3L, Some 2l); (4L, None) ] -> ()
     | _ -> failwith "best");
    (* Scores are 5, NULL, 2: age 36 does not match, and the NULL makes it
       NULL, not false; a NULL age is NULL. *)
    ddl c "UPDATE users SET age = 5 WHERE id = 3";
    (match ok (R.Session.collect c scored D.Args.[]) with
     | [ (1L, None); (2L, None); (3L, Some true); (4L, None) ] -> ()
     | _ -> failwith "scored"));
  let rejected name build = match build () with
    | exception Invalid_argument _ -> ()
    | (_ : (unit, _, _) R.t) -> failwith (name ^ ": accepted") in
  rejected "scalar of a nullable column" (fun () -> S.(query Params.[] (fun [] -> from users (fun [_; _; _] ->
    select Exprs.[scalar (from posts (fun [_; _; _; score] -> aggregate Exprs.[Null.max score] ~row:Fn.id))]
      ~row:Fn.id))));
  (* Only a non-null custom codec has an option type without being nullable. *)
  let some = D.Codec.Values.custom ~encode:(fun o -> Or_error.of_option o ~error:(Error.of_string "none"))
    ~decode:(fun n -> Or_error.return (Some n)) D.Codec.Values.int64 in
  rejected "Null.scalar of a non-null column" (fun () -> S.(query Params.[] (fun [] -> from users (fun [_; _; _] ->
    select Exprs.[Null.scalar (from users (fun [_; _; _] ->
      aggregate Exprs.[coalesce (max (value some (Some 1L))) ~default:(value some (Some 1L))] ~row:Fn.id))]
      ~row:Fn.id))));
  let tagged = T.(declare "tagged" Columns.["tag", blob] ~row:Fn.id) in
  rejected "in_ of a BLOB column for a VARCHAR" (fun () -> S.(query Params.[] (fun [] -> from users (fun [_; name; _] ->
    select Exprs.[name] ~row:Fn.id ~where:(is_true (in_ name (from tagged (fun [tag] -> select Exprs.[tag] ~row:Fn.id))))))));
  Stdlib.print_endline "sql: exists, in_ (three-valued), scalar and Null.scalar subqueries=ok"

(* Set operations: each side keeps its ORDER BY and LIMIT; they nest and
   serve as subqueries; codecs must match. *)
let () =
  let ids order = S.(from users (fun [uid; _; _] -> select Exprs.[uid] ~row:Fn.id ~order_by:[order uid] ~limit:1)) in
  let owners = S.(from posts (fun [_; owner; _; _] -> select Exprs.[owner] ~row:Fn.id)) in
  let run c source = ok (R.Session.collect c S.(query Params.[] (fun [] -> source)) D.Args.[]) in
  let sorted = List.sort ~compare:Int64.compare in
  let union_sql = R.query S.(query Params.[] (fun [] -> union_all (ids asc) (ids desc))) in
  if String.( <> ) union_sql
       "(SELECT t0.\"id\" FROM \"main\".\"users\" AS t0 ORDER BY t0.\"id\" ASC LIMIT 1) UNION ALL \
        (SELECT t1.\"id\" FROM \"main\".\"users\" AS t1 ORDER BY t1.\"id\" DESC LIMIT 1)" then failwith union_sql;
  connected (fun c ->
    seed_posts c;
    assert (List.equal Int64.equal (run c S.(union_all (ids asc) (ids desc))) [ 1L; 4L ]);
    assert (List.equal Int64.equal (sorted (run c S.(union owners owners))) [ 1L; 3L ]);
    assert (List.equal Int64.equal (sorted (run c S.(union_all owners owners))) [ 1L; 1L; 1L; 1L; 3L; 3L ]);
    assert (List.equal Int64.equal (sorted (run c S.(intersect (from users (fun [uid; _; _] ->
      select Exprs.[uid] ~row:Fn.id)) owners))) [ 1L; 3L ]);
    assert (List.equal Int64.equal (sorted (run c S.(except_ (from users (fun [uid; _; _] ->
      select Exprs.[uid] ~row:Fn.id)) owners))) [ 2L; 4L ]);
    assert (List.equal Int64.equal (sorted (run c S.(union (union_all (ids asc) (ids desc)) owners))) [ 1L; 3L; 4L ]);
    let posting = S.(query Params.[] (fun [] -> from users (fun [uid; _; _] ->
      select Exprs.[uid] ~row:Fn.id ~order_by:[asc uid] ~where:(is_true (in_ uid (union owners owners)))))) in
    assert (List.equal Int64.equal (ok (R.Session.collect c posting D.Args.[])) [ 1L; 3L ]));
  let tags = T.(declare "tags" Columns.["tag", blob] ~row:Fn.id) in
  match S.(union (from users (fun [_; name; _] -> select Exprs.[name] ~row:Fn.id))
             (from tags (fun [tag] -> select Exprs.[tag] ~row:Fn.id))) with
  | exception Invalid_argument _ -> Stdlib.print_endline "sql: union, union all, intersect, except; nesting; codecs match=ok"
  | _ -> failwith "union of VARCHAR and BLOB accepted"

(* Named binders: [Table.fields] handles name the same binders as positional
   patterns, so each named query renders the positional text and rows. *)
let S.Named.[u_id; u_name; _] = T.fields users
let S.Named.[p_id; p_owner; p_title; p_score] = T.fields posts
let titles_named = S.(
  query Params.[] (fun [] ->
    from users (fun u ->
      join posts ~on:(fun p -> p.%(p_owner) = u.%(u_id)) (fun p ->
        select Exprs.[u.%(u_name); p.%(p_title)] ~row:(fun n t -> (n, t)) ~order_by:[asc p.%(p_id)]))))
let with_posts_named = S.(
  query Params.[] (fun [] ->
    from users (fun u ->
      left_join posts ~on:(fun p -> p.%(p_owner) = u.%(u_id)) (fun p ->
        select Exprs.[u.%(u_name); outer p.%?(p_title); Null.outer p.%?(p_score)] ~row:(fun n t s -> (n, t, s))
          ~order_by:[asc u.%(u_id); asc (outer p.%?(p_id))]))))
let () =
  expect_sql "titles_named" titles_named (R.query titles);
  expect_sql "with_posts_named" with_posts_named (R.query with_posts);
  connected (fun c ->
    seed_posts c;
    assert (Poly.equal (ok (R.Session.collect c titles_named D.Args.[])) (ok (R.Session.collect c titles D.Args.[])));
    assert (Poly.equal (ok (R.Session.collect c with_posts_named D.Args.[]))
              (ok (R.Session.collect c with_posts D.Args.[]))));
  Stdlib.print_endline "sql: named binders in from, join and left join match positional=ok"
