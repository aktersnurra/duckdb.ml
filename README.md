# duckdb.ml

An OxCaml DuckDB binding. **Through stage 3b:** synchronous databases/connections, exclusive transactions,
reusable prepared statements, typed parameters/owned rows and scoped borrowed chunks. The unsafe
`duckdb-ffi` and Base-backed safe `duckdb` packages start no scheduler.

```ocaml
let run config =
  Duckdb.with_database config ~f:(fun database ->
    Duckdb.with_connection database ~f:(fun connection ->
      Duckdb.with_transaction connection ~f:(fun transaction ->
        Duckdb.execute_transaction transaction "create table example(i integer)")))
```

Read the [public interface](lib/duckdb/duckdb.mli),
[native dependency/install instructions](docs/native-dependency.md), and
[stage-3b guarantees and validation](docs/stage3b-validation.md).
With the pinned local toolchain/native dependency already provisioned:

```sh
stage1/run build @all
stage1/run runtest --force
stage1/run exec examples/synchronous.exe
bash test/install_smoke.sh
```

Appender and typed local Parquet belong to stage 3c. Async/Eio adapters, pools, cancellation and performance work are later
stages. The private [stage-1](docs/stage1-validation.md) and
[stage-2](docs/stage2-validation.md) experiments and regression suites remain
available; their narrower guarantees are not public API claims.
