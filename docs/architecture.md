# Architecture

The repository publishes four packages: `duckdb-ffi` contains the native C API
bridge; `duckdb` owns synchronous database resources; `duckdb-async` and
`duckdb-eio` are independent scheduler adapters over the safe core.

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

Typed rows, appender ingestion, transactions, and local Parquet import/export
are supported. Remote storage, credentials, and a SQL DSL are not supported.
