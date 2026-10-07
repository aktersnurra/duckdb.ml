# Typed SQL (sub-project 2)

Status: implemented, 2026-10-07; refined while prototyping (see
[Refinements](#refinements-found-while-prototyping)). Implements roadmap row 2 of the
[core redesign](core-redesign.md) and replaces its
[Appendix A](core-redesign.md#appendix-a-typed-sql-end-state-sketch) sketch
where the two differ (listed under [Divergences](#divergences-from-appendix-a)).

## Goal

Build single-table `SELECT` queries from typed expressions instead of SQL
strings. The type checker rejects type errors, NULL mishandling, ungrouped
columns in grouped contexts and wrong parameter types. A built query is an
ordinary `('params, 'row, 'multiplicity) Request.t`: execution, the statement
cache, validation and the adapters are unchanged.

## Scope

In: one table per query; `select`, `aggregate` (aggregates without GROUP BY)
and `group_by`; `where`, `having`, `order_by`, `limit`, `offset`; typed
parameters; comparisons, arithmetic, booleans, `is_null`, `coalesce`, `like`;
aggregates `count_star`, `count`, `sum`, `min`, `max`, `avg`.

Out (later): joins, subqueries, `INSERT`/`UPDATE`/`DELETE` builders, literals
of custom-codec types, window functions, `DISTINCT`, set operations. Static
detection of scope leaks (an expression used outside its query) stays out.
Unlike Appendix A assumed, DuckDB would not always reject one: every query
aliases its table `t0` and numbers parameters from `$1`, so a leaked column
or parameter could bind the other query's namesake. Column and parameter
nodes therefore carry the scope (one `from` or `query` call) that bound
them, and building a query that contains a foreign one raises
`Invalid_argument`, a programming error like an out-of-bounds `Array.get`.

The layer ships inside `duckdb` as `Duckdb.Sql`. It needs library-internal
access to codec plans and request construction; a separate package would make
those public.

## API

```ocaml
module S = D.Sql

let users = D.Table.(declare "users"
  Columns.["id", int64; "name", string; "age", nullable int32]
  ~row:(fun id name age -> { id; name; age }))

let adults = S.(
  query Params.[int32] (fun [min_age] ->
    from users (fun [id; name; age] ->
      select Exprs.[id; name] ~row:(fun id name -> (id, name))
        ~where:Expr.(is_true Null.(age >= nullable (param min_age)))
        ~order_by:[asc id] ~limit:100)))
(* : (int32 * unit, int64 * string, Request.many) Request.t *)

let by_name = S.(
  query Params.[] (fun [] ->
    from users (fun [_; name; age] ->
      group_by Keys.[name] (fun [name] ->
        select Exprs.[name; count_star; Null.max age]
          ~row:(fun n c m -> (n, c, m))
          ~having:Expr.(count_star > int64 1L)))))
(* : (unit, string * int64 * int32 option, Request.many) Request.t *)

let total = S.(
  query Params.[] (fun [] ->
    from users (fun [id; _; _] -> aggregate Exprs.[count id] ~row:Fn.id)))
(* : (unit, int64, Request.one) Request.t *)
```

### Query structure

- `query params f` binds parameters and returns the `Request.t`.
- `from table f` binds the table's columns as `row` expressions through a GADT
  list pattern typed by the table's shape.
- Inside `from`, exactly one of:
  - `select exprs ~row ?where ?order_by ?limit ?offset` → `many`;
  - `aggregate exprs ~row ?where` → `one` (aggregates, no GROUP BY);
  - `group_by keys f` → `f` receives the keys rebound as `grouped` and
    returns `select exprs ~row ?where ?having ?order_by ?limit ?offset` over
    grouped expressions → `many`. Its `~where` takes row expressions (the
    table binders stay in scope) and filters rows before grouping.
- Clauses are optional labelled arguments, not a builder state machine.
  Clause order cannot be wrong and needs no typestate.
- Multiplicity comes from structure, by explicit names: `select` is `many`,
  `aggregate` is `one`.

### Expressions

`('a, 'n, +'k) Expr.t`:

- `'a`: the OCaml value type a selected expression decodes to, as in `Codec`
  (`int32 option` for a nullable `int32`).
- `'n`: `Codec.non_null` or `Codec.nullable`.
- `'k`: `row` or `grouped`.

Nullability (three-valued logic in the types):

| Function | Type (`'k` uniform) |
|---|---|
| `Expr.(=) (<>) (<) (<=) (>) (>=)` | `('a, non_null) → ('a, non_null) → (bool, non_null)` |
| `Expr.Null.(=) … (>=)` | `('a option, nullable) → ('a option, nullable) → (bool option, nullable)` |
| `nullable` | `('a, non_null) → ('a option, nullable)` |
| `coalesce e ~default` | `('a option, nullable) → ('a, non_null) → ('a, non_null)` |
| `is_null` | `('a option, nullable) → (bool, non_null)` |
| `is_true` | `(bool option, nullable) → (bool, non_null)` (SQL `IS TRUE`) |
| `(&&) (||) not` | on `(bool, non_null)`; `Null.(&&) (||) not` on `(bool option, nullable)` |
| `like` | `(string, non_null) → (string, non_null) → (bool, non_null)` |

`~where` and `~having` take `(bool, non_null, _)`. A nullable condition is
written `is_true …`, which is what SQL `WHERE` does with NULL.

Comparisons are polymorphic in `'a`. On a custom codec they compare the base
values. Arithmetic is per type, as in OCaml: `+ - * /` on `int64`,
`+. -. *. /.` on `float`, and submodules `I64`, `I32`, `I16`, `I8`, `F64`,
`F32` (signatures `INTEGRAL` and `FRACTIONAL`) with `+ - * /`, `sum` and
`avg`. Results are cast back to the operand type. Integer `/` truncates
(DuckDB `//`) and returns a nullable result, because DuckDB yields NULL for
a zero divisor; float `/` is IEEE (a zero divisor gives an infinity or NaN).
`Null` mirrors the operators for nullable operands.

Literals exist for base scalars only (`bool`, `int8` … `int64`, `float32`,
`float64`, `string`) and render as typed SQL (`CAST(1 AS BIGINT)`, non-finite floats as `CAST('inf' AS DOUBLE)`, escaped
string literals). A value of a custom-codec type enters a query as a
parameter, because encoding can fail.

### Aggregates

| Function | Type |
|---|---|
| `count_star` | `(int64, non_null, grouped)` |
| `count e` | `(_, _, row) → (int64, non_null, grouped)` |
| `sum`, `min`, `max` | `('a, non_null, row) → ('a option, nullable, grouped)` |
| `Null.sum`, `Null.min`, `Null.max` | `('a option, nullable, row) → ('a option, nullable, grouped)` |
| `avg`, `Null.avg` | numeric `row` → `(float option, nullable, grouped)` |

`sum`, `min`, `max` and `avg` are nullable because an empty input yields
NULL. `sum` and `avg` exist for the numeric types only (per-type, like
arithmetic). `sum` renders as `CAST(sum(x) AS <input type>)` because DuckDB
widens integer sums to HUGEINT; an overflow is a runtime native error.

### Parameters

`Params.[int32; nullable string]` binds `('a, 'n) Param.t` values. `param p`
is polymorphic in `'k`, so one parameter serves both `row` and `grouped`
contexts. (A lambda-bound expression would be monomorphic.) Parameters render
as `CAST($n AS <type>)`, numbered by binding position; a parameter may be used
more than once. A declared parameter that the query never uses fails at first
prepare with `Parameter_count` (DuckDB counts only the parameters it sees).

### Ordering

`~order_by` takes a list of `asc e` / `desc e` with `e` of the select's kind.
`~limit` and `~offset` take `int`.

## Types and internals

**Module.** `lib/duckdb/sql.ml` (private, no `.mli`; it declares the
`INTEGRAL`/`FRACTIONAL` module types itself), re-exported and constrained by
`Duckdb.Sql` in `duckdb.mli`.

**Representation.** `Expr.t` is abstract. Its implementation is an untyped
node tree plus the `Codec` used when the expression is selected. Comparisons
carry the `bool` codec; arithmetic, `min`, `max` and `coalesce` keep the
operand's codec; `nullable` wraps it. The typing discipline lives in the
signatures and is pinned by compile-failure fixtures. A typed GADT AST was
rejected: it cannot be covariant in `'k`, needs annotations throughout, about
doubles the code, and gives users nothing since the output is SQL text.

**Lists.** Hand-written GADT lists in `Sql`:

- `Params`: indexed by the `'params` tuple (for `Args`) and a shape that
  keeps `'n` per element (for `Param.t`).
- `Binders`: `('shape, 'k) t`; `(::) : ('a, 'n, 'k) Expr.t * ('s, 'k) t ->
  (('a, 'n) slot * 's, 'k) t`. Binder patterns are exhaustive.
- `Keys`: `group_by` keys, row expressions, indexed by shape.
- `Exprs`: the select list, `('list, 'fn, 'result, 'k) t` with one `'k` for
  all elements: the context index Appendix A deferred.

**Table shape.** `Table.Columns` gains a fourth index `'shape`
(`('a, 'n) slot * …`), and `Table.t` / `Request.table` become
`('columns, 'shape, 'row) t`. `Spine` keeps serving `Fields` unchanged.

**Compilation.** `query` renders

```
SELECT <exprs> FROM "<schema>"."<table>" AS t0
[WHERE …] [GROUP BY …] [HAVING …] [ORDER BY …] [LIMIT n] [OFFSET n]
```

Columns render as `t0."name"` with the existing `quote`. It then builds the
`Request.t` through a new internal constructor, `Request.generated`, from the SQL, the `Fields` of
`Params`, and the `Fields` and row function of `Exprs` (a hand-written
re-indexing). Generated requests are validated at first prepare like any
other: column count and types against DuckDB's metadata.

The typed appender keeps two indices; it holds its table with the shape
existential.

**Errors.** No new constructors. A wrong table or column name is reported
at first use as `Prepare` or `Type_mismatch`, as for hand-written SQL. A
leaked expression raises `Invalid_argument` when the query is built (see
Scope). Operators on a custom codec over an unsuitable base type, or on a
BLOB (OCaml `string`), type-check and fail at first prepare. Overflow in a `sum` cast is a native error during execution.

## Verified compiler facts

Probed with the repository's OxCaml (scratch files, 2026-10-07):

| Fact | Result |
|---|---|
| `fun [id; name; age] -> …` over a GADT list indexed by shape | Exhaustive, no warning (`-w +A-42-45-70`) |
| Comparing `id : (int64, non_null, _)` with `age : (int32 option, nullable, _)` | Rejected |
| `param : ('a, 'n) param -> ('a, 'n, 'k) expr` used in `row` and `grouped` contexts within one query | Accepted |
| A `row` column in a `select` inside `group_by` | Rejected (`row` is not compatible with `grouped`) |
| A select list mixing `row` and `grouped` | Rejected |
| `type ('a, 'n, +'k) expr = { sql : string }` with abstract kinds | Accepted |

| `$n` parameters through the existing bind path | A repeated `$1` counts once; a declared, unused parameter is `Parameter_count` |
| DuckDB `1 // 0`, `CAST(1 AS DOUBLE) / 0` | NULL; `inf` |
| DuckDB `typeof(sum(INTEGER))`, `avg(FLOAT)`, `TINYINT + TINYINT` | HUGEINT; DOUBLE; TINYINT (overflow is an error) |
| Binder patterns from another library under Dune's default flags | Accepted; with `-w @a` they raise warnings 40/42 |

## Divergences from Appendix A

1. **Nullability.** Appendix A had operators with equal `'n` on both sides.
   That cannot type a comparison's result (`bool` or `bool option` depending
   on `'n`) without a type-level function. This design has two operator sets
   (`Expr` and `Expr.Null`) and explicit `nullable`, `coalesce`, `is_null`,
   `is_true`.
2. **Parameters** are bound as `Param.t` and lifted with `param`, instead of
   variance on `'k` or a `const` lift.
3. **Lists.** `Exprs`, `Keys`, `Binders` and `Params` are hand-written instead
   of `Spine` instances (requirement 4 relaxed). `Table` gains a shape index.
4. **Shape of the builder.** Clauses are labelled arguments of `select`,
   `aggregate` and `group_by`, not a `|>` pipeline; `aggregate` names the
   `one` case.

## Fixes from the independent review

- `aggregate` accepted a select list without any aggregate (only literals or
  parameters), typed `one` but returning a row per table row; building such
  a query now raises `Invalid_argument`.
- Operators accepted operands whose OCaml types agree but whose codecs do
  not: a string literal against a BLOB column (DuckDB casts the literal to
  BLOB and decodes `\xHH` escapes, even through `CAST(… AS VARCHAR)`), or a
  plain literal against a custom codec's column (compared unencoded).
  Comparisons, arithmetic, `like` and `coalesce` now require both operands
  to share a codec: the same base scalar, and for custom codecs the same
  codec value; otherwise building the query raises `Invalid_argument`. A
  custom-codec value enters as a parameter declared with that codec.
- The claim that `~having` outside `group_by` is always rejected at prepare
  was wrong: DuckDB accepts it when the select list holds only literals and
  parameters (one group, 0 or 1 rows; `many` admits that).
- Documented: a `string` literal containing NUL fails with `Embedded_nul`;
  an empty select list and a negative `~limit`/`~offset` fail at prepare.

## Refinements found while prototyping

- Arithmetic submodules are `I64` … `F32`, not `Int64` …: inside a local
  open `Sql.( … )`, `Int64` would shadow the standard module.
- Integer `/` returns a nullable result (DuckDB yields NULL on a zero divisor).
- `group_by` has no `?where`: the grouped `select` takes `~where` over row
  expressions. `~having` on a `select` outside `group_by` type-checks and is
  rejected by DuckDB at first prepare.
- Parameters render with a cast so that their type never depends on
  DuckDB's inference.
- A `select` of grouped expressions directly under `from` is rejected; that
  is `aggregate`.

## Testing and acceptance

**`test/test_sql.ml`** (TDD, plain assertions):

- Rendering: exact SQL from `Request.query` for each construct: quoting
  (including names containing `"`), `$n` numbering, typed literals and string
  escaping, `CAST(sum…)`, clause order, `group_by`/`having`, `limit`/`offset`.
- Execution on an in-memory database: each operator family and aggregate;
  three-valued logic (`Null.(>=)` with a NULL operand gives `None`, `is_true`
  filters it); `coalesce`; `like`; `avg` of no rows gives `None`; `aggregate`
  returns one row through `Session.find`; a column or parameter smuggled into
  another query raises `Invalid_argument` when that query is built.
- Interop: a generated request runs twice through the statement cache, and
  once through each of the async and Eio adapters. A table declaration that
  disagrees with the catalog reports the same validation error as
  `Table.select`.

**`test/sql_compile/`** with `check_sql_types.sh` (the `expect name
needles…` pattern of `check_request_types.sh`), a `positive.ml` holding the
examples above, and one rejected fixture each for:

1. a non-null operator on a nullable column;
2. a `Null` operator on a non-null column;
3. `~where` with a nullable bool;
4. a row column in a grouped `select`, and in `~having`;
5. an aggregate in `~where`;
6. mixed kinds in one `Exprs` list;
7. comparing different types;
8. `+` on `string`, and `+` on `float`;
9. `find` on a `select` (`many`);
10. wrong arity or parameter type in `Args` for a generated request, and a
    parameter compared at the wrong type;
11. a binder pattern whose arity differs from the table;
12. a grouped `select` directly under `from`.

Existing tests and `request_compile` fixtures migrate to the three-index
`Table.t` (mechanical).

**Acceptance:** `./tools/run build @all` and `./tools/run runtest --force`
pass; `examples/sql.exe` runs. No performance target: generated requests
decode through the same path as hand-written ones. A one-off measurement
(not a harness path; the harness has no table) confirms it: folding 1M rows
of `t(a BIGINT, b BIGINT)` (`b` NULL every tenth row), `threads=1`,
`taskset -c 0`, median of 10 after 2 warmups, two interleaved rounds: the
generated `select Exprs.[a; b]` took 39.5 and 40.7 ms, the hand-written
`SELECT a, b FROM t` 41.8 and 41.0 ms.

**Documentation:** `docs/architecture.md` drops the "no SQL DSL" non-goal;
the L3 row of `typed-requests.md` is updated; the README gains a short
section; CHANGELOG entry.
