(* Typed SQL: queries built from typed expressions compile to requests. *)
open! Base
module D = Duckdb
module R = D.Request
module S = D.Sql

(* The declaration states the constraints; Table.create runs its CREATE TABLE. *)
let users = D.Table.(declare "users"
  Columns.["id", int64; "name", string; "age", nullable int32]
  ~row:(fun id name age -> (id, name, age))
  ~constraints:(fun [id; _; age] -> Constraint.[
    primary_key Key.[id];
    check_null S.(Null.(column age >= nullable (int32 0l))) ]))
let by_id = D.Table.lookup users (fun [id; _; _] -> D.Table.Key.[id])

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
  match D.Table.create c users with
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
        match R.Session.find_opt c by_id D.Args.[2L] with
        | Error e -> Error e
        | Ok found ->
          Stdio.printf "user 2: %s\n" (Option.value_map found ~default:"none" ~f:(fun (_, name, _) -> name));
          match D.Table.verify c users with
          | Error e -> Error e
          | Ok () -> R.Session.collect c by_name D.Args.[]

let () =
  Stdio.print_endline (R.query adults);
  match Result.bind (D.Config.create Memory) ~f:(fun config ->
    D.with_database config ~f:(fun db -> D.with_connection db ~f:run)) with
  | Ok groups ->
    List.iter groups ~f:(fun (name, n, oldest) ->
      Stdio.printf "%s: %Ld, oldest %s\n" name n (Option.value_map oldest ~default:"unknown" ~f:Int32.to_string))
  | Error _ -> Stdio.eprintf "query failed\n"
