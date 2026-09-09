# duckdb.ml

An OxCaml DuckDB binding. The `duckdb-ffi` and Base-backed safe `duckdb`
packages start no scheduler. `duckdb-async` and `duckdb-eio` are separate
adapters; Eio supports bounded direct-style SQL, transactions, typed owned
queries/folds, whole-request ingestion, and local Parquet reads/exports.

```ocaml
let run config =
  Duckdb.with_database config ~f:(fun database ->
    Duckdb.with_connection database ~f:(fun connection ->
      Duckdb.with_transaction connection ~f:(fun transaction ->
        Duckdb.execute_transaction transaction "create table example(i integer)")))
```

Read the [public interfaces](lib/duckdb/duckdb.mli) and
[Eio interface](lib/eio/duckdb_eio.mli), [native dependency/install instructions](docs/native-dependency.md),
and [Stage4 validation status](docs/stage4-validation.md).
With the pinned local toolchain/native dependency already provisioned:

```sh
stage1/run build @all
stage1/run runtest --force
stage1/run exec examples/synchronous.exe
stage1/run exec examples/asynchronous.exe
stage1/run exec examples/eio.exe
bash test/install_adapters_smoke.sh
```

The Eio example uses only public typed operations and makes a temporary local
Parquet file; it removes that file before shutdown. Installation smoke stages
FFI then core and one adapter at a time; it is a Dune installation check, not
an opam solver or publication check. Stage5 performance work remains unimplemented.
The private [stage-1](docs/stage1-validation.md) and [stage-2](docs/stage2-validation.md)
experiments and regression suites remain available; their narrower guarantees
are not public API claims.
