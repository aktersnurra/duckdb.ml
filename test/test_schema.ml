open! Base
module D = Duckdb
module R = D.Request
module T = D.Table
module S = D.Sql
let rec describe (e : D.Error.t) = match e.cause with
  | Native s -> "Native: " ^ s
  | Unknown_table { schema; name } -> "Unknown_table " ^ schema ^ "." ^ name
  | Constraint_mismatch { constraint_kind; expected; actual } ->
    Printf.sprintf "Constraint_mismatch %s: expected %s, actual %s" constraint_kind expected actual
  | Unknown_column { name } -> "Unknown_column " ^ name | Missing_column { name } -> "Missing_column " ^ name
  | Type_mismatch { expected; actual; _ } -> "Type_mismatch " ^ expected ^ "/" ^ actual
  | Row_count _ -> "Row_count"
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
let ddl c sql = ok (R.Session.exec c (R.exec D.Fields.[] sql) D.Args.[])
let invalid name f = match f () with
  | exception Invalid_argument _ -> ()
  | _ -> failwith (name ^ ": accepted")

let users = T.(declare "users"
  Columns.["id", int64; "email", string; "age", nullable int32]
  ~row:(fun id email age -> (id, email, age))
  ~constraints:(fun [id; email; age] -> Constraint.[
    primary_key Key.[id];
    unique Key.[email];
    default age S.(nullable (int32 18l));
    check S.(is_true Null.(column age >= nullable (int32 0l))) ]))
let posts = T.(declare "posts"
  Columns.["id", int64; "owner", int64; "title", string]
  ~row:(fun id owner title -> (id, owner, title))
  ~constraints:(fun [id; owner; _] -> Constraint.[
    primary_key Key.[id];
    foreign_key Key.[owner] ~references:(users, fun [id; _; _] -> Key.[id]) ]))
let by_email = T.lookup users (fun [_; email; _] -> T.Key.[email])

(* The generated DDL, read back from the context of a second, failing create. *)
let created_sql c table =
  ok (T.create c table);
  match T.create c table with
  | Error { D.Error.context = Query sql; cause = Native _ } -> sql
  | Error e -> failwith ("second create: " ^ describe e)
  | Ok () -> failwith "second create succeeded"
let () =
  connected (fun c ->
    let expect name actual expected =
      if String.( <> ) actual expected then failwith (Printf.sprintf "%s:\n  %s\nexpected\n  %s" name actual expected) in
    expect "users" (created_sql c users)
      "CREATE TABLE \"main\".\"users\" (\"id\" BIGINT NOT NULL, \"email\" VARCHAR NOT NULL, \
       \"age\" INTEGER DEFAULT CAST(18 AS INTEGER), PRIMARY KEY (\"id\"), UNIQUE (\"email\"), \
       CHECK (((\"age\" >= CAST(0 AS INTEGER)) IS TRUE)))";
    expect "posts" (created_sql c posts)
      "CREATE TABLE \"main\".\"posts\" (\"id\" BIGINT NOT NULL, \"owner\" BIGINT NOT NULL, \
       \"title\" VARCHAR NOT NULL, PRIMARY KEY (\"id\"), \
       FOREIGN KEY (\"owner\") REFERENCES \"main\".\"users\" (\"id\"))";
    expect "lookup" (R.query by_email)
      "SELECT \"id\", \"email\", \"age\" FROM \"main\".\"users\" WHERE \"email\" = CAST($1 AS VARCHAR)");
  Stdlib.print_endline "schema: CREATE TABLE and lookup SQL=ok"

(* Created tables verify; constraints are enforced; lookups find zero or one row. *)
let () =
  connected (fun c ->
    ok (T.create c users); ok (T.create c posts);
    ok (T.verify c users); ok (T.verify c posts);
    ddl c "INSERT INTO users(id, email) VALUES (1, 'ada@x')";
    (match ok (R.Session.find_opt c by_email D.Args.["ada@x"]) with
     | Some (1L, "ada@x", Some 18l) -> ()
     | _ -> failwith "lookup: default age");
    assert (Option.is_none (ok (R.Session.find_opt c by_email D.Args.["nobody"])));
    let native name sql = match R.Session.exec c (R.exec D.Fields.[] sql) D.Args.[] with
      | Error { D.Error.cause = Native _; _ } -> ()
      | _ -> failwith (name ^ ": not rejected") in
    native "duplicate key" "INSERT INTO users(id, email) VALUES (1, 'other')";
    native "duplicate unique" "INSERT INTO users(id, email) VALUES (2, 'ada@x')";
    native "check" "INSERT INTO users(id, email, age) VALUES (3, 'c', -1)";
    native "check rejects NULL" "INSERT INTO users(id, email, age) VALUES (4, 'd', NULL)";
    native "dangling foreign key" "INSERT INTO posts VALUES (1, 99, 't')";
    ddl c "INSERT INTO posts VALUES (1, 1, 't')");
  Stdlib.print_endline "schema: create, verify, enforcement, defaults, lookup=ok"

(* A non-main schema, and check_null's SQL rule (NULL passes). *)
let () =
  let audited = T.(declare ~schema:"app" "audit"
    Columns.["id", int64; "level", nullable int32] ~row:(fun id level -> (id, level))
    ~constraints:(fun [id; level] -> Constraint.[
      primary_key Key.[id]; check_null S.(Null.(column level > nullable (int32 0l))) ])) in
  connected (fun c ->
    ddl c "CREATE SCHEMA app";
    ok (T.create c audited);
    ok (T.verify c audited);
    ddl c "INSERT INTO app.audit VALUES (1, NULL)");
  Stdlib.print_endline "schema: other schema, check_null passes NULL=ok"

(* Verify reports the first difference against hand-written tables. *)
let () =
  let differs name table setup expected =
    connected (fun c ->
      List.iter setup ~f:(ddl c);
      match T.verify c table with
      | Ok () -> failwith (name ^ ": verified")
      | Error e -> if String.( <> ) (describe e) expected then
          failwith (Printf.sprintf "%s: %s, expected %s" name (describe e) expected)) in
  let users_ddl ?(id = "id BIGINT NOT NULL") ?(email = "email VARCHAR NOT NULL")
      ?(age = "age INTEGER DEFAULT 18") ?(rest = ", PRIMARY KEY (id), UNIQUE (email), CHECK (age >= 0)") () =
    Printf.sprintf "CREATE TABLE users(%s, %s, %s%s)" id email age rest in
  differs "missing table" users [] "Unknown_table main.users";
  differs "type" users [ users_ddl ~id:"id INTEGER NOT NULL" () ] "Type_mismatch BIGINT/INTEGER";
  differs "nullable where NOT NULL declared" users [ users_ddl ~email:"email VARCHAR" () ]
    "Constraint_mismatch NOT NULL: expected \"email\" NOT NULL, actual \"email\" nullable";
  differs "NOT NULL where nullable declared" users [ users_ddl ~age:"age INTEGER NOT NULL DEFAULT 18" () ]
    "Constraint_mismatch NOT NULL: expected \"age\" nullable, actual \"age\" NOT NULL";
  differs "missing primary key" users [ users_ddl ~rest:", UNIQUE (email), CHECK (age >= 0)" () ]
    "Constraint_mismatch PRIMARY KEY: expected PRIMARY KEY (\"id\"), actual none";
  differs "missing unique" users [ users_ddl ~rest:", PRIMARY KEY (id), CHECK (age >= 0)" () ]
    "Constraint_mismatch UNIQUE: expected UNIQUE (\"email\"), actual none";
  differs "extra unique" users [ users_ddl ~rest:", PRIMARY KEY (id), UNIQUE (email), UNIQUE (id, email), CHECK (age >= 0)" () ]
    "Constraint_mismatch UNIQUE: expected none, actual UNIQUE (\"id\", \"email\")";
  differs "missing check" users [ users_ddl ~rest:", PRIMARY KEY (id), UNIQUE (email)" () ]
    "Constraint_mismatch CHECK: expected CHECK (\"age\"), actual none";
  differs "missing default" users [ users_ddl ~age:"age INTEGER" () ]
    "Constraint_mismatch DEFAULT: expected DEFAULT on \"age\", actual none";
  differs "extra default" users [ users_ddl ~email:"email VARCHAR NOT NULL DEFAULT 'x'" () ]
    "Constraint_mismatch DEFAULT: expected none, actual DEFAULT on \"email\"";
  let posts_ddl fk = [ users_ddl ~rest:", PRIMARY KEY (id), UNIQUE (email), CHECK (age >= 0)" ();
    "CREATE TABLE posts(id BIGINT NOT NULL, owner BIGINT NOT NULL, title VARCHAR NOT NULL, PRIMARY KEY (id)" ^ fk ^ ")" ] in
  differs "missing foreign key" posts (posts_ddl "")
    "Constraint_mismatch FOREIGN KEY: expected FOREIGN KEY (\"owner\") REFERENCES \"users\" (\"id\"), actual none";
  differs "foreign key to another column" posts
    (posts_ddl ", FOREIGN KEY (id) REFERENCES users (id)")
    "Constraint_mismatch FOREIGN KEY: expected FOREIGN KEY (\"owner\") REFERENCES \"users\" (\"id\"), actual none";
  Stdlib.print_endline "schema: verify reports tables, types, nullability, keys, checks and defaults=ok"

(* Misuse the types cannot express raises when the declaration is built. *)
let () =
  invalid "two primary keys" (fun () -> T.(declare "t" Columns.["a", int64; "b", int64] ~row:(fun a b -> (a, b))
    ~constraints:(fun [a; b] -> Constraint.[ primary_key Key.[a]; primary_key Key.[b] ])));
  invalid "default mentions a column" (fun () -> T.(declare "t" Columns.["a", int64; "b", int64] ~row:(fun a b -> (a, b))
    ~constraints:(fun [a; b] -> Constraint.[ default a (S.column b) ])));
  invalid "column of another declaration" (fun () ->
    let stolen = ref None in
    ignore (T.(declare "t" Columns.["a", int64] ~row:Fn.id ~constraints:(fun [a] -> stolen := Some a; [])));
    T.(declare "u" Columns.["a", int64] ~row:Fn.id
      ~constraints:(fun [_] -> Constraint.[ primary_key Key.[Option.value_exn !stolen] ])));
  invalid "foreign key to an undeclared key" (fun () -> T.(declare "t" Columns.["e", string] ~row:Fn.id
    ~constraints:(fun [e] -> Constraint.[ foreign_key Key.[e] ~references:(posts, fun [_; _; title] -> Key.[title]) ])));
  invalid "foreign key to another schema" (fun () -> T.(declare ~schema:"app" "t" Columns.["o", int64] ~row:Fn.id
    ~constraints:(fun [o] -> Constraint.[ foreign_key Key.[o] ~references:(users, fun [id; _; _] -> Key.[id]) ])));
  invalid "lookup by an undeclared key" (fun () -> T.lookup posts (fun [_; owner; _] -> T.Key.[owner]));
  Stdlib.print_endline "schema: Invalid_argument for misuse at declare and lookup=ok"

(* Review findings: a foreign key compares its column pairs, so a reference
   permuted against the declaration is a difference; a permuted key cannot be
   declared at all (DuckDB rejects it at CREATE). *)
let parent = T.(declare "parent" Columns.["x", int64; "y", int64] ~row:(fun x y -> (x, y))
  ~constraints:(fun [x; y] -> Constraint.[ primary_key Key.[x; y]; unique Key.[y; x] ]))
let child = T.(declare "child" Columns.["a", int64; "b", int64] ~row:(fun a b -> (a, b))
  ~constraints:(fun [a; b] -> Constraint.[ foreign_key Key.[a; b] ~references:(parent, fun [x; y] -> Key.[x; y]) ]))
let () =
  connected (fun c ->
    ok (T.create c parent);
    ddl c "CREATE TABLE child(a BIGINT NOT NULL, b BIGINT NOT NULL, FOREIGN KEY (a, b) REFERENCES parent (y, x))";
    match T.verify c child with
    | Error { D.Error.cause = Constraint_mismatch { constraint_kind = "FOREIGN KEY"; _ }; _ } -> ()
    | Error e -> failwith ("permuted reference: " ^ describe e)
    | Ok () -> failwith "permuted reference: verified");
  connected (fun c -> ok (T.create c parent); ok (T.create c child); ok (T.verify c child));
  let only_pk = T.(declare "only_pk" Columns.["x", int64; "y", int64] ~row:(fun x y -> (x, y))
    ~constraints:(fun [x; y] -> Constraint.[ primary_key Key.[x; y] ])) in
  invalid "reference permuted against the referenced key" (fun () ->
    T.(declare "child" Columns.["a", int64; "b", int64] ~row:(fun a b -> (a, b))
      ~constraints:(fun [a; b] -> Constraint.[
        foreign_key Key.[a; b] ~references:(only_pk, fun [x; y] -> Key.[y; x]) ])));
  Stdlib.print_endline "schema: foreign keys pair columns in order, in verify and at declare=ok"

(* Documented limitations, closed. verify compares identifiers as DuckDB
   does, ignoring case. A unique index over plain columns satisfies a
   declared UNIQUE; an expression index does not. A foreign key between
   columns of different SQL types (BLOB and VARCHAR share OCaml's string)
   is rejected when declared. *)
let () =
  connected (fun c ->
    ddl c "CREATE TABLE \"Users\" (\"ID\" BIGINT PRIMARY KEY, \"Email\" VARCHAR NOT NULL UNIQUE, AGE INTEGER DEFAULT 18, \
           CHECK (age >= 0))";
    ok (T.verify c users));
  let accounts = T.(declare "accounts" Columns.["id", int64; "email", string] ~row:(fun id email -> (id, email))
    ~constraints:(fun [id; email] -> Constraint.[ primary_key Key.[id]; unique Key.[email] ])) in
  connected (fun c ->
    ddl c "CREATE TABLE accounts (id BIGINT PRIMARY KEY, email VARCHAR NOT NULL)";
    ddl c "CREATE UNIQUE INDEX accounts_email ON accounts (\"EMAIL\")";
    ok (T.verify c accounts));
  connected (fun c ->
    ddl c "CREATE TABLE accounts (id BIGINT PRIMARY KEY, email VARCHAR NOT NULL)";
    ddl c "CREATE UNIQUE INDEX accounts_email ON accounts (lower(email))";
    match T.verify c accounts with
    | Error { D.Error.cause = Constraint_mismatch { constraint_kind = "UNIQUE"; _ }; _ } -> ()
    | Error e -> failwith ("expression index: " ^ describe e)
    | Ok () -> failwith "expression index: verified");
  let blobs = T.(declare "blobs" Columns.["b", blob] ~row:Fn.id
    ~constraints:(fun [b] -> Constraint.[ primary_key Key.[b] ])) in
  invalid "foreign key from VARCHAR to BLOB" (fun () -> T.(declare "t" Columns.["s", string] ~row:Fn.id
    ~constraints:(fun [s] -> Constraint.[ foreign_key Key.[s] ~references:(blobs, fun [b] -> Key.[b]) ])));
  Stdlib.print_endline "schema: verify ignores identifier case, accepts unique indexes; typed foreign keys=ok"
