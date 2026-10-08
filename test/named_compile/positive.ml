(* Every accepted named-binder form compiles. *)
module D = Duckdb
module S = D.Sql
module Users = struct
  let t = D.Table.(declare "users" Columns.["id", int64; "name", string; "age", nullable int32]
    ~row:(fun id name age -> (id, name, age))
    ~constraints:(fun [id; _; _] -> Constraint.[ primary_key Key.[id] ]))
  let S.Named.[id; name; age] = D.Table.fields t
end
module Posts = struct
  let t = D.Table.(declare "posts" Columns.["id", int64; "owner", int64; "title", string]
    ~row:(fun id owner title -> (id, owner, title)))
  let S.Named.[id; owner; title] = D.Table.fields t
end
let names : (int32 * unit, string * int32 option, D.Request.many) D.Request.t =
  S.(query Params.[int32] (fun [min_age] ->
    from Users.t (fun u ->
      select Exprs.[u.%(Users.name); u.%(Users.age)] ~where:(is_true Null.(u.%(Users.age) >= nullable (param min_age)))
        ~row:(fun n a -> (n, a)))))
let titles : (unit, string * string, D.Request.many) D.Request.t =
  S.(query Params.[] (fun [] ->
    from Users.t (fun u ->
      join Posts.t ~on:(fun p -> p.%(Posts.owner) = u.%(Users.id)) (fun p ->
        select Exprs.[u.%(Users.name); p.%(Posts.title)] ~row:(fun n t -> (n, t))))))
let maybe_titles : (unit, string * string option, D.Request.many) D.Request.t =
  S.(query Params.[] (fun [] ->
    from Users.t (fun u ->
      left_join Posts.t ~on:(fun p -> p.%(Posts.owner) = u.%(Users.id)) (fun p ->
        select Exprs.[u.%(Users.name); outer p.%?(Posts.title)] ~row:(fun n t -> (n, t))))))
let ages : (unit, int32 option, D.Request.many) D.Request.t =
  S.(query Params.[] (fun [] ->
    from Users.t (fun u ->
      left_join Users.t ~on:(fun v -> v.%(Users.id) = u.%(Users.id)) (fun v ->
        select Exprs.[Null.outer v.%?(Users.age)] ~row:(fun a -> a)))))
let rename : (int64 * (string * unit), int64, D.Request.one) D.Request.t =
  S.(command Params.[int64; string] (fun [id; name] ->
    update Users.t (fun u -> set [u.%(Users.name) := param name] ~where:(u.%(Users.id) = param id))))
let upsert = S.(command Params.[int64; string] (fun [id; name] ->
  insert Users.t (fun u ->
    values [u.%(Users.id) := param id; u.%(Users.name) := param name]
      ~on_conflict:(update_on Keys.[u.%(Users.id)] (fun proposed ->
        [u.%(Users.name) := proposed.%(Users.name)])))))
let purge = S.(command Params.[] (fun [] -> delete Users.t (fun u -> filter (is_null u.%(Users.age)))))
