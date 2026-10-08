(* Every accepted typed-DML form compiles. *)
module D = Duckdb
module S = D.Sql
let users = D.Table.(declare "users" Columns.["id", int64; "name", string; "age", nullable int32]
  ~row:(fun id name age -> (id, name, age))
  ~constraints:(fun [id; _; _] -> Constraint.[ primary_key Key.[id] ]))
let archive = D.Table.(declare "archive" Columns.["id", int64; "name", string] ~row:(fun id name -> (id, name)))
let rename : (int64 * (string * unit), int64, D.Request.one) D.Request.t = S.(command Params.[int64; string] (fun [id; name] ->
  update users (fun [uid; uname; _] -> set [uname := param name] ~where:(uid = param id))))
let add : (string * unit, int64, D.Request.many) D.Request.t = S.(command Params.[string] (fun [name] ->
  insert users (fun [uid; uname; _] -> values [uname := param name] |> returning Exprs.[uid] ~row:(fun i -> i))))
let upsert = S.(command Params.[int64; string] (fun [id; name] ->
  insert users (fun [uid; uname; _] ->
    values [uid := param id; uname := param name]
      ~on_conflict:(update_on Keys.[uid] (fun [_; new_name; _] -> [uname := new_name])))))
let purge = S.(command Params.[] (fun [] -> delete users (fun [_; _; age] -> filter (is_null age))))
let copy = S.(command Params.[] (fun [] ->
  insert archive (fun [aid; aname] -> select_into Targets.[aid; aname]
    (from users (fun [uid; uname; _] -> select Exprs.[uid; uname] ~row:(fun a b -> (a, b)))))))
let run (c : D.connection) =
  match D.Request.Session.find c rename D.Args.[1L; "x"] with
  | Error e -> Error e
  | Ok (_ : int64) -> D.Request.Session.collect c add D.Args.["y"]
