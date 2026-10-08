# Query Composition (sub-project 4a) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Joins (INNER, LEFT with lifted nullability, CROSS), `DISTINCT`, literals of any codec, EXISTS/IN/scalar subqueries and set operations in `Duckdb.Sql`.

**Architecture:** `sql.ml` gains join records on a body, a source tree (`Select | Set`), and subquery nodes. Aliases are assigned at render time in order of appearance, through a scope → alias map that replaces the fixed `t0.` qualifier. LEFT JOIN bodies bind `outer` values lifted by `outer`/`Null.outer`. Spec: [docs/design/query-composition.md](docs/design/query-composition.md).

**Tech Stack:** OxCaml (`-extension-universe beta`), Base, dune, DuckDB 1.5.5, via `./tools/run`.

**Process note.** As in sub-projects 2–3, each task is test-first: the test is added to `test/test_sql.ml` (or a fixture to `test/sql_compile/`), run red, then implemented and run green. Run one suite with `./tools/run exec test/test_sql.exe`; the fixtures with `./tools/run build @test/runtest`.

---

## File structure

| File | Responsibility |
|---|---|
| `lib/duckdb/sql.ml` | Joins, `outer`, `distinct`, `value`, subquery nodes, set operations, alias rendering |
| `lib/duckdb/duckdb.mli` | The `Sql` signature additions |
| `lib/duckdb/table.ml` | Adjusts to `render`'s alias map (CHECK/DEFAULT keep no qualifier) |
| `test/test_sql.ml` | Behaviour against DuckDB |
| `test/sql_compile/*.ml.fail`, `test/check_sql_types.sh` | Compile-failure fixtures |
| docs | README "Typed SQL", CHANGELOG, roadmap rows 4a–4c, design note |

## Key types (sql.ml)

```ocaml
type join_kind = Inner | Left | Cross
type join = { kind : join_kind; target : string; scope : int; on : node option }
(* body gains: distinct : bool; joins : join list (outermost first) *)
type ('row, 'm) source =
  | Select of { target : string; scope : int; body : ('row, row, 'm) body }
  | Set of { op : string; left : ('row, 'm) source; right : ('row, 'm) source }   (* 'm many *)
(* node gains: Exists of packed_source | In_subquery of node * packed_source | Scalar of packed_source *)
type ('a, 'n) outer = { node : node; codec : ('a, 'n) Codec.t }
```

Rendering threads a mutable counter for aliases and an association list
scope → alias of every enclosing table; `render` of a `Column` looks its
scope up there (absent: `foreign ()`), the table qualifier path passes an
empty map plus `~qualifier:""`.

### Task 1: Aliases, joins, outer, distinct — DONE

- [ ] Tests: inner join of users/posts (SQL text `… FROM "main"."users" AS t0 INNER JOIN "main"."posts" AS t1 ON (t1."owner" = t0."id") …` and rows); left join where a user has no post decodes `None` through `outer`; `Null.outer` of a nullable column; cross join count; three nested joins (users ⋈ posts ⟕ comments); `~distinct:true`; the same query built twice renders the same text; a binder of a join used in another query raises `Invalid_argument`.
- [ ] Implement: alias map rendering; `join`, `left_join`, `cross_join`, `Outer`, `outer`, `Null.outer`; `select ?distinct`.
- [ ] Green: `./tools/run exec test/test_sql.exe`; all earlier `sql:` lines still `=ok`; `./tools/run exec test/test_schema.exe` (CHECK rendering unchanged).

### Task 2: `value` — DONE

- [ ] Tests: custom-codec `value` compared with its column (accepted; rows); `value` of `date`, `timestamp_us`, `timestamp_ms`, `timestamp_s`, `timestamp_ns`, `timestamp_tz` and `blob` selected and decoded equal to the input (with `SET TimeZone='America/New_York'` for TZ); an encode error raises `Invalid_argument`; a timestamp `value` as `Table` default is accepted by `create` and rejected by `Migration.add_column`.
- [ ] Implement per the spec's rendering table.
- [ ] Green as above, plus `./tools/run exec test/test_migration.exe`.

### Task 3: Subqueries — DONE (with Task 4)

- [ ] Tests: correlated `exists`; `in_` true / NULL (subquery with a NULL) / false; `scalar` over `aggregate count_star` correlated; `Null.scalar` over `max` of a nullable column; `Invalid_argument` for `in_` of two columns, `scalar` over a nullable column, `Null.scalar` over a non-null column, `in_` with incompatible codecs (BLOB vs VARCHAR).
- [ ] Implement nodes, rendering with continued aliases, the checks.
- [ ] Green.

### Task 4: Set operations — DONE

Refinement (both tasks): `in_`, `scalar` and set operations need the column
types, which `~row` hides, so `body` and `source` gained a column-list index
(`('list, 'row, 'k, 'm) body`, `('list, 'row, 'm) source`): column count and
types are now static, codecs (BLOB vs VARCHAR, custom) checked when built.
The type change touched both tasks at once, so their code came before their
tests; each runtime check was then mutation-tested (disabled → its test
fails). Rendering binds pieces with `let` in textual order (`^` evaluates
right to left), so aliases number left to right.

- [ ] Tests: `union`, `union_all`, `intersect`, `except_` results; each side keeps its own ORDER BY/LIMIT; nesting; a set operation as an `in_` subquery; `Invalid_argument` for different column counts and incompatible codecs.
- [ ] Implement.
- [ ] Green.

### Task 5: Compile fixtures

- [ ] `positive.ml` gains a join, a left join with `outer`, subqueries and a union.
- [ ] Fixtures: `outer_unlifted`, `outer_nullable`, `null_outer_non_null`, `scalar_many`, `in_type`, `union_rows`, `find_join`; expectations in `check_sql_types.sh`.
- [ ] `./tools/run runtest --force` exit 0.

### Task 6: Documentation

- [ ] README "Typed SQL" join/subquery example compiled and run; CHANGELOG; core-redesign roadmap rows 4a–4c; design note status and refinements; mli doc comments.
- [ ] `./tools/run build @all` clean; `./tools/run runtest --force` exit 0.
