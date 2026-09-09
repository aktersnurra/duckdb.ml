let use connection =
  let request = Duckdb.Bridge.create () in
  let _ = Duckdb.Bridge.settlement request in
  Duckdb.Bridge.run request connection ~f:(fun facade ->
    match Duckdb.execute facade "SELECT 1" with
    | Error e -> Error e | Ok () -> Ok "owned")
