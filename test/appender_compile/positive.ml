let cell : Duckdb.cell = Duckdb.Cell (Duckdb.Scalar.Required Duckdb.Scalar.Int64, 9007199254740993L)
let create (tx : Duckdb.transaction) = Duckdb.open_appender tx "table"
let close (a : Duckdb.appender) = Duckdb.close_appender a
