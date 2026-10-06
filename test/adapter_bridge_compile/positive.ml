let use connection =
  let canceller = Duckdb.Bridge.canceller () in
  let _ = Duckdb.Bridge.settlement canceller in
  Duckdb.Bridge.run (Duckdb.Bridge.request canceller) connection ~f:(fun facade ->
    match Duckdb.execute facade "SELECT 1" with
    | Error e -> Error e | Ok () -> Ok "owned")
