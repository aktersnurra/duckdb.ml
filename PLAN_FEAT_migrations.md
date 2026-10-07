# Versioned Migrations (sub-project 3b) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `Duckdb.Migration`: ordered, numbered, forward-only steps applied each in its own transaction with a bookkeeping row, with history checks and optional verification.

**Architecture:** A step is `{ version; name; checksum; kind }` where `kind` is rendered SQL statements or an OCaml function over the step's transaction. `apply` creates `main.duckdb_ml_migrations`, compares the applied rows with the list (prefix by version, name, MD5 checksum), applies the rest through `Request.Session.with_transaction`, then runs `Table.verify`. Spec: [docs/design/migrations.md](docs/design/migrations.md).

**Tech Stack:** OxCaml (`-extension-universe beta`), Base, dune, DuckDB 1.5.5, via `./tools/run`.

**Process note.** As in sub-projects 2 and 3a, the code was prototyped while planning to verify it against the compiler and DuckDB; it passed and was kept. Each task lists its verification.

---

## File structure

| File | Responsibility |
|---|---|
| `lib/duckdb/failure.ml(i)`, `duckdb.mli` | Context `Migration`, cause `Migration_mismatch` |
| `lib/duckdb/migration.ml` | Steps, kinds, bookkeeping, history check, `apply` |
| `lib/duckdb/duckdb.mli` | `Migration` signature after `Table` |
| `examples/*.ml`, `test/test_request.ml`, `test/request_compile/positive.ml` | Exhaustive `Error` matches extended |
| `test/test_migration.ml`, `test/migration_compile/`, `test/check_migration_types.sh` | Tests and fixtures |
| docs | README, CHANGELOG, roadmap, design note |

### Task 1: Migrations — DONE (`rktyxqqm 72e91ed8`)

- [x] Context and cause; `migration.ml`; `duckdb.mli`; `migration` in `private_modules`; exhaustive matches extended.
- [x] `test/test_migration.ml`: from empty with verify, idempotent rerun, extension with name-based steps; `add_column` default + NOT NULL on rows, failure without default leaves no trace, constrained column `Invalid_argument`; failing `run` step rolled back alone and rerun; edited/renamed/ahead/gap histories with exact causes; version order; verify after applying. Run: `./tools/run exec test/test_migration.exe` → 5 `=ok` lines.
- [x] `test/migration_compile`: `positive.ml` + 3 fixtures in `runtest`.
- [x] `./tools/run runtest --force` exit 0 (after extending `test/request_compile/positive.ml`'s context match, found by the first full run).

### Task 2: Documentation — DONE

- [x] README "Migrations" section, compiled and run from the README text against its own declarations (`applied 1,2,3,4`); roadmap paragraph.
- [x] CHANGELOG; core-redesign row 3 done; design note status and refinements.
