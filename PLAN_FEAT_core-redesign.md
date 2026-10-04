# Core Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement sub-project 1 of `docs/design/core-redesign.md`:

- scoped `@ local` handles behind one kind-indexed session GADT;
- `Codec` as the only value description, with exact `int8`/`int16`/`float32`;
- one list structure (`Spine`);
- a shape GADT for execution;
- one flat error type;
- a unique `Bridge` request;
- an `Owned` module for the scheduler adapters.

**Architecture:** The internals (`Resource`, `Query`, `Appender`, `Request`)
stay global-mode code and keep every runtime check. A new private module
(`Session`) defines the public handle GADT. Its payloads carry the
`@@ global` modality, so public functions take `@ local` handles and unwrap
them to global internals. The mode boundary is the facade only. Each task
keeps the tree building and the test suite passing, and ends in one jj
commit.

**Tech Stack:** OxCaml (OCaml 5.2.0 + extensions, `-extension-universe beta`),
Base, Dune via `./tools/run`, DuckDB through `duckdb-ffi`, Async and Eio
adapters, jj.

---

## Read first

- `AGENTS.md`, `docs/development.md`, `docs/design/core-redesign.md` (the
  spec), and `docs/design/typed-requests.md` (the previous layer).
- **Toolchain:** always use `./tools/run …` (local OxCaml and DuckDB). Never
  use a shared switch, and never use `git`; use `jj`.
- **Build:** `./tools/run build @all 2>&1 | tail -30` must print nothing
  after the last line of the command.
- **Tests:** `./tools/run runtest --force 2>&1 | tee .local/core-redesign/<task>.log | tail -40`.
  It must exit 0. The compile-fixture suites print their `...=ok` lines.
- **Commit at the end of each task:**
  `jj describe -m "<message>\n\nCo-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>" && jj new`.
- **Logs:** run `mkdir -p .local/core-redesign` once. Keep every task's test
  log there (`.local` is ignored).
- **Mechanical migrations:** where a task changes many call sites in the same
  way, it gives the exact rewrite rule and the complete list of files. Apply
  the rule to every listed file, then let the compiler find what is left:
  `./tools/run build @all` must reach zero errors before tests run.

## Compiler facts (verified; see the design note's probe section)

| Fact | Consequence |
|---|---|
| `type _ session = Connection : inner @@ global -> [ \`Connection ] session` compiles. Matching a `@ local` session yields a global `inner` that may be stored | The facade can take `@ local` handles over global internals |
| Storing, returning or capturing a local handle in a global closure is rejected ("is \"local\" to the parent region") | The escape and busy-capture fixtures work |
| `Stdlib.Effect.Deep.try_with` and `Sys.with_async_exns` take plain (global, many) closures | Scope callbacks cannot be `@ local` or `@ once` (see Task 1) |
| `Base.Exn.protect` takes `@ local once` closures | Not needed after the line above |
| `int8`/`int16`/`float32` with literals `1s`/`1S`/`1.5s`. `Stdlib_stable.Int8.{of_int,to_int}`, `Int16.{of_int,to_int}`, `Float32.{of_float,to_float}` (library `stdlib_stable`) | Exact small numeric witnesses |
| `type request = { cell : canceller @@ aliased }` lets `request : canceller -> request @ unique` work. A double `run r` is rejected ("already been used as unique") | Unique Bridge requests |

## Target public interface (end state of this plan)

Tasks move `lib/duckdb/duckdb.mli` toward this incrementally. Doc comments
are carried over from the current file wherever the meaning is unchanged.

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
    | Index of { index : int; length : int }          (* Statement only *)
    | Unbound_parameter of int                         (* Statement only *)
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

module Scalar : sig
  type _ t =
    | Bool : bool t | Int8 : int8 t | Int16 : int16 t | Int32 : int32 t | Int64 : int64 t
    | Float32 : float32 t | Float64 : float t | String : string t | Blob : string t
    | Date : int32 t | Timestamp_s : int64 t | Timestamp_ms : int64 t
    | Timestamp_us : int64 t | Timestamp_ns : int64 t | Timestamp_tz : int64 t
  val name : 'a t -> string
end

module Codec : sig
  type non_null
  type nullable
  type ('a, 'n) t
  module Values : sig
    val bool : (bool, non_null) t
    val int8 : (int8, non_null) t
    val int16 : (int16, non_null) t
    val int32 : (int32, non_null) t
    val int64 : (int64, non_null) t
    val float32 : (float32, non_null) t
    val float64 : (float, non_null) t
    val string : (string, non_null) t
    val blob : (string, non_null) t
    val date : (int32, non_null) t
    val timestamp_s : (int64, non_null) t
    val timestamp_ms : (int64, non_null) t
    val timestamp_us : (int64, non_null) t
    val timestamp_ns : (int64, non_null) t
    val timestamp_tz : (int64, non_null) t
    val of_scalar : 'a Scalar.t -> ('a, non_null) t
    val nullable : ('a, non_null) t -> ('a option, nullable) t
    val custom : encode:('a -> 'b Base.Or_error.t) -> decode:('b -> 'a Base.Or_error.t) ->
      ('b, non_null) t -> ('a, non_null) t
  end
end
module Fields : sig
  include module type of Codec.Values
  type ('list, 'fn, 'result) t =
    | [] : (unit, 'result, 'result) t
    | (::) : ('a, _) Codec.t * ('list, 'fn, 'result) t -> ('a * 'list, 'a -> 'fn, 'result) t
end
module Args : sig
  type 'list t = [] : unit t | (::) : 'a * 'list t -> ('a * 'list) t
end
type 'a step = Continue of 'a | Stop of 'a

module Config : sig (* as today, errors are Error.t *) end

type database
type _ session
type connection = [ `Connection ] session
type transaction = [ `Transaction ] session

val with_database : Config.t -> f:(database @ local -> ('a, Error.t) result) -> ('a, Error.t) result
val with_connection : database @ local -> f:(connection @ local -> ('a, Error.t) result) -> ('a, Error.t) result
val with_transaction : connection @ local -> f:(transaction @ local -> ('a, Error.t) result) -> ('a, Error.t) result
val execute : _ session @ local -> string -> (unit, Error.t) result

module Statement : sig
  type prepared
  type chunk
  val with_prepared : _ session @ local -> string -> f:(prepared @ local -> ('a, Error.t) result) -> ('a, Error.t) result
  val parameter_count : prepared @ local -> (int, Error.t) result
  val bind : prepared @ local -> int -> ('a, _) Codec.t -> 'a -> (unit, Error.t) result
  val reset : prepared @ local -> (unit, Error.t) result
  val fold_chunks : prepared @ local -> init:'a -> f:(chunk @ local -> 'a -> ('a step, Error.t) result) -> ('a, Error.t) result
  val chunk_length : chunk @ local -> int
  val column : chunk @ local -> column:int -> row:int -> ('a, _) Codec.t -> ('a, Error.t) result
end

module Request : sig
  type zero = [ `Zero ]  type one = [ `One ]
  type zero_or_one = [ `Zero | `One ]  type many = [ `Zero | `One | `Many ]
  type ('params, 'row, 'multiplicity) t
  type ('columns, 'row) table
  val exec : ?oneshot:bool -> ('params, _, _) Fields.t -> string -> ('params, unit, zero) t
  val one : ?oneshot:bool -> ('params, _, _) Fields.t -> (_, 'fn, 'row) Fields.t -> row:'fn -> string -> ('params, 'row, one) t
  val zero_or_one : (* same shape *) ...
  val many : (* same shape *) ...
  val query : (_, _, _) t -> string

  module type QUERY = sig
    type _ owner
    type error
    type 'a future
    val exec : _ owner @ local -> ('p, unit, [< `Zero ]) t -> 'p Args.t -> (unit, error) result future
    val find : _ owner @ local -> ('p, 'row, [< `One ]) t -> 'p Args.t -> ('row, error) result future
    val find_opt : _ owner @ local -> ('p, 'row, [< `Zero | `One ]) t -> 'p Args.t -> ('row option, error) result future
    val collect : _ owner @ local -> ('p, 'row, [< `Zero | `One | `Many ]) t -> 'p Args.t -> ('row list, error) result future
    val fold : _ owner @ local -> ('p, 'row, [< `Zero | `One | `Many ]) t -> 'p Args.t ->
      init:'a -> f:('row -> 'a -> ('a step, Error.t) result) -> ('a, error) result future
  end
  module type CONNECTION = sig
    include QUERY
    val with_transaction : [ `Connection ] owner @ local -> f:(transaction @ local -> ('a, Error.t) result) ->
      ('a, error) result future
    val ingest : [ `Connection ] owner @ local -> ('columns, _) table -> 'columns Args.t list list -> flush:bool ->
      (unit, error) result future
  end
  module Session : CONNECTION
    with type 'k owner = 'k session and type error = Error.t and type 'a future = 'a
end

module Table : sig
  type ('columns, 'row) t = ('columns, 'row) Request.table
  module Columns : sig (* as today *) end
  val declare : ?schema:string -> string -> ('columns, 'fn, 'row) Columns.t -> row:'fn -> ('columns, 'row) t
  val select : (_, 'row) t -> (unit, 'row, Request.many) Request.t
  val insert : ('columns, _) t -> ('columns, unit, Request.zero) Request.t
  type ('columns, 'row) appender
  val with_appender : _ session @ local -> ('columns, 'row) t ->
    f:(('columns, 'row) appender @ local -> ('a, Error.t) result) -> ('a, Error.t) result
  val append : ('columns, _) appender @ local -> 'columns Args.t list -> (unit, Error.t) result
  val flush : (_, _) appender @ local -> (unit, Error.t) result
end

module Parquet : sig
  type path
  val path : string -> (path, Error.t) result
  val export : connection @ local -> query:string -> path -> (unit, Error.t) result
  val fold : connection @ local -> path list -> (_, 'fn, 'row) Fields.t -> row:'fn -> init:'a ->
    f:('row -> 'a -> ('a step, Error.t) result) -> ('a, Error.t) result
  val fold_table : connection @ local -> path list -> (_, 'row) Table.t -> init:'a ->
    f:('row -> 'a -> ('a step, Error.t) result) -> ('a, Error.t) result
end

module Bridge : sig
  type canceller
  type request
  type settlement = Pending | Settled
  val canceller : unit -> canceller
  val request : canceller -> request @ unique
  val cancel : canceller -> unit
  val settlement : canceller -> settlement
  val run : request @ unique -> connection @ local ->
    f:(connection @ local -> ('a, Error.t) result) -> ('a, Error.t) result
end

(** Runtime-checked lifecycle for scheduler adapters (Async/Eio pools). *)
module Owned : sig
  val open_database : Config.t -> (database, Error.t) result
  val close_database : database -> (unit, Error.t) result
  val connect : database -> (connection, Error.t) result
  val close_connection : connection -> (unit, Error.t) result
  type ('row, 'out) shape =
    | Exec : (unit, unit) shape
    | Find : ('row, 'row) shape
    | Find_opt : ('row, 'row option) shape
    | Collect : ('row, 'row list) shape
    | Fold : { init : 'a; f : 'row -> 'a -> ('a step, Error.t) result } -> ('row, 'a) shape
  val run : _ session @ local -> ('row, 'out) shape -> ('p, 'row, _) Request.t -> 'p Args.t ->
    ('out, Error.t) result
end
```

Removed from today's `duckdb.mli`:

- `Row`, `Scalar.field`, `Scalar.validate`/`round_float32`, `cell`;
- the core `appender` and its `open_appender`/`append_rows`/`flush_appender`/`close_appender`/`with_appender*`;
- `prepared`/`query_result`/`chunk` at the top level (moved to `Statement`);
- `prepare*`, `execute_prepared`, `close_result`, `close_prepared`, `fold_rows`, `with_prepared_transaction`;
- `execute_transaction`;
- manual `open_database`/`close_database`/`connect`/`close_connection` (moved to `Owned`);
- `Parquet.fold_rows`;
- `Request.Connection`/`Request.Transaction` (merged into `Request.Session`);
- `Request.request_error`/`context`/`cause` (merged into `Error`);
- `Rollback_exception`.

## File map

| File | Responsibility after this plan |
|---|---|
| `lib/duckdb/error.ml{,i}` (new) | The flat error type and context helpers |
| `lib/duckdb/spine.ml{,i}` (new) | `Spine.Make`: the shared list structure |
| `lib/duckdb/session.ml{,i}` (new) | Public handle GADT (`@@ global` payloads) and dispatch to the internals |
| `lib/duckdb/scalar.ml{,i}` | Witnesses with exact small numerics; `repr`; no validation |
| `lib/duckdb/codec.ml{,i}` | Unchanged role; small-numeric values |
| `lib/duckdb/fields.ml`, `columns.ml` | `Spine.Make` instances |
| `lib/duckdb/resource.ml{,i}` | Unchanged role; errors become `Error.cause`; Bridge canceller/request split |
| `lib/duckdb/query.ml{,i}` | Codec-typed bind/column; fold on the prepared statement (no result handle) |
| `lib/duckdb/borrowed_chunk.ml{,i}` | Codec-typed reads; `Row` code deleted |
| `lib/duckdb/appender.ml{,i}` | Private cell appender used only by `Request` tables |
| `lib/duckdb/request.ml{,i}` | Requests, shape `run`, table appender, `Session` ops over internal owners |
| `lib/duckdb/parquet.ml{,i}` | Fields-based fold, export |
| `lib/duckdb/duckdb.ml`, `duckdb.mli` | Facade: local-mode signatures over `Session` |
| `lib/duckdb/row.ml{,i}` | Deleted |
| `lib/worker/duckdb_worker.ml{,i}` | Lifecycle via `Owned`; one `request_run`; Fields-based raw ops |
| `lib/async/*`, `lib/eio/*` | Same structure; new error and transaction-callback types |

---

### Task 1: Amend the design note with the plan-time findings

**Files:**
- Modify: `docs/design/core-redesign.md`

These are four facts found while planning. The executor records them; they
are not decisions. The user reviews them with this plan.

- [ ] **Step 1: Add P4 and P5 under the probe list**

Insert after the P3 bullet:

```markdown
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
```

- [ ] **Step 2: Correct the sections that P4 and the code reading change**

In "Handles come only from scopes and are local", replace the sentence
starting "`@ once` lets callers pass closures" with:

```markdown
Callbacks are ordinary closures (P4); they receive local handles but cannot
capture one.
```

In "Callbacks that run while a handle is busy are global", replace the last
sentence ("Scope callbacks that are not busy periods … accept local
closures.") with:

```markdown
Because of P4 this applies to every scope callback, not only busy periods.
```

In section 3, "Removed causes", replace the `Unbound_parameter` and `Index`
bullet with:

```markdown
  - `Unbound_parameter` and `Index` are **kept**, reachable only through
    `Statement` (positional `bind`, chunk `column` access). Typed requests
    cannot produce them.
```

Under "Kept but narrowed", add:

```markdown
- `Live_children` is removed. `Owned.close_database` with open connections,
  and `Bridge.run` on an owner with live statements, return `Busy`.
- `Bridge.cancel : canceller -> unit`: with no failure mode left, it returns
  `unit`.
```

- [ ] **Step 3: Verify and commit**

Run: `grep -n "P4\|P5\|Live_children\|Unbound_parameter" docs/design/core-redesign.md`
Expected: the new P4/P5 bullets and the corrected bullets are present.

```bash
jj describe -m "docs(design): record mode-barrier and error findings for the core redesign

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>" && jj new
```

---

### Task 2: Baseline and delete the dead multiplicity field

**Files:**
- Modify: `lib/duckdb/request.ml:7-29`, `lib/duckdb/request.mli` (no change
  expected; verify)

- [ ] **Step 1: Record the baseline**

```bash
mkdir -p .local/core-redesign
./tools/run build @all 2>&1 | tail -5
./tools/run runtest --force 2>&1 | tee .local/core-redesign/baseline.log | tail -20
```

Expected: the build prints nothing and runtest exits 0. If the baseline
fails, stop and report: no task may start from a red tree.

- [ ] **Step 2: Delete the field and its tag**

In `lib/duckdb/request.ml`, delete lines 7-9 (the comment and
`type multiplicity = …`). Make the record and constructors read:

```ocaml
type ('params, 'row, 'multiplicity) t =
  { id : int; sql : string; oneshot : bool; params : 'params params; rows : 'row rows }
```

```ocaml
let make ?(oneshot = false) params rows sql =
  { id = Stdlib.Atomic.fetch_and_add next_id 1; sql; oneshot; params = Params params; rows }
let exec ?oneshot params sql = make ?oneshot params (Rows (Fields.[], ())) sql
let one ?oneshot params fields ~row sql = make ?oneshot params (Rows (fields, row)) sql
let zero_or_one ?oneshot params fields ~row sql = make ?oneshot params (Rows (fields, row)) sql
let many ?oneshot params fields ~row sql = make ?oneshot params (Rows (fields, row)) sql
```

- [ ] **Step 3: Verify that nothing read it**

Run: `grep -rn "multiplicity\b\|Exactly_\|At_most_one\|Any_count" lib test`
Expected: only the type parameter name `'multiplicity` and test comments.

Run: `./tools/run build @all 2>&1 | tail -5 && ./tools/run runtest --force 2>&1 | tee .local/core-redesign/task2.log | tail -5`
Expected: build clean, runtest exits 0.

- [ ] **Step 4: Commit**

```bash
jj describe -m "refactor(request): delete the unread runtime multiplicity tag

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>" && jj new
```

---

### Task 3: Exact small numeric witnesses

**Files:**
- Modify: `lib/duckdb/dune` (add `stdlib_stable`), `lib/duckdb/scalar.ml`,
  `lib/duckdb/scalar.mli`, `lib/duckdb/codec.ml`, `lib/duckdb/codec.mli`,
  `lib/duckdb/query.ml:82-107`, `lib/duckdb/borrowed_chunk.ml:10-14`,
  `lib/duckdb/appender.ml:62-80`, `lib/duckdb/duckdb.mli` (Scalar and
  Codec.Values sections)
- Modify tests: `test/test_scalar.ml`, `test/test_query.ml:56,78-79`,
  `test/test_appender.ml:83`, `test/test_parquet.ml:36`,
  `test/async/test_typed_cases.ml`, `test/eio/typed_cases.ml`
- Create: `test/request_compile/int8_range.ml.fail`
- Modify: `test/check_request_types.sh`

- [ ] **Step 1: Write the failing compile fixture**

`test/request_compile/int8_range.ml.fail`:

```ocaml
module D = Duckdb
let r = D.Request.exec D.Fields.[int8] "INSERT INTO t VALUES (?)"
let args = D.Args.[200s]
```

In `test/check_request_types.sh`, before the final `echo`, add:

```bash
expect int8_range 'exceeds the range of representable integers of type "int8"'
```

Change the final `echo` count from "20 intended rejections" to "21 intended
rejections".

- [ ] **Step 2: Write the failing runtime test**

Append to `test/test_request.ml`:

```ocaml
(* Exact small numerics: boundary values roundtrip without validation. *)
let () =
  connected (fun c ->
    ok (C.exec c (R.exec D.Fields.[] "CREATE TABLE n(a TINYINT, b SMALLINT, f FLOAT)") D.Args.[]);
    let insert = R.exec D.Fields.[int8; int16; float32] "INSERT INTO n VALUES (?, ?, ?)" in
    ok (C.exec c insert D.Args.[-128s; 32767S; 0.1s]);
    ok (C.exec c insert D.Args.[127s; -32768S; -0.s]);
    let rows = R.many D.Fields.[] D.Fields.[int8; int16; float32] ~row:(fun a b f -> (a, b, f))
      "SELECT a, b, f FROM n ORDER BY a" in
    match ok (C.collect c rows D.Args.[]) with
    | [ (a1, b1, f1); (a2, b2, f2) ] ->
      assert (Stdlib_stable.Int8.to_int a1 = -128 && Stdlib_stable.Int16.to_int b1 = 32767);
      assert (Float.equal (Stdlib_stable.Float32.to_float f1) (Stdlib_stable.Float32.to_float 0.1s));
      assert (Stdlib_stable.Int8.to_int a2 = 127 && Stdlib_stable.Int16.to_int b2 = -32768);
      assert (Int64.equal (Stdlib.Int64.bits_of_float (Stdlib_stable.Float32.to_float f2)) Int64.min_value)
    | _ -> failwith "small numerics: unexpected rows");
  Stdlib.print_endline "request: int8/int16/float32 boundaries roundtrip exactly=ok"
```

Add `stdlib_stable` to the `libraries` of the `(tests (names test_schema_epoch test_request) …)` stanza in `test/dune`.

- [ ] **Step 3: Run both to verify they fail**

Run: `./tools/run runtest --force 2>&1 | tail -30`
Expected: compile errors in `test_request.ml`, because `D.Fields.int8` has
type `(int, …)` while the literal `-128s` is `int8`. The `int8_range`
fixture may be "unexpected acceptance" or report a different message; either
way the run fails.

- [ ] **Step 4: Implement the witnesses**

`lib/duckdb/dune`: change `(libraries base threads duckdb-ffi)` to
`(libraries base threads stdlib_stable duckdb-ffi)`.

`lib/duckdb/scalar.ml`, the type and representations:

```ocaml
type _ t =
  | Bool : bool t | Int8 : int8 t | Int16 : int16 t | Int32 : int32 t | Int64 : int64 t
  | Float32 : float32 t | Float64 : float t | String : string t | Blob : string t
  | Date : int32 t | Timestamp_s : int64 t | Timestamp_ms : int64 t
  | Timestamp_us : int64 t | Timestamp_ns : int64 t | Timestamp_tz : int64 t

type _ repr =
  | Integer : { encode : 'a -> int64; decode : int64 -> 'a } -> 'a repr
  | Floating : { encode : 'a -> float; decode : float -> 'a } -> 'a repr
  | Bytes : string repr

module I8 = Stdlib_stable.Int8
module I16 = Stdlib_stable.Int16
module F32 = Stdlib_stable.Float32
let int8 = Integer { encode = (fun x -> Int64.of_int (I8.to_int x)); decode = (fun n -> I8.of_int (Int64.to_int_trunc n)) }
let int16 = Integer { encode = (fun x -> Int64.of_int (I16.to_int x)); decode = (fun n -> I16.of_int (Int64.to_int_trunc n)) }
let int32 = Integer { encode = Stdlib.Int64.of_int32; decode = Stdlib.Int64.to_int32 }
let int64 = Integer { encode = Fn.id; decode = Fn.id }
let repr : type a. a t -> a repr = function
  | Bool -> Integer { encode = (fun b -> if b then 1L else 0L); decode = (fun n -> not (Int64.equal n 0L)) }
  | Int8 -> int8 | Int16 -> int16
  | Int32 -> int32 | Date -> int32
  | Int64 -> int64 | Timestamp_s -> int64 | Timestamp_ms -> int64
  | Timestamp_us -> int64 | Timestamp_ns -> int64 | Timestamp_tz -> int64
  | Float32 -> Floating { encode = F32.to_float; decode = F32.of_float }
  | Float64 -> Floating { encode = Fn.id; decode = Fn.id }
  | String -> Bytes | Blob -> Bytes
```

Delete `round_float32`, `validate` and `validate_option`, and delete the
`Range` constructor from `type error`. Mirror all of this in `scalar.mli`:
the type, the `repr` type, and remove `validate`, `validate_option` and
`round_float32`.

`lib/duckdb/codec.ml` / `codec.mli`: `int8 : (int8, non_null) t`,
`int16 : (int16, non_null) t`, `float32 : (float32, non_null) t`. The
bodies (`of_scalar Scalar.Int8`, …) are unchanged.

`lib/duckdb/query.ml`, `bind_value`:

```ocaml
let bind_value : type a. prepared -> int -> a S.t -> a -> unit = fun p index typ value ->
  let id = S.native_id typ in
  match S.repr typ with
  | S.Integer { encode; _ } -> F.bind_int64 p.native index id (encode value)
  | S.Floating { encode; _ } -> F.bind_float p.native index id (encode value)
  | S.Bytes -> F.bind_string p.native index id value
```

In `bind`, delete the line `let* () = data (S.validate_option typ value) in`.

`lib/duckdb/borrowed_chunk.ml`, `read`:

```ocaml
  | S.Floating { decode; _ } -> decode (F.chunk_float chunk.native column row)
```

`lib/duckdb/appender.ml`, `encode`:

```ocaml
    | S.Floating { encode; _ } -> id, false, 0L, encode value, ""
```

In `validate_cell`, replace `let+ () = data (S.validate_option typ value) in encode typ value`
with `Ok (encode typ value)`.

`lib/duckdb/duckdb.mli`: apply the same changes to the `Scalar` section
(the type, delete `validate` and `round_float32`) and to `Codec.Values`.

- [ ] **Step 5: Migrate the tests**

- `test/test_scalar.ml`: replace the whole file with a test of the remaining
  `Scalar` surface:

```ocaml
open! Base
module S = Duckdb.Scalar
let () =
  assert (String.equal (S.name S.Int8) "TINYINT");
  assert (String.equal (S.name S.Float32) "FLOAT");
  Stdlib.print_endline "scalar: names=ok"
```

- **`test/test_query.ml:56`, `test/test_appender.ml:83`,
  `test/test_parquet.ml:36`:** these Float32 lists become `float32` literals:
  `[0.s; -0.s; 0.1s; Stdlib_stable.Float32.infinity; Stdlib_stable.Float32.neg_infinity; Stdlib_stable.Float32.nan]`.
  Change each file's float-equality helper to compare
  `Stdlib_stable.Float32.to_float` images bit-for-bit
  (`Int64.equal (Stdlib.Int64.bits_of_float (to_float a)) (bits_of_float (to_float b))`,
  with NaN equal to NaN). Int8/Int16 lists in the same files become `s`/`S`
  literals. Add `stdlib_stable` to each affected test stanza's `libraries`
  in `test/dune` (`test_query`, `test_appender`, `test_parquet`), and to the
  async and eio test dune files for the typed cases.
- **`test/test_query.ml:78-79`:** the two `Range` assertions describe values
  that can no longer be constructed. Delete them. The `int8_range` fixture
  replaces the first; there is no float32 analogue to replace the second,
  because every `float32` is representable.
- **`test/async/test_typed_cases.ml`, `test/eio/typed_cases.ml`:** replace
  every `int8`/`int16`/`float32` value with the matching literal suffix.

Run: `grep -rn "round_float32\|S.Range\|Scalar.Range\|validate_option" lib test examples bench`
Expected: no matches.

- [ ] **Step 6: Run and verify**

Run: `./tools/run build @all 2>&1 | tail -5 && ./tools/run runtest --force 2>&1 | tee .local/core-redesign/task3.log | grep -E "int8|21 intended|small numerics|FAIL|Error" | head`
Expected: `request: int8/int16/float32 boundaries roundtrip exactly=ok`,
`request types: positive forms and 21 intended rejections …=ok`, and no
`Error`/`FAIL` lines. Runtest exits 0.

- [ ] **Step 7: Commit**

```bash
jj describe -m "feat(scalar)!: exact int8, int16 and float32 witnesses

Out-of-range values are no longer representable, so the Range error,
Scalar.validate and round_float32 are deleted.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>" && jj new
```

---

### Task 4: `Codec` replaces `Scalar.field` at the low level

**Files:**
- Modify: `lib/duckdb/scalar.ml{,i}` (delete `field`, `witness`),
  `lib/duckdb/query.ml{,i}` (`bind`, `column`),
  `lib/duckdb/borrowed_chunk.ml{,i}` (`column`),
  `lib/duckdb/appender.ml{,i}` (`cell`), `lib/duckdb/request.ml:74-140`,
  `lib/duckdb/parquet.ml:74`, `lib/duckdb/duckdb.mli`
- Modify tests: every file matching
  `grep -rln "Required\|Nullable\|Scalar.field\|S.field" test examples bench`

- [ ] **Step 1: Write the failing test**

Append to `test/test_query.ml`, using the file's own helpers:

```ocaml
(* Low-level bind/column take codecs, including custom ones. *)
let () =
  connected (fun c ->
    let parity = D.Codec.Values.custom D.Codec.Values.int64
      ~encode:(fun b -> Ok (if b then 1L else 0L)) ~decode:(fun n -> Ok (Int64.equal n 1L)) in
    ok (D.with_prepared c "SELECT ?::BIGINT AS x, NULL::VARCHAR AS y" ~f:(fun p ->
      let* () = D.bind p 1 parity true in
      let* r = D.execute_prepared p in
      D.fold_chunks r ~init:() ~f:(fun chunk () ->
        let* x = D.column chunk ~column:0 ~row:0 parity in
        let* y = D.column chunk ~column:1 ~row:0 D.Codec.Values.(nullable string) in
        assert x; assert (Option.is_none y);
        Ok (D.Stop ())))));
  Stdlib.print_endline "query: codec-typed bind/column incl. custom=ok"
```

If `test_query.ml` has no `connected` helper, copy the one from
`test/test_request.ml:20-23` into it.

- [ ] **Step 2: Run to verify it fails**

Run: `./tools/run build @all 2>&1 | grep -m3 Error`
Expected: a type error: `D.bind` expects a `Scalar.field`.

- [ ] **Step 3: Implement**

In `lib/duckdb/query.ml`, `bind` takes a codec and encodes through its plan:

```ocaml
let bind : type a n. prepared -> int -> (a, n) Codec.t -> a -> (unit, error) result = fun p index codec value ->
  without_result p (fun () ->
    let count = Array.length p.bound in
    if index < 1 || index > count then Error (Data_error (S.Index { index; length = count }))
    else
      let apply : type b. b S.t -> b option -> (unit, error) result = fun typ value ->
        let actual = p.parameter_types.(index - 1) in
        let* () =
          if accepts actual typ then Ok ()
          else Error (Data_error (S.Type_mismatch { index; expected = S.name typ; actual })) in
        p.bound.(index - 1) <- false;
        Exn.protect ~finally:(fun () -> F.clear_prepared_input p.native)
          ~f:(fun () -> Stdlib.Sys.with_async_exns (fun () ->
            (match value with None -> F.bind_null p.native index | Some x -> bind_value p index typ x);
            let+ () = settled p.connection p.native in
            p.bound.(index - 1) <- true)) in
      let encoded encode value = Result.map_error (encode value) ~f:(fun reason ->
        Data_error (S.Encode_rejected { index; reason })) in
      match codec with
      | Codec.Non_null (Codec.Plan plan) ->
        let* b = encoded plan.encode value in apply plan.scalar (Some b)
      | Codec.Nullable (Codec.Plan plan) ->
        match value with
        | None -> apply plan.scalar None
        | Some v -> let* b = encoded plan.encode v in apply plan.scalar (Some b))
```

A custom codec's encoder can now reject at the low level. To report that
without depending on `Request`, add a constructor to `Scalar.error`:
`Encode_rejected of { index : int; reason : Base.Error.t }`, and the same for
decoding, `Decode_rejected of { column : int; row : int; reason : Base.Error.t }`.
Both fold into `Error.cause` in Task 9.

In `lib/duckdb/borrowed_chunk.ml`, `column` takes a codec:

```ocaml
let column : type a n. t @ local -> column:int -> row:int -> (a, n) Codec.t -> (a, Resource.error) result =
  fun (chunk @ local) ~column ~row codec ->
    let columns = F.column_count chunk.native in
    if column < 0 || column >= columns then Error (Resource.Data_error (S.Index { index = column; length = columns }))
    else if row < 0 || row >= length chunk then Error (Resource.Data_error (S.Index { index = row; length = length chunk }))
    else
      let get : type b. b S.t -> (b option, Resource.error) result = fun typ ->
        match check_type chunk.native column typ with
        | Error e -> Error e
        | Ok () -> if F.chunk_valid chunk.native column row then Ok (Some (read chunk column row typ)) else Ok None in
      let decoded decode b = Result.map_error (decode b) ~f:(fun reason ->
        Resource.Data_error (S.Decode_rejected { column; row; reason })) in
      match codec with
      | Codec.Nullable (Codec.Plan plan) ->
        (match get plan.scalar with
         | Error e -> Error e
         | Ok None -> Ok None
         | Ok (Some b) -> Result.map (decoded plan.decode b) ~f:Option.some)
      | Codec.Non_null (Codec.Plan plan) ->
        (match get plan.scalar with
         | Error e -> Error e
         | Ok None -> Error (Resource.Data_error (S.Null { column; row }))
         | Ok (Some b) -> decoded plan.decode b)
```

The `Row`-based `validate_schema`/`decode` in the same file keep compiling
because Task 5 deletes them. In this task, make their `Row.Column` case
pattern-match on `Codec.t` instead of `Scalar.field`. The `Row.t`
constructor `Column : ('a, _) Codec.t * 'b t -> ('a * 'b) t` changes
accordingly in `row.ml{,i}` and `duckdb.mli`.

In `lib/duckdb/appender.ml`, the internal cell carries a base witness and
option:

```ocaml
type cell = Cell : 'a S.t * 'a option -> cell
```

`validate_cell` drops the `match field with Required/Nullable` and uses
`apply typ value` directly. In `lib/duckdb/request.ml`, `bound`/`encode_value`
produce `Bound : 'b Scalar.t * 'b option -> bound`. `bind_all` calls
`Query.bind p (i + 1) (Codec.Values.nullable (Codec.Values.of_scalar typ)) value`.
The table `append` builds `Appender.Cell (typ, value)`. `decode_value`
calls `Query.column chunk ~column ~row codec` directly; its own plan match
and the decoded-error wrapping are deleted, because `Borrowed_chunk.column`
now does both. Map the `S.Decode_rejected` it returns to the request cause
`Decode_rejected { column; row = seen + row; reason }`.

In `lib/duckdb/parquet.ml:74`, replace
`Query.bind p 1 (Scalar.Required Scalar.String) temporary` with
`Query.bind p 1 Codec.Values.string temporary`.

Delete `type _ field` and `witness` from `scalar.ml{,i}` and from the
`Scalar` section of `duckdb.mli`. Change `bind`'s and `column`'s
signatures in `query.mli` and `duckdb.mli` to `('a, _) Codec.t`.

- [ ] **Step 4: Migrate the call sites**

Rewrite rule, applied to every file listed by
`grep -rln "Required\|Nullable\|Scalar.field\|S.field" test examples bench lib/worker lib/async lib/eio`:

- `Scalar.Required S.X` / `Required X` (in bind/column/Row positions) → the
  matching `Codec.Values` value (`int64`, `string`, …);
- `Scalar.Nullable S.X` / `Nullable X` → `Codec.Values.(nullable x)`;
- `Duckdb.Cell (Required X, v)` → stays until Task 6, written as
  `Duckdb.Cell (X, Some v)`; `Cell (Nullable X, v)` → `Cell (X, v)`.

Then `./tools/run build @all 2>&1 | grep -c Error` must reach 0.

- [ ] **Step 5: Run and verify**

Run: `./tools/run runtest --force 2>&1 | tee .local/core-redesign/task4.log | grep -E "codec-typed|FAIL|rror" | head`
Expected: `query: codec-typed bind/column incl. custom=ok`. Runtest exits 0.

- [ ] **Step 6: Commit**

```bash
jj describe -m "refactor(core)!: codecs replace Scalar.field in bind, column and cells

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>" && jj new
```

---

### Task 5: Delete `Row.t`; every decoder is `Fields` plus `~row`

**Files:**
- Delete: `lib/duckdb/row.ml`, `lib/duckdb/row.mli`
- Modify: `lib/duckdb/dune` (`private_modules`: remove `row`),
  `lib/duckdb/duckdb.ml` (remove `module Row`),
  `lib/duckdb/borrowed_chunk.ml{,i}` (delete `width`, `validate_schema`,
  `decode`), `lib/duckdb/query.ml{,i}` (delete `fold_rows`),
  `lib/duckdb/parquet.ml{,i}` (delete `fold_file`, `fold_rows`),
  `lib/duckdb/duckdb.mli`,
  `lib/worker/duckdb_worker.ml{,i}` (`query`, `fold_rows`,
  `parquet_fold_rows`),
  `lib/async/duckdb_async.ml{,i}`, `lib/eio/duckdb_eio.ml{,i}` (the same
  three operations)
- Modify tests: `grep -rln "Row\.\|fold_rows" test examples bench`

- [ ] **Step 1: Write the failing test**

`test/async/test_typed_cases.ml` is the raw-decoder user; converting it is
the failing test. Replace its decoder definitions (lines 9-10):

```ocaml
let rows = Duckdb.Fields.[int64]
let equal_rows = List.equal Int64.equal
```

and its three raw calls:

```ocaml
    complete (ok (A.query pool "SELECT i FROM typed ORDER BY i" rows ~row:Fn.id)) >>= fun result ->
    let result = ok result in
    require "owned typed query" (equal_rows result [1L; 2L; 3L]);
    complete (ok (A.fold_rows pool "SELECT i FROM typed ORDER BY i" rows ~row:Fn.id ~init:0L
      ~f:(fun value total -> Ok (if Int64.equal value 2L then Duckdb.Stop (Int64.(total + value)) else Duckdb.Continue Int64.(total + value)))))
```

```ocaml
      complete (ok (A.parquet_fold_rows pool [path] rows ~row:Fn.id ~init:[] ~f:(fun row values -> Ok (Duckdb.Continue (row :: values)))))
      >>| fun result ->
      require "worker-local Parquet read/export" (equal_rows (List.rev (ok result)) [1L; 2L; 3L]))
```

Make the same change in `test/eio/typed_cases.ml`: find its `Row.` decoder
with `grep -n "Row\." test/eio/typed_cases.ml` and convert it with the same
three substitutions (decoder → `Fields.[int64]`, `~row:Fn.id` after it,
tuple patterns `(v, ())` → `v`).

- [ ] **Step 2: Run to verify it fails**

Run: `./tools/run build @all 2>&1 | grep -m3 Error`
Expected: a type error, because `A.query` expects a `Row.t` and not a
`Fields.t` with `~row`.

- [ ] **Step 3: Implement**

Change the signatures, in the worker `S` and both adapters (each `.mli`
and `.ml`), from `'row Duckdb.Row.t` to `(_, 'fn, 'row) Duckdb.Fields.t -> row:'fn`:

```ocaml
val query : slot -> D.Bridge.request -> string -> (_, 'fn, 'row) D.Fields.t -> row:'fn -> ('row list, D.error) result
val fold_rows : slot -> D.Bridge.request -> string -> (_, 'fn, 'row) D.Fields.t -> row:'fn -> init:'a ->
  f:('row -> 'a -> ('a D.step, D.error) result) -> ('a, D.error) result
val parquet_fold_rows : slot -> D.Bridge.request -> string list -> (_, 'fn, 'row) D.Fields.t -> row:'fn ->
  init:'a -> f:('row -> 'a -> ('a D.step, D.error) result) -> ('a, D.error) result
```

The worker implements them as oneshot typed requests:

```ocaml
  let raw sql fields ~row = D.Request.many ~oneshot:true D.Fields.[] fields ~row sql
  let core_error (e : D.Request.request_error) = match e.cause with
    | D.Request.Core error -> error
    | _ -> D.Native_error (D.Request.query_of_context e.context)
  let query slot request sql fields ~row =
    bridged slot request (fun c ->
      Result.map_error (D.Request.Connection.collect c (raw sql fields ~row) D.Args.[]) ~f:core_error)
  let fold_rows slot request sql fields ~row ~init ~f =
    bridged slot request (fun c ->
      Result.map_error ~f:core_error
        (D.Request.Connection.fold c (raw sql fields ~row) D.Args.[] ~init
           ~f:(fun v acc -> Result.map_error (in_callback f v acc) ~f:(fun e -> { D.Request.context = D.Request.Query sql; cause = D.Request.Core e }))))
  let parquet_fold_rows slot request names fields ~row ~init ~f =
    bridged slot request (fun c ->
      let* paths = Result.all (List.map names ~f:D.Parquet.path) in
      Result.map_error ~f:core_error
        (D.Parquet.fold c paths fields ~row ~init
           ~f:(fun v acc -> Result.map_error (in_callback f v acc) ~f:(fun e -> { D.Request.context = D.Request.Query "read_parquet"; cause = D.Request.Core e }))))
```

`core_error` is temporary: Task 9 deletes it when the two error types merge.
Its fallback branch keeps the non-core typed causes (decode, row count)
visible, as `Native_error` text.

Delete `fold_query`, `Row`, `Query.fold_rows`, `Borrowed_chunk.{width,validate_schema,decode}`
and `Parquet.{fold_file,fold_rows}`. Remove `row` from `private_modules`
and `module Row = Row` from `duckdb.ml`. In `duckdb.mli`, delete the
`Row` module, `fold_rows`, and `Parquet.fold_rows`.

- [ ] **Step 4: Migrate the call sites**

Rewrite rule for each file in
`grep -rln "Row\.\|fold_rows" test examples bench`:

- `D.fold_rows r D.Row.(Column (int64, Empty)) ~init ~f:(fun (n, ()) acc -> …)` →
  `D.Request.Connection.fold c (D.Request.many D.Fields.[] D.Fields.[int64] ~row:Fn.id sql) D.Args.[] ~init ~f:(fun n acc -> …)`,
  with the SQL moved from the surrounding `with_prepared`. Where the test
  exercises `fold_rows` on an already-executed result *specifically* (a
  result-lease test), rewrite it with `fold_chunks` plus `column` instead.
  Name each such test in the task log.
- `Parquet.fold_rows c paths decoder` → `Parquet.fold c paths fields ~row`.
- Adapter `query pool sql decoder` → `query pool sql fields ~row`.

- [ ] **Step 5: Run and verify**

Run: `grep -rn "Row\." lib test examples bench | grep -v "_build"`
Expected: no matches.
Run: `./tools/run build @all 2>&1 | tail -5 && ./tools/run runtest --force 2>&1 | tee .local/core-redesign/task5.log | tail -5`
Expected: the build is clean, runtest exits 0, and the new raw-Fields
cases print their ok lines.

- [ ] **Step 6: Commit**

```bash
jj describe -m "refactor(core)!: delete Row.t; raw SQL decodes through Fields

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>" && jj new
```

---

### Task 6: The cell appender becomes private; appending only through `Table`

**Files:**
- Modify: `lib/duckdb/duckdb.mli` (delete `cell`, `appender`,
  `open_appender`, `append_rows`, `flush_appender`, `close_appender`,
  `with_appender`, `with_appender_transaction`),
  `lib/duckdb/duckdb.ml` (`include Appender` → no include; `Request` uses
  `Appender` directly),
  `lib/worker/duckdb_worker.ml{,i}` (delete `ingest`; keep `table_ingest`),
  `lib/async/duckdb_async.ml{,i}`, `lib/eio/duckdb_eio.ml{,i}` (delete raw
  `ingest` and its `Ingest` operation constructor)
- Create: `test/request_compile/core_appender_gone.ml.fail`
- Modify tests: `test/test_appender.ml`, `test/test_appender_concurrency.ml`,
  `test/test_appender_signals.ml`, `test/native_delivery/appender_delivery.ml`,
  `test/test_adapter_bridge.ml:84`, `test/appender_compile/*`, plus
  `grep -rln "append_rows\|open_appender\|with_appender_transaction\|Cell (\|ingest" test examples bench`

- [ ] **Step 1: Write the failing fixture**

`test/request_compile/core_appender_gone.ml.fail`:

```ocaml
let f tx = Duckdb.open_appender tx "t"
```

In `check_request_types.sh`, add
`expect core_appender_gone 'Unbound value "Duckdb.open_appender"'` and bump
the count to 22.

- [ ] **Step 2: Run to verify it fails**

Run: `./tools/run runtest --force 2>&1 | grep -m2 "core_appender_gone"`
Expected: `unexpected acceptance: core_appender_gone`.

- [ ] **Step 3: Implement**

Remove the listed values and types from `duckdb.mli`. In `duckdb.ml`,
replace `include Appender` with nothing. `Request`/`Table` already reach
`Appender` as a private module. Delete the raw `ingest` from the worker,
from both adapters' `.mli`/`.ml`, and from their operation variants. The
typed `Request.ingest`/`table_ingest` remain.

- [ ] **Step 4: Migrate the tests (classification)**

| File | Treatment |
|---|---|
| `test/test_appender.ml` | Port to `Table.declare` + `Table.with_appender*` + `Table.append`. The test at line 98 (append after close → `Closed`) is deleted here and re-added as a compile fixture in Task 11 (`appender_escape`). Line 141 (`execute_transaction tx` while an appender is open → `Busy`) stays as runtime `Busy` until Task 11 makes it the compile fixture `busy_appender` |
| `test/test_appender_concurrency.ml` | Port to `Table`; Busy/Closed expectations unchanged |
| `test/test_appender_signals.ml` | Port to `Table`; expectations unchanged |
| `test/native_delivery/appender_delivery.ml` | Port to `Table`. Line 248 (closed alias revoked) is deleted here and becomes the compile fixture `appender_escape` in Task 11 |
| `test/test_adapter_bridge.ml:84` | `flush_appender` → `Table.flush`; expectation unchanged |
| `test/appender_compile/*` | Fixtures that name the core appender are rewritten against `Table.appender` (same intent: chunk/connection/owner escape). Record each rewrite in the task log |
| adapters' raw `ingest` tests | Switch to `Request.ingest` with a declared table |

- [ ] **Step 5: Run and verify**

Run: `./tools/run build @all 2>&1 | tail -5 && ./tools/run runtest --force 2>&1 | tee .local/core-redesign/task6.log | grep -E "22 intended|FAIL|rror" | head`
Expected: `…22 intended rejections…=ok`. Runtest exits 0.

- [ ] **Step 6: Commit**

```bash
jj describe -m "refactor(core)!: append only through declared tables

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>" && jj new
```

---

### Task 7: `Spine.Make` for `Fields` and `Columns`

**Files:**
- Create: `lib/duckdb/spine.ml`, `lib/duckdb/spine.mli`
- Modify: `lib/duckdb/fields.ml`, `lib/duckdb/columns.ml`,
  `lib/duckdb/request.ml:238-243` (`fields_of_columns`, `column_names`),
  `lib/duckdb/dune` (`private_modules`: add `spine`)

- [ ] **Step 1: Write the failing test**

Append to `test/test_table.ml`:

```ocaml
(* Columns and Fields share one structure: a table's columns decode the
   same rows as the equivalent Fields list. *)
let () =
  let module T = Duckdb.Table in
  let t = T.declare "s" T.Columns.["a", int64; "b", nullable string] ~row:(fun a b -> (a, b)) in
  assert (String.equal (Duckdb.Request.query (T.select t)) "SELECT \"a\", \"b\" FROM \"main\".\"s\"");
  Stdlib.print_endline "table: spine-backed columns render=ok"
```

- [ ] **Step 2: Run to verify the baseline behaviour**

Run: `./tools/run runtest --force 2>&1 | grep "spine-backed"`
Expected: the line prints. This is a refactor; the test pins the behaviour
that must survive it.

- [ ] **Step 3: Implement**

`lib/duckdb/spine.mli`:

```ocaml
(** One heterogeneous list structure, indexed by the element values'
    types ['list], a curried constructor ['fn] and its result ['result]. *)
module Make (E : sig type ('a, 'n) t end) : sig
  type ('list, 'fn, 'result) t =
    | [] : (unit, 'result, 'result) t
    | (::) : ('a, _) E.t * ('list, 'fn, 'result) t -> ('a * 'list, 'a -> 'fn, 'result) t

  (** Re-indexes every element; the indices are unchanged. *)
  type 'g map = { f : 'a 'n. ('a, 'n) E.t -> ('a, 'n) 'g }
  type 'b fold = { g : 'a 'n. ('a, 'n) E.t -> 'b -> 'b }
  val fold : ('l, 'f, 'r) t -> init:'b -> 'b fold -> 'b
  val length : ('l, 'f, 'r) t -> int
end
```

A type constructor parameter (`'g`) cannot be abstracted in OCaml, so
re-indexing is done by a second functor:

```ocaml
module Map (A : sig type ('a, 'n) t end) (B : sig type ('a, 'n) t end)
    (LA : module type of Make (A)) (LB : module type of Make (B)) : sig
  type f = { f : 'a 'n. ('a, 'n) A.t -> ('a, 'n) B.t }
  val map : f -> ('l, 'fn, 'r) LA.t -> ('l, 'fn, 'r) LB.t
end
```

Remove `map` from `Make` (keep `fold` and `length`).

`lib/duckdb/spine.ml`:

```ocaml
module Make (E : sig type ('a, 'n) t end) = struct
  type ('list, 'fn, 'result) t =
    | [] : (unit, 'result, 'result) t
    | (::) : ('a, _) E.t * ('list, 'fn, 'result) t -> ('a * 'list, 'a -> 'fn, 'result) t
  type 'b fold = { g : 'a 'n. ('a, 'n) E.t -> 'b -> 'b }
  let rec fold : type l f r. (l, f, r) t -> init:'b -> 'b fold -> 'b = fun l ~init folder ->
    match l with [] -> init | x :: rest -> fold rest ~init:(folder.g x init) folder
  let length l = fold l ~init:0 { g = (fun _ n -> n + 1) }
end
module Map (A : sig type ('a, 'n) t end) (B : sig type ('a, 'n) t end)
    (LA : module type of Make (A)) (LB : module type of Make (B)) = struct
  type f = { f : 'a 'n. ('a, 'n) A.t -> ('a, 'n) B.t }
  let rec map : type l fn r. f -> (l, fn, r) LA.t -> (l, fn, r) LB.t = fun m -> function
    | LA.[] -> LB.[]
    | LA.(x :: rest) -> LB.(m.f x :: map m rest)
end
```

If `module type of Make (A)` is rejected for applicative-functor reasons,
inline `Map` as a plain recursive function in `request.ml` (as
`fields_of_columns` is today), and keep only `Make`, `fold` and `length` in
`Spine`. Record the fallback in the task log. Do not fight the type checker
past one attempt: the shared constructors are the value here.

`lib/duckdb/fields.ml`:

```ocaml
include Codec.Values
include Spine.Make (Codec)
```

`lib/duckdb/columns.ml`:

```ocaml
include Codec.Values
type ('a, 'n) named = string * ('a, 'n) Codec.t
include Spine.Make (struct type ('a, 'n) t = ('a, 'n) named end)
```

`duckdb.mli` is unchanged: the `[]`/`(::)` types are structurally identical
and the extra values stay unexported.

In `request.ml`, `column_names` becomes
`List.rev (Columns.fold columns ~init:[] { g = (fun (name, _) acc -> name :: acc) })`,
and `fields_of_columns` uses `Map` (or stays as written today under the
fallback).

- [ ] **Step 4: Run and verify**

Run: `./tools/run build @all 2>&1 | tail -5 && ./tools/run runtest --force 2>&1 | tee .local/core-redesign/task7.log | grep -E "spine-backed|intended|FAIL|rror" | head`
Expected: `table: spine-backed columns render=ok`, and the request types
line still reports 22 rejections. Runtest exits 0.

- [ ] **Step 5: Commit**

```bash
jj describe -m "refactor(fields): one Spine structure behind Fields and Columns

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>" && jj new
```

---

### Task 8: The shape GADT and one `run` per layer

**Files:**
- Modify: `lib/duckdb/request.ml{,i}` (add `shape`, `run`; rebuild the
  `Connection`/`Transaction` ops on it), `lib/duckdb/duckdb.mli` (add
  `Request.shape`, `Request.run`; Task 10 moves them to `Owned`),
  `lib/worker/duckdb_worker.ml{,i}` (replace `request_exec`/`find`/
  `find_opt`/`collect`/`fold` with `request_run`),
  `lib/async/duckdb_async.ml{,i}`, `lib/eio/duckdb_eio.ml{,i}` (one
  `typed_run` each; the public functions become wrappers)

- [ ] **Step 1: Write the failing test**

Append to `test/test_request.ml`:

```ocaml
(* One run per shape agrees with the named operations. *)
let () =
  seeded (fun c ->
    assert (Option.equal String.equal (ok (R.run c R.Find by_id D.Args.[1L])) (ok (C.find c by_id D.Args.[1L])));
    assert (Option.is_none (ok (R.run c R.Find_opt maybe D.Args.[9L])));
    assert (List.length (ok (R.run c R.Collect rows D.Args.[0L])) = 2);
    assert (ok (R.run c (R.Fold { init = 0; f = (fun _ n -> Ok (D.Continue (n + 1))) }) rows D.Args.[0L]) = 2);
    ok (R.run c R.Exec insert D.Args.[3L; None; None]));
  Stdlib.print_endline "request: shape run agrees with named operations=ok"
```

- [ ] **Step 2: Run to verify it fails**

Run: `./tools/run build @all 2>&1 | grep -m2 Error`
Expected: `Unbound value R.run`.

- [ ] **Step 3: Implement in the core**

In `lib/duckdb/request.ml`, after `run_fold`:

```ocaml
type ('row, 'out) shape =
  | Exec : (unit, unit) shape
  | Find : ('row, 'row) shape
  | Find_opt : ('row, 'row option) shape
  | Collect : ('row, 'row list) shape
  | Fold : { init : 'a; f : 'row -> 'a -> ('a Query.step, request_error) result } -> ('row, 'a) shape

(* One execution path; the shape decides how many rows are admitted. *)
let run_shape : type row out. connection -> transaction option -> (row, out) shape ->
  (_, row, _) t -> _ Args.t -> (out, request_error) Result.t = fun c within shape r args ->
  match shape with
  | Exec -> run_exec c within r args
  | Find -> run_find c within r args
  | Find_opt -> at_most_one c within r args ~expected:`Zero_or_one
  | Collect -> collect_rows c within r args
  | Fold { init; f } -> run_fold c within r args ~init ~f
```

Note that `Exec` has `row = unit`. The type checker accepts
`run_exec c within r args` there because `r : (_, unit, _) t`.

`Connection` becomes:

```ocaml
module Connection = struct
  type owner = connection
  type error = request_error
  type 'a future = 'a
  let run c shape r args = run_shape c None shape r args
  let exec c r args = run c Exec r args
  let find c r args = run c Find r args
  let find_opt c r args = run c Find_opt r args
  let collect c r args = run c Collect r args
  let fold c r args ~init ~f = run c (Fold { init; f }) r args
  (* with_transaction, ingest unchanged *)
end
```

`Transaction` is the same with
`run tx shape r args = run_shape (transaction_connection tx) (Some tx) shape r args`.
Export `type ('row, 'out) shape` and
`val run : connection -> ('row, 'out) shape -> ('p, 'row, _) t -> 'p Args.t -> ('out, request_error) result`
(that is, `Connection.run`) in `request.mli` and in `duckdb.mli`'s
`Request`.

- [ ] **Step 4: Implement in the worker and the adapters**

In the worker `S`, replace the five `request_*` declarations with:

```ocaml
  val request_run : slot -> D.Bridge.request -> ('row, 'out) D.Request.shape ->
    ('p, 'row, _) D.Request.t -> 'p D.Args.t -> ('out, D.Request.request_error) result
```

Implementation. A `Fold` callback runs inside the callback marker:

```ocaml
  let marked : type row out. (row, out) R.shape -> (row, out) R.shape = function
    | R.Fold { init; f } -> R.Fold { init; f = in_callback f }
    | (R.Exec | R.Find | R.Find_opt | R.Collect) as shape -> shape
  let request_run slot request shape r args =
    typed slot request ~context:(in_query r) (fun c -> R.Connection.run c (marked shape) r args)
```

Async (`lib/async/duckdb_async.ml`, `module Request`):

```ocaml
  let submit_run pool shape r args = typed pool (fun slot bridge -> W.request_run slot bridge shape r args)
  let submit_exec pool r args = submit_run pool R.Exec r args
  let submit_find pool r args = submit_run pool R.Find r args
  let submit_find_opt pool r args = submit_run pool R.Find_opt r args
  let submit_collect pool r args = submit_run pool R.Collect r args
  let submit_fold pool r args ~init ~f = submit_run pool (R.Fold { init; f }) r args
```

(with `module R = Duckdb.Request`). The awaiting forms stay
`await (submit_* …)`. In Eio, the same with `typed pool (fun slot bridge -> W.request_run slot bridge shape r args)`.
The public `.mli` files are unchanged: the multiplicity guards stay on the
named wrappers.

- [ ] **Step 5: Run and verify**

Run: `grep -n "request_exec\|request_find\|request_collect\|request_fold" lib`
Expected: no matches.
Run: `./tools/run build @all 2>&1 | tail -5 && ./tools/run runtest --force 2>&1 | tee .local/core-redesign/task8.log | grep -E "shape run|intended|FAIL|rror" | head`
Expected: `request: shape run agrees with named operations=ok`, and the
compile fixtures still 22/22. Runtest exits 0. Also run
`./tools/run build @adapter-bridge 2>&1 | tail -3`; expected empty.

- [ ] **Step 6: Commit**

```bash
jj describe -m "refactor(request): one shape-driven run per layer

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>" && jj new
```

---

### Task 9: One flat error type

**Files:**
- Create: `lib/duckdb/error.ml`, `lib/duckdb/error.mli`
- Modify: every module under `lib/` that names `error`, `Data_error`,
  `Scalar.error`, `request_error`, `Core`, `Rollback_exception` or
  `Cleanup_exception`: `resource.ml{,i}`, `query.ml{,i}`,
  `borrowed_chunk.ml{,i}`, `appender.ml{,i}`, `request.ml{,i}`,
  `parquet.ml{,i}`, `table.ml`, `scalar.ml{,i}`, `duckdb.ml`,
  `duckdb.mli`, the worker, both adapters
- Modify tests: all files matching
  `grep -rln "D.Native_error\|Data_error\|request_error\|R.Core\|Rollback_exception\|Cleanup_exception\|Duckdb.error" test examples bench`

- [ ] **Step 1: Write the failing test**

Append to `test/test_request.ml`:

```ocaml
(* Errors are flat: context plus cause, no Core/Data_error nesting. *)
let () =
  connected (fun c ->
    let bad = R.exec D.Fields.[] "SELEC 1" in
    (match C.exec c bad D.Args.[] with
     | Error { D.Error.context = D.Error.Query "SELEC 1"; cause = D.Error.Native _ } -> ()
     | _ -> failwith "flat error: unexpected shape");
    let wrong = R.one D.Fields.[] D.Fields.[string] ~row:Fn.id "SELECT 1::BIGINT" in
    match C.find c wrong D.Args.[] with
    | Error { cause = D.Error.Type_mismatch { actual = "BIGINT"; expected = "VARCHAR"; _ }; _ } -> ()
    | _ -> failwith "flat error: type names");
  Stdlib.print_endline "request: flat errors with type names=ok"
```

- [ ] **Step 2: Run to verify it fails**

Run: `./tools/run build @all 2>&1 | grep -m2 Error`
Expected: `Unbound module D.Error`.

- [ ] **Step 3: Create `Error`**

`lib/duckdb/error.mli`, with exactly the `Error` signature from "Target
public interface" above, plus these internal helpers:

```ocaml
(* Attaches [context] to a core cause. *)
val within : context -> ('a, cause) result -> ('a, t) result
(* Engine type id to its SQL name; unknown ids render as "type <id>". *)
val type_name : int -> string
```

`lib/duckdb/error.ml`:

```ocaml
open! Base
type context =
  | Database | Connection | Transaction
  | Query of string | Table of { schema : string; name : string } | Parquet of string
type cause =
  | Invalid_configuration of string | Embedded_nul | Closed | Busy | Cancelled
  | Native of string | Unsupported_statement | Effects_not_allowed
  | Type_mismatch of { index : int; expected : string; actual : string }
  | Null of { column : int; row : int }
  | Index of { index : int; length : int }
  | Unbound_parameter of int
  | Parameter_count of { expected : int; actual : int }
  | Column_count of { expected : int; actual : int }
  | Parameter_schema_changed
  | Row_count of { expected : [ `One | `Zero_or_one ]; actual : [ `Zero | `More_than_one ] }
  | Unknown_column of { name : string } | Missing_column of { name : string }
  | Encode_rejected of { index : int; reason : Error.t }
  | Decode_rejected of { column : int; row : int; reason : Error.t }
  | Destination_exists | Unsupported_parquet_type of { column : int; actual : string }
  | Rollback_failed of { primary : t; rollback : t }
and t = { context : context; cause : cause }
let within context result = Result.map_error result ~f:(fun cause -> { context; cause })
let type_name id =
  match List.find Scalar.all ~f:(fun (Scalar.Packed typ) -> Scalar.native_id typ = id) with
  | Some (Scalar.Packed typ) -> Scalar.name typ
  | None -> "type " ^ Int.to_string id
```

`Error` depends on `Scalar` only. `Scalar.error` is deleted: its
constructors are `Error.cause` constructors.

- [ ] **Step 4: Migrate the internals (rewrite rules)**

Apply these in dependency order: `scalar`, `resource`, `borrowed_chunk`,
`query`, `appender`, `request`, `parquet`, `table`, `duckdb`, worker,
adapters.

- `Resource.error` becomes `type error = Error.cause` (an alias), so internal
  signatures `(_, error) result` stay unchanged.
- `Native_error s` → `Native s`. `Data_error (S.X …)` → `X …` (flatten). The
  `data` helper in `resource.ml` is deleted, along with each `data (…)` call
  site (the value is already a cause).
- `Type_mismatch { …; actual }` with an int `actual` →
  `actual = Error.type_name actual`. `Unsupported_parquet_type { column; actual }` likewise.
- **`Rollback_failed (a, b)` at the core level** →
  `Rollback_failed { primary = { context = Transaction; cause = a }; rollback = { context = Transaction; cause = b } }`.
  `core_outcome` in `resource.ml` changes accordingly.
- **`Live_children` is deleted:**
  - `close_connection` and `close_database`: `require … Live_children` → `require … Busy`.
  - `Bridge.run` admission: `require (List.is_empty c.owner.prepared_children) Live_children` → `Busy`.
  - `Query.without_result`: `Error Live_children` → `Error Busy`.
- `exception Rollback_exception of exn * error` is deleted. `combine`'s
  `Raised primary, Ok (Error secondary)` case raises
  `Cleanup_exception ({ context = Transaction; cause = secondary }, primary)`.
  The secondary is the rollback failure; the exception keeps the primary
  exception and its backtrace, as before. `Cleanup_exception` becomes
  `of Error.t * exn` and is defined once, in `error.ml`, as
  `exception Cleanup_exception of t * exn`. `Resource` and `Request` re-export
  it; the second `Request.Cleanup_exception` is deleted.
- **In `request.ml`:**
  - `type cause`, `request_error`, `context` and `query_of_context` are
    deleted, and `Error` is used instead.
  - `Core e` → the cause `e` itself.
  - `core context r` → `Error.within context r`.
  - `with_context` → `Error.within`.
  - `transaction_outcome.rollback_failed` →
    `fun primary rollback -> { context = primary.context; cause = Rollback_failed { primary; rollback = { context = Transaction; cause = rollback } } }`.
  - `QUERY`'s `fold` callback error becomes `Error.t`.
- **Public facade:** `duckdb.ml` exports `module Error = Error` and
  `exception Cleanup_exception = Error.Cleanup_exception`. Every public
  function that returns a core cause wraps it with its context through
  `Error.within`:

  | Function | Context |
  |---|---|
  | `Config.create` | `Database` |
  | `with_database` | `Database` |
  | `with_connection` | `Connection` |
  | `execute c sql` | `Query sql` |
  | `with_transaction` | `Transaction` |
  | prepared-statement functions | `Query sql` (the statement's own SQL) |
  | `Parquet.*` | `Parquet path` (`Parquet "read_parquet"` for multi-file folds) |

  The wrapping lives in `duckdb.ml`. Internals keep returning causes.
- **Worker and adapters:**
  - `Core of Duckdb.error` → `Core of Duckdb.Error.t`;
  - `Request of Duckdb.Request.request_error` → `Request of Duckdb.Error.t`;
  - `Core_failure of Duckdb.error` (Eio) → `Core_failure of Duckdb.Error.t`;
  - the temporary `core_error` from Task 5 is deleted: the raw ops return
    `Error.t` directly.

- [ ] **Step 5: Migrate the tests**

For each file listed in Files:

- `D.Native_error s` → `{ D.Error.cause = D.Error.Native s; _ }`;
- `Error D.Busy` (and similar) → `Error { cause = D.Error.Busy; _ }`;
- `R.Core (D.X)` → `D.Error.X`;
- `Data_error (S.X …)` → `D.Error.X …`;
- `test/test_duckdb.ml:14`'s error-equality helper compares `cause`s;
- `Live_children` expectations become `Busy`: `test/test_duckdb.ml:47,82,126`,
  `test/test_adapter_bridge.ml:72,289`, `test/test_query.ml:12`;
- `describe` helpers in tests match the flat causes;
- `test/compile/positive.ml:1` →
  `let owned_error () = Domain.Safe.spawn (fun () -> { Duckdb.Error.context = Database; cause = Closed })`.

- [ ] **Step 6: Run and verify**

Run: `grep -rn "Native_error\|Data_error\|request_error\|Live_children\|Rollback_exception\|Scalar.error" lib test examples bench`
Expected: no matches.
Run: `./tools/run build @all 2>&1 | tail -5 && ./tools/run runtest --force 2>&1 | tee .local/core-redesign/task9.log | grep -E "flat errors|intended|FAIL|rror:" | head`
Expected: `request: flat errors with type names=ok`. Runtest exits 0.
Also run `./tools/run build @adapter-bridge @adapter-bridge-responsiveness 2>&1 | tail -3`; expected empty.

- [ ] **Step 7: Commit**

```bash
jj describe -m "refactor(error)!: one flat Error.t with context and cause

Live_children and Rollback_exception are removed; Busy and
Cleanup_exception cover them.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>" && jj new
```

---

### Task 10: The session GADT, `Statement`, `Owned`, and no duplicates

This task changes the API *shape* without modes. Task 11 adds `@ local`.

**Files:**
- Create: `lib/duckdb/session.ml`, `lib/duckdb/session.mli`
- Modify: `lib/duckdb/dune` (`private_modules`: add `session`, `error`),
  `lib/duckdb/duckdb.ml`, `lib/duckdb/duckdb.mli`,
  `lib/duckdb/query.ml{,i}` (fold on the prepared statement, no public result),
  `lib/duckdb/request.ml{,i}` (`Session` ops), `lib/duckdb/table.ml`,
  `lib/duckdb/parquet.ml`, the worker, both adapters, and all tests using
  the removed names

- [ ] **Step 1: Write the failing tests**

Append to `test/test_request.ml`:

```ocaml
(* One operation set over both session kinds. *)
let () =
  connected (fun c ->
    let s = R.Session.exec in
    ok (s c create D.Args.[]);
    ok (R.Session.with_transaction c ~f:(fun tx ->
      let* () = R.Session.exec tx insert D.Args.[1L; Some "a"; None] in
      let* n = R.Session.collect tx rows D.Args.[0L] in
      assert (List.length n = 1); Ok ()));
    assert (List.length (ok (R.Session.collect c rows D.Args.[0L])) = 1));
  Stdlib.print_endline "request: Session ops over connection and transaction=ok"
```

Create `test/request_compile/nested_transaction.ml.fail`:

```ocaml
module D = Duckdb
let f c = D.with_transaction c ~f:(fun tx -> D.with_transaction tx ~f:(fun _ -> Ok ()))
```

and add
`expect nested_transaction '[ \`Transaction ]' '[ \`Connection ]'` to
`check_request_types.sh`, bumping the count to 23. Delete
`request_compile/tx_instance_on_connection.ml.fail` and its `expect` line:
the two instances no longer exist, and `nested_transaction` covers the same
intent (a transaction cannot stand in for a connection). The count is then
22 again.

- [ ] **Step 2: Run to verify they fail**

Run: `./tools/run build @all 2>&1 | grep -m2 Error`
Expected: `Unbound module R.Session`.

- [ ] **Step 3: Create `Session`**

`lib/duckdb/session.mli`:

```ocaml
(* Public handles. Payloads are global so that a facade function receiving a
   local handle can reach the global internals. *)
type database = { database : Resource.database @@ global }
type _ t =
  | Connection : Resource.connection @@ global -> [ `Connection ] t
  | Transaction : Resource.transaction @@ global -> [ `Transaction ] t
val connection : _ t @ local -> Resource.connection
val within : _ t @ local -> Resource.transaction option
```

`lib/duckdb/session.ml`:

```ocaml
type database = { database : Resource.database @@ global }
type _ t =
  | Connection : Resource.connection @@ global -> [ `Connection ] t
  | Transaction : Resource.transaction @@ global -> [ `Transaction ] t
let connection (type k) (s : k t @ local) = match s with
  | Connection c -> c
  | Transaction tx -> Resource.transaction_connection tx
let within (type k) (s : k t @ local) = match s with
  | Connection _ -> None
  | Transaction tx -> Some tx
```

Task 10 uses no `@ local` on the public side yet. These two helpers already
accept local values, so Task 11 only changes the `.mli` signatures.

- [ ] **Step 4: Rebuild the facade over `Session`**

In `duckdb.mli`/`duckdb.ml`:

```ocaml
type database = Session.database
type 'k session = 'k Session.t
type connection = [ `Connection ] session
type transaction = [ `Transaction ] session
```

(Abstract in the `.mli`: `type database`, `type _ session`.)

Errors cross scopes through *lifted* internals. A callback returns
`Error.t`, but the internal scope functions return `Error.cause`. Each
internal scope used by the facade gets a variant that is polymorphic in the
callback's error type, following the existing `with_transaction_lifted`.
Add these to `resource.mli` and `query.mli`:

```ocaml
(* resource.mli *)
val with_database_lifted : lift:(Error.cause -> 'e) -> Config.t -> f:(database -> ('a, 'e) result) -> ('a, 'e) result
val with_connection_lifted : lift:(Error.cause -> 'e) -> database -> f:(connection -> ('a, 'e) result) -> ('a, 'e) result
(* query.mli *)
val with_prepared_lifted : lift:(Error.cause -> 'e) -> connection -> transaction option -> string ->
  f:(prepared -> ('a, 'e) result) -> ('a, 'e) result
val fold_prepared_lifted : lift:(Error.cause -> 'e) -> prepared -> init:'a ->
  f:(chunk @ local -> 'a -> ('a step, 'e) result) -> ('a, 'e) result
```

Implement each by applying `Result.map_error ~f:lift` to every internal
result, and passing the callback's result through unchanged. The existing
cause-typed function becomes `…_lifted ~lift:Fn.id`. `Resource.scope`'s
`result_error` ref, which pairs a cleanup exception with the primary error,
becomes polymorphic in the same way; it only stores the value.

The facade in `duckdb.ml`:

```ocaml
let in_context context cause = { Error.context; cause }
let with_database config ~f =
  Resource.with_database_lifted ~lift:(in_context Database) config ~f:(fun database -> f { Session.database })
let with_connection (db : database) ~f =
  Resource.with_connection_lifted ~lift:(in_context Connection) db.database ~f:(fun c -> f (Session.Connection c))
let with_transaction (Session.Connection c : connection) ~f =
  Request.with_transaction_on c ~f:(fun tx -> f (Session.Transaction tx))
let execute s sql = Error.within (Query sql) (match Session.within s with
  | None -> Resource.execute (Session.connection s) sql
  | Some tx -> Resource.execute_transaction tx sql)

module Statement = struct
  type prepared = Query.prepared
  type chunk = Query.chunk
  let in_statement p = in_context (Query (Query.sql p))
  let with_prepared s sql ~f =
    Query.with_prepared_lifted ~lift:(in_context (Query sql)) (Session.connection s) (Session.within s) sql ~f
  let parameter_count p = Result.map_error (Query.parameter_count p) ~f:(in_statement p)
  let bind p i codec v = Result.map_error (Query.bind p i codec v) ~f:(in_statement p)
  let reset p = Result.map_error (Query.reset p) ~f:(in_statement p)
  let fold_chunks p ~init ~f = Query.fold_prepared_lifted ~lift:(in_statement p) p ~init ~f
  let chunk_length = Query.chunk_length
  let column chunk ~column ~row codec =
    Result.map_error (Query.column chunk ~column ~row codec) ~f:(in_context (Query (Borrowed_chunk.sql chunk)))
end
```

`Request.with_transaction_on` is today's `Request.Connection.with_transaction`
(lifted, with `transaction_outcome`), renamed. `Query.with_prepared_lifted`
dispatches on its `transaction option` argument: `None` prepares on the
connection, `Some tx` prepares in the transaction. This replaces the two
functions `with_prepared`/`with_prepared_transaction`.

`Query.fold_prepared_lifted` (new, in `query.ml`) executes and folds inside the
lease, replacing the public `execute_prepared` + `fold_chunks` pair:

```ocaml
let fold_prepared_lifted ~lift p ~init ~f =
  match execute_prepared p with
  | Error cause -> Error (lift cause)
  | Ok r -> fold_chunks_lifted ~lift r ~init ~f
```

`fold_chunks_lifted` is today's `fold_chunks` (via `fold_internal`), made
polymorphic in the callback's error type as described above.
`execute_prepared` and `fold_chunks` stay internal to `Query`.

`Query.sql p = p.sql` is added. `Borrowed_chunk.t` becomes
`{ native : F.prepared; sql : string }` with `val sql : t @ local -> string`.
`fold_internal` builds it as `stack_ { Borrowed_chunk.native; sql = r.prepared.sql }`.

`Request.Session` (in `request.ml`): rename `run_shape` to dispatch on a
session:

```ocaml
module Session = struct
  type 'k owner = 'k Session.t
  type error = Error.t
  type 'a future = 'a
  let run s shape r args = run_shape (Session.connection s) (Session.within s) shape r args
  let exec s r args = run s Exec r args
  let find s r args = run s Find r args
  let find_opt s r args = run s Find_opt r args
  let collect s r args = run s Collect r args
  let fold s r args ~init ~f = run s (Fold { init; f }) r args
  let with_transaction (Session.Connection c) ~f = with_transaction_on c ~f:(fun tx -> f (Session.Transaction tx))
  let ingest (Session.Connection c) table batches ~flush = (* today's Connection.ingest body on c *)
end
```

`Request.Connection` and `Request.Transaction` are deleted. `QUERY` becomes
`type _ owner` as in the target interface. Because `Request` now depends on
`Session`, `Session` must not depend on `Request`; it does not.

`Table.with_appender s table ~f` dispatches the same way: a connection wraps
`with_transaction_on`, a transaction uses today's
`with_appender_transaction`. `Table.with_appender_transaction` is deleted.

`Owned` (in `duckdb.ml`):

```ocaml
module Owned = struct
  let open_database config = Error.within Database (Result.map (Resource.open_database config) ~f:(fun database -> { Session.database }))
  let close_database (db : database) = Error.within Database (Resource.close_database db.database)
  let connect (db : database) = Error.within Connection (Result.map (Resource.connect db.database) ~f:(fun c -> Session.Connection c))
  let close_connection (Session.Connection c : connection) = Error.within Connection (Resource.close_connection c)
  type ('row, 'out) shape = ('row, 'out) Request.shape =
    | Exec : (unit, unit) shape
    | Find : ('row, 'row) shape
    | Find_opt : ('row, 'row option) shape
    | Collect : ('row, 'row list) shape
    | Fold : { init : 'a; f : 'row -> 'a -> ('a step, Error.t) result } -> ('row, 'a) shape
  let run = Request.Session.run
end
```

Remove `Request.shape`/`Request.run` from `duckdb.mli` (added in Task 8);
they now live in `Owned`. Remove from `duckdb.mli`:

- `open_database`, `close_database`, `connect`, `close_connection`;
- `execute_transaction`;
- `prepare`, `prepare_transaction`, `close_prepared`;
- `execute_prepared`, `close_result`, `query_result`;
- `with_prepared_transaction`;
- top-level `prepared`/`chunk`/`fold_chunks`/`chunk_length`/`column`/`bind`/
  `reset`/`parameter_count` (all now in `Statement`).

`Parquet.fold`/`fold_table`/`export` take `connection` (the session type)
and unwrap it with `Session.connection`.

`Bridge.run` takes and passes `connection` sessions:

```ocaml
let run request (Session.Connection c : connection) ~f =
  Resource.Bridge.run_lifted ~lift:(fun cause -> { Error.context = Connection; cause }) request c
    ~f:(fun facade -> f (Session.Connection facade))
```

`Resource.Bridge.run_lifted` is today's `run`, made polymorphic in the
callback's error type in the same way as `with_connection_lifted`.

- [ ] **Step 5: Migrate the worker and adapters**

- **Worker:** `type database = Database of D.database` stays.
  `open_database`/`connect`/`close_*` call `D.Owned.*`.
  `request_run slot request shape r args` calls
  `D.Owned.run c (marked shape) r args`, with
  `marked : ('row, 'out) D.Owned.shape -> …`. `transaction` and
  `request_transaction` use `D.with_transaction` and
  `D.Request.Session.with_transaction`. `table_ingest` uses
  `D.Request.Session.ingest`-style code over `D.Table.with_appender`.
  `execute` uses `D.execute`. The worker's typed signatures change
  `D.Request.shape` to `D.Owned.shape`.
- **Adapters:**
  - `Duckdb.transaction` stays the callback parameter type.
  - `Request.Generic : Duckdb.Request.CONNECTION with type 'k owner = t and …`:
    add a `type 'k owner = t` alias in each adapter's `Generic`.
  - The `QUERY` functions in `Generic` take `_ owner`, which is `t`.

- [ ] **Step 6: Migrate the tests (classification)**

Rewrite rules for every test file:

- `D.Request.Connection.X c` / `C.X c` → `R.Session.X c`; `T.X tx` →
  `R.Session.X tx`. Delete the `module C = …`/`module T = …` aliases.
- `D.execute_transaction tx sql` → `D.execute tx sql`.
- `D.with_prepared_transaction tx sql ~f` → `D.Statement.with_prepared tx sql ~f`.
- `D.with_prepared c sql ~f:(fun p -> let* r = D.execute_prepared p in D.fold_chunks r …)` →
  `D.Statement.with_prepared c sql ~f:(fun p -> D.Statement.fold_chunks p …)`.
- `D.bind`/`D.column`/`D.reset`/`D.parameter_count`/`D.chunk_length` →
  `D.Statement.*`.
- Manual `D.open_database`/`D.connect`/`D.close_*` → `D.Owned.*`.

Tests whose *subject* is the standalone result handle, and what happens to
each:

| Test | Scenario | Outcome |
|---|---|---|
| `test/test_query.ml` result-lease cases (the `children` helper from line 12) | reset/re-execute/close while a result is open | Deleted: no result handle exists outside a fold. Inside `fold_chunks`, a `reset`/`bind` on the same prepared statement returns `Busy` (the lease is held). Add one replacement assertion: inside `Statement.fold_chunks p ~f:(fun _ _ -> …)`, `Statement.reset p` is `Error { cause = Busy; _ }` |
| `test/test_query_concurrency.ml:91` | `execute_prepared` on a retained statement after close → `Closed` | Moved to Task 11 as the compile fixture `prepared_escape`; deleted here |
| `test/test_adapter_bridge.ml:56-58` | escaped `parameter_count`/`fold_chunks`/`execute_transaction` → `Closed` | Prepared/result/tx escape becomes a compile fixture in Task 11 (`prepared_escape`, `escape_ref`); deleted here. Owner-level `Closed` lines (33-34, 49, 198, 219, 245, 353) stay as runtime tests via `Owned` |

Everything else in the classification from the design note (concurrency,
signals, native delivery, bridge recovery) keeps its runtime expectation
and switches to `Owned` handles.

- [ ] **Step 7: Run and verify**

Run: `grep -rn "execute_transaction\|prepare_transaction\|execute_prepared\|close_result\|Request.Connection\|Request.Transaction\|with_prepared_transaction" lib/duckdb/duckdb.mli test examples bench lib/async lib/eio lib/worker`
Expected: no matches.
Run: `./tools/run build @all 2>&1 | tail -5 && ./tools/run runtest --force 2>&1 | tee .local/core-redesign/task10.log | grep -E "Session ops|intended|FAIL|rror:" | head`
Expected: `request: Session ops over connection and transaction=ok`, and the
request-types line still reports 22 rejections. Runtest exits 0. Also run
`./tools/run build @adapter-bridge @adapter-bridge-responsiveness 2>&1 | tail -3`
and `bash test/install_adapters_smoke.sh 2>&1 | tail -3`; both succeed.

- [ ] **Step 8: Commit**

```bash
jj describe -m "refactor(core)!: one kind-indexed session, Statement and Owned

Removes every *_transaction duplicate, Request.Connection/Transaction,
the public result handle and manual lifecycle (now Owned).

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>" && jj new
```

---

### Task 11: Scoped handles are `@ local`

**Files:**
- Modify: `lib/duckdb/duckdb.mli` (mode annotations, exactly as in "Target
  public interface"), `lib/duckdb/duckdb.ml` (annotate the parameters
  `(s @ local)` where inference does not reach), `lib/duckdb/request.mli`
  (`QUERY` with `_ owner @ local`), `lib/duckdb/session.mli` (already
  local-accepting)
- Create: `test/scope_compile/` with `positive.ml` and fixtures,
  `test/check_scope_types.sh`, and a dune rule
- Modify tests: those listed in Step 5

- [ ] **Step 1: Write the fixtures and the runner**

`test/check_scope_types.sh` is a copy of `test/check_request_types.sh` with
`request_compile` → `scope_compile` and these `expect` lines:

```bash
expect escape_return 'local'
expect escape_ref 'is "local" to the parent region'
expect escape_closure 'is "local" to the parent region'
expect prepared_escape 'local'
expect appender_escape 'local'
expect busy_fold 'is "local" to the parent region'
expect busy_transaction 'is "local" to the parent region'
expect busy_appender 'is "local" to the parent region'
echo 'scope types: positive forms and 8 intended rejections (escape, busy capture)=ok'
```

Fixtures (each starts with `module D = Duckdb`; `cfg` is a parameter):

- `escape_return.ml.fail`:
  `let f cfg = D.with_database cfg ~f:(fun db -> D.with_connection db ~f:(fun c -> Ok c))`
- `escape_ref.ml.fail`:
  `let leak = ref None` and
  `let f db = D.with_connection db ~f:(fun c -> leak := Some c; Ok ())`
- `escape_closure.ml.fail`:
  `let f db = D.with_connection db ~f:(fun c -> Ok (fun () -> D.execute c "SELECT 1"))`
- `prepared_escape.ml.fail`:
  `let f c = D.Statement.with_prepared c "SELECT 1" ~f:(fun p -> Ok p)`
- `appender_escape.ml.fail`:
  `let f c t = D.Table.with_appender c t ~f:(fun a -> Ok a)`
- `busy_fold.ml.fail`:

```ocaml
module D = Duckdb
let r = D.Request.many D.Fields.[] D.Fields.[int64] ~row:Fun.id "SELECT 1"
let f c = D.Request.Session.fold c r D.Args.[] ~init:() ~f:(fun _ () ->
  Result.map (D.execute c "SELECT 1") ~f:(fun () -> D.Continue ()))
```

- `busy_transaction.ml.fail`:
  `let f c = D.with_transaction c ~f:(fun _tx -> D.execute c "SELECT 1")`
- `busy_appender.ml.fail`:
  `let f c t = D.Table.with_appender c t ~f:(fun _a -> D.execute c "SELECT 1")`

`positive.ml` holds the accepted counterparts:

```ocaml
module D = Duckdb
let r = D.Request.many D.Fields.[] D.Fields.[int64] ~row:Fun.id "SELECT 1"
let helper c = D.execute c "SELECT 1"            (* inferred: _ session @ local -> … *)
let ok cfg = D.with_database cfg ~f:(fun db -> D.with_connection db ~f:(fun c ->
  let open Result in
  let ( let* ) x f = bind x ~f in
  let* () = helper c in
  let* () = D.with_transaction c ~f:(fun tx -> D.execute tx "SELECT 1") in
  let* n = D.Request.Session.fold c r D.Args.[] ~init:0 ~f:(fun x n -> Ok (D.Continue (n + Int64.to_int x))) in
  D.Statement.with_prepared c "SELECT 1" ~f:(fun p -> D.Statement.fold_chunks p ~init:n ~f:(fun _ n -> Ok (D.Stop n)))))
```

In `test/dune`:

```
(rule (alias runtest)
 (deps check_scope_types.sh ../lib/duckdb/duckdb.mli (glob_files scope_compile/*))
 (action (run bash %{dep:check_scope_types.sh} %{ocamlc})))
```

- [ ] **Step 2: Run to verify they fail**

Run: `./tools/run runtest --force 2>&1 | grep -m3 "unexpected acceptance\|scope types"`
Expected: `unexpected acceptance: escape_return`, because handles are not
local yet.

- [ ] **Step 3: Add the modes**

Change `duckdb.mli` to the target signatures, which add `@ local` to every
handle parameter and to every callback's handle argument. Then
`./tools/run build @all`. Expected errors are implementations that need an
explicit `(s @ local)` on a parameter whose use the compiler cannot infer
(for example, functions defined by partial application). Add the annotation
at each reported site. **Do not** add `@ local` to internal modules'
signatures: the facade's `Session.connection`/`within` produce the global
internals.

A facade function that wraps its callback (`fun c -> f (Session.Connection c)`)
already passes a global value where a local one is expected; that is
accepted.

- [ ] **Step 4: Run the fixtures**

Run: `./tools/run runtest --force 2>&1 | grep -E "scope types|unexpected|missing"`
Expected: `scope types: positive forms and 8 intended rejections (escape, busy capture)=ok`.
If a fixture fails only on its `expect` substring, inspect
`$tmp/<name>.out` by re-running the script with `set -x` removed and the
`trap` line commented out. Replace the substring with the observed
compiler wording, keeping it specific to locality ("local" plus
"region"/"escape"). Record the change in the task log.

- [ ] **Step 5: Migrate the tests whose scenario is now unwritable**

| Test (line) | Scenario | Outcome |
|---|---|---|
| `test/test_duckdb.ml:55-61` | handle alias used after its scope → `Closed` | Unwritable with scoped handles. Covered by `escape_return`/`escape_ref`. Keep the `Owned` variant: `Owned.close_connection c`, then `execute c` → `Closed` |
| `test/test_duckdb.ml:85` | escaped transaction used after settlement | Unwritable; covered by `escape_ref`. Deleted |
| `test/test_duckdb.ml:114` | saved effect continuation resumed after scope | Keep if it compiles. If the compiler rejects it because it captures a local handle, move it to `scope_compile` as `effect_escape` with the observed message |
| `test/test_duckdb.ml:81-83,126,136,157-176` | cross-thread Busy/Closed on a shared connection | Runtime, via `Owned.connect`, so the handle is global and shareable with threads |
| `test/test_query_concurrency.ml` (all threads sharing `c`) | concurrency | Runtime via `Owned` handles |
| `test/test_appender.ml:141` | `execute tx` while an appender is open | Unwritable (callback cannot capture `tx`); covered by `busy_appender`. Deleted |
| `test/test_appender_concurrency.ml`, `*_signals.ml`, `native_delivery/*`, `bridge_recovery/*` | owner-level Busy/Closed | Runtime via `Owned`; expectations unchanged |
| `test/async/test_native_cases.ml:168`, `test/eio/cancellation_eio.ml:200`, `test/adapter/evidence/test_{async,eio}_evidence.ml:26,130` | escaped adapter transaction token → `Closed` | Unwritable: adapter transaction callbacks receive `transaction @ local` (Task 13). Deleted here; Task 13 adds `adapter_tx_escape` fixtures |

Every other test only needs the rewrite rules from Task 10. Where a test
helper function takes a handle and the compiler asks for a local parameter,
add `(c @ local)`.

- [ ] **Step 6: Run and verify**

Run: `./tools/run build @all 2>&1 | tail -5 && ./tools/run runtest --force 2>&1 | tee .local/core-redesign/task11.log | grep -E "scope types|request types|FAIL|rror:" | head`
Expected: both type-suite lines are ok. Runtest exits 0.

- [ ] **Step 7: Commit**

```bash
jj describe -m "feat(core)!: scoped handles are local; escapes and busy captures are type errors

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>" && jj new
```

---

### Task 12: Unique Bridge requests

**Files:**
- Modify: `lib/duckdb/resource.ml:567-666`, `lib/duckdb/resource.mli`
  (Bridge), `lib/duckdb/duckdb.ml{,i}` (Bridge facade), the worker (the
  `D.Bridge.request` parameter type), both adapters (create, cancel and
  settlement call sites), `test/test_adapter_bridge*.ml`,
  `test/adapter_bridge_responsiveness.ml`, `test/native_delivery/*.ml`,
  `test/adapter_bridge_compile/*`
- Create: `test/scope_compile/bridge_twice.ml.fail`

- [ ] **Step 1: Write the failing fixture and runtime test**

`test/scope_compile/bridge_twice.ml.fail`:

```ocaml
module D = Duckdb
let f c =
  let r = D.Bridge.request (D.Bridge.canceller ()) in
  let _ = D.Bridge.run r c ~f:(fun _ -> Ok ()) in
  D.Bridge.run r c ~f:(fun _ -> Ok ())
```

Add `expect bridge_twice 'already been used as unique'` and bump the count
to 9.

Append to `test/test_adapter_bridge.ml`:

```ocaml
(* One canceller latches every request bound to it; cancelling a settled
   canceller is a no-op. *)
let () =
  with_owner (fun owner ->
    let k = B.canceller () in
    expect_ok (B.run (B.request k) owner ~f:(fun _ -> Ok ()));
    assert (match B.settlement k with B.Settled -> true | B.Pending -> false);
    B.cancel k;
    B.cancel k;
    match B.run (B.request k) owner ~f:(fun _ -> Ok ()) with
    | Error { D.Error.cause = D.Error.Cancelled; _ } -> ()
    | _ -> failwith "latched canceller did not cancel a later request");
  Stdlib.print_endline "bridge: canceller fan-out, settled cancel no-op=ok"
```

Use the file's existing owner helper and `expect`-style helpers. If they
differ in name, adapt to them, keeping the assertions.

- [ ] **Step 2: Run to verify they fail**

Run: `./tools/run build @all 2>&1 | grep -m2 Error`
Expected: `Unbound value B.canceller`.

- [ ] **Step 3: Implement**

In `resource.ml`'s `Bridge`, keep the existing per-request record and state
machine under the name `state` (rename `type nonrec request = request`
internally), and add:

```ocaml
  type canceller = { fan_mutex : Stdlib.Mutex.t; mutable latched : bool; mutable bound : request list }
  type handle = { cell : canceller; state : request }

  let canceller () = { fan_mutex = Stdlib.Mutex.create (); latched = false; bound = [] }
  let fan k f =
    Stdlib.Mutex.lock k.fan_mutex;
    Exn.protect ~finally:(fun () -> Stdlib.Mutex.unlock k.fan_mutex) ~f:(fun () -> Stdlib.Sys.with_async_exns f)
  (* Lock order: canceller -> request mutex (cancel_state takes the latter). *)
  let cancel_state state =
    request_locked state (fun () ->
      match state.request_state with
      | Finished -> ()
      | Fresh | Admitted | Running | Quiescing | Settling ->
        state.cancelled <- true;
        Option.iter state.native_request ~f:F.Native_request.cancel)
  let request k =
    let state = create () in
    fan k (fun () ->
      if k.latched then state.cancelled <- true;
      k.bound <- state :: k.bound);
    { cell = k; state }
  let cancel k = fan k (fun () -> k.latched <- true; List.iter k.bound ~f:cancel_state)
  let settlement k = fan k (fun () ->
    if not (List.is_empty k.bound) && List.for_all k.bound ~f:(fun s ->
      request_locked s (fun () -> match s.request_state with Finished -> true | _ -> false))
    then Settled else Pending)
  let run_lifted ~lift (h : handle) c ~f = run_state ~lift h.state c ~f
```

Here `run_state` is the Task 10 `run_lifted` on a single state, renamed. `consume` keeps its runtime
`Closed`/`Busy` check: it is unreachable through the unique public API but
remains the backstop for `Owned` misuse. `create` becomes private. `cancel`
and `settlement` on a single state are deleted; the canceller versions
replace them.

`resource.mli` exposes `canceller`, `handle` (abstract), `request`,
`cancel`, `settlement` and `run_lifted : lift:(Error.cause -> 'e) -> handle -> connection -> f:(connection -> ('a, 'e) result) -> ('a, 'e) result`.

In `duckdb.mli`/`duckdb.ml`, the facade:

```ocaml
module Bridge = struct
  type canceller = Resource.Bridge.canceller
  type request = { cell : Resource.Bridge.handle @@ aliased }
  type settlement = Resource.Bridge.settlement = Pending | Settled
  let canceller = Resource.Bridge.canceller
  let request k : request @ unique = { cell = Resource.Bridge.request k }
  let cancel = Resource.Bridge.cancel
  let settlement = Resource.Bridge.settlement
  let run (r @ unique) (Session.Connection c : connection) ~f =
    Resource.Bridge.run_lifted ~lift:(fun cause -> { Error.context = Connection; cause }) r.cell c
      ~f:(fun facade -> f (Session.Connection facade))
end
```

with `.mli` signatures as in the target interface. The record wrapper
exists only so the uniqueness annotation sits on a fresh allocation; P1
showed the `@@ aliased` field is required.

- [ ] **Step 4: Migrate the call sites**

- **Worker:** `D.Bridge.request` parameters become `D.Bridge.request @ unique`
  in `S`. Each `bridged slot request work` passes it straight to
  `D.Bridge.run` (one use).
- **Async adapter:** where a request is created and cancelled (`r.bridge`
  holds the request today), store the `canceller` in `r.bridge`. Create the
  unique request at dispatch, with `D.Bridge.request canceller`, and move it
  into the worker closure. `latch r` calls `D.Bridge.cancel canceller`,
  which returns `unit`: delete the `match … with Error Closed` arms. Code
  that read `settlement request` reads `settlement canceller`.
- **Eio adapter:** the same transformation.
- **Tests:**
  - `B.create ()` → `B.request (B.canceller ())` where the request is only
    run.
  - Where a test cancels, bind `let k = B.canceller ()` and use `k` for
    `cancel`/`settlement`.
  - Expectations of `Closed` from `B.cancel` (`test/test_adapter_bridge.ml:35,50,73`,
    `test/adapter_bridge_responsiveness.ml:40`): `cancel` now returns `unit`
    and is a no-op. Replace each with an assertion that a request created
    afterwards runs, or is `Cancelled` if the canceller was latched before.
  - The adapter tests' "delayed-A-cancel=Closed" output lines
    (`test/test_adapter_bridge_{async,eio}.ml:154,185`) change to
    `delayed-A-cancel=noop`.
  - Re-running a request (`test/test_adapter_bridge.ml:36`, `B.run request`
    twice) is unwritable; it is covered by `bridge_twice` and deleted.
  - `test/adapter_bridge_compile/forge_request.ml.fail`: keep its intent
    (requests cannot be forged) against the new record type; update its
    expected message in `test/check_adapter_bridge_interfaces.sh` to the
    observed unbound-field or private-type message.

- [ ] **Step 5: Run and verify**

Run: `./tools/run build @all 2>&1 | tail -5 && ./tools/run runtest --force 2>&1 | tee .local/core-redesign/task12.log | grep -E "canceller fan-out|scope types|FAIL|rror:" | head`
Expected: `bridge: canceller fan-out, settled cancel no-op=ok` and
`scope types: … 9 intended rejections …=ok`. Runtest exits 0. Then run
`./tools/run build @adapter-bridge @adapter-bridge-responsiveness 2>&1 | tail -3`
(expected empty) and `bash test/check_adapter_bridge_interfaces.sh 2>&1 | tail -2` (expected ok).

- [ ] **Step 6: Commit**

```bash
jj describe -m "feat(bridge)!: unique requests bound to a shareable canceller

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>" && jj new
```

---

### Task 13: Adapter surfaces

**Files:**
- Modify: `lib/async/duckdb_async.mli`, `lib/async/duckdb_async.ml`,
  `lib/eio/duckdb_eio.mli`, `lib/eio/duckdb_eio.ml`
- Create: `test/async/` and `test/eio/` fixtures `adapter_tx_escape.ml.fail`,
  added to `test/async/check_interfaces.sh` and the Eio interface check
  (find it with `ls test/eio/*.sh test/check_*`)

- [ ] **Step 1: Write the failing fixtures**

Async `adapter_tx_escape.ml.fail`:

```ocaml
let leak = ref None
let f pool = Duckdb_async.transaction pool ~f:(fun tx -> leak := Some tx; Ok ())
```

Expected message: `is "local" to the parent region`. Write the Eio
equivalent with `Duckdb_eio.transaction`.

`test/async/check_interfaces.sh` is not wired into Dune (a pre-existing
gap, noted in the last phase). Wire it in: add a `(rule (alias runtest) …)`
in `test/async/dune`, modelled on the `check_request_types.sh` rule, with
the deps the script reads. Read the script's header for its arguments.

- [ ] **Step 2: Run to verify they fail**

Run: `./tools/run runtest --force 2>&1 | grep -m2 "adapter_tx_escape"`
Expected: `unexpected acceptance`.

- [ ] **Step 3: Change the adapter signatures**

In both adapters:

- `transaction : t -> f:(Duckdb.transaction @ local -> ('a, Duckdb.Error.t) result) -> …`
- `Request.with_transaction` and `Request.submit_transaction`: the same
  callback type.
- `Request.Generic : Duckdb.Request.CONNECTION with type 'k owner = t and type error = error and type 'a future = …`
  (if Task 10 already did this, verify it).
- Delete the doc sentences "An escaped token is dynamically revoked
  (Closed)" and "token revoked on return", replacing them with "The token
  is local to the callback."

The worker's `transaction`/`request_transaction` callbacks get the same
`@ local` parameter type.

- [ ] **Step 4: Run and verify**

Run: `./tools/run build @all 2>&1 | tail -5 && ./tools/run runtest --force 2>&1 | tee .local/core-redesign/task13.log | grep -E "adapter_tx_escape|interfaces|FAIL|rror:" | head`
Expected: both adapter interface checks print their ok lines with the new
fixture. Runtest exits 0. Then run `bash test/install_adapters_smoke.sh 2>&1 | tail -3`;
expected success.

- [ ] **Step 5: Commit**

```bash
jj describe -m "feat(adapters)!: local transaction tokens; wire the Async interface check into runtest

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>" && jj new
```

---

### Task 14: Docs, examples, mutation scripts, full CI

**Files:**
- Modify: `docs/architecture.md`, `examples/synchronous.ml`,
  `examples/asynchronous.ml`, `examples/eio.ml`, `CHANGELOG.md`,
  `docs/design/core-redesign.md` (status line), `README.md` (API snippets,
  if any), the mutation scripts under `test/` and `tools/` that reference
  removed names (find them with
  `grep -rln "execute_prepared\|Row\.\|append_rows\|Request.Connection\|Live_children\|round_float32" test tools bench --include='*.py' --include='*.sh'`)

- [ ] **Step 1: Examples**

Rewrite `examples/synchronous.ml` on the final API: scopes,
`Request.Session`, `Table`, `Statement` for one low-level read, and
`Error.t` matching. Its `error_name` function matches `Error.cause`
exhaustively. Port the two adapter examples the same way.
Run: `./tools/run exec examples/synchronous.exe && ./tools/run exec examples/asynchronous.exe && ./tools/run exec examples/eio.exe`
Expected: each exits 0 with its documented output.

- [ ] **Step 2: Mutation scripts**

For each script found above, port the mutated snippets to the new names.
Run each script as the last phase did; the commands are in the previous
phase's final commit message (`jj log -r 'description(glob:"docs(request)*")' -T description --no-pager`).
Each mutant must still fail for its named reason, and every file must be
restored byte-for-byte. A mutant whose target code no longer exists is
removed with a one-line comment saying why, as was done for
`select_premature_schema_validator`. Log to
`.local/core-redesign/mutations-*.log`.

- [ ] **Step 3: Documentation**

- `docs/architecture.md`: describe the session GADT, scopes-only handles,
  `Owned`, `Statement`, the single error type and the shape-driven `run`.
  Replace the "no SQL DSL" non-goal with: "A typed SQL layer is planned
  (sub-project 2 of `docs/design/core-redesign.md`)."
- `docs/design/core-redesign.md`: change the status to
  "approved and implemented (sub-project 1)". Add an "Implementation notes"
  section listing every deviation recorded in the task logs (Spine fallback
  if taken, observed fixture messages, the effect-continuation test
  outcome).
- `CHANGELOG.md`, under `## Unreleased`, add `### Changed (breaking)` with
  one bullet per removed or renamed item from the target interface's
  "Removed" paragraph, and `### Added` with `Error`, `Owned`,
  `Statement`, `Request.Session`, `Bridge.canceller`/`request`, exact small
  numerics, and the new fixtures.

- [ ] **Step 4: Full CI sequence**

Run every command from `docs/development.md`'s main block, in order,
logging each to `.local/core-redesign/ci-<n>.log`:

```bash
./tools/run build @all
./tools/run runtest --force
python3 -m unittest test.soak.test_run_soak bench.test_benchmark_summary tools.test_bootstrap
./tools/run exec examples/synchronous.exe
./tools/run exec examples/asynchronous.exe
./tools/run exec examples/eio.exe
bash test/install_adapters_smoke.sh
./tools/run exec --no-build test/soak/test_soak_support.exe
python3 test/soak/run_model_soak.py --seed 104729 --episodes 8 --output .local/soak-model.log
python3 test/soak/run_soak.py --seed 104729 --repetitions 1 --output .local/soak.log
python3 bench/run_benchmarks.py --correctness-only --rows 1000 --warmups 0 --samples 1 --output-dir .local/benchmark-check
./tools/run runtest test/native-ffi --force
./tools/run build @adapter-bridge @adapter-bridge-responsiveness
```

Expected: each exits 0. A failure is fixed in the task that owns the code,
then the sequence is re-run. The soak and benchmark harnesses use the
public API, so expect to port them in this step. Record the ports.

- [ ] **Step 5: Commit**

```bash
jj describe -m "docs: document the core redesign; port examples, mutations and harnesses

Verification (all exit 0): <paste the command list and the final ok lines
from .local/core-redesign/ci-*.log>

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>" && jj new
```

---

## Spec coverage

| Spec section | Task |
|---|---|
| One session type indexed by kind; no `*_transaction` duplicates; nested transactions are a type error | 10, 11 (`nested_transaction` fixture in 10) |
| Handles only from scopes, `@ local`; `query_result` removed | 10 (shape), 11 (modes) |
| Busy-period callbacks cannot capture handles | 11 (`busy_*` fixtures); P4 widens it to every scope (Task 1) |
| `@ unique` Bridge request | 12 |
| Portability (no mode crossing) | Already enforced; existing `domain.ml.fail` fixtures in `compile/`, `query_compile/` and `adapter_bridge_compile/` keep passing every task |
| `Owned` for the adapters | 10 |
| `Codec` is the only value description | 4 |
| Exact small numerics | 3 |
| One shared list structure | 7 |
| `Row.t` and `cell` removed | 5, 6 |
| Shape GADT, one `run` per layer; dead multiplicity field removed | 8, 2 |
| One error type; removed and kept causes | 9 (+ Task 1 corrections) |
| Public API table | 10–13 |
| Compile-fixture list | 3 (`int8_range`), 6, 10 (`nested_transaction`), 11 (escape/busy), 12 (`bridge_twice`), 13 (adapter escape) |
| Converting runtime tests for impossible errors | 6, 10, 11, 12 classification tables |
| Mutation scripts, docs, examples, CHANGELOG | 14 |
| Appendix A requirements (Request.t single executable; Codec inspectable internally; shared nullability index; Spine; polymorphic-variant row count; Table keeps inspectable columns) | Preserved by 7, 8 and 10; no task removes them |
