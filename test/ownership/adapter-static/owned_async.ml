let escape prepared =
  Duckdb.Statement.fold_chunks prepared ~init:() ~f:(fun chunk () ->
    let length = Duckdb.Statement.chunk_length chunk in
    let _work = Async.In_thread.run (fun () -> length) in
    Ok (Duckdb.Stop ()))
