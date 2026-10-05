module D = Duckdb
let r = D.Request.many D.Fields.[] D.Fields.[int64] ~row:Fun.id "SELECT 1"
let helper c = D.execute c "SELECT 1"            (* inferred: _ session @ local -> … *)
(* Binding-operator continuations are always global closures, and a local
   closure cannot be passed in tail position, so code that uses a local handle
   after a bind matches on the result. *)
let ok cfg = D.with_database cfg ~f:(fun db -> D.with_connection db ~f:(fun c ->
  match helper c with
  | Error _ as e -> e
  | Ok () ->
    match D.with_transaction c ~f:(fun tx -> D.execute tx "SELECT 1") with
    | Error _ as e -> e
    | Ok () ->
      match D.Request.Session.fold c r D.Args.[] ~init:0 ~f:(fun x n -> Ok (D.Continue (n + Int64.to_int x))) with
      | Error _ as e -> e
      | Ok n -> D.Statement.with_prepared c "SELECT 1" ~f:(fun p -> D.Statement.fold_chunks p ~init:n ~f:(fun _ n -> Ok (D.Stop n)))))
