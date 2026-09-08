let consume result = Duckdb.fold_chunks result ~init:0 ~f:(fun chunk total ->
  let alias = chunk in
  let length = Duckdb.chunk_length alias in
  let owned = Duckdb.column chunk ~column:0 ~row:0 (Duckdb.Scalar.Nullable Duckdb.Scalar.Int64) in
  let _ = owned in Ok (Duckdb.Continue (total + length)))
let owned_domain result = Duckdb.fold_chunks result ~init:0 ~f:(fun chunk _ ->
  let owned = Duckdb.chunk_length chunk in
  let worker = Domain.Safe.spawn (fun () -> owned) in
  Ok (Duckdb.Stop (Domain.join worker)))
let reentrant_alias result = Duckdb.fold_chunks result ~init:() ~f:(fun chunk () ->
  let _ = Duckdb.close_result result in
  let _ = Duckdb.chunk_length chunk in Ok (Duckdb.Stop ()))
