# Core redesign (design note)

Status: proposed. Sub-project 1 of 3. It builds on the typed request and
table layers ([typed-requests.md](typed-requests.md)) at `4a0712df`.

## Goal

Make the public API as statically precise as the pinned OxCaml compiler
allows. GADTs index everything that has a type-level shape. OxCaml modes
(`local`, `once`, `unique`, portability) replace runtime lifecycle checks
where they can do so soundly. The package is unreleased (0.1.0), so
duplicate and superseded forms are removed, not deprecated.

The work is split into three sub-projects. Each gets its own design note,
plan and implementation:

| # | Sub-project | Scope |
|---|---|---|
| 1 | Core redesign (this note) | Scoped `@ local` handles, one kind-indexed session type, `Codec` as the only value description, one shared list structure, a shape GADT for execution, one error type |
| 1b | Performance | A measured baseline (full benchmark run, several samples), then in order of payoff: columnar bulk reads (whole DuckDB vectors into OCaml arrays/Bigarrays in one native call), unboxed numbers (`int64#`, `float#`) through the decode path, allocation-free decoding for codecs without custom conversion, and `[@zero_alloc]` proofs on the borrowed path. Comes before typed SQL, which decodes through the same path |
| 2 | Typed SQL | GADT expressions and a query builder that compile to `Request.t` ([Appendix A](#appendix-a-typed-sql-end-state-sketch)) |
| 3 | Schema and migrations | Constraints on table declarations, then versioned migrations |
| later | `[@@deriving duckdb]` | Optional ppx that generates `Columns`/row declarations. Added only if hand-written declarations turn out to be tedious; nothing in 1–3 depends on it |

Sub-project 2 reverses the earlier non-goal "no SQL DSL" in
`docs/architecture.md` and in the L3 row of `typed-requests.md`. Those
documents are updated when sub-project 2's design is approved. Its design
note decides whether it ships inside `duckdb` or as a separate package.

## Decisions taken

| Question | Decision |
|---|---|
| Compatibility | Break freely. Nothing has been released |
| ppx | None in sub-projects 1–3. GADT values are written by hand |
| OxCaml depth | Modes are used wherever they are sound and readable without borrowing. Full typestate (threading unique handles through every call) waits for OxCaml borrowing |
| Handle lifecycle | Scopes only in the public synchronous API. A runtime-checked `Owned` module serves the scheduler adapters |
| Sequencing | Bottom-up. Appendix A constrains sub-project 1 so that sub-project 2 needs no rework |

## Compiler facts this design relies on

Probed with `_opam/bin/ocamlopt` (OxCaml on OCaml 5.2.0):

| Feature | Result |
|---|---|
| `@ unique` parameters | Works. A second `close t` after `close t` is rejected |
| `@ once` closures | Works |
| `@ local` | Works (already used for chunks) |
| Borrowing (`&t`) | Not available (`Unbound value "(&)"`) |
| Lending a unique value to an aliased use and then consuming it | Rejected ("already been used") |
| A unique value returned inside a tuple | Rejected when any component is aliased (P1); the design avoids it |

Probes run before the plan (P1–P3), all done:

- **P1 (done).** A unique request cannot be returned in one tuple together
  with an aliased canceller: a tuple (boxed or unboxed) that contains an
  aliased component is aliased as a whole. A two-step API works:
  `canceller : unit -> canceller`, then
  `request : canceller -> request @ unique`, with
  `type request = { cell : canceller @@ aliased }`. Without the
  `@@ aliased` modality the canceller is consumed into the unique record.
  A double `run r` is rejected ("already been used as unique").
- **P2 (done).** An unannotated helper `let helper c = query c + 1`, where
  `query` takes `c @ local`, is inferred as `conn @ local -> int`. Users do
  not annotate helpers that pass handles along.
- **P3 (done).** `float32`, `int8` and `int16` exist under
  `-extension-universe beta`, with literals `1.5s`, `1s` and `1S`. An
  out-of-range literal (`200s : int8`) is a compile error: "Integer literal
  exceeds the range of representable integers of type int8".
- **P4 (done, found while planning).** Every scope runs its callback through
  the effect barrier (`Resource.scope`, then `without_escaping_effects`, then
  `Stdlib.Effect.Deep.try_with`). `try_with` and `Sys.with_async_exns` take
  plain (global, many) closures. Scope callbacks therefore cannot be
  `@ local` or `@ once` without an unsafe mode cast, which `AGENTS.md`
  forbids. Callbacks stay ordinary closures that *receive* `@ local` handles.
  Consequence: no scope callback can capture any local handle. The
  busy-capture rule covers every scope, including `with_connection` and
  `with_prepared`. Combining two scoped handles needs `Owned`, or folding
  into an OCaml value.
- **P5 (done).** A GADT whose payloads carry `@@ global`
  (`Connection : inner @@ global -> [ \`Connection ] session`) lets a
  function matching a `@ local` session store the global payload. Storing,
  returning or capturing the session itself is rejected ("is \"local\" to the
  parent region").

## 1. Handles and modes

### One session type, indexed by kind

```ocaml
type database
type _ session            (* abstract in the .mli *)
type connection = [ `Connection ] session
type transaction = [ `Transaction ] session
```

Internally `session` is a GADT:

```ocaml
type _ session =
  | Connection : conn_state -> [ `Connection ] session
  | Transaction : tx_state -> [ `Transaction ] session
```

Operations valid on either kind take `_ session`: `execute`,
`Statement.with_prepared`, `Table.with_appender`, and the `Request`
operations. This removes every `*_transaction` duplicate:

- `execute_transaction`
- `prepare_transaction`
- `with_prepared_transaction`
- `with_appender_transaction`
- `Table.with_appender_transaction`
- the separate `Request.Transaction` module

Inside the library, the `transaction option` threaded through
`with_admission`, `register_child`, `lend_child` and similar functions
becomes a match on the session.

Operations that need a connection say so. Nested transactions are
therefore a type error:

```ocaml
val with_transaction : connection @ local -> f:(transaction @ local -> ('a, Error.t) result) @ once ->
  ('a, Error.t) result
```

### Handles come only from scopes and are local

```ocaml
val with_database   : Config.t -> f:(database @ local -> ('a, Error.t) result) @ once -> ('a, Error.t) result
val with_connection : database @ local -> f:(connection @ local -> ('a, Error.t) result) @ once -> ('a, Error.t) result
```

`open_database`, `close_database`, `connect`, `close_connection`, `prepare`,
`close_prepared`, `open_appender` and `close_appender` leave the public
synchronous API. A handle cannot end up in a result, a ref or a global
closure, so use-after-close cannot be written. The runtime alias-revocation
machinery is no longer needed for synchronous code. Callbacks are ordinary
closures (P4); they receive local handles but cannot capture one.

`query_result`, `execute_prepared` and `close_result` are removed.
`Statement.fold_chunks : prepared @ local -> init:'a -> f:(chunk @ local -> 'a -> ('a step, Error.t) result) -> ('a, Error.t) result`
executes with the current bindings and folds inside the result lease, as
the `Request` operations do. No result handle exists outside a fold.

### Callbacks that run while a handle is busy are global

Row-fold callbacks and the `with_transaction` callback are typed as global
closures (the default mode). A closure that captures a local handle is
itself local, so it cannot be passed there. Two runtime `Busy` cases become
compile errors:

- issuing a query on `conn` from a row callback of a fold over `conn`;
- using `conn` inside `with_transaction conn`'s callback, which can reach
  only the transaction it is given.

The cost: those callbacks cannot capture any local value, such as a second
connection. Moving data between two databases means folding into an OCaml
value first. Because of P4 this applies to every scope callback, not only
busy periods.

### Uniqueness where ownership really transfers

`Bridge.canceller ()` creates an aliased, thread-shareable canceller.
`Bridge.request c` creates a unique request bound to it (P1). `run`
consumes the request, so a request cannot run twice (today that is a
runtime `Closed`). One canceller may back several requests, and `cancel`
latches all of them. Cancelling after every request has settled is a
no-op that returns `Ok ()`, not `Closed`. `settlement` moves to the
canceller.

Uniqueness is not used elsewhere. Without borrowing, a unique session
would have to be threaded through every call.

### Portability

Handle types declare no mode crossing, so the compiler stops them from
crossing domains. The documented rule that handles are not domain-safe
becomes a type check.

### `Owned`: the adapters' lifecycle

`Duckdb.Owned` keeps `open_database`, `connect`, `close_connection` and
`close_database` over owned (global) handles, with today's runtime checks.
It also exposes `shape`/`run` ([section 2](#requests-and-the-shape-gadt)).
It is documented as the interface for scheduler adapters. The Async and
Eio pool state machines (reconnect, discard, settlement) are unchanged in
structure and move to it.

## 2. Values, rows and requests

### `Codec` is the only value description

`Scalar.field` is removed. Binding, reading, appending and (later)
expressions take `('a, 'n) Codec.t`. The representation stays:

```ocaml
type ('a, 'n) t =
  | Non_null : 'a plan -> ('a, non_null) t
  | Nullable : 'a plan -> ('a option, nullable) t
```

`decode_value` stops converting each codec back into a field before
reading. Codecs are inspectable inside the library (base scalar plus
nullability), as Appendix A needs. The nullability index (`non_null`,
`nullable`) is defined once, here, and reused by expressions.

### Exact small numeric types

The witnesses become `Int8 : int8 t`, `Int16 : int16 t` and
`Float32 : float32 t` (P3). Out-of-range and non-round-tripping values
cannot be represented, and out-of-range literals are compile errors.
`Scalar.validate`'s range checks, the `Range` error and `round_float32` are
deleted. Converting from `int` or `float` becomes the caller's explicit
choice, using the compiler library's conversions.

### One structure for every typed list

`Fields` (codecs), `Columns` (named codecs) and, later, `Exprs` share one
structure: indices `('list, 'fn, 'result)`, constructors `[]`/`(::)` for
list-literal syntax and `fun [a; b] ->` patterns, and a curried row
constructor. It is defined once:

```ocaml
module Spine : sig
  module Make (E : sig type ('a, 'n) t end) : sig
    type ('list, 'fn, 'result) t =
      | [] : (unit, 'result, 'result) t
      | (::) : ('a, _) E.t * ('list, 'fn, 'result) t -> ('a * 'list, 'a -> 'fn, 'result) t
  end
end
```

The traversals (length, iteration, re-indexing from one element type to
another through a polymorphic record) are written once.
`fields_of_columns` becomes such a re-indexing. `Args` stays the plain list
of values.

### `Row.t` and `cell` are removed

Every decoder is a `Fields.t` plus a curried `~row`. This includes
`Parquet.fold` and the adapters' raw-SQL `query`/`fold_rows`. Appending is
public only through `Table`: columns are matched by name, rows are
`'cols Args.t`, and the whole batch is validated before any native call.
The `cell list list` appender becomes private plumbing under `Table`.

### Requests and the shape GADT

`Request.t` keeps the row count as a type index only. The runtime
`multiplicity` field is deleted: it is written but never read
(`lib/duckdb/request.ml:9-29`), and its comment claiming that execution
uses it is wrong.

Execution is one function per layer, driven by a shape GADT:

```ocaml
type ('row, 'out) shape =
  | Exec     : (unit, unit) shape
  | Find     : ('row, 'row) shape
  | Find_opt : ('row, 'row option) shape
  | Collect  : ('row, 'row list) shape
  | Fold     : { init : 'a; f : 'row -> 'a -> ('a step, Error.t) result } -> ('row, 'a) shape

val run : _ session @ local -> ('row, 'out) shape -> ('p, 'row, _) Request.t -> 'p Args.t ->
  ('out, Error.t) result
```

The synchronous core, the worker capsule and both adapters each implement
`run` once, instead of exec/find/find_opt/collect/fold separately (five
functions in each of four layers today). The public `exec`, `find`,
`find_opt`, `collect` and `fold` are one-line wrappers that keep the
row-count guards (`[< \`One ]` and so on). The guards stay on named
functions because a polymorphic-variant upper bound cannot be attached
cleanly to a GADT constructor. `shape` and `run` are exported through
`Owned`, not as user-facing API.

## 3. Errors

`Duckdb.error`, `Scalar.error` (as `Data_error`) and `Request.request_error`
(with `Core of error`) merge into one type with no nesting:

```ocaml
module Error : sig
  type context =
    | Database | Connection | Transaction
    | Query of string | Table of { schema : string; name : string } | Parquet of string
  type cause =
    | Invalid_configuration of string | Embedded_nul | Closed | Busy | Cancelled
    | Native of string | Unsupported_statement | Effects_not_allowed
    | Type_mismatch of { index : int; expected : string; actual : string }
    | Null of { column : int; row : int }
    | Parameter_count of { expected : int; actual : int }
    | Column_count of { expected : int; actual : int }
    | Parameter_schema_changed
    | Row_count of { expected : [ `One | `Zero_or_one ]; actual : [ `Zero | `More_than_one ] }
    | Unknown_column of { name : string } | Missing_column of { name : string }
    | Encode_rejected of { index : int; reason : Base.Error.t }
    | Decode_rejected of { column : int; row : int; reason : Base.Error.t }
    | Destination_exists | Unsupported_parquet_type of { column : int; actual : string }
    | Rollback_failed of { primary : t; rollback : t }
  and t = { context : context; cause : cause }
end
exception Cleanup_exception of Error.t * exn
```

- **Removed causes, now impossible:**
  - `Live_children`: handles are scoped and folds stay inside the lease.
  - `Range`: values are exact `int8`/`int16`/`float32` (P3).
- **Kept but narrowed:** `Closed` and `Busy` are reachable only through
  `Owned`/the adapters, overlapping `Bridge` use, and the capture cases that
  the global-callback rule does not cover. Each function documents which
  causes it can return.
- `Unbound_parameter` and `Index` are kept, reachable only through
  `Statement` (positional `bind`, chunk `column` access). Typed requests
  cannot produce them.
- Where `Live_children` used to be returned, `Owned.close_database` with open
  connections and `Bridge.run` on an owner with live statements return `Busy`.
- `Bridge.cancel : canceller -> unit`: with no failure mode left, it returns
  `unit`.
- **Type names, not native ids:** `actual` fields carry a type name instead
  of a raw native id.
- **One exception:** `Rollback_exception` and the two `Cleanup_exception`s
  merge into one exception.
- **Rejected alternative:** polymorphic-variant error sets per operation.
  They are precise, but every signature and compiler message grows.

## 4. Public API after the redesign

| Module / values | Contents |
|---|---|
| `Config`, `Error` | Configuration; the one error type |
| `Scalar`, `Codec`, `Fields`, `Columns`, `Args` | Witnesses and the shared list structure |
| `with_database`, `with_connection`, `with_transaction`, `execute` | Scopes only; `_ session` handles |
| `Request` | Requests built from strings; `exec`/`find`/`find_opt`/`collect`/`fold` on `_ session` |
| `Table` | `declare`, `select`, `insert`, `with_appender`, `append`, `flush` |
| `Statement` | Low-level escape hatch: `with_prepared`, codec-typed `bind`, `parameter_count`, `fold_chunks`, `column` |
| `Parquet` | `path`, `fold`, `fold_table`, `export` |
| `Bridge` | `canceller`, `request` (unique, bound to a canceller), `run`, `cancel`, `settlement` |
| `Owned` | Runtime-checked lifecycle plus `shape`/`run`, for adapters |

Both adapters expose one `QUERY` signature over their pools.
`with_transaction` there gives the callback a `@ local` transaction on the
worker thread. `duckdb.worker`'s `S` shrinks to its lifecycle,
`transaction`, `ingest`, `run` and Parquet operations.

## 5. Testing and migration

- **New compile-failure fixtures**, one per new static guarantee:
  - a handle escaping a scope (into a result, a ref and a global closure);
  - running a `Bridge` request twice (P1);
  - capturing the busy connection in a fold callback;
  - capturing the connection in `with_transaction`'s callback;
  - `with_transaction` on a transaction;
  - an out-of-range `int8` literal passed as a parameter.
- **Existing fixtures:** the 21 files in `test/request_compile` and the
  other `*_compile` suites are ported to the new API. Each keeps its
  original meaning or is removed with a stated reason.
- **Runtime tests for errors that become impossible:** 23 test files use
  `Closed`, `Busy` or `Live_children`. For each one, the plan records
  whether it becomes a compile-failure fixture, stays a runtime test via
  `Owned`/the adapters, or is removed because its scenario cannot be
  written.
- **Mutation scripts and Eio mutants** are checked again. A mutant that can
  no longer fail is retired with a comment, as in the typed-requests work.
- **Docs and examples:** `docs/architecture.md`,
  `examples/synchronous.ml` and `CHANGELOG.md` are rewritten for the new
  API.

## Appendix A: typed SQL end-state sketch

This appendix is not part of sub-project 1. It records what sub-project 1
must not block.

**Indices.** An expression is `('a, 'n, 'k) Expr.t`:

- `'a`: the OCaml value type, from a `Codec`. Custom codecs work in
  expressions.
- `'n`: nullability, the `Codec` index. Operators require equal `'n` on
  both sides, and `nullable e` lifts explicitly.
- `'k`: grouping kind (`row | grouped`).

**Scopes are lambdas (higher-order abstract syntax).** Columns and
parameters are bound positionally through GADT list patterns:

```ocaml
let users = Table.declare "users"
  Columns.["id", int64; "name", string; "age", nullable int32]
  ~row:(fun id name age -> { id; name; age })

let adults = Query.(
  params Fields.[int32] (fun [min_age] ->
    from users (fun [id; name; age] ->
      where (age >= nullable min_age)
      |> select [id; name] ~row:(fun id name -> (id, name)))))
(* : (int32 * unit, int64 * string, many) Request.t *)
```

**Grouping.** `group_by` rebinds its keys as `grouped`. Aggregates map
`row` to `grouped`. Using an outer row column inside a grouped `select`
does not type-check.

**Row count from structure.** An aggregate with no GROUP BY returns `one`.
A primary-key lookup returns `zero_or_one` (sub-project 3). Everything else
returns `many`.

**Output.** A compiled query is an ordinary `('params, 'row, 'm)
Request.t`. Literals render as typed SQL and parameters as `$n`. The
execution, cache, validation and adapters are unchanged.

**Requirements on sub-project 1:**

1. `Request.t` stays the single executable value, buildable from a string
   or from a compiled query.
2. `Codec` is inspectable inside the library.
3. The nullability index is defined once and shared.
4. `Spine` serves `Fields`, `Columns` and `Exprs`.
5. The row count stays a polymorphic-variant index.
6. `Table` keeps its column list as an inspectable GADT.

**Deferred to sub-project 2:**

- A lambda-bound parameter is monomorphic in `'k`. The fix is variance on
  `'k` or an explicit `const` lift.
- Scope leaks (an expression used outside its query) are not checked
  statically. DuckDB rejects them at first prepare, and validation reports
  it.
