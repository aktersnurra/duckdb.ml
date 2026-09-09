let escape result =
  Duckdb.fold_chunks result ~init:() ~f:(fun chunk () ->
    let length = Duckdb.chunk_length chunk in
    let _length = Eio_unix.run_in_systhread (fun () -> length) in
    Ok (Duckdb.Stop ()))
