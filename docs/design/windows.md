# Window functions (sub-project 4c)

Status: implemented, 2026-10-08; refined while implementing (see
[Refinements](#refinements-found-while-implementing)). Extends [typed SQL](typed-sql.md) and
[query composition](query-composition.md); roadmap row 4c of the
[core redesign](core-redesign.md).

## Goal

Ranking, offset and aggregate window functions with frames and QUALIFY,
typed so that a window result can only appear where DuckDB evaluates
windows: the select list, ORDER BY and QUALIFY.

## Scope

In: `row_number`, `rank`, `dense_rank`, `ntile`, `percent_rank`,
`cume_dist`; `lag`, `lead`, `first_value`, `last_value`, `nth_value`;
`count`, `sum`, `min`, `max`, `avg` over windows; PARTITION BY, ORDER BY,
ROWS and RANGE frames; QUALIFY; windows in grouped selects (over
aggregates).

Out: named windows (`WINDOW w AS …`, identical results); GROUPS frames and
EXCLUDE; IGNORE NULLS; FILTER clauses; window functions in DML.

## API

```ocaml
from sales (fun [k; d; v] ->
  let w = window ~partition_by:[part k] ~order_by:[asc d]
      ~frame:(rows ~start:(Preceding 2) ~end_:Current_row) () in
  select_over Exprs.[lift k; lift d; row_number w; Over.sum v w; lag v w]
    ~qualify:(row_number w <= int64 3L) ~order_by:[asc (lift k); desc (row_number w)]
    ~row:(fun k d n s prev -> (k, d, n, s, prev)))
```

```ocaml
type 'k windowed                  (* the kind of window results over base kind 'k *)
type 'k window                    (* a window specification over base kind 'k *)
type 'k part
type bound = Unbounded_preceding | Preceding of int | Current_row | Following of int | Unbounded_following
type frame

val part : (_, _, 'k) expr -> 'k part
val rows : start:bound -> end_:bound -> frame
val range : start:bound -> end_:bound -> frame
val window : ?partition_by:'k part list -> ?order_by:'k order list -> ?frame:frame -> unit -> 'k window
val lift : ('a, 'n, 'k) expr -> ('a, 'n, 'k windowed) expr

val select_over : ?distinct:bool -> ?where:(bool, Codec.non_null, row) expr ->
  ?having:(bool, Codec.non_null, grouped) expr -> ?qualify:(bool, Codec.non_null, 'k windowed) expr ->
  ?order_by:'k windowed order list -> ?limit:int -> ?offset:int ->
  ('a * 'list, 'fn, 'row, 'k windowed) Exprs.t -> row:'fn -> ('a * 'list, 'row, 'k, Request.many) body

val row_number : 'k window -> (int64, Codec.non_null, 'k windowed) expr
val rank : 'k window -> (int64, Codec.non_null, 'k windowed) expr
val dense_rank : 'k window -> (int64, Codec.non_null, 'k windowed) expr
val ntile : int -> 'k window -> (int64, Codec.non_null, 'k windowed) expr
val percent_rank : 'k window -> (float, Codec.non_null, 'k windowed) expr
val cume_dist : 'k window -> (float, Codec.non_null, 'k windowed) expr

val lag : ?offset:int -> ('a, Codec.non_null, 'k) expr -> 'k window -> ('a option, Codec.nullable, 'k windowed) expr
val lead : ?offset:int -> ('a, Codec.non_null, 'k) expr -> 'k window -> ('a option, Codec.nullable, 'k windowed) expr
val lag_or : ?offset:int -> default:('a, Codec.non_null, 'k) expr -> ('a, Codec.non_null, 'k) expr -> 'k window ->
  ('a, Codec.non_null, 'k windowed) expr
val lead_or : (as lag_or)
val first_value : ('a, Codec.non_null, 'k) expr -> 'k window -> ('a option, Codec.nullable, 'k windowed) expr
val last_value : (as first_value)
val nth_value : int -> ('a, Codec.non_null, 'k) expr -> 'k window -> ('a option, Codec.nullable, 'k windowed) expr

module Over : sig
  val count_star : 'k window -> (int64, Codec.non_null, 'k windowed) expr
  val count : (_, _, 'k) expr -> 'k window -> (int64, Codec.non_null, 'k windowed) expr
  val min : ('a, Codec.non_null, 'k) expr -> 'k window -> ('a option, Codec.nullable, 'k windowed) expr
  val max : (as min)
  val sum : (int64, Codec.non_null, 'k) expr -> 'k window -> (int64 option, Codec.nullable, 'k windowed) expr
  val avg : (int64, Codec.non_null, 'k) expr -> 'k window -> (float option, Codec.nullable, 'k windowed) expr
  module Null : sig (min, max, sum, avg over nullable operands) end
end
(* INTEGRAL and FRACTIONAL gain sum_over and avg_over (and Null versions):
   I32.sum_over, F64.avg_over, … *)
module Null : sig … val lag, lead, first_value, last_value, nth_value over nullable operands end
```

- A window's partition and order keys and every window function's
  arguments have the base kind `'k`: `row` in a plain select, `grouped`
  inside `group_by` (so `Over.sum (sum v) w` is `sum(sum(v)) OVER (…)`).
- Window results have kind `'k windowed`, which no WHERE, HAVING, GROUP BY
  key, aggregate argument, join ON, DML assignment or window argument
  accepts: each is a compile error.
- `select_over`'s list, QUALIFY and ORDER BY are of kind `'k windowed`;
  other expressions join them through `lift` (literals and parameters are
  of any kind and need none). Its result is an ordinary `'k` body, so
  `from`, joins, `group_by`, subqueries and set operations take it.
- `lag`/`lead` are NULL past the partition edge; `lag_or`/`lead_or` take a
  non-null default for a non-null operand. `first_value`, `last_value` and
  `nth_value` are nullable: a frame may be empty (`ROWS BETWEEN 2 PRECEDING
  AND 1 PRECEDING` at the first row) and `nth_value` may run past it.
- `Over.sum`/`sum_over` cast back to the operand type (DuckDB returns
  HUGEINT); overflow is a native error, as for `sum`.
- `ntile n`, `nth_value n`, `?offset` and frame offsets are literal
  integers: DuckDB fails to bind a parameter in `ntile`. A negative one
  raises `Invalid_argument` when built.

## Internals

- `lib/duckdb/sql.ml`: `type 'k windowed`; a window is `{ partition : node
  list; order : order list; frame : (string * bound * bound) option }`; a
  new node `Over of node * window` renders `<function> OVER (PARTITION BY …
  ORDER BY … ROWS BETWEEN … AND …)`, the function a `Apply`, `Count_star` or
  wrapped in `Cast` (sums: `CAST(sum(x) OVER (…) AS T)`).
- `body` gains `qualify : node option`, rendered after HAVING; `select_over`
  builds the same `Body` as `select`.
- `aggregates` stops at `Over` (a window aggregate does not make a select
  an aggregate); `mentioned` recurses into its partition and order.
- Rendering keeps textual order (window clauses left to right).

## Refinements found while implementing

- `ntile n` and `nth_value n` require `n >= 1` (`Invalid_argument`
  otherwise); offsets and frame bounds `>= 0`. A negative frame offset is
  raised by `rows`/`range` when the frame is built.
- `select_over` is `select` plus `qualify`, re-typing the order keys, so it
  shares `select`'s non-empty list and limit checks.
- A window aggregate inside `aggregate` is a type error (the list's kind is
  `grouped`, a window's `grouped windowed`), so no check when built is
  needed for it; `aggregates` ignores `Over` nodes for `select_over`.
- `Over.Null.sum (sum v) w` renders `CAST(sum(CAST(sum(v) AS BIGINT)) OVER
  () AS BIGINT)`: both casts are the existing sum's cast back to the
  operand type.

## Errors

No new causes. `Invalid_argument` for a negative `ntile`, `nth_value`,
offset or frame bound. Left to DuckDB (request errors): a RANGE frame with
an offset needs exactly one numeric ORDER BY key.

## Verified DuckDB facts

Probed with DuckDB 1.5.5, 2026-10-08:

| Fact | Result |
|---|---|
| Window in WHERE / HAVING | "WHERE/HAVING clause cannot contain window functions" |
| Window inside an aggregate | "aggregate function calls cannot contain window function calls" |
| `sum(sum(v)) OVER ()`, `rank() OVER (ORDER BY sum(v))` with GROUP BY | Accepted |
| QUALIFY, window in ORDER BY | Accepted |
| `row_number`, `rank`, `dense_rank`, `ntile`, `count(*)` OVER | BIGINT |
| `percent_rank`, `cume_dist`, `avg` OVER | DOUBLE |
| `sum(BIGINT)`, `sum(INTEGER)` OVER | HUGEINT |
| `lag(v, 1, 0)`, `lead`, `first_value`, `nth_value(v, 2)` | Edge rows NULL (or the default) |
| ROWS / RANGE BETWEEN n PRECEDING AND CURRENT ROW | Accepted |
| `ntile(CAST($1 AS BIGINT))` | "Expected 1 parameters, but none were supplied" |

## Testing

`test/test_sql_window.ml`: rendered SQL and results for each ranking
function; `lag`/`lead` with and without offset and default; `first_value`,
`last_value`, `nth_value`; a ROWS running total and a RANGE moving sum;
`Over.count`/`min`/`max`/`avg`; `Over.sum` decoded in its operand type;
QUALIFY top-N per group; ORDER BY a window; `sum(sum(v)) OVER ()` in
`group_by`; a window over a join; `Invalid_argument` for negative literals.

`test/window_compile/`: rejected: a window in `~where`, in `~having`,
inside `Over.sum`, an unlifted column in a windowed list, `lag_or` of a
nullable column, a window in an UPDATE assignment.

Acceptance: `./tools/run build @all`, `./tools/run runtest --force` pass.

Documentation: README "Typed SQL", CHANGELOG, roadmap row 4c,
`PLAN_FEAT_windows.md`, this note's status.
