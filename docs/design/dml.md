# Typed INSERT, UPDATE and DELETE (sub-project 4b)

Status: implemented, 2026-10-08; refined while implementing (see
[Refinements](#refinements-found-while-implementing)). Extends [typed SQL](typed-sql.md) and
[query composition](query-composition.md); roadmap row 4b of the
[core redesign](core-redesign.md).

## Goal

Write statements built from the same typed expressions as queries, compiled
to ordinary `Request.t` values: the affected-row count or typed `RETURNING`
rows, partial inserts, `INSERT … SELECT` and upserts keyed by a declared key.

## Scope

In: UPDATE (with WHERE, subqueries), DELETE, INSERT of chosen columns
(others take their defaults) or `DEFAULT VALUES`, `INSERT … SELECT` from a
typed source, `RETURNING` on all of them, `ON CONFLICT (key) DO NOTHING` and
`DO UPDATE SET … [WHERE …]` with `excluded`.

Out: multi-row VALUES (bulk rows go through the appender, `Table.append`);
`UPDATE … FROM` (a correlated subquery expresses it); `INSERT OR REPLACE`
(an upsert expresses it); MERGE; DML as a subquery or CTE (DuckDB rejects
DML in subqueries).

## API

```ocaml
(* Rows changed: (int64 * (string * unit), int64, one) Request.t *)
let rename = S.(command Params.[int64; string] (fun [id; name] ->
  update users (fun [uid; uname; _] -> set [uname := param name] ~where:(uid = param id))))

(* The generated ids: (string * unit, int64, many) Request.t *)
let add = S.(command Params.[string] (fun [name] ->
  insert users (fun [uid; uname; _] -> values [uname := param name] |> returning Exprs.[uid] ~row:Fn.id)))

let upsert = S.(command Params.[int64; string] (fun [id; name] ->
  insert users (fun [uid; uname; _] ->
    values [uid := param id; uname := param name]
      ~on_conflict:(update_on Keys.[uid] (fun [_; new_name; _] -> [uname := new_name])))))

let purge = S.(command Params.[] (fun [] -> delete users (fun [_; _; age] -> filter (is_null age))))

let copy = S.(command Params.[] (fun [] ->
  insert archive (fun [aid; aname] -> select_into Targets.[aid; aname]
    (from users (fun [uid; uname; _] -> select Exprs.[uid; uname] ~row:(fun a b -> (a, b))))))))
```

```ocaml
type ('shape, 'row, 'm) change    (* a statement body over a table of 'shape *)
type ('row, 'm) statement
type assignment

val command : ('params, 'shape) Params.t -> ('shape Bound.t -> ('row, 'm) statement) ->
  ('params, 'row, 'm) Request.t
val ( := ) : ('a, 'n, row) expr -> ('a, 'n, row) expr -> assignment

val update : (_, 'shape, _) Request.table -> (('shape, row) Binders.t -> ('shape, 'row, 'm) change) -> ('row, 'm) statement
val delete : (_, 'shape, _) Request.table -> (('shape, row) Binders.t -> ('shape, 'row, 'm) change) -> ('row, 'm) statement
val insert : (_, 'shape, _) Request.table -> (('shape, row) Binders.t -> ('shape, 'row, 'm) change) -> ('row, 'm) statement

val set : ?where:(bool, Codec.non_null, row) expr -> assignment list -> (_, int64, Request.one) change
val filter : (bool, Codec.non_null, row) expr -> (_, int64, Request.one) change
val all : (_, int64, Request.one) change
val values : ?on_conflict:'shape conflict -> assignment list -> ('shape, int64, Request.one) change
val select_into : ?on_conflict:'shape conflict -> 'list Targets.t -> ('list, _, _) source ->
  ('shape, int64, Request.one) change
val returning : ('a * 'list, 'fn, 'row, row) Exprs.t -> row:'fn -> ('shape, int64, Request.one) change ->
  ('shape, 'row, Request.many) change

type 'shape conflict
val nothing_on : _ Keys.t -> _ conflict
val update_on : ?where:(bool, Codec.non_null, row) expr -> _ Keys.t ->
  (('shape, row) Binders.t -> assignment list) -> 'shape conflict

module Targets : sig
  type 'list t =
    | [] : unit t
    | (::) : ('a, _, row) expr * 'list t -> ('a * 'list) t
end
```

- `command` mirrors `query`: parameters render as `$1`, `$2`, … and keep
  the `query` scope, so subqueries and `excluded` may use them.
- Without `returning`, a statement returns the affected-row count: DuckDB
  reports a one-row `Count` BIGINT for every DML statement. With
  `returning`, the select list's rows (`many`). `returning` takes a
  count-returning body, so it cannot apply twice (by type).
- The body's binders are the table's columns: assignment targets, WHERE
  operands, RETURNING expressions; in `update_on`, the existing row, with
  the callback's binders the proposed row (`excluded."col"`).
- `values` names the inserted columns; the others take their defaults.
  `values []` is `DEFAULT VALUES`. Values cannot mention the table's
  columns (there is no row yet).
- `select_into Targets.[c1; c2] source`: the source's column types equal
  the targets' (`'list`), by type.
- A body is indexed by its table's shape, so `update_on`'s `excluded`
  binders are typed by the inserted table (a callback of another arity or
  column types is a compile error, not binders of the wrong type).

### Checks when built (`Invalid_argument`)

- An assignment or `Targets` element that is not a column of the statement's
  table, or one column assigned twice.
- An assignment whose value's codec differs from the column's (the operand
  codec check of [typed SQL](typed-sql.md)).
- A value or `select_into` source that mentions the inserted table's
  columns (rendered as a foreign expression).
- A conflict key that is not the declared primary key or a declared unique
  key (as a set; DuckDB accepts any order), or that names columns of
  another table.
- An empty `set` list.

### Rendering

| Statement | SQL |
|---|---|
| update | `UPDATE "s"."t" AS t0 SET "c" = <v>, … [WHERE …] [RETURNING …]` |
| delete | `DELETE FROM "s"."t" AS t0 [WHERE …] [RETURNING …]` |
| insert values | `INSERT INTO "s"."t" ("c", …) VALUES (<v>, …) [ON CONFLICT …] [RETURNING …]` |
| insert defaults | `INSERT INTO "s"."t" DEFAULT VALUES [RETURNING …]` |
| insert select | `INSERT INTO "s"."t" ("c", …) <select> [ON CONFLICT …] [RETURNING …]` |
| conflict | `ON CONFLICT ("k", …) DO NOTHING` / `DO UPDATE SET "c" = <v>, … [WHERE …]` |

UPDATE and DELETE alias the table `t0`, so subqueries correlate. An INSERT
renders the target `AS t0` only with ON CONFLICT and unqualified otherwise:
DuckDB rejects `RETURNING t0.c` after `INSERT INTO t AS t0 … VALUES …`
without ON CONFLICT ("Referenced table t0 not found"). SET targets are
unqualified column names, as SQL requires. `excluded` columns render
`excluded."c"`.

## Internals

- `lib/duckdb/sql.ml`. A statement holds its target, scope, kind and result:
  `Update { assignments; where } | Delete { where } | Insert_values {
  assignments; conflict } | Insert_select { columns; source; conflict }`;
  the result is `Count` or a `Returning` of fields, row function and nodes,
  behind a GADT indexed by `'row` and `'m`.
- An assignment is `{ scope; column; value }`: `:=` takes the target's
  column node (else `Invalid_argument`) and checks codecs; the statement
  checks the scope against its table when built.
- The conflict's `excluded` binders get their own scope, mapped to the alias
  `excluded` when rendering its assignments and WHERE.
- Rendering reuses the 4a context (aliases in textual order, scope → alias
  map, parameters' scope).

## Refinements found while implementing

- A body is also indexed by its statement kind: `('shape, 'kind, 'row, 'm)
  change`, with `` [ `Update ] `` for `set`, `` [ `Delete ] `` for `filter`
  and `all`, `` [ `Insert ] `` for `values` and `select_into`; `update`,
  `delete` and `insert` require theirs, so `update t (fun _ -> values …)`
  is a compile error (fixture `kind_mismatch`), not a check when built.
- `:=` shadows reference assignment inside `S.( … )`; code there writes
  `Stdlib.( := )` (as the comparison operators already shadow Base's).
- INSERT and ON CONFLICT were implemented with Task 1, before their tests;
  each check when built was then mutation-tested (disabled → its test
  fails). `:=`'s own column check is backed by the statement's table check
  (a non-column target is rejected either way).

## Errors

No new causes. Misuse: `Invalid_argument` when built, as listed. Execution
failures (NOT NULL, key violations, a conflict target DuckDB cannot use)
are ordinary request errors (`Native`).

## Verified DuckDB facts

Probed with DuckDB 1.5.5, 2026-10-08:

| Fact | Result |
|---|---|
| UPDATE/DELETE/INSERT without RETURNING | One row, column `Count` BIGINT |
| `INSERT INTO t AS t0 … VALUES … RETURNING t0.c` | Prepare error "Referenced table t0 not found" |
| The same with `ON CONFLICT … DO NOTHING/UPDATE` | Accepted |
| `RETURNING c` (unqualified) after INSERT | Accepted |
| `DO UPDATE SET n = n + 10, name = excluded.name` | Existing row's `n`, proposed `name` |
| `DO UPDATE … WHERE t0.n > 100` not matching | Row kept, nothing returned |
| `ON CONFLICT (m, k)` for `UNIQUE (k, m)` | Accepted |
| `ON CONFLICT (k)` for `UNIQUE (k, m)` | Binder error |
| `INSERT … SELECT … ON CONFLICT … RETURNING` | Accepted |
| `UPDATE … SET c = DEFAULT`, `VALUES (…, DEFAULT)` | Accepted |
| `DELETE … WHERE id IN (SELECT …) RETURNING …` | Accepted |

## Testing

`test/test_sql_dml.ml`: rendered SQL and effects against DuckDB for update
(count; correlated subquery in WHERE), delete (`filter`, `all`), insert
(partial with defaults, `DEFAULT VALUES`, `select_into`), `returning` on
each, upserts (`nothing_on`; `update_on` with `excluded` and `~where`),
each `Invalid_argument`, a NOT NULL violation as an `Error`.

`test/dml_compile/` (the `check_*_types.sh` pattern): `positive.ml` with the
examples above; rejected: an assignment of another type, a nullable value
for a non-null column, `select_into` with mismatched targets, `find` on a
statement with `returning`, `returning` twice.

Acceptance: `./tools/run build @all`, `./tools/run runtest --force` pass.

Documentation: README "Typed SQL", CHANGELOG, core-redesign roadmap row 4b,
`PLAN_FEAT_dml.md`, this note's status.
