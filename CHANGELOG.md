# Changelog

## Unreleased

### Performance (sub-project 1b)

[Design and results](docs/design/performance.md).

Added:
- `Statement.Column`: local typed views of one chunk column, checked once
  per chunk (`view` returns `Opened`/`Rejected`). Numeric accessors return
  unboxed values and are `[@zero_alloc]`; nullable views have `is_null`,
  `null_count` and `_or` accessors with an explicit default.
- `Bulk`: `collect` and `collect_strings` copy one result column into a
  Bigarray (or string array) with one native copy per chunk; `blit` and
  `blit_validity` do so for one chunk; `Bulk.Columns` describes whole
  columns for appending.
- `Table.append_columns`: appends Bigarray columns typed by the table
  declaration, with one copy per column per 2,048-row slice.
- `Error.Length_mismatch { column; expected; actual }` for
  `append_columns` columns or masks of unequal length.
- `lib/duckdb` builds with `-zero-alloc-check default`;
  `test/test_allocation.ml` asserts per-row allocation of the fast paths.
- Benchmark: paths `column_views`, `collect`, `row_ingest` and
  `columnar_ingest`, rotated per sample; the database runs with `threads=1`,
  recorded in the output.

Changed:
- Typed rows (requests, tables, Parquet, adapters) decode through a
  per-chunk vector cache with saturated row application: 280 ms to 89 ms
  for 1M rows of two BIGINT columns. Errors are unchanged; cancellation is
  still checked before every row. For a row whose later column is rejected,
  effects between curried arguments of the row function no longer run.
- `Table.append` stages rows into reusable native data chunks and appends
  them with `duckdb_append_data_chunk`: 566 ms to 70 ms for 1M rows in
  1,000-row batches. Error precedence and batch atomicity are unchanged;
  invalid UTF-8 in a VARCHAR value still poisons the appender.
- `Codec.non_null` and `Codec.nullable` are private variants, so
  single-case matches on `Bulk.validity` and `Bulk.strings` are exhaustive.
- `duckdb-ffi`: `append_cell`, `append_rows` and `clear_appender_input` are
  replaced by staging externals (`stage_begin`, `stage_*`, `stage_blit`,
  `stage_mask`, `append_staged`, `clear_stage`); per-chunk view externals
  (`view_*`) are added.
- The documentation of `Encode_rejected` now states that its index is
  one-based, as it always was.
- Typed requests over parameterised table functions (`range(?)`) no longer
  fail with a spurious `Column_count`: declared rows are validated against
  the executed result's columns.

### Changed (breaking)

Core redesign, sub-project 1 ([design](docs/design/core-redesign.md)).

- `Duckdb.error`, `Scalar.error` (`Data_error`) and `Request.request_error`
  (`context`, `cause`, `Core`) are replaced by one flat `Error.t`
  (`{ context; cause }`). `Native_error` is renamed `Native`;
  `Type_mismatch.actual` and `Unsupported_parquet_type.actual` are SQL type
  names instead of native ids; `Rollback_failed` is a record of two `Error.t`.
- `Live_children` is removed: closing a parent with live children, or a
  Bridge import of a busy owner, returns `Busy`.
- `Range`, `Scalar.validate` and `Scalar.round_float32` are removed: `Int8`,
  `Int16` and `Float32` witnesses (and codecs) carry exact `int8`, `int16`
  and `float32` values.
- `Rollback_exception` and `Request.Cleanup_exception` are removed; the one
  `Cleanup_exception of Error.t * exn` covers both. `Request.query_of_context`
  is removed.
- `Row` and `Scalar.field` are removed; decoders are `Fields` plus `~row`,
  and `bind`/`column` take codecs.
- `cell`, the core `appender`, `open_appender`, `append_rows`,
  `flush_appender`, `close_appender`, `with_appender` and
  `with_appender_transaction` are removed; append through `Table`.
- `prepared`, `query_result` and `chunk` move to `Statement`;
  `prepare`, `prepare_transaction`, `close_prepared`, `execute_prepared`,
  `close_result`, `fold_rows` and `with_prepared_transaction` are removed
  (use `Statement.with_prepared`, `fold_chunks`, `execute`).
- Published `duckdb.worker` library: `request_exec`/`find`/`find_opt`/
  `collect`/`fold` collapse into `request_run`, which takes `Owned.shape`;
  the cell-based `S.ingest` is removed; every operation takes
  `Bridge.request @ unique`; raw `query`/`fold_rows`/`parquet_fold_rows` take
  `Fields` plus `~row`; transaction callbacks take
  `Duckdb.transaction @ local`.
- `execute_transaction` is removed: `execute` takes `_ session`.
- `open_database`, `close_database`, `connect` and `close_connection` move to
  `Owned`. `connection` and `transaction` are now ``[ `Connection ] session``
  and ``[ `Transaction ] session``.
- Scoped handles are `@ local`: they cannot be returned, stored or captured,
  and scope callbacks cannot capture another handle (formerly runtime
  `Busy`/`Closed`). `with_transaction` takes a connection only.
- `Parquet.fold_rows` is removed (use `Parquet.fold`/`fold_table`).
- `Request.Connection` and `Request.Transaction` are merged into
  `Request.Session`. `QUERY`/`CONNECTION` index `owner` by session kind, and
  fold/transaction callbacks return `Error.t`.
- `Table.with_appender_transaction` is removed: `Table.with_appender` takes
  `_ session`, and `append`/`flush` return `Error.t`.
- `Bridge.create` is replaced by `Bridge.canceller` and a unique
  `Bridge.request`; `run` consumes the request, so a second `run` is a type
  error. `cancel` and `settlement` take the canceller; `cancel` returns
  `unit` and is a no-op after settlement (formerly `Error Closed`).
- Async and Eio: `ingest` over `cell` batches is removed (use
  `Request.ingest` with a declared table); `query`, `fold_rows` and
  `parquet_fold_rows` take `Fields` plus `~row`; `Core` carries
  `Duckdb.Error.t`; `Request.error`'s `Request` carries `Duckdb.Error.t`.
  Transaction callbacks receive `Duckdb.transaction @ local`.
- Adapters' raw `query`/`fold_rows` on SQL with a parameter (`SELECT ?`)
  return `Parameter_count` instead of an unbound-parameter error.
- `Null` and `Decode_rejected` rows are absolute within the result for typed
  requests and adapter queries (still chunk-relative for `Statement.column`).
- Benchmark: `execute_ns` is about 0 on both paths, because execution is
  fused with the fold; `process_ns` includes execution and decoding.

### Added
- `Error` (`context`, `cause`, `t`), the one error type.
- `Owned`: runtime-checked lifecycle and the shape-driven `run` for
  scheduler adapters.
- `Statement`: `with_prepared`, codec `bind`, `reset`, `parameter_count`,
  `fold_chunks`, `execute`, `chunk_length`, `column`.
- `Request.Session`: one operation set over connections and transactions.
- `Bridge.canceller` (shareable) and `Bridge.request` (unique, bound to a
  canceller).
- Exact small numerics: `int8`, `int16` and `float32` codecs and witnesses.
- Compile-failure fixtures for local handles and unique requests
  (`test/scope_compile`) and for adapter transaction tokens
  (`adapter_tx_escape` in `test/async/compile` and `test/eio/compile`).
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
- `Request.CONNECTION`, implemented by `Request.Session` and by each
  adapter's `Request.Generic`. `Duckdb_async.Request.submit_*` gives
  cancellable forms. Typed operations are added to `duckdb.worker`.
- Compile-failure fixtures for every static guarantee (`test/request_compile`,
  plus Async and Eio fixtures).

### Changed
- Prepared statements (`Statement.fold_chunks`, typed requests) re-prepare to check parameter types only when a schema
  change may have become visible (process-wide schema epoch), and never for
  parameterless statements. The outcome of the check is unchanged.

See [docs/design/typed-requests.md](docs/design/typed-requests.md).
