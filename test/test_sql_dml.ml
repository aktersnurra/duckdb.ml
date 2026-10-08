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
  | Unsupported_statement -> "Unsupported_statement"
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
let ddl c sql = ok (R.Session.exec c (R.exec D.Fields.[] sql) D.Args.[])
let count c sql = ok (R.Session.find c (R.one D.Fields.[] D.Fields.[int64] ~row:Fn.id sql) D.Args.[])
let expect_sql name request expected =
  if String.( <> ) (R.query request) expected then
    failwith (Printf.sprintf "%s: rendered\n  %s\nexpected\n  %s" name (R.query request) expected)
let rejected name build = match build () with
  | exception Invalid_argument _ -> ()
  | (_ : (_, _, _) R.t) -> failwith (name ^ ": accepted")

let users = T.(declare "users" Columns.["id", int64; "name", string; "age", nullable int32]
  ~row:(fun id name age -> (id, name, age)))
let posts = T.(declare "posts" Columns.["id", int64; "owner", int64; "title", string]
  ~row:(fun id owner title -> (id, owner, title)))
let seed c =
  ddl c "CREATE SEQUENCE user_ids START 10";
  ddl c "CREATE TABLE users(id BIGINT PRIMARY KEY DEFAULT nextval('user_ids'), name VARCHAR NOT NULL DEFAULT 'anon', age INTEGER)";
  ddl c "INSERT INTO users VALUES (1, 'ada', 36), (2, 'bob', NULL), (3, 'cy', 17)";
  ddl c "CREATE TABLE posts(id BIGINT NOT NULL, owner BIGINT NOT NULL, title VARCHAR NOT NULL)";
  ddl c "INSERT INTO posts VALUES (10, 1, 'intro'), (11, 3, 'hello')"

(* UPDATE and DELETE: the affected-row count, or typed RETURNING rows. *)
let rename = S.(command Params.[int64; string] (fun [id; name] ->
  update users (fun [uid; uname; _] -> set [uname := param name] ~where:(uid = param id))))
let age_posters = S.(command Params.[] (fun [] ->
  update users (fun [uid; _; age] ->
    set [age := nullable (int32 99l)]
      ~where:(exists (from posts (fun [_; owner; _] -> select Exprs.[owner] ~row:Fn.id ~where:(owner = uid)))))))
let renamed = S.(command Params.[string] (fun [name] ->
  update users (fun [uid; uname; _] -> set [uname := param name] ~where:(uid > int64 1L)
    |> returning Exprs.[uid; uname] ~row:(fun i n -> (i, n)))))
let purge = S.(command Params.[] (fun [] -> delete users (fun [_; _; age] -> filter (is_null age))))
let purged = S.(command Params.[] (fun [] ->
  delete users (fun [uid; uname; _] -> all |> returning Exprs.[uid; uname] ~row:(fun i n -> (i, n)))))
let () =
  expect_sql "rename" rename
    "UPDATE \"main\".\"users\" AS t0 SET \"name\" = CAST($2 AS VARCHAR) WHERE (t0.\"id\" = CAST($1 AS BIGINT))";
  expect_sql "purge" purge "DELETE FROM \"main\".\"users\" AS t0 WHERE (t0.\"age\" IS NULL)";
  expect_sql "purged" purged "DELETE FROM \"main\".\"users\" AS t0 RETURNING t0.\"id\", t0.\"name\"";
  connected (fun c ->
    seed c;
    assert (Int64.equal (ok (R.Session.find c rename D.Args.[1L; "ada lovelace"])) 1L);
    assert (Int64.equal (ok (R.Session.find c rename D.Args.[42L; "nobody"])) 0L);
    assert (Int64.equal (ok (R.Session.find c age_posters D.Args.[])) 2L);
    assert (Int64.equal (count c "SELECT count(*) FROM users WHERE age = 99") 2L);
    (match List.sort ~compare:Poly.compare (ok (R.Session.collect c renamed D.Args.["x"])) with
     | [ (2L, "x"); (3L, "x") ] -> ()
     | _ -> failwith "renamed");
    assert (Int64.equal (ok (R.Session.find c purge D.Args.[])) 1L);
    (match List.sort ~compare:Poly.compare (ok (R.Session.collect c purged D.Args.[])) with
     | [ (1L, "ada lovelace"); (3L, "x") ] -> ()
     | _ -> failwith "purged");
    assert (Int64.equal (count c "SELECT count(*) FROM users") 0L));
  let cents = D.Codec.Values.custom ~encode:(fun n -> Or_error.return (Int64.( * ) n 100L))
    ~decode:(fun n -> Or_error.return (Int64.( / ) n 100L)) D.Codec.Values.int64 in
  let prices = T.(declare "prices" Columns.["price", cents] ~row:Fn.id) in
  rejected "a target that is not a column" (fun () -> S.(command Params.[] (fun [] ->
    update users (fun [uid; _; _] -> set [I64.(uid + int64 1L) := int64 2L]))));
  (* A users column smuggled into an update of posts. *)
  let leaked = ref None in
  ignore (S.(command Params.[] (fun [] -> update users (fun [uid; _; _] ->
    Stdlib.(leaked := Some uid); set [uid := int64 2L]))));
  rejected "a column of another table" (fun () -> S.(command Params.[] (fun [] ->
    update posts (fun [_; owner; _] -> set [Option.value_exn !leaked := owner]))));
  rejected "a duplicate target" (fun () -> S.(command Params.[] (fun [] ->
    update users (fun [_; uname; _] -> set [uname := string "a"; uname := string "b"]))));
  rejected "an empty set" (fun () -> S.(command Params.[] (fun [] -> update users (fun [_; _; _] -> set []))));
  rejected "a plain literal for a custom codec" (fun () -> S.(command Params.[] (fun [] ->
    update prices (fun [p] -> set [p := int64 2L]))));
  ignore (S.(command Params.[] (fun [] -> update prices (fun [p] -> set [p := value cents 2L]))));
  Stdlib.print_endline "dml: update and delete counts, returning, correlated where, misuse rejected=ok"
