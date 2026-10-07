(* Every accepted typed-SQL form compiles. *)
open! Base
module D = Duckdb
module S = D.Sql

let users = D.Table.(declare "users" Columns.["id", int64; "name", string; "age", nullable int32]
  ~row:(fun id name age -> (id, name, age)))
let adults : (int32 * unit, int64 * string, D.Request.many) D.Request.t = S.(
  query Params.[int32] (fun [min_age] ->
    from users (fun [id; name; age] ->
      select Exprs.[id; name] ~row:(fun id name -> (id, name))
        ~where:(is_true Null.(age >= nullable (param min_age)))
        ~order_by:[asc id] ~limit:100)))
let by_name : (unit, string * int64 * int32 option, D.Request.many) D.Request.t = S.(
  query Params.[] (fun [] ->
    from users (fun [_; name; age] ->
      group_by Keys.[name] (fun [name] ->
        select Exprs.[name; count_star; Null.max age] ~row:(fun n c m -> (n, c, m))
          ~having:(count_star > int64 1L)))))
let total : (unit, int64, D.Request.one) D.Request.t = S.(
  query Params.[] (fun [] -> from users (fun [id; _; _] -> aggregate Exprs.[count id] ~row:Fn.id)))
let run (c : D.connection) =
  match D.Request.Session.collect c adults D.Args.[18l] with
  | Error e -> Error e
  | Ok (_ : (int64 * string) list) -> D.Request.Session.find c total D.Args.[]
