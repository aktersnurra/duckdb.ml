# Schema Declarations (sub-project 3a) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Constraints on `Table.declare`, with `Table.create`, `Table.verify` and a typed `Table.lookup`.

**Architecture:** Typed constraint builders over column binders (scope-tagged, as in typed SQL) are resolved once at `declare` into an untyped `Table_constraint.t` list stored in the table definition; `create` renders DDL from it, `verify` compares it with `duckdb_columns()`/`duckdb_constraints()`, `lookup` builds a `Request.generated`. Spec: [docs/design/schema.md](docs/design/schema.md).

**Tech Stack:** OxCaml (`-extension-universe beta`), Base, dune, DuckDB 1.5.5, via `./tools/run`.

**Process note.** As in sub-project 2, the plan's code was prototyped while planning to verify it against the compiler and DuckDB; it passed and was kept. Each task lists its verification.

---

## File structure

| File | Responsibility |
|---|---|
| `lib/duckdb/failure.ml(i)`, `duckdb.mli` | Causes `Unknown_table`, `Constraint_mismatch` |
| `lib/duckdb/table_constraint.ml` | Untyped, rendered constraints |
| `lib/duckdb/request.ml(i)` | `Table_def.constraints`, `declare_table ?constraints`, `check_declaration` exposed |
| `lib/duckdb/sql.ml` | `column` values, `?qualifier` rendering, `mentioned` |
| `lib/duckdb/table.ml` | `Binders`, `Key`, `Constraint`, `declare`, `create`, `verify`, `lookup` |
| `lib/duckdb/duckdb.mli` | `Sql` before `Table`; new `Table` API |
| `test/test_schema.ml`, `test/schema_compile/`, `test/check_schema_types.sh` | Tests and fixtures |
| `examples/sql.ml`, `examples/synchronous.ml` | `Table.create`, constraints, `lookup` |
| docs | README, CHANGELOG, roadmap, design note |

### Task 1: Constraints, create, verify, lookup — DONE (`rpmnxstx b0352b47`)

- [x] Causes, `Table_constraint`, `Table_def.constraints`, `Sql` column values/qualifier/mentioned, `table.ml` API, `duckdb.mli` reorder and signatures; exhaustive `Error.cause` matches in examples and `test_request.ml` extended.
- [x] `test/test_schema.ml`: DDL and lookup SQL (read from a second create's error context), create/verify/enforcement/defaults/lookup, other schema and `check_null`, 12 verify differences with exact causes, 6 `Invalid_argument` cases. Run: `./tools/run exec test/test_schema.exe` → 5 `=ok` lines.
- [x] `test/schema_compile`: `positive.ml` + 7 fixtures, `check_schema_types.sh` in `runtest`.
- [x] `./tools/run runtest --force` exit 0.

### Task 2: Examples — DONE (`mzmkoyuv d2bb07ad`)

- [x] `examples/sql.ml`: constraints (`primary_key`, `check_null`), `Table.create`, `lookup`, `verify`. `./tools/run exec examples/sql.exe` prints the query, `adult 1 ada`, `user 2: bob`, `ada: 2, oldest 36`, `bob: 1, oldest unknown`.
- [x] `examples/synchronous.ml`: `Table.create` replaces the hand-written CREATE TABLE.

### Task 3: Documentation — DONE

- [x] README: constraints in the first example (compiled and run from the README text: prints `1 ada`), a "Schema" section (compiled), roadmap.
- [x] CHANGELOG entry; core-redesign roadmap row 3 (3a done); design note status and refinements.
- [x] Verify: `./tools/run build @all`, `./tools/run runtest --force` exit 0.
