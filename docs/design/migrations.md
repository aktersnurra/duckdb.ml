# Versioned migrations (sub-project 3b)

Status: implemented, 2026-10-07; refined while prototyping (see
[Refinements](#refinements-found-while-prototyping)). Completes roadmap row 3 of the
[core redesign](core-redesign.md), building on
[schema declarations](schema.md).

## Goal

Bring a database from any earlier version to the current one by applying an
ordered list of numbered steps, each atomically, recording what was applied,
and rejecting a history that no longer matches the code.

## Scope

In: ordered numbered steps; typed steps derived from table declarations
(`create`, `add_column`); name-based `drop_table`, `drop_column`,
`rename_table`, `rename_column`; raw `sql`; OCaml `run` steps; a bookkeeping
table; history checks; optional verification of declarations afterwards.

Out: down migrations (forward only: a correction is a new step); generating
steps by diffing declarations against the catalog (renames are ambiguous and
DuckDB cannot add constraints to existing tables); a type-level schema
evolved by the steps; running migrations through the Async/Eio adapters
(run them on a synchronous connection at startup, before opening a pool).

## API

```ocaml
module M = D.Migration

(* Each declaration-based step takes the declaration as it was when the step
   was written: users_v1 has no "nick"; users_v2 = users_v1 plus "nick". *)
let migrations = M.[
  step 1 "create users" (create users_v1);
  step 2 "create posts" (create posts);
  step 3 "add nickname" (add_column users_v2 (fun [_; _; _; nick] -> Column nick));
  step 4 "backfill nicknames" (run (fun tx -> R.Session.exec tx backfill D.Args.[]));
  step 5 "drop legacy" (drop_table "legacy_users");
  step 6 "rename column" (rename_column ~table:"posts" "body" ~to_:"text");
  step 7 "index" (sql "CREATE INDEX posts_owner ON posts(owner)") ]

let start (c @ local) = M.apply c migrations ~verify:M.[ table users_v2; table posts ]
(* : (int list, Error.t) result, the versions this call applied *)
```

### Steps

| Step | SQL |
|---|---|
| `create table` | The declaration's `CREATE TABLE` (as `Table.create`) |
| `add_column table pick` | `ALTER TABLE t ADD COLUMN "c" T [DEFAULT d]`; for a non-null column also `ALTER TABLE t ALTER COLUMN "c" SET NOT NULL` |
| `drop_table ?schema name` | `DROP TABLE "s"."name"` |
| `drop_column ?schema ~table name` | `ALTER TABLE "s"."table" DROP COLUMN "name"` |
| `rename_table ?schema from ~to_` | `ALTER TABLE "s"."from" RENAME TO "to_"` |
| `rename_column ?schema ~table from ~to_` | `ALTER TABLE "s"."table" RENAME COLUMN "from" TO "to_"` |
| `sql s` | `s` as written |
| `run f` | `f : [ `Transaction ] session @ local -> (unit, Error.t) result` |

`?schema` defaults to `main`; identifiers are quoted.

`add_column` picks one column of the declaration through binders (as
`Table.lookup` does); `Column` hides its type. The column takes the
declaration's type, nullability and default. DuckDB rejects constraints in
`ADD COLUMN`, so a non-null column is added with its default and then set NOT
NULL. DuckDB's statement extraction also splits `ADD COLUMN … DEFAULT
<expression>` into several statements for any default other than a plain
constant (`CAST(…)`, `TRUE`, functions, operators), so the default is
written as a quoted constant cast to the column's type (`DEFAULT '5'`), and
a default that is not a literal raises `Invalid_argument`; without a declared default this succeeds only on an empty table (a
native error otherwise, rolling the step back). A column that is part of a
declared PRIMARY KEY, UNIQUE, CHECK or FOREIGN KEY raises `Invalid_argument`
when the step is built: DuckDB cannot add those to an existing table, so such
a change is a new table (create, copy with `sql`, drop, rename).

`step version name kind`. `M.[…]` is an ordinary list. Versions must be
strictly increasing; a duplicate or decreasing version raises
`Invalid_argument` when `apply` receives the list.

### Apply

`apply : [ `Connection ] session @ local -> ?verify:table list -> step list ->
(int list, Error.t) result`:

1. Creates the bookkeeping table if `duckdb_tables()` lacks it:
   `"main"."duckdb_ml_migrations"(version BIGINT PRIMARY KEY, name VARCHAR
   NOT NULL, checksum VARCHAR NOT NULL, applied_at TIMESTAMPTZ NOT NULL
   DEFAULT now())` (`CREATE TABLE IF NOT EXISTS`).
2. Reads the applied rows by version and checks that they are exactly a
   prefix of the list: same version, name and checksum at each position. The
   first difference is `Migration_mismatch { version; expected; actual }`:
   an edited or renamed applied step, a gap, a reordering, or a database
   ahead of the code (`expected = "none"`).
3. Applies each pending step in its own transaction together with its
   bookkeeping row. The first failure stops the run and is returned with the
   context `Migration { version; name }`; earlier steps stay applied, the
   failed one leaves no trace.
4. Verifies each `~verify` declaration with `Table.verify`.

Returns the versions applied by this call (`[]` when up to date).

**Frozen declarations.** `create` and `add_column` take the declaration as
it was when the step was written, kept as its own value (`users_v1`,
`users_v2`, …), never the current one. A fresh database replays every step:
`create users` with a current declaration that already has `nick`, followed
by `add_column … nick`, fails ("column already exists"); and on an existing
database a change to the declaration a step was applied with reads as an
edited step (`Migration_mismatch`).

**Checksums** are the MD5 hex digest of what a step does: the SQL text of
`sql`, drop and rename steps; for `create` and `add_column`, the
declaration's structure (schema, table, column names, type names,
nullability, constraints with their rendered CHECK and DEFAULT
expressions), not the DDL text, so a library change to DDL spelling does not
change applied checksums; for a `run` step, its name only (code cannot be
hashed), so an edited `run` step is not detected.

**Concurrency.** DuckDB's file lock keeps a second read-write process from
opening the database at all. Two connections of one process migrating
concurrently insert the same bookkeeping key; DuckDB rejects the second
transaction with a conflict, and that `apply` returns the native error.
Rerunning it then finds the steps applied.

## Errors

- Context `Migration of { version : int; name : string }`.
- Cause `Migration_mismatch of { version : int; expected : string; actual :
  string }`, `expected`/`actual` rendered as `"3 add nickname (<md5>)"` or
  `"none"`.

## Internals

- `lib/duckdb/migration.ml`: a step is `{ version; name; checksum; kind }`,
  `kind = Statements { statements; canonical } | Run f` with
  `f : [ `Transaction ] Session.t @ local -> (unit, Failure.t) result`;
  SQL kinds render their SQL when built, and the checksum covers
  `canonical`. The bookkeeping table is created by
  hand-written SQL; history is read with a typed request and each row
  inserted with a typed request in the step's transaction.
- `add_column` reads the picked column's codec, default and constraints from
  `Request.Table_def`.
- `duckdb.mli`: `Migration` after `Table`.

## Fixes from the independent review

- `add_column` with any default other than a string failed with
  `Unsupported_statement` (the extraction quirk above; the only test used a
  string default). Defaults are now quoted constants; tests cover int32,
  float `nan`, bool and `Int64.min_value` on a table with rows.
- The API example built its steps from the current declarations; it now uses
  frozen ones, and checksums cover a declaration's structure instead of its
  DDL text.
- The concurrency note said "two processes"; it is two connections.
- Follow-up (2026-10-08): `apply` creates the bookkeeping table only when
  `duckdb_tables()` lacks it. `CREATE TABLE IF NOT EXISTS` is rejected on a
  read-only database even when the table exists ("Cannot execute statement
  of type CREATE … read-only mode"), so an up-to-date database opened
  read-only could not be checked; now it applies nothing and verifies.

## Refinements found while prototyping

- `rename_table` and `rename_column` take the old name positionally
  (`rename_table "a" ~to_:"b"`): an optional `?schema` needs a positional
  argument after it to be erasable.
- The bookkeeping table is created by hand-written SQL, not
  `Table.declare`: its `applied_at` default is `now()`, which typed literals
  cannot express.
- History mismatches carry the context `Migration { version; name }` of the
  differing position (the step's name, or the applied row's when the code
  has no step there).
- Adding `Migration` to `Error.context` extends exhaustive matches; the
  examples and the request-types fixture match it.

## Verified DuckDB facts

Probed with DuckDB 1.5.5, 2026-10-07:

| Fact | Result |
|---|---|
| `ADD COLUMN … NOT NULL`, `UNIQUE`, `CHECK`, with or without DEFAULT | "Adding columns with constraints not yet supported" |
| `ADD COLUMN b INTEGER DEFAULT 0` then `ALTER COLUMN b SET NOT NULL` on a table with rows | Both succeed; NOT NULL recorded |
| `SET NOT NULL` on a column holding NULL | "NOT NULL constraint failed" |
| CREATE TABLE and ALTER TABLE inside `with_transaction` whose callback fails | Both rolled back |
| `RENAME COLUMN`, `DROP COLUMN`, `RENAME TO` | Succeed |
| Rename or drop of a table referenced by a foreign key | Rejected (dependency error) |
| Raw `BEGIN` through a request | Rejected by the library; transactions go through `with_transaction` |

## Testing

`test/test_migration.ml`:

- From empty: `apply` returns every version and `~verify` passes; a second
  `apply` returns `[]`; a list extended by one step applies only that one.
- A failing step 4: steps 1–3 stay applied, 4 leaves no trace, the error's
  context is `Migration { version = 4; … }`; after fixing it a rerun applies 4.
- History: an edited applied step, a renamed one, a database ahead of the
  code, and a gap, each with its exact `Migration_mismatch`.
- Each step kind, observed in the catalog and data: `add_column` of a
  non-null column with a default on a table with rows (rows get the default;
  NOT NULL recorded); a nullable column without default; `Invalid_argument`
  for a constrained column; a `run` step's backfill rolled back with its
  failing step.
- `Invalid_argument` for duplicate and decreasing versions.
- A `~verify` difference is returned after the steps applied, with the
  `Table` context.

`test/migration_compile/` (the `check_*_types.sh` pattern): `positive.ml`
with the example above; rejected: `apply` on a transaction, a `run` callback
of the wrong result type, an `add_column` picker of the wrong arity.

Acceptance: `./tools/run build @all`, `./tools/run runtest --force` pass.

Documentation: README "Migrations" section, CHANGELOG, roadmap row 3 done,
this note's status.
