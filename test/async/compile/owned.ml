let copy_length result =
  Duckdb.fold_chunks result ~init:0 ~f:(fun chunk _ -> Ok (Duckdb.Stop (Duckdb.chunk_length chunk)))
(* Compile-only LIMITATION control: a pre-existing Deferred is an owned value;
   result polymorphism cannot prove completion of that deferred inside a transaction. *)
let deferred_value pool =
  let already_owned = Async.Deferred.return 42 in
  Duckdb_async.transaction pool ~f:(fun _ -> Ok already_owned)
