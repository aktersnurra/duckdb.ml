(* Every accepted migration form compiles. *)
open! Base
module D = Duckdb
module R = D.Request
module T = D.Table
module M = D.Migration

let users = T.(declare "users" Columns.["id", int64; "email", string; "nick", nullable string]
  ~row:(fun id email nick -> (id, email, nick))
  ~constraints:(fun [id; _; _] -> Constraint.[ primary_key Key.[id] ]))
let backfill = R.exec D.Fields.[] "UPDATE users SET nick = email"
let migrations = M.[
  step 1 "create users" (create users);
  step 2 "add nick" (add_column users (fun [_; _; nick] -> Column nick));
  step 3 "backfill" (run (fun tx -> R.Session.exec tx backfill D.Args.[]));
  step 4 "drop legacy" (drop_table ~schema:"main" "legacy");
  step 5 "drop column" (drop_column ~table:"users" "old");
  step 6 "rename table" (rename_table "a" ~to_:"b");
  step 7 "rename column" (rename_column ~table:"users" "body" ~to_:"text");
  step 8 "index" (sql "CREATE INDEX users_email ON users(email)") ]
let start (c : D.connection) : (int list, D.Error.t) result = M.apply c migrations ~verify:M.[ table users ]
