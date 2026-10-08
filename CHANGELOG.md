# Changelog

## Unreleased

### Typed INSERT, UPDATE and DELETE (sub-project 4b)

[Design](docs/design/dml.md).

Added to `Sql`:
- `command`, building write statements as `query` builds SELECTs: `update …
  (set [c := v] ?where)`, `delete … (filter e | all)`, `insert … (values
  [c := v] | select_into Targets.[…] source)`. Without `returning` a
  statement returns the affected-row count (`int64`, `one`); `returning
  Exprs.[…] ~row` returns rows (`many`).
- `nothing_on` / `update_on` (ON CONFLICT on a declared key, `excluded`
  binders typed by the table).
- `test/test_sql_dml.ml`; 7 fixtures in `test/dml_compile`.

Inside `S.( … )`, `:=` now shadows reference assignment.

### Query composition (sub-project 4a)

[Design](docs/design/query-composition.md).

Added to `Sql`:
- `join`, `left_join`, `cross_join`, nested to any depth. A LEFT JOIN's body
  binds `outer` values, lifted by `outer`/`Null.outer` to options.
- `select ~distinct`.
- `value codec v`: literals of any codec (custom codecs, dates, timestamps,
  blobs), encoded when built.
- `exists`, `in_` (three-valued), `scalar`/`Null.scalar` (one-row sources)
  subqueries, correlated or not.
- `union`, `union_all`, `intersect`, `except_`.
- `test/test_sql_time_zone.ml` (run with `TZ=America/New_York`); 7 compile
  fixtures.

Changed: `Sql.body` and `Sql.source` are indexed by their column types
(`('list, 'row, 'k, 'm) body`, `('list, 'row, 'm) source`). Tables are
aliased `t0`, `t1`, … in order of appearance.

### Review limitations closed

- `Table.verify` ignores ASCII case in schema, table, column and referenced
  names, as DuckDB does, and accepts a unique index over plain columns for a
  declared UNIQUE.
- `Table.Constraint.foreign_key` raises `Invalid_argument` when the key's
  SQL types differ from the referenced key's (VARCHAR against BLOB).
- `Sql.select` and `Sql.aggregate` require a non-empty select list by type;
  a negative `~limit` or `~offset` raises `Invalid_argument`.
- `Migration.apply` creates its bookkeeping table only when missing, so it
  runs on an up-to-date read-only database.

### Versioned migrations (sub-project 3b)

[Design](docs/design/migrations.md).

Added:
- `Migration`: `step version name kind` with kinds `create` (a
  declaration's CREATE TABLE), `add_column` (declared type and default, then
  SET NOT NULL for a non-null column), `drop_table`, `drop_column`,
  `rename_table`, `rename_column`, `sql` and `run` (code in the step's
  transaction). `apply` creates `main.duckdb_ml_migrations`, checks that the
  applied history is a prefix of the list, applies each pending step in its
  own transaction, optionally verifies declarations, and returns the
  versions it applied.
- `Error.context` `Migration { version; name }`; `Error.cause`
  `Migration_mismatch { version; expected; actual }`.
- `test/test_migration.ml`; 3 compile-failure fixtures in
  `test/migration_compile`.

Forward only. A `run` step's checksum covers its name only, so editing one
is not detected. `create` and `add_column` take the declaration as it was
when the step was written (a frozen copy); their checksums cover its
structure. `add_column` accepts literal defaults only. Two connections
migrating one database conflict on the bookkeeping key; the second fails and
finds the steps applied on a rerun (DuckDB's file lock keeps a second process
out).

### Schema declarations (sub-project 3a)

[Design](docs/design/schema.md).

Added:
- `Table.declare ~constraints`: `primary_key`, `unique`, `foreign_key`
  (typed against the referenced table's declared key, same schema),
  `default` (at the column's type and nullability), `check` (NULL fails)
  and `check_null` (NULL passes), over typed column binders. NOT NULL comes
  from codecs; keys take non-null columns only.
- `Table.create` (CREATE TABLE from the declaration), `Table.verify`
  (read-only catalog check: columns, types, nullability, keys and foreign
  keys exactly, CHECK by column set and DEFAULT by presence) and `Table.lookup` (by a
  declared key, typed `zero_or_one`).
- `Error.cause`: `Unknown_table` and `Constraint_mismatch`.
- `Sql.column`: a declared table column as a row expression, for CHECK.
- `test/test_schema.ml`; 7 compile-failure fixtures in `test/schema_compile`.

Changed:
- `duckdb.mli` declares `Sql` before `Table`; `Sql.from` names its table
  type `Request.table` (equal to `Table.t`).
- Examples create their tables with `Table.create`.

Raises `Invalid_argument` when a declaration is built: two primary keys, a
column from another declaration, a default mentioning a column, a foreign
key to an undeclared key or another schema, a lookup by an undeclared key.

### Typed SQL (sub-project 2)

[Design](docs/design/typed-sql.md).

Added:
- `Duckdb.Sql`: single-table SELECT queries built from phantom-typed
  expressions `('a, 'n, 'k) expr` that compile to an ordinary `Request.t`.
  `query`/`from` bind parameters and columns through GADT list patterns;
  `select` (many rows), `aggregate` (one row) and `group_by` with `~where`,
  `~having`, `~order_by`, `~limit`, `~offset`. Comparisons, `like`, boolean
  operators, three-valued `Null` operators, `nullable`/`coalesce`/`is_null`/
  `is_true`, per-type arithmetic (`I64` … `F32`; integer `/` is nullable),
  and the aggregates `count_star`, `count`, `sum`, `min`, `max`, `avg`.
- `examples/sql.ml`; `test/test_sql.ml`; 16 compile-failure fixtures in
  `test/sql_compile`.

Changed (breaking):
- `Table.t` and `Table.Columns` gain a `'shape` index (each column's value
  type and nullability, `Codec.slot`): `('columns, 'shape, 'row) Table.t`.
  Declarations are written as before; annotations and adapter signatures
  name the extra parameter.

Checked at run time: building a query raises `Invalid_argument` for an
expression used outside the query that bound it, operands of different
codecs (e.g. a string literal against a BLOB, a plain literal against a
custom codec), and an `aggregate` without any aggregate. On first prepare: a
declared parameter the query never uses (`Parameter_count`), and `~having` on
a `select` outside `group_by` unless its select list holds only literals and
parameters.

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
