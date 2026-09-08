let transfer (owned : string) = Domain.Safe.spawn (fun () -> owned)
let alias (connection : Duckdb.connection) = connection
