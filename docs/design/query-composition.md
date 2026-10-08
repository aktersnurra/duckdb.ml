# Query composition (sub-project 4a)

Status: implemented, 2026-10-08; refined while implementing (see
[Refinements](#refinements-found-while-implementing)). Extends [typed SQL](typed-sql.md) (roadmap row
2 of the [core redesign](core-redesign.md)); first of 4a (query composition),
4b (DML builders), 4c (window functions).

## Goal

Queries over several tables and nested queries, with the same static
guarantees as single-table queries: a column that a LEFT JOIN may leave NULL
decodes as an option, and every misuse the types cannot express is rejected
when the query is built.

## Scope

In: INNER, LEFT and CROSS joins, nested to any depth; `DISTINCT`; literals of
any codec (`value`); correlated and uncorrelated `EXISTS`, `IN` and scalar
subqueries; `UNION`, `UNION ALL`, `INTERSECT`, `EXCEPT`.

Out: RIGHT JOIN (a LEFT JOIN written the other way round); FULL JOIN (both
sides lifted); subqueries in FROM (derived tables); ORDER BY or LIMIT over a
set operation's combined result; `NOT IN` (three-valued pitfalls; `not`
over `is_true (in_ …)` expresses the intended filter); lateral joins.

## API

### Joins

```ocaml
from users (fun [uid; name; _] ->
  join posts ~on:(fun [_; owner; _] -> owner = uid) (fun [pid; _; title] ->
    left_join comments ~on:(fun [_; post; _] -> post = pid) (fun [_; _; body] ->
      select Exprs.[name; title; Null.outer body] ~distinct:true
        ~row:(fun n t b -> (n, t, b)))))
```

```ocaml
val join : (_, 'shape, _) Request.table -> on:(('shape, row) Binders.t -> (bool, Codec.non_null, row) expr) ->
  (('shape, row) Binders.t -> ('row, row, 'm) body) -> ('row, row, Request.many) body
val left_join : (_, 'shape, _) Request.table -> on:(('shape, row) Binders.t -> (bool, Codec.non_null, row) expr) ->
  ('shape Outer.t -> ('row, row, 'm) body) -> ('row, row, Request.many) body
val cross_join : (_, 'shape, _) Request.table -> (('shape, row) Binders.t -> ('row, row, 'm) body) ->
  ('row, row, Request.many) body

type ('a, 'n) outer
module Outer : sig
  type 'shape t =
    | [] : unit t
    | (::) : ('a, 'n) outer * 'shape t -> (('a, 'n) Codec.slot * 'shape) t
end
val outer : ('a, Codec.non_null) outer -> ('a option, Codec.nullable, row) expr
module Null : sig … val outer : ('a option, Codec.nullable) outer -> ('a option, Codec.nullable, row) expr end
```

- `join` and `cross_join` bind row expressions, as `from` does.
- `left_join`'s `~on` binds the right table's columns as row expressions (ON
  is evaluated before NULL extension); its body binds them as `outer`
  values, usable only after lifting: `outer` for a non-null column,
  `Null.outer` for a nullable one (the existing two-operator-set rule). A
  missing right row thus decodes as `None`, never as a non-null value.
- A join's body may use the binders of every enclosing `from` and join.
- A join's result has multiplicity `many`: joined rows multiply. An
  `aggregate` body inside a join still yields one row, but the join body's
  type is `many`, so `find` is rejected statically.
- `select`, `aggregate` and `group_by` inside joins work as in single-table
  queries; `group_by` keys may come from any joined table.

### DISTINCT

`select ?distinct:bool …` (default false) renders `SELECT DISTINCT`.

### Literals of any codec

```ocaml
val value : ('a, Codec.non_null) Codec.t -> 'a -> ('a, Codec.non_null, 'k) expr
```

Encodes the value with the codec when the query is built and renders the base
value by its scalar (see [Rendering `value`](#rendering-value)): numbers,
booleans and strings as the existing literals, BLOB with every byte
escaped, dates and timestamps through epoch functions. The result carries
the codec, so `value cents 2L = price` passes the operand codec check that a
plain `int64 2L` fails. An encode error raises `Invalid_argument`. As a
table DEFAULT, a numeric, boolean, string or BLOB `value` is a constant
(usable by `Migration.add_column`); a date or timestamp `value` is an
expression, which `create` accepts and `add_column` rejects.

### Subqueries

```ocaml
from users (fun [uid; name; _] ->
  select Exprs.[name; scalar (from posts (fun [_; owner; _] ->
                         aggregate Exprs.[count_star] ~row:Fn.id ~where:(owner = uid)))]
    ~where:(exists (from posts (fun [_; owner; _] ->
                      select Exprs.[owner] ~row:Fn.id ~where:(owner = uid))))
    ~row:(fun n c -> (n, c)))
```

```ocaml
val exists : (_, _) source -> (bool, Codec.non_null, 'k) expr
val in_ : ('a, _, 'k) expr -> ('a, _) source -> (bool option, Codec.nullable, 'k) expr
val scalar : ('a, Request.one) source -> ('a option, Codec.nullable, 'k) expr
module Null : sig … val scalar : ('a option, Request.one) source -> ('a option, Codec.nullable, 'k) expr end
```

- A subquery is an ordinary `from …` source. Its callbacks may use the
  binders of enclosing queries (correlation) and the enclosing `query`'s
  parameters.
- `in_` is nullable: DuckDB yields NULL, not false, when no row matches and
  the subquery holds a NULL. Filter with `is_true (in_ …)`.
- `scalar` accepts only `one`-row sources (`aggregate`): DuckDB fails at run
  time when a scalar subquery returns several rows.
- Built-time checks (`Invalid_argument`): `in_` and `scalar` sources have
  exactly one column, with a codec compatible with the other operand (for
  `in_`); `scalar` requires a non-null column and `Null.scalar` a nullable
  one, so the decoded type is exactly `'a option`.

### Set operations

```ocaml
val union : ('row, _) source -> ('row, _) source -> ('row, Request.many) source
val union_all : ('row, _) source -> ('row, _) source -> ('row, Request.many) source
val intersect : ('row, _) source -> ('row, _) source -> ('row, Request.many) source
val except_ : ('row, _) source -> ('row, _) source -> ('row, Request.many) source
```

Rows decode with the left source's row function. Both sides must have the
same column count and pairwise compatible codecs, or building raises
`Invalid_argument` (DuckDB silently casts BIGINT ∪ VARCHAR to VARCHAR). Each
side renders in parentheses and keeps its own ORDER BY and LIMIT. Set
operations nest and may be used as subqueries.

## Internals

- `lib/duckdb/sql.ml` only.
- A body records its joins: `joins : { kind; target; scope; on : node option } list`,
  outermost first. `join` and friends wrap the inner body, prepending their
  join; multiplicity becomes `many`.
- `source` becomes a tree: `Select of { target; scope; body } | Set of { op;
  left; right }`, keeping the row decoder and column codecs of its left-most
  select.
- Aliases are assigned at render time, `t0`, `t1`, … in order of
  appearance, continuing into subqueries, so the SQL text does not depend on
  scope ids: building one query twice yields the same text and statement
  cache entry.
- `render` takes a scope → alias map instead of the fixed `t0.` qualifier. A
  column whose scope is in the map renders `<alias>."<name>"`; any other
  scope is a foreign expression, as now. Table CHECK and DEFAULT rendering
  keeps the empty qualifier.
- New nodes: `Exists of source`, `In_subquery of node * source`,
  `Scalar of source`. `mentioned` and `aggregates` recurse into them where
  meaningful (`aggregates` does not count an aggregate inside a subquery as
  one of the outer select list).
- Parameters keep the scope of the outer `query`, wherever they appear.

### Rendering `value`

| Base scalar | SQL |
|---|---|
| BOOLEAN | `TRUE`/`FALSE` |
| TINYINT … BIGINT | `CAST(<n> AS <type>)` |
| FLOAT, DOUBLE | existing float literals |
| VARCHAR | quoted string |
| BLOB | `CAST('\xNN…' AS BLOB)`, every byte escaped |
| DATE | `CAST(DATE '1970-01-01' + CAST(<days> AS INTEGER) AS DATE)` |
| TIMESTAMP | `make_timestamp(CAST(<µs> AS BIGINT))` |
| TIMESTAMP_MS | `CAST(epoch_ms(CAST(<ms> AS BIGINT)) AS TIMESTAMP_MS)` |
| TIMESTAMP_S | `CAST(make_timestamp(CAST(<s> AS BIGINT) * 1000000) AS TIMESTAMP_S)` (beyond ±9.2e12 s: a native overflow error at execution) |
| TIMESTAMP_NS | `make_timestamp_ns(CAST(<ns> AS BIGINT))` |
| TIMESTAMPTZ | `(to_timestamp(0) + to_microseconds(CAST(<µs> AS BIGINT)))` |

Each spelling round-trips its epoch value exactly under a non-UTC session
time zone (`America/New_York`). Casting a TIMESTAMP to TIMESTAMPTZ does not:
it reads the timestamp as local time.

## Refinements found while implementing

- `body` and `source` are indexed by their column value types:
  `('list, 'row, 'k, 'm) body`, `('list, 'row, 'm) source`. A `~row`
  function can map a column to any type, so the row type alone cannot type
  `in_`'s or `scalar`'s column: decoding a scalar subquery through a
  mapped row type would be unsound. With the index, `in_` takes
  `('a * unit, _, _) source` and `scalar` `('a * unit, _, one) source`
  (one column of the operand's type, by type), and set operations require
  the same `'list` on both sides; only codec identity (BLOB vs VARCHAR,
  custom codecs) and `scalar`'s nullability remain checks when built.
- `in_` of a non-null operand against a nullable column is a type error
  (`'a` against `'a option`); lift the operand with `nullable`.
- Rendering binds each piece with `let` in textual order: `^` evaluates its
  right operand first, which numbered subquery aliases right to left.
- The time-zone round trip is its own executable, run by dune with
  `TZ=America/New_York`: the library refuses `SET`, and DuckDB's ICU reads
  `TZ` once at startup (`putenv` in the process has no effect).
- A BLOB `value` has a quoted constant (`'\xNN…'`), so it is usable as an
  `add_column` default; only dates and timestamps are expressions.

## Errors

No new causes. Misuse raises `Invalid_argument` when the query is built:
incompatible codecs; a wrong column count for `in_`, `scalar` or a set
operation; the wrong nullability for `scalar`/`Null.scalar`; an encode error
in `value`; a binder used outside its query or join.

## Verified DuckDB facts

Probed with DuckDB 1.5.5, 2026-10-08:

| Fact | Result |
|---|---|
| `x IN (subquery)` with no match and a NULL in the subquery | NULL |
| Correlated `EXISTS`, scalar `max` subquery | Work; empty scalar → NULL |
| Scalar subquery returning several rows | "More than one row returned by a subquery used as an expression" |
| LEFT JOIN without a match | Right columns NULL |
| `UNION ALL` of BIGINT and VARCHAR | Accepted, cast to VARCHAR |
| Parenthesized sides with their own ORDER BY / LIMIT in UNION ALL | Kept |
| `SELECT DISTINCT a … ORDER BY b` (b not selected) | Accepted |
| INTERSECT, EXCEPT | Set semantics |
| `make_timestamp(µs)`, `epoch_ms(ms)`, `make_timestamp_ns(ns)`, `to_timestamp(0) + to_microseconds(µs)` | Exact round trip of `epoch_us`/`epoch_ms`/`epoch_ns`, any time zone |
| `CAST(<TIMESTAMP> AS TIMESTAMPTZ)` under `America/New_York` | Shifted by the zone offset |
| `CAST(<BIGINT> AS TIMESTAMP)` | "Unimplemented type for cast" |

## Testing

`test/test_sql.ml`: rendered SQL and results against DuckDB for inner, left
(missing right row → `None`) and cross joins; three nested joins; `distinct`;
`value` for a custom codec, a date, a timestamp and a blob; correlated
`exists`, `in_` with a NULL, `scalar` over an aggregate; the four set
operations; each `Invalid_argument`; one query built twice gives the same
SQL text.

`test/sql_compile/` fixtures rejected: an `outer` binder used unlifted;
`outer` on a nullable column and `Null.outer` on a non-null one; `scalar` of
a `many` source; `in_` of a mismatched type; a set operation of different
row types; `find` on a join.

Acceptance: `./tools/run build @all`, `./tools/run runtest --force` pass.

Documentation: README "Typed SQL", CHANGELOG, core-redesign roadmap (rows
4a–4c), `PLAN_FEAT_query-composition.md`, this note's status.
