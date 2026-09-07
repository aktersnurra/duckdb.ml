let owned_error () = Domain.Safe.spawn (fun () -> Duckdb.Closed)
let alias (c : Duckdb.connection) = c
let transaction_callback c = Duckdb.with_transaction c ~f:(fun tx -> Duckdb.execute_transaction tx "select 1")
