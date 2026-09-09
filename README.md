# duckdb.ml

`duckdb.ml` is an OxCaml binding for DuckDB.  It provides a safe synchronous
API plus separately installable `duckdb-async` and `duckdb-eio` adapters.

```ocaml
Duckdb.with_database config ~f:(fun database ->
  Duckdb.with_connection database ~f:(fun connection ->
    Duckdb.execute connection "select 42"))
```

Start with [architecture](docs/architecture.md), [native dependencies](docs/native-dependency.md), and the public examples in [`examples/`](examples/).

For a provisioned checkout:

```sh
./tools/run build @all
./tools/run runtest --force
./tools/run exec examples/synchronous.exe
./tools/run exec examples/asynchronous.exe
./tools/run exec examples/eio.exe
bash test/install_adapters_smoke.sh
```

The library supports local DuckDB databases and typed local Parquet reads and
exports. Remote storage and credentials are out of scope.
