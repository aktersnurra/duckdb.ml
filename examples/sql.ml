(* Typed SQL: queries built from typed expressions compile to requests. *)
open! Base
module D = Duckdb
module R = D.Request
module S = D.Sql

let users = D.Table.(declare "users"
  Columns.["id", int64; "name", string; "age", nullable int32]
  ~row:(fun id name age -> (id, name, age)))
let create = R.exec D.Fields.[] "CREATE TABLE users(id BIGINT, name VARCHAR, age INTEGER)"

let adults = S.(
  query Params.[int32] (fun [min_age] ->
    from users (fun [id; name; age] ->
      select Exprs.[id; name] ~row:(fun id name -> (id, name))
        ~where:(is_true Null.(age >= nullable (param min_age)))
        ~order_by:[asc id])))
let by_name = S.(
  query Params.[] (fun [] ->
    from users (fun [_; name; age] ->
      group_by Keys.[name] (fun [name] ->
        select Exprs.[name; count_star; Null.max age] ~row:(fun n c m -> (n, c, m))
          ~order_by:[asc name]))))

let run (c @ local) =
  match R.Session.exec c create D.Args.[] with
  | Error e -> Error e
  | Ok () ->
    match D.Table.with_appender c users ~f:(fun a ->
      D.Table.append a [ D.Args.[1L; "ada"; Some 36l]; D.Args.[2L; "bob"; None]; D.Args.[3L; "ada"; Some 17l] ]) with
    | Error e -> Error e
    | Ok () ->
      match R.Session.collect c adults D.Args.[18l] with
      | Error e -> Error e
      | Ok adults ->
        List.iter adults ~f:(fun (id, name) -> Stdio.printf "adult %Ld %s\n" id name);
        R.Session.collect c by_name D.Args.[]

let () =
  Stdio.print_endline (R.query adults);
  match Result.bind (D.Config.create Memory) ~f:(fun config ->
    D.with_database config ~f:(fun db -> D.with_connection db ~f:run)) with
  | Ok groups ->
    List.iter groups ~f:(fun (name, n, oldest) ->
      Stdio.printf "%s: %Ld, oldest %s\n" name n (Option.value_map oldest ~default:"unknown" ~f:Int32.to_string))
  | Error _ -> Stdio.eprintf "query failed\n"
