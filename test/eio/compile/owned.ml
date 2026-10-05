open! Base

let value pool =
  Duckdb_eio.transaction pool ~f:(fun tx ->
    Result.map (Duckdb.execute tx "SELECT 42") ~f:(fun () -> "owned"))
