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

## Sessions and scopes

A handle is a `database` or a `_ session`. The session type is indexed by
kind: ``connection = [ `Connection ] session`` and
``transaction = [ `Transaction ] session``. Internally it is a GADT whose
constructors carry their state as `@@ global` payloads, so a function
matching a local session can still store the state it needs. Operations
valid on either kind (`execute`, `Statement.with_prepared`,
`Table.with_appender`, `Request.Session`) take `_ session`; operations that
need a connection say so, so a nested `with_transaction` is a type error.

Handles come only from scopes (`with_database`, `with_connection`,
`with_transaction`, `Statement.with_prepared`, `Table.with_appender`) and are
`@ local` to the callback. A handle cannot be returned, stored in a ref or
captured by a global closure, so use-after-close cannot be written. Scope
callbacks are ordinary (global) closures that receive local handles, so they
cannot capture another local handle either: a query on a connection from
inside a fold over it, or use of the connection inside its own transaction
callback, is a compile error rather than a runtime `Busy`. Moving data
between two scopes means folding into an OCaml value first. The runtime
effect barrier (`Effects_not_allowed`) stays: an effect handler installed
outside a scope could otherwise keep a continuation holding a local handle.

Sequencing on a local handle cannot use a plain `let*`, because a binding
operator's continuation is a global closure and so cannot use the handle.
Use Base's `Result.bind` (its `~f` is local) for one step, with
`[@nontail]` because a local closure cannot be an argument in a tail call:

```ocaml
let count_and_sum (session @ local) =
  Result.bind (Request.Session.find session count Args.[]) ~f:(fun n ->
    Result.map (sum_above session 0L) ~f:(fun sum -> n, sum)) [@nontail]
```

For several steps, use `match … with Error e -> Error e | Ok v -> …`
(`examples/synchronous.ml`). With `ppx_let`, `let%bindl_fun` and
`Base.Result.Let_syntax` also work, since the ppx stack-allocates the
continuation; the library itself stays ppx-free. A helper that only passes a
handle along is inferred local. A helper that captures one in a closure is
inferred global, and the error then appears at its call site; annotate the
parameter `(c @ local)`.

`Owned` is the runtime-checked lifecycle for scheduler adapters:
`open_database`, `connect`, `close_connection` and `close_database` over
owned (global) handles, with `Closed` and `Busy` checked at run time. The
Async and Eio pools use it. Owned connections keep those dynamic checks; the
revocation and drain machinery in `Resource` also stays as defence in depth.

`Statement` is the low-level escape hatch: positional `bind` with codecs,
`parameter_count`, `reset`, `fold_chunks` and `execute`. `fold_chunks`
executes and folds borrowed chunks inside the result lease; `execute` runs
it and discards the rows. No result handle exists outside the fold, and a
borrowed chunk is usable only inside its callback; `column` copies values
out as owned values.

## Values, requests and tables

`Codec` is the only value description: a base `Scalar` witness, optionally
nullable (the `non_null`/`nullable` index rules out `nullable (nullable _)`),
optionally mapped to a user type with `custom`. Binding, reading and
appending all take codecs. `int8`, `int16` and `float32` are exact
(`int8`/`int16`/`float32` OCaml types), so out-of-range values cannot be
represented. `Fields` (codecs) and `Table.Columns` (named codecs) are two
instances of one `Spine` list structure with list-literal syntax and a
curried row constructor; `Args` is the plain list of values.

A `Request` is a value: SQL text, typed parameters, typed rows and a row
count index that decides whether `exec`, `find`, `find_opt`, `collect` or
`fold` accept it. It is checked against engine metadata when first
prepared, and prepared statements are cached per connection (LRU,
`Config ?statement_cache`). Execution is one shape-driven function per
layer: `Owned.run` takes a `('row, 'out) Owned.shape` (`Exec`, `Find`,
`Find_opt`, `Collect`, `Fold`), and the named operations are one-line
wrappers that keep the row-count guards. The synchronous core, the worker
capsule and both adapters each implement `run` once. `Request.CONNECTION`
is implemented by `Request.Session` (both session kinds) and by each
adapter's `Request.Generic`.

A `Table` declaration drives typed appender rows, a typed SELECT and INSERT,
and Parquet decoding, and is checked against the catalog by column name.
It is the only append path: a batch is validated before any native row
mutation.

Parameterized statements are re-validated only when a schema change may have
become visible. A process-wide schema epoch advances around every
CREATE/ALTER/DROP and on settlement of a transaction that ran one.

## Errors

Every operation returns one flat `Error.t = { context; cause }`. The context
says where (`Database`, `Connection`, `Transaction`, `Query sql`, `Table`,
`Parquet path`); the cause says why. A failed rollback keeps both errors
(`Rollback_failed { primary; rollback }`), and an error followed by an
exceptional cleanup is `Cleanup_exception`. Rows in `Null` and
`Decode_rejected` are absolute within the result for typed requests and
adapter queries, and chunk-relative for `Statement.column`. `Index` and
`Unbound_parameter` come only from `Statement`.

## Bridge and adapters

`Bridge.canceller ()` is aliased and shareable across threads.
`Bridge.request c` is a `@ unique` request bound to it; `run` consumes the
request, so running it twice is a type error. `cancel` latches the canceller
and every request bound to it, and is a no-op returning `unit` once they
have settled. `settlement` is reported per canceller.

Adapters use bounded admission. Cancellation can remove queued work or interrupt
running work, but it cannot prove a write did not commit. Shutdown stops
admission, settles queued work, drains or interrupts active work, and closes
resources in dependency order. Async callers observe completion through its
request interface; Eio callers retain their own cancellation context while
protected cleanup drains. Adapter transaction callbacks receive a local
`transaction` on the worker thread.

## Scope

Typed rows, appender ingestion, transactions, and local Parquet import/export
are supported. Remote storage and credentials are not supported. A typed SQL
layer is planned (sub-project 2 of `docs/design/core-redesign.md`), after a
performance sub-project (1b: columnar bulk reads, unboxed numbers,
allocation-free decoding). See [typed requests](design/typed-requests.md) and
the [core redesign](design/core-redesign.md).
