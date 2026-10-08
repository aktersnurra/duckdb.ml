# Window Functions (sub-project 4c) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ranking, offset and aggregate window functions with frames and QUALIFY in `Duckdb.Sql`, of a `'k windowed` kind that only `select_over` accepts.

**Architecture:** A window is `{ partition; order; frame }`; a node `Over of node * window` renders `f(…) OVER (…)`; the body gains `qualify`; `select_over` builds an ordinary `'k` body from a `'k windowed` list. Spec: [docs/design/windows.md](docs/design/windows.md).

**Tech Stack:** OxCaml (`-extension-universe beta`), Base, dune, DuckDB 1.5.5, via `./tools/run`.

**Process note.** Test-first per task in `test/test_sql_window.ml` (new executable): run red, implement, green with `./tools/run exec test/test_sql_window.exe`, then `test_sql.exe` and `test_sql_dml.exe` for regressions.

---

## File structure

| File | Responsibility |
|---|---|
| `lib/duckdb/sql.ml` | `windowed`, windows, `Over` node, `qualify`, `select_over`, functions |
| `lib/duckdb/duckdb.mli` | The `Sql` signature additions |
| `test/test_sql_window.ml`, `test/dune` | Behaviour against DuckDB |
| `test/window_compile/`, `test/check_window_types.sh` | Compile fixtures |
| docs | README, CHANGELOG, roadmap row 4c, design note |

### Task 1: Windows, `select_over`, ranking, QUALIFY

- [ ] Tests: `row_number` partitioned and ordered (rendered `row_number() OVER (PARTITION BY t0."k" ORDER BY t0."d" ASC)`), `rank`, `dense_rank`, `ntile 2`, `percent_rank`, `cume_dist` values; QUALIFY top-1 per group; ORDER BY a window; `lift` of columns; `Invalid_argument` for `ntile (-1)`.
- [ ] Implement `windowed`, `window`, `part`, `lift`, `Over` node and rendering, `qualify`, `select_over`, ranking functions.
- [ ] Green.

### Task 2: Offsets and frames

- [ ] Tests: `lag`/`lead` (NULL at edges), `?offset:2`, `lag_or ~default`; `first_value`, `last_value` (default frame and `rows Unbounded_preceding Unbounded_following`), `nth_value 2`; `Null.lag` of a nullable column; ROWS running total and RANGE moving sum; frame rendering; `Invalid_argument` for a negative offset or frame bound.
- [ ] Implement.
- [ ] Green.

### Task 3: Aggregates over windows

- [ ] Tests: `Over.count_star`, `Over.count`, `Over.min`/`max`, `Over.sum` decoded as int64 (and `I32.sum_over` as int32), `Over.avg`, `Over.Null.sum` of a nullable column; `sum(sum(v)) OVER ()` and `rank` over `sum` inside `group_by`; a window over a join; an `aggregate` select with a window aggregate is still rejected as without aggregate when no plain aggregate exists.
- [ ] Implement `Over`, `sum_over`/`avg_over` in INTEGRAL/FRACTIONAL.
- [ ] Green.

### Task 4: Compile fixtures

- [ ] `positive.ml` and fixtures `window_where`, `window_having`, `window_in_aggregate`, `unlifted_column`, `lag_or_nullable`, `window_assignment`; `check_window_types.sh`; dune rule.
- [ ] `./tools/run runtest --force` exit 0.

### Task 5: Documentation

- [ ] README example compiled and run; CHANGELOG; roadmap row 4c; design note status/refinements; mli docs.
- [ ] `./tools/run build @all` clean; `./tools/run runtest --force` exit 0.
