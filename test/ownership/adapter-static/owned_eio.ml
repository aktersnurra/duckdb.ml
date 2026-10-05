let escape prepared =
  Duckdb.Statement.fold_chunks prepared ~init:() ~f:(fun chunk () ->
    let length = Duckdb.Statement.chunk_length chunk in
    let _length = Eio_unix.run_in_systhread (fun () -> length) in
    Ok (Duckdb.Stop ()))
