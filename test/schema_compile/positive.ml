(* Every accepted schema declaration form compiles. *)
open! Base
module D = Duckdb
module S = D.Sql
module T = D.Table

let users = T.(declare "users"
  Columns.["id", int64; "email", string; "age", nullable int32]
  ~row:(fun id email age -> (id, email, age))
  ~constraints:(fun [id; email; age] -> Constraint.[
    primary_key Key.[id];
    unique Key.[email];
    default age S.(nullable (int32 18l));
    check S.(is_true Null.(column age >= nullable (int32 0l)));
    check_null S.(Null.(column age < nullable (int32 200l))) ]))
let posts = T.(declare "posts"
  Columns.["id", int64; "owner", int64; "title", string]
  ~row:(fun id owner title -> (id, owner, title))
  ~constraints:(fun [id; owner; title] -> Constraint.[
    primary_key Key.[id; owner];
    default title (S.string "untitled");
    foreign_key Key.[owner] ~references:(users, fun [id; _; _] -> Key.[id]) ]))
let by_email : (string * unit, int64 * string * int32 option, D.Request.zero_or_one) D.Request.t =
  T.lookup users (fun [_; email; _] -> T.Key.[email])
let run (c : D.connection) =
  match T.create c users with
  | Error e -> Error e
  | Ok () ->
    match T.verify c users with
    | Error e -> Error e
    | Ok () -> D.Request.Session.find_opt c by_email D.Args.["a"]
