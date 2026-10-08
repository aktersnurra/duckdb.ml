# Schema declarations (sub-project 3a)

Status: implemented, 2026-10-07; refined while prototyping (see
[Refinements](#refinements-found-while-prototyping)). Implements the first half of roadmap
row 3 of the [core redesign](core-redesign.md): constraints on table
declarations. Versioned migrations (3b) follow in their own design and build
on this one.

## Goal

A table declaration states the table's constraints. The library creates the
table from it, verifies an existing table against it, and types lookups by a
declared key as returning at most one row.

## Scope

In: PRIMARY KEY, UNIQUE, FOREIGN KEY, CHECK, DEFAULT; NOT NULL derived from
codecs; `Table.create`, `Table.verify`, `Table.lookup`.

Out: migrations (3b); self-referencing foreign keys (the table's value does
not exist while it is declared); foreign keys across schemas (DuckDB rejects
them: "Creating foreign keys across different schemas or catalogs is not
supported"); nullable key columns; `ON DELETE`/`ON UPDATE` actions (DuckDB
has none); comparing CHECK or DEFAULT expression text (DuckDB normalizes it).

## API

```ocaml
let users = Table.(declare "users"
  Columns.["id", int64; "email", string; "age", nullable int32]
  ~row:(fun id email age -> { id; email; age })
  ~constraints:(fun [id; email; age] -> Constraint.[
    primary_key Key.[id];
    unique Key.[email];
    default age Sql.(nullable (int32 18l));
    check Sql.(is_true Null.(column age >= nullable (int32 0l))) ]))

let posts = Table.(declare "posts"
  Columns.["id", int64; "owner", int64; "title", string]
  ~row:(fun id owner title -> (id, owner, title))
  ~constraints:(fun [id; owner; _] -> Constraint.[
    primary_key Key.[id];
    foreign_key Key.[owner] ~references:(users, fun [id; _; _] -> Key.[id]) ]))

let by_email = Table.lookup users (fun [_; email; _] -> Key.[email])
(* : (string * unit, user, Request.zero_or_one) Request.t *)

let setup (c @ local) =
  match Table.create c users with
  | Error e -> Error e
  | Ok () -> Table.create c posts

let check (c @ local) = Table.verify c users
```

### Columns and keys

- `~constraints` (optional) receives the columns as `('a, 'n) Table.column`
  binders, typed by the declaration's shape. `Sql.column c` makes a row
  expression of one, for `check`.
- NOT NULL is the codec's nullability: a non-null codec is a NOT NULL column.
  It is never declared separately.
- `Key.[…]` lists non-null columns only; a nullable column in a key is a
  compile error. DuckDB makes primary-key columns NOT NULL implicitly; this
  rule extends that to UNIQUE keys so that a lookup never compares NULL.
  A key's first index is the tuple of its column types, which becomes the
  lookup's parameter type.

### Constraints

| Constructor | Type and rule |
|---|---|
| `primary_key key` | At most one per declaration (`Invalid_argument` at `declare` otherwise) |
| `unique key` | Any number |
| `foreign_key cols ~references:(table, f)` | `f` binds the referenced table's columns and returns a key; its column types must equal `cols`' types (static). The referenced key must be that table's declared primary key or a declared unique key, in its declared column order (DuckDB matches the order), and the table must be in the same schema (`Invalid_argument` at `declare`) |
| `default col e` | `e : ('a, 'n, Sql.row) Sql.expr` (an aggregate does not type-check) at the column's own type and nullability, e.g. `Sql.(nullable (int32 18l))` for a nullable column. An `e` that mentions a column raises `Invalid_argument` at `declare` |
| `check e` | `e : (bool, non_null, row) Sql.expr`: a NULL result fails the check, so a nullable condition is written with `is_true` |
| `check_null e` | `e : (bool option, nullable, row) Sql.expr`: SQL's own rule, NULL passes |

Constraint expressions are typed SQL expressions over the declaration's own
columns; an expression from another scope raises `Invalid_argument`, as in
typed SQL.

DuckDB limitation, documented on `foreign_key`: a referenced row cannot be
updated at all, even in non-key columns, while it is referenced (DuckDB
implements updates on indexed tables as delete and insert). Probed:
`UPDATE users SET email = 'b' WHERE id = 1` fails with "Violates foreign key
constraint because key … is still referenced".

### Lookup

`Table.lookup : ('c, 's, 'row) t -> ('s Binders.t -> ('key, _) Key.t) ->
('key, 'row, Request.zero_or_one) Request.t` selects the declared columns
where each key column equals its parameter, decoded by the declared row. The
key must be the declared primary key or a declared unique key, compared as a
column set (`Invalid_argument` otherwise). `find_opt` still checks the row
count at run time, so a key the database does not enforce is reported as
`Row_count`, never as a wrong row.

### Create

`Table.create : _ session @ local -> (_, _, _) t -> (unit, Error.t) result`
runs one `CREATE TABLE`:

```sql
CREATE TABLE "main"."users" (
  "id" BIGINT NOT NULL, "email" VARCHAR NOT NULL,
  "age" INTEGER DEFAULT CAST(18 AS INTEGER),
  PRIMARY KEY ("id"), UNIQUE ("email"),
  CHECK ((("age" >= CAST(0 AS INTEGER)) IS TRUE)))
```

Column types are the codecs' base scalars. CHECK and DEFAULT expressions use
the typed SQL renderer without the `t0.` qualifier. No `IF NOT EXISTS`:
deciding whether to create belongs to migrations (3b). An existing table is
a native error.

### Verify

`Table.verify : _ session @ local -> (_, _, _) t -> (unit, Error.t) result`
is read-only. It reads `duckdb_columns()` and `duckdb_constraints()` in the
session's snapshot and returns the first difference, in this order:

1. The table exists; otherwise `Unknown_table { schema; name }` (new cause).
2. Columns, by the appender's existing rules: `Unknown_column`,
   `Missing_column` (an undeclared catalog column without a default), then
   `Type_mismatch`.
3. Nullability, exactly: non-null codec ⇔ NOT NULL.
4. PRIMARY KEY, UNIQUE, FOREIGN KEY: exactly the declared ones, both ways (a
   missing constraint and an undeclared extra one are differences). Key
   column sets compare order-insensitively; a foreign key compares the
   referenced table and its (column, referenced column) pairs, so a
   permuted reference is a difference.
5. CHECK, by column set only: one catalog CHECK per declared CHECK over the
   same columns; the expression is not compared (`CHECK (n < 0)` passes
   against a declared `n >= 0`).
6. DEFAULT, by presence: a column has a default exactly when one is declared.

A difference other than 1 and 2 is `Constraint_mismatch { constraint_kind;
expected; actual }` (new cause), with rendered descriptions, e.g.
`constraint_kind = "UNIQUE"`, `expected = "UNIQUE (email)"`,
`actual = "none"`; for nullability, `constraint_kind = "NOT NULL"` and
`expected = "\"age\" nullable"`.

Opening an appender keeps its current column check; full verification runs
only when called.

## Internals

- `lib/duckdb/table_constraint.ml` (new, no dependencies): the untyped,
  rendered form `Primary_key of string list | Unique of string list |
  Foreign_key of { columns; table; references } | Check of { sql; columns } |
  Default of { column; sql }`. `Request.Table_def` gains
  `constraints : Table_constraint.t list`, built once in `declare`.
- `lib/duckdb/table.ml`: the typed `Binders`, `Key` and `Constraint` (whose
  values still carry each column's binding scope and unrendered
  expressions), `declare` (binds the columns in a fresh scope, applies the
  callback, checks and renders), `create`, `verify`, `lookup`.
- `Sql` gains `type ('a, 'n) column` and `column` (a table column as a row
  expression), a `?qualifier` on rendering (`""` in a table's own clauses),
  and `mentioned` (the columns a node uses, for CHECK verification and the
  DEFAULT rule). Column nodes now carry the raw name and quote at rendering.
- `duckdb.mli`: `Sql` moves before `Table`, because constraints mention
  `Sql.expr`; `Sql.from` names its table type `Request.table`.
- `Table.lookup` builds its SQL and calls `Request.generated` with the key's
  `Fields`.
- `Error.cause` gains `Unknown_table` and `Constraint_mismatch`.

## Fixes from the independent review

- `verify` compared a foreign key's columns and referenced columns as two
  independent sets, so a permuted reference verified; it now compares the
  pairs, reading the catalog lists in order.
- `foreign_key` accepted a referenced key in another column order than the
  declared key, which DuckDB then rejected at CREATE; it now requires the
  declared order.
- `default` accepted grouped expressions (`count_star`); it now takes row
  expressions.

Known limitations, closed in a follow-up (2026-10-08):

- `verify` compares schema, table, column and referenced names as DuckDB
  resolves them, ignoring ASCII case (catalog lookups use `lower()`);
  non-ASCII identifiers that differ only in case are not unified.
- A unique, non-primary index over plain columns (`CREATE UNIQUE INDEX …`)
  satisfies a declared UNIQUE of the same columns; an expression index does
  not, and an undeclared index is no difference. Index columns come from
  `duckdb_indexes().expressions`, a VARCHAR that casts to `VARCHAR[]` of SQL
  text (`"Email Addr"` quoted, `n` bare, `(lower(e))` an expression).
- `foreign_key` compares the SQL types of the key and the referenced key
  (OCaml `string` stands for VARCHAR and BLOB) and raises `Invalid_argument`
  when they differ, instead of failing at `create`.

Still open: `duckdb_columns()` lists views too, so `verify` on a view checks
its columns and finds no constraints.

## Refinements found while prototyping

- The untyped constraint module is `Table_constraint`, not `Constraint`, so
  that the public `Table.Constraint` does not shadow it inside `table.ml`.
- `Table.column` is an alias of `Sql.column`: `Sql` is declared before
  `Table`, so the column type lives there.
- `verify` checks column types by preparing `SELECT <declared columns> …
  LIMIT 0` and validating it like any request, instead of mapping catalog
  type names: `duckdb_columns().data_type` spells some types differently
  (`TIMESTAMP WITH TIME ZONE`) from the engine type ids the library checks.
- `verify` reads the catalog with `match`, not `let*`: a `let*`
  continuation cannot capture the local session.
- Catalog column lists are read one name per row (`unnest`) and grouped by
  `constraint_index`, since the codecs decode no LIST type.
- Tests read the exact DDL from the error context of a second, failing
  `create` (`Query sql`), without exposing the renderer.
- Type errors in `~constraints` are often reported at a column codec in
  `Columns.[…]`, because the declaration is inferred as a whole; the
  messages still name both types.

## Verified DuckDB facts

Probed with the bundled DuckDB 1.5.5, 2026-10-07:

| Fact | Result |
|---|---|
| `duckdb_constraints()` | One row per constraint: `constraint_type` (`PRIMARY KEY`, `UNIQUE`, `FOREIGN KEY`, `CHECK`, `NOT NULL`), `constraint_column_names`, `referenced_table` (no schema), `referenced_column_names`, `expression` (CHECK, normalized: `<>` becomes `!=`) |
| A PRIMARY KEY column | Also listed as `NOT NULL`; `duckdb_columns().is_nullable = false` |
| `DEFAULT CAST(18 AS INTEGER)` | Stored verbatim in `column_default`; a literal `18` is stored as `18` |
| Foreign key to another schema | Rejected at CREATE |
| Update of a referenced row | Rejected, even for non-key columns |
| CHECK or FK violation | Native `Constraint Error` |

## Testing

`test/test_schema.ml` (TDD, plain assertions):

- DDL: exact `CREATE TABLE` text for each constraint kind, quoting, a
  nullable column's DEFAULT.
- Create then verify: `Ok` for each example declaration, including a
  non-`main` schema.
- Verify differences, each against a table created with hand-written DDL:
  missing table; type; nullability both ways; missing and extra PRIMARY KEY,
  UNIQUE, FOREIGN KEY; foreign key to another column; missing CHECK; missing
  and extra DEFAULT. Each asserts the exact cause.
- Enforcement: duplicate key, failing CHECK and dangling foreign key are
  native errors; an omitted column takes its default.
- `lookup`: `None`, `Some`, and its rendered SQL.
- `Invalid_argument` at `declare`/`lookup`: two primary keys, an undeclared
  lookup key, a foreign key to an undeclared key or another schema, a column
  inside a default.

`test/schema_compile/` with `check_schema_types.sh` (the
`check_sql_types.sh` pattern), a `positive.ml` with the examples above, and
rejected fixtures: a nullable column in a key; a foreign key whose key types
differ; a default of the wrong type and of the wrong nullability; `check` on
a nullable condition; `find` on a lookup; a constraints binder of the wrong
arity.

Acceptance: `./tools/run build @all` and `./tools/run runtest --force` pass;
the examples gain `Table.create` in place of hand-written `CREATE TABLE`
where they declare the table anyway.

Documentation: README (constraints in the example, a short "Schema"
section), CHANGELOG, the core-redesign roadmap (3a done), and this note's
status.
