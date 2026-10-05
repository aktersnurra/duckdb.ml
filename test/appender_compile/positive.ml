let t = Duckdb.Table.(declare "table" Columns.[ "x", int64 ] ~row:(fun x -> x))
let append (tx : Duckdb.transaction) = Duckdb.Table.with_appender tx t ~f:(fun a ->
  Duckdb.Table.append a [Duckdb.Args.[9007199254740993L]])
let flush (a : (int64 * unit, int64) Duckdb.Table.appender) = Duckdb.Table.flush a
