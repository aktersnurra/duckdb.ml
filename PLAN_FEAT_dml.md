# Typed DML (sub-project 4b) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `Sql.command` with typed UPDATE, DELETE, INSERT (values, defaults, `select_into`), `returning` and ON CONFLICT upserts.

**Architecture:** A statement is `{ target; scope; kind; result }` in `sql.ml`, rendered with the 4a context; bodies are `('shape, 'row, 'm) change`, results a GADT of `Count` or `Returning` fields. Spec: [docs/design/dml.md](docs/design/dml.md).

**Tech Stack:** OxCaml (`-extension-universe beta`), Base, dune, DuckDB 1.5.5, via `./tools/run`.

**Process note.** Test-first per task: tests in `test/test_sql_dml.ml` (new executable), run red, implement, run green with `./tools/run exec test/test_sql_dml.exe`; then `test_sql.exe` for regressions.

---

## File structure

| File | Responsibility |
|---|---|
| `lib/duckdb/sql.ml` | Statements, assignments, conflict clauses, rendering |
| `lib/duckdb/duckdb.mli` | The `Sql` signature additions |
| `test/test_sql_dml.ml`, `test/dune` | Behaviour against DuckDB |
| `test/dml_compile/`, `test/check_dml_types.sh` | Compile fixtures |
| docs | README, CHANGELOG, roadmap row 4b, design note |

### Task 1: `command`, UPDATE, DELETE, `returning`

- [ ] Tests: `rename` renders `UPDATE "main"."users" AS t0 SET "name" = CAST($2 AS VARCHAR) WHERE (t0."id" = CAST($1 AS BIGINT))` and returns count 1 / 0; update with a correlated `exists` WHERE; `delete … filter` count; `delete … all` count; `returning` on update (new values) and delete (old rows); `Invalid_argument` for a non-column target, a column of another table, a duplicate target, an empty `set`, codec mismatch (custom codec column := plain literal).
- [ ] Implement statement types, `command`, `:=`, `set`, `filter`, `all`, `update`, `delete`, `returning`.
- [ ] Green.

### Task 2: INSERT values, defaults, `select_into`

- [ ] Tests: partial insert with defaults (rendered without alias), `values []` → `DEFAULT VALUES`, `returning` the generated id (sequence default), `select_into` from a source with a WHERE; NOT NULL violation as `Error (Native _)`; `Invalid_argument` for a value mentioning the table's columns, a `Targets` element of another table.
- [ ] Implement.
- [ ] Green.

### Task 3: ON CONFLICT

- [ ] Tests: `nothing_on` keeps the row (count 0); `update_on` with `excluded` changes it (count 1), with `~where` not matching keeps it; renders `AS t0` and `ON CONFLICT ("id") DO UPDATE SET "name" = excluded."name"`; with `returning`; `select_into` with `nothing_on`; `Invalid_argument` for an undeclared key and a key from another table.
- [ ] Implement.
- [ ] Green.

### Task 4: Compile fixtures

- [ ] `test/dml_compile/positive.ml` (the design examples), fixtures `assign_type`, `assign_nullable`, `select_into_types`, `find_returning`, `returning_twice`, `conflict_shape`; `check_dml_types.sh`; dune rule.
- [ ] `./tools/run runtest --force` exit 0.

### Task 5: Documentation

- [ ] README "Typed SQL" DML example compiled and run; CHANGELOG; roadmap row 4b done; design note status/refinements; mli docs.
- [ ] `./tools/run build @all` clean; `./tools/run runtest --force` exit 0.
