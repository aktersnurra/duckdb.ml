let copy_length prepared =
  Duckdb.Statement.fold_chunks prepared ~init:0 ~f:(fun chunk _ -> Ok (Duckdb.Stop (Duckdb.Statement.chunk_length chunk)))
(* Compile-only LIMITATION control: a pre-existing Deferred is an owned value;
   result polymorphism cannot prove completion of that deferred inside a transaction. *)
let deferred_value pool =
  let already_owned = Async.Deferred.return 42 in
  Duckdb_async.transaction pool ~f:(fun _ -> Ok already_owned)
