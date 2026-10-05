let owned_error () = Domain.Safe.spawn (fun () -> Duckdb.Error.{ context = Database; cause = Closed })
let alias (c : Duckdb.connection) = c
let transaction_callback c = Duckdb.with_transaction c ~f:(fun tx -> Duckdb.execute tx "select 1")
