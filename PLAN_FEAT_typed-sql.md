# Typed SQL (sub-project 2) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `Duckdb.Sql`, typed single-table SELECT queries built from phantom-typed expressions that compile to an ordinary `Request.t`.

**Architecture:** An untyped node tree rendered to SQL, behind `('a, 'n, +'k) expr` whose typing rules live in `duckdb.mli` and are pinned by compile-failure fixtures. Table declarations gain a `'shape` index so `from` binds columns with their exact types. Spec: [docs/design/typed-sql.md](docs/design/typed-sql.md).

**Tech Stack:** OxCaml (`-extension-universe beta`), Base, dune, DuckDB 1.5.5. Commands run through `./tools/run` (provisioned opam switch).

**Process note.** Tasks 1 and 2 were prototyped while planning, to verify that the code this plan would contain compiles and runs. They passed, so they were kept as commits, not re-done from the plan. They are listed with their verification.

---

## File structure

| File | Responsibility |
|---|---|
| `lib/duckdb/codec.ml(i)` | `('a, 'n) slot`, the shape element |
| `lib/duckdb/columns.ml` | Hand-written 4-index column list, `names` |
| `lib/duckdb/request.ml(i)` | 3-index `table`, existential appender shape, `quote`, `generated` |
| `lib/duckdb/sql.ml` | Expression nodes, rendering, lists, `query`/`from`/`select`/`aggregate`/`group_by`, operators |
| `lib/duckdb/duckdb.mli` | Public `Table` (3 indices) and `Sql` signatures |
| `test/test_sql.ml` | Rendering and execution tests |
| `test/sql_compile/`, `test/check_sql_types.sh` | Positive program and rejected fixtures |
| `test/async/typed_request_async.ml`, `test/eio/request_eio.ml` | One generated request through each adapter |
| `examples/sql.ml` | Runnable example |
| docs | Architecture, typed requests, README, CHANGELOG, design note |

### Task 1: Table shape index — DONE (`omomorzx 157cae32`)

- [x] `Codec.slot`; `Columns` 4-index with `names`; `Request.table`/`Table.t` 3-index; appender holds its table shape existentially; Parquet/adapter signatures `(_, _, _)`.
- [x] Verified alone: `jj new omomorzx`, `./tools/run build @all` (clean), `./tools/run runtest --force` (exit 0).

### Task 2: `Duckdb.Sql` with tests and fixtures — DONE (`usyklzzr 2c5b8675`)

- [x] `lib/duckdb/sql.ml`, `Request.quote`/`Request.generated`, `duckdb.mli` `Sql` signature, `sql` in `private_modules`.
- [x] `test/test_sql.ml`: 7 groups (README examples, Null logic, quoting/like/order/paging, per-type arithmetic, aggregates, custom codecs and parameter reuse, statement cache and catalog mismatch). Run: `./tools/run exec test/test_sql.exe` → 7 `=ok` lines.
- [x] `test/sql_compile`: `positive.ml` plus 16 fixtures, checked by `check_sql_types.sh` in `runtest`.
- [x] `./tools/run runtest --force` exit 0.

### Task 3: Adapter interop

**Files:** Modify `test/async/typed_request_async.ml`, `test/eio/request_eio.ml`.

- [ ] **Step 1: Add a generated request to the Async test.** After the `rollback left no row` check, insert:

```ocaml
  let generated = D.Sql.(query Params.[int64] (fun [floor] ->
    from notes (fun [value; _] ->
      select Exprs.[value] ~row:Fn.id ~where:(value >= param floor) ~order_by:[asc value]))) in
  Q.collect pool generated D.Args.[0L] >>| request_ok >>= fun typed ->
  require "generated request" (List.equal Int64.equal typed remaining);
```

and extend the final message to `…, cancellable submit, generated SQL=ok`.

- [ ] **Step 2: Add the same to the Eio test.** After `rollback left no row`:

```ocaml
      let generated = D.Sql.(query Params.[int64] (fun [floor] ->
        from notes (fun [value; _] ->
          select Exprs.[value] ~row:Fn.id ~where:(value >= param floor) ~order_by:[asc value]))) in
      require "generated request"
        (List.equal Int64.equal (request_ok (Q.collect pool generated D.Args.[0L])) [1L; 2L]);
```

and extend its message to `…, fiber cancellation, generated SQL=ok`.

- [ ] **Step 3: Run.** `./tools/run build @test/async/runtest @test/eio/runtest 2>&1 | grep -E "generated SQL|Error"`. Expected: both lines end in `generated SQL=ok`, no `Error`.

- [ ] **Step 4: Commit.** `jj describe -m "test(sql): generated requests through the Async and Eio adapters"`, then `jj new`.

### Task 4: Example and timing

**Files:** Create `examples/sql.ml`. Modify `examples/dune`.

- [ ] **Step 1: Write `examples/sql.ml`.**

```ocaml
(* Typed SQL: queries built from typed expressions compile to requests. *)
open! Base
module D = Duckdb
module R = D.Request
module S = D.Sql

let users = D.Table.(declare "users"
  Columns.["id", int64; "name", string; "age", nullable int32]
  ~row:(fun id name age -> (id, name, age)))
let create = R.exec D.Fields.[] "CREATE TABLE users(id BIGINT, name VARCHAR, age INTEGER)"

let adults = S.(
  query Params.[int32] (fun [min_age] ->
    from users (fun [id; name; age] ->
      select Exprs.[id; name] ~row:(fun id name -> (id, name))
        ~where:(is_true Null.(age >= nullable (param min_age)))
        ~order_by:[asc id])))
let by_name = S.(
  query Params.[] (fun [] ->
    from users (fun [_; name; age] ->
      group_by Keys.[name] (fun [name] ->
        select Exprs.[name; count_star; Null.max age] ~row:(fun n c m -> (n, c, m))
          ~order_by:[asc name]))))

let run (c @ local) =
  match R.Session.exec c create D.Args.[] with
  | Error e -> Error e
  | Ok () ->
    match D.Table.with_appender c users ~f:(fun a ->
      D.Table.append a [ D.Args.[1L; "ada"; Some 36l]; D.Args.[2L; "bob"; None]; D.Args.[3L; "ada"; Some 17l] ]) with
    | Error e -> Error e
    | Ok () ->
      match R.Session.collect c adults D.Args.[18l] with
      | Error e -> Error e
      | Ok adults ->
        List.iter adults ~f:(fun (id, name) -> Stdio.printf "adult %Ld %s\n" id name);
        R.Session.collect c by_name D.Args.[]

let () =
  Stdio.print_endline (R.query adults);
  match Result.bind (D.Config.create Memory) ~f:(fun config ->
    D.with_database config ~f:(fun db -> D.with_connection db ~f:run)) with
  | Ok groups ->
    List.iter groups ~f:(fun (name, n, oldest) ->
      Stdio.printf "%s: %Ld, oldest %s\n" name n (Option.value_map oldest ~default:"unknown" ~f:Int32.to_string))
  | Error _ -> Stdio.eprintf "query failed\n"
```

- [ ] **Step 2: Register it.** Append to `examples/dune`:

```
(executable (name sql) (modules sql) (libraries base stdio duckdb)
 (flags (:standard -extension-universe beta)))
```

- [ ] **Step 3: Run.** `./tools/run exec examples/sql.exe`. Expected:

```
SELECT t0."id", t0."name" FROM "main"."users" AS t0 WHERE ((t0."age" >= CAST($1 AS INTEGER)) IS TRUE) ORDER BY t0."id" ASC
adult 1 ada
ada: 2, oldest 36
bob: 1, oldest unknown
```

- [ ] **Step 4: One-off timing (not a harness path).** In the scratchpad, time `R.Session.fold` over a 1M-row `t(a BIGINT, b BIGINT)` table (`b` NULL every tenth row) for the generated `select Exprs.[a; b]` and for `R.many … "SELECT a, b FROM t"`, `SET threads=1`, `taskset -c 0`, median of 10 after 2 warmups. Record both medians in the design note's acceptance section. Expected: within noise (same decode path).

- [ ] **Step 5: Commit.** `jj describe -m "docs(examples): typed SQL example"`, then `jj new`.

### Task 5: Documentation

**Files:** `docs/architecture.md`, `docs/design/typed-requests.md`, `docs/design/core-redesign.md`, `README.md`, `CHANGELOG.md`, `docs/design/typed-sql.md`.

- [ ] **Step 1:** `docs/architecture.md`: replace the planned-typed-SQL / "no SQL DSL" text with a short description of `Duckdb.Sql` (output is `Request.t`, checked by the type checker, link to the design note).
- [ ] **Step 2:** `docs/design/typed-requests.md`: update the L3 row to say L3 is implemented by `Duckdb.Sql`.
- [ ] **Step 3:** `docs/design/core-redesign.md`: roadmap row 2 marked done with a link to `typed-sql.md`; Appendix A note that `typed-sql.md` supersedes it where they differ.
- [ ] **Step 4:** `README.md`: a "Typed SQL" section after "What the compiler rejects", with the `adults`/`by_name` example and three rejected lines (nullable compare, ungrouped column in a grouped select, `find` on a `select`); roadmap paragraph: typed SQL done, schema and migrations next. Add `examples/sql.exe` to the build commands.
- [ ] **Step 5:** `CHANGELOG.md`: entry for sub-project 2 — `Duckdb.Sql`; breaking `Table.t`/`Table.Columns` shape index; runtime-checked cases (unused parameter is `Parameter_count`, `~having` outside `group_by`, scope leaks).
- [ ] **Step 6:** Design note status: "implemented".
- [ ] **Step 7: Verify.** `./tools/run build @all`, `./tools/run runtest --force` (exit 0), `./tools/run exec examples/sql.exe`.
- [ ] **Step 8: Commit.** `jj describe -m "docs: typed SQL in the architecture, README and changelog"`.
