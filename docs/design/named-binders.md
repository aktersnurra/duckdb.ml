# Named binders

Status: implemented, 2026-10-09. Extends [typed SQL](typed-sql.md),
[query composition](query-composition.md) and [DML](dml.md).

## Goal

Refer to a table's columns by a named handle instead of by position in
`from`, join and DML callbacks. Positional binders (`fun [_; owner; _]`)
cost a run of `_` on wide tables and, worse, keep type-checking when two
columns of one type are swapped in the declaration: every query then reads
the other column. A handle is taken from the declaration once, next to its
column list, and every query names it.

## Scope

In: `from`, `join` and `cross_join` (`~on` and body), `left_join` (`~on`
as expressions, body through `outer`/`Null.outer`), `update`, `delete`,
`insert` and `update_on`'s proposed row.

Out: `group_by` keys (their shape is the key list, chosen per query);
`~constraints` (it runs inside `declare`, before handles exist);
`Table.lookup` (its callback names one key). Positional binders stay;
the API is additive.

## API

```ocaml
module Users = struct
  let t = D.Table.(declare "users"
    Columns.["id", int64; "name", string; "age", nullable int32] ...)
  let S.Named.[id; name; age] = D.Table.fields t
end

S.(query Params.[] (fun [] ->
  from Users.t (fun u ->
    left_join Posts.t ~on:(fun p -> p.%(Posts.owner) = u.%(Users.id)) (fun p ->
      select Exprs.[u.%(Users.name); outer p.%?(Posts.title)]
        ~row:(fun n t -> (n, t))))))
```

```ocaml
(* Sql *)
type ('shape, 'a, 'n) field     (* column ['a]/['n] of a table of shape ['shape] *)
module Named : sig
  type ('whole, 'rest) t =
    | [] : (_, unit) t
    | (::) : ('whole, 'a, 'n) field * ('whole, 'rest) t ->
      ('whole, ('a, 'n) Codec.slot * 'rest) t
end
val ( .%() ) : ('shape, 'k) Binders.t -> ('shape, 'a, 'n) field -> ('a, 'n, 'k) expr
val ( .%?() ) : 'shape Outer.t -> ('shape, 'a, 'n) field -> ('a, 'n) outer

(* Table *)
val fields : (_, 'shape, _) t -> ('shape, 'shape) Sql.Named.t
```

`Named` rather than `Fields`: `Duckdb.Fields` is public, and a `Sql.Fields`
would shadow it inside every `Sql.( … )` local open.

`.%?()` returns the `outer` value, not a lifted expression: the lift's
result type depends on nullability (`outer` gives `'a option`,
`Null.outer` keeps `'a`), which one function cannot express.

## Typing and limits

A field is a typed index into the shape, so `u.%(f)` has exactly the type
of the positional binder it names, and a handle used on a table of another
shape is a compile error. Handles are typed by shape, not by table: a
`Users` handle used on another table of the identical shape type-checks
and names the same position there. Generative table identity would rule
this out at the cost of a fresh type per declaration and a break in every
signature naming `Request.table`; not taken.

`let S.Named.[id; name; age] = …` is exhaustive by the shape (no warning);
a pattern of the wrong length is a type error.

## Implementation

`field` is a GADT, `Here | Next of field`; `( .%() )` and `( .%?() )` walk
the binder list when the query is built. `Table.fields` recurses over the
declaration's `Columns`, re-indexing each tail's `Here` against the whole
shape through a polymorphic-record continuation. No casts, no runtime
failure modes, no change to rendering.

## Tests

- `test/test_sql.ml`: named `from`, `join`, `left_join`, `update`,
  `insert … update_on`, each rendering the same SQL and returning the same
  rows as its positional form.
- `test/named_compile/` with `check_named_types.sh`: a positive file; a
  handle of another shape rejected; `.%()` on `Outer.t` rejected; a
  `.%?()` result used as an expression without `outer` rejected; a
  wrong-length `Named` pattern rejected.

Documentation: README (typed SQL example), CHANGELOG (Unreleased), this
note's status.
