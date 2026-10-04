# Architecture

The repository publishes four packages: `duckdb-ffi` contains the native C API
bridge; `duckdb` owns synchronous database resources; `duckdb-async` and
`duckdb-eio` are independent scheduler adapters over the safe core. Both
adapters apply the same `duckdb.worker` functor (`Duckdb_worker.Make`) to get
their synchronous owner capsule. Its `Probe` argument is the only seam tests
need, so instrumented builds inject observers instead of patching sources.

Inside `duckdb`, admission, cleanup and settlement are small combinators in
`Resource`. Admission runs an ordered list of checks under the owner gate.
`acquiring` releases a fresh native owner on any failure. `close_once` and
`force_close` give manual and scoped close. `settle` combines a failed outcome
with its rollback. `Query`, `Appender` and `Parquet` are built from these.

Database, connection, statement, result, chunk, and appender lifetimes are
explicit and scoped. Borrowed chunk views are usable only in their synchronous
owner callback; copy to owned values before retaining data. A completed close is
idempotent and succeeds when repeated. Invalid handles, and parent close attempts
with live children, return documented errors rather than exposing native handles.

Adapters use bounded admission. Cancellation can remove queued work or interrupt
running work, but it cannot prove a write did not commit. Shutdown stops
admission, settles queued work, drains or interrupts active work, and closes
resources in dependency order. Async callers observe completion through its
request interface; Eio callers retain their own cancellation context while
protected cleanup drains.

Above that core sits an optional typed layer
([design](design/typed-requests.md)). A `Request` is a value: SQL text, typed
parameters, typed rows, and a multiplicity phantom that decides whether
`exec`, `find`, `find_opt`, `collect` or `fold` accept it. It is checked
against engine metadata when first prepared, and prepared statements are
cached per connection (LRU, `Config ?statement_cache`). A `Table` declaration
drives typed appender rows, a typed SELECT and INSERT, and Parquet decoding,
and is checked against the catalog by column name. `Request.CONNECTION` is
implemented by the synchronous connection and by each adapter's
`Request.Generic`. The low-level API is unchanged; the typed layer only adds.

Parameterized statements are re-validated only when a schema change may have
become visible. A process-wide schema epoch advances around every
CREATE/ALTER/DROP and on settlement of a transaction that ran one.

Typed rows, appender ingestion, transactions, and local Parquet import/export
are supported. Remote storage, credentials, and a SQL DSL are not supported.
