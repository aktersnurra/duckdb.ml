let escape result =
  Duckdb.fold_chunks result ~init:() ~f:(fun chunk () ->
    let length = Duckdb.chunk_length chunk in
    let _work = Async.In_thread.run (fun () -> length) in
    Ok (Duckdb.Stop ()))
