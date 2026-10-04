# Changelog

## Unreleased

### Added
- Typed request layer (`Duckdb.Codec`, `Fields`, `Args`, `Request`): a request
  is SQL text plus typed parameters, typed rows and a multiplicity phantom
  that gates `exec`/`find`/`find_opt`/`collect`/`fold` at compile time. It is
  validated against engine metadata when first prepared. Rows decode straight
  into curried constructors or flat tuples, and `Codec.custom` maps user types.
- Per-connection prepared-statement cache (LRU, `Config.create ?statement_cache`,
  default 64; `~oneshot` opts out).
- Typed tables (`Duckdb.Table`): declared columns drive typed appender rows,
  SELECT and INSERT. They are checked against the catalog by name, and omitted
  columns must have defaults.
- `Parquet.fold`/`fold_table` decode through `Fields` or a declared table.
- `Request.CONNECTION`, implemented by the synchronous connection and by each
  adapter's `Request.Generic`. `Duckdb_async.Request.submit_*` gives
  cancellable forms. Typed operations are added to `duckdb.worker`.
- Compile-failure fixtures for every static guarantee (`test/request_compile`,
  plus Async and Eio fixtures).

### Changed
- `execute_prepared` re-prepares to check parameter types only when a schema
  change may have become visible (process-wide schema epoch), and never for
  parameterless statements. The outcome of the check is unchanged.

See [docs/design/typed-requests.md](docs/design/typed-requests.md).
