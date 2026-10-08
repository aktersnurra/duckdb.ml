# Named binders Implementation Plan

**Goal:** Named column handles for `Sql` callbacks (`u.%(Users.name)`), per
[docs/design/named-binders.md](docs/design/named-binders.md).

**Architecture:** `Sql.field` is a GADT index into a table shape;
`.%()`/`.%?()` project `Binders.t`/`Outer.t`; `Table.fields` builds the
handles from the declaration's `Columns`.

**Tech:** OxCaml via `./tools/run`; jj bookmark `feat/named-binders`.

### Task 1: Compile fixtures (failing first)

- Create `test/named_compile/{positive.ml, other_shape.ml.fail,
  outer_index.ml.fail, outer_unlifted.ml.fail, wrong_length.ml.fail}` and
  `test/check_named_types.sh` (copy of `check_dml_types.sh`'s harness);
  add the rule to `test/dune`.
- Run `./tools/run build @test/runtest` → fails: `Named`, `fields`,
  `.%()` unbound.

### Task 2: Interface and implementation

- `lib/duckdb/duckdb.mli`: `field`, `Named`, `( .%() )`, `( .%?() )` in
  `Sql` after `Outer`/`outer`; `fields` in `Table` after `declare`.
- `lib/duckdb/sql.ml`: the GADT, `Named`, both projections.
- `lib/duckdb/table.ml`: `fields` over `Columns`.
- Fixtures pass.

### Task 3: Runtime tests

- `test/test_sql.ml`: named forms of from / join / left_join, and in
  `test/test_sql_dml.ml` update and `insert … update_on`; each asserts
  the positional form's SQL text and rows. Write them, see them fail to
  compile before Task 2 lands (or, if Task 2 is in, assert equality).

### Task 4: Docs

- README typed SQL: a named example; CHANGELOG `## Unreleased`; design
  note status "implemented".
- `./tools/run build @all && ./tools/run runtest --force` exit 0.
