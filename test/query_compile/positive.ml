let consume prepared = Duckdb.Statement.fold_chunks prepared ~init:0 ~f:(fun chunk total ->
  let alias = chunk in
  let length = Duckdb.Statement.chunk_length alias in
  let owned = Duckdb.Statement.column chunk ~column:0 ~row:0 (Duckdb.Codec.Values.(nullable int64)) in
  let _ = owned in Ok (Duckdb.Continue (total + length)))
let owned_domain prepared = Duckdb.Statement.fold_chunks prepared ~init:0 ~f:(fun chunk _ ->
  let owned = Duckdb.Statement.chunk_length chunk in
  let worker = Domain.Safe.spawn (fun () -> owned) in
  Ok (Duckdb.Stop (Domain.join worker)))
let reentrant_alias prepared = Duckdb.Statement.fold_chunks prepared ~init:() ~f:(fun chunk () ->
  let _ = Duckdb.Statement.reset prepared in
  let _ = Duckdb.Statement.chunk_length chunk in Ok (Duckdb.Stop ()))
