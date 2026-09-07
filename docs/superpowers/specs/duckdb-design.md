# duckdb.ml — approved project specification

## Intent

Build an OxCaml library for DuckDB, with optional Async and Eio integration. This is deliberately a learning and performance-engineering project exploring layouts, locality, ownership and parallelism through a useful database binding. Do not redirect toward Python or plain OCaml merely to minimize effort. OxCaml is an intentional dependency; upstream OCaml compatibility is not required.

Inspect the workspace and instructions, validate assumptions against current upstream documentation and small compiled experiments, then implement incrementally. Make routine design decisions autonomously. If a compiler feature or runtime incompatibility blocks the design, demonstrate it and propose the smallest viable adjustment.

## Packages

One repository, separate Dune libraries, independently installable packages:

- `duckdb-ffi`: public DuckDB C API bindings; unsafe pointers and representation-dependent code stay here.
- `duckdb`: safe synchronous OxCaml API, resource ownership, typed parameters and columns.
- `duckdb-async`: Async offloading, pooling, transactions and cancellation.
- `duckdb-eio`: Eio offloading, pooling, transactions and cancellation.

Both adapters depend on `duckdb`, not each other. The synchronous core starts no scheduler. No `duckdb-ox` package without concrete implementation evidence. Keep scheduler-specific code in adapters; no generic scheduler functor without substantial demonstrated duplication.

## Toolchain and platform

Initial target: x86-64 Arch Linux with glibc. Actual development host was observed to be Artix Linux x86-64; verify glibc/tool compatibility rather than assuming distribution equivalence. Deployment may be inside a bhyve Linux VM on FreeBSD; VM provisioning is excluded.

Pin OxCaml toolchain/repository revision and DuckDB version. Compile both Async and Eio against that exact toolchain early; ordinary OCaml support is not evidence. Provide reproducible instructions and native dependency documentation. Do not rely solely on the rolling system DuckDB package. Use a project-local setup; leave existing shared opam switches untouched. Ask before administrator-level installation.

Inspect existing OCaml DuckDB bindings for reusable work, license, quality and API coverage before adopting any code. No license choice for this project has yet been authorized; do not invent attribution or copy incompatible code.

## FFI

Use the public C API, not internal C++. Choose Ctypes-generated or handwritten C stubs from a working comparison, including runtime-lock release and unboxed accessors.

Long-running foreign calls release the runtime lock correctly. While released, never access movable OCaml heap data or call runtime functions requiring the lock. Copy or safely retain arguments before release. Follow documented ownership/destruction, including failed-operation cleanup. Prefer current chunk/vector APIs over deprecated accessors.

## Safe synchronous API

Abstract handles: databases, connections, prepared statements, results, chunks, appenders.

Support in-memory/file databases, configuration, deterministic close, SQL execution, prepared parameter binding, structured errors, scoped transactions with rollback on failure, chunk iteration, typed columns, bulk ingestion via appender, and internal interruption for adapters.

Initially support booleans, signed integers, floats, strings, blobs, NULL, dates and timestamps. Preserve integer widths and timestamp units explicitly. Unsupported types produce clear errors; no silent narrowing or precision loss. Use compact witnesses/GADTs where helpful. Validate dynamic SQL schemas at runtime; arbitrary SQL is not statically checked. No ORM or SQL DSL.

Define repeated-close behavior, parent closure with outstanding children, and which invalid-handle operations are statically rejected versus runtime errors before freezing interfaces.

### Local Parquet (approved addition)

Provide dedicated typed functions for querying local Parquet files, including multiple files, and exporting query results to local Parquet. Construct required DuckDB SQL internally with correct escaping/binding. Use DuckDB's engine, not a separate Parquet implementation. Include read/write round-trip tests in stage 3. Remote storage, credentials and networking are outside initial scope.

## Ownership and borrowed memory

Prototype and compile locality/uniqueness/borrowing before freezing the API. A borrowed column view must not outlive its owning chunk. `local` alone does not prove foreign lifetime: destruction, invalidation and owner reuse must also be prevented while views remain usable. Uniqueness does not imply deterministic destruction on every path; combine restrictions with scoped cleanup.

State limitations and use safe alternatives if a guarantee cannot be soundly expressed. Distinguish borrowed views from owned copies. Borrowed callbacks are initially synchronous; asynchronous transfers require explicit safe ownership. Foreign numeric buffers are not managed OxCaml arrays: no pointer-to-array representation casts. Nullable numeric columns carry values plus validity information; do not assume `or_null` supports arbitrary unboxed numerics.

## Adapters

Async returns deferred results with an explicit cancellation interface (deferreds are not automatically cancellable). Eio uses direct style with documented error behavior, respects cancellation contexts and protects required cleanup.

Use each runtime's blocking-thread facility and bounded admission. Offload potentially blocking fetching/flushing as well as execution. A connection is exclusively leased throughout a transaction; no interleaved statements by other borrowers. Define nested transactions explicitly. Cancellation locks must be independent of locks held during blocking queries.

Cancellation must cancel queued work without executing; interrupt running work; await foreign completion before reclaiming resources; clean results and transaction state; return only clean connections or discard them; and report cancellation idiomatically. Prevent delayed interruption for operation A reaching operation B after connection reuse. Cancellation does not prove a write did not commit; document that.

Pool shutdown stops admission, settles queued requests, drains or interrupts active work and closes in safe order.

## Validation and performance

Correct scalar/chunk implementation before SIMD. Benchmark owned-row decoding versus borrowed chunk traversal on identical data; measure elapsed time, allocations and GC, separating SQL execution from OCaml processing. Batch scheduling at query/chunk boundaries, never per cell.

Tests cover parameter/result round trips, NULL, numeric boundaries, timestamp units, scoped exceptions and early exit, invalid handles and repeated close, compile-time borrowed escape rejection where promised, transaction isolation between borrowers, queued/running/completion-racing cancellation, stale interruption, pool reuse/shutdown and scheduler responsiveness during long foreign calls. Use native memory diagnostics where available. No zero-copy, allocation-free or static-safety claims without evidence.

## Stages and decision gates

1. Toolchain compatibility checks and minimal end-to-end query. Demonstrate both adapter dependency stacks compile and compare stub approaches before choosing one.
2. Ownership and borrowed-column prototype. Positive and negative compile tests and invalidation/cleanup evidence precede API freeze.
3. Safe synchronous API, appender and typed local Parquet functions.
4. Async and Eio adapters.
5. Cancellation/shutdown hardening, benchmarks and documentation.

Plan each stage based on prior experimental evidence instead of speculating about future signatures. Deliver working code, examples for all three public APIs, reproducible instructions, tests, and concise guarantees/limitations. Do not mark unimplemented later stages complete.
