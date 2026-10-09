# duckdb.ml

[![Ubuntu CI](https://github.com/aktersnurra/duckdb.ml/actions/workflows/ubuntu.yml/badge.svg)](https://github.com/aktersnurra/duckdb.ml/actions/workflows/ubuntu.yml)

`duckdb.ml` is an OxCaml binding for DuckDB in which the type checker does the
bookkeeping. Parameters, rows and table columns are typed by GADTs. Handles
are `@ local` to their scope, so use-after-close cannot be written. Separately
installable `duckdb-async` and `duckdb-eio` adapters provide the same typed API
over connection pools.

It is full OxCaml, not upstream OCaml: it uses modes (`local`, `unique`,
`global`), modalities and `int8`/`int16`/`float32`.

## Installing

The packages need the exact pinned toolchain (OxCaml `5.2.0minus39`, Dune
`3.22.2+ox`, Base `v0.18~preview.130.106+341`; see
[`tools/toolchain.lock.json`](tools/toolchain.lock.json)) and the DuckDB
1.5.5 shared library, which they do not bundle. In a switch with that
toolchain:

```sh
python3 tools/setup_duckdb.py --prefix "$HOME/.local/duckdb-1.5.5"   # from a checkout
export DUCKDB_INCLUDE_DIR="$HOME/.local/duckdb-1.5.5"
export LIBRARY_PATH="$DUCKDB_INCLUDE_DIR${LIBRARY_PATH:+:$LIBRARY_PATH}"
export LD_LIBRARY_PATH="$DUCKDB_INCLUDE_DIR${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
opam pin add duckdb-ffi git+https://github.com/aktersnurra/duckdb.ml.git#v0.2.1
opam pin add duckdb git+https://github.com/aktersnurra/duckdb.ml.git#v0.2.1
# optional adapters: duckdb-async, duckdb-eio (same URL)
```

The packages are not in the opam repository: their dependencies are OxCaml
builds. [Native dependency](docs/native-dependency.md) covers deployment of
`libduckdb.so`.

## Example

```ocaml
open! Base
module D = Duckdb
module R = D.Request

type user = { id : int64; name : string; age : int32 option }

(* Tables and requests are plain values: declared once, checked against the
   catalog when first used, and cached per connection. *)
let users = D.Table.(declare "users"
  Columns.["id", int64; "name", string; "age", nullable int32]
  ~row:(fun id name age -> { id; name; age })
  ~constraints:(fun [id; _; _] -> Constraint.[ primary_key Key.[id] ]))
let adults = R.many D.Fields.[int32] D.Fields.[int64; string] ~row:(fun id name -> (id, name))
  "SELECT id, name FROM users WHERE age >= ? ORDER BY id"

(* [c] is local to its scope: it cannot be stored, returned or captured. *)
let run (c @ local) =
  match D.Table.create c users with
  | Error e -> Error e
  | Ok () ->
    match D.Table.with_appender c users ~f:(fun a ->
      D.Table.append a [ D.Args.[1L; "ada"; Some 36l]; D.Args.[2L; "bob"; None] ]) with
    | Error e -> Error e
    | Ok () -> R.Session.collect c adults D.Args.[18l]

let () =
  let result =
    Result.bind (D.Config.create Memory) ~f:(fun config ->
      D.with_database config ~f:(fun db -> D.with_connection db ~f:run)) in
  match result with
  | Ok rows -> List.iter rows ~f:(fun (id, name) -> Stdio.printf "%Ld %s\n" id name)
  | Error { D.Error.cause = Type_mismatch { expected; actual; _ }; _ } ->
    Stdio.eprintf "expected %s, got %s\n" expected actual
  | Error _ -> Stdio.eprintf "query failed\n"
```

This prints `1 ada`. More in [`examples/`](examples/), including the low-level
`Statement` API (positional binding, borrowed chunks) and both adapters.

## What the compiler rejects

Each line below is a compile error, pinned by a fixture in
[`test/scope_compile`](test/scope_compile) or
[`test/request_compile`](test/request_compile):

```ocaml
D.with_connection db ~f:(fun c -> Ok c)                          (* handle escapes its scope *)
D.with_transaction c ~f:(fun _ -> D.execute c "...")             (* busy connection captured *)
D.with_transaction c ~f:(fun tx -> D.with_transaction tx ~f:g)   (* nested transaction *)
R.Session.find c (R.many ...) args                               (* [find] needs exactly one row *)
R.Session.exec c insert D.Args.[1L]                              (* wrong parameter arity or type *)
D.Args.[200s]                                                    (* out of range for int8 *)
let r = D.Bridge.request k in D.Bridge.run r c ...; D.Bridge.run r c ...   (* request runs once *)
```

What stays a runtime check is reported as a flat `Error.t`
(`{ context; cause }`): native failures, cancellation, NULL in a non-null
column, a schema that does not match its declaration, and `Busy`/`Closed`
when you opt into manually managed handles through `Owned`.

## Typed SQL

`Duckdb.Sql` builds queries from typed expressions. A query is an ordinary
`Request.t`, run, cached and validated like hand-written SQL:

```ocaml
module S = D.Sql

let adults = S.(
  query Params.[int32] (fun [min_age] ->
    from users (fun [id; name; age] ->
      select Exprs.[id; name] ~row:(fun id name -> (id, name))
        ~where:(is_true Null.(age >= nullable (param min_age)))
        ~order_by:[asc id] ~limit:100)))
(* : (int32 * unit, int64 * string, many) Request.t *)

let by_name = S.(
  query Params.[] (fun [] ->
    from users (fun [_; name; age] ->
      group_by Keys.[name] (fun [name] ->
        select Exprs.[name; count_star; Null.max age]
          ~row:(fun n c m -> (n, c, m)) ~having:(count_star > int64 1L)))))
```

Expressions carry their value type, nullability and grouping. NULL follows
SQL's three-valued logic in the types: `Null` operators take and return
options, and `is_true`, `coalesce` and `nullable` convert explicitly. These
are compile errors (fixtures in [`test/sql_compile`](test/sql_compile)):

```ocaml
select Exprs.[id] ~row:Fn.id ~where:(age >= int32 18l)          (* age is nullable *)
group_by Keys.[name] (fun [name] -> select Exprs.[name; id] …)  (* id is not grouped *)
R.Session.find c adults D.Args.[18l]                             (* a select is many rows *)
```

Joins nest as callbacks. A LEFT JOIN's right columns can be NULL, so its body
binds them as `outer` values, usable only once lifted to options by `outer`
(or `Null.outer` for an already nullable column). Subqueries are ordinary
`from …` sources and may refer to the enclosing query's columns:

```ocaml
let posts = D.Table.(declare "posts"
  Columns.["id", int64; "owner", int64; "title", string]
  ~row:(fun id owner title -> (id, owner, title)))

let with_posts = S.(
  query Params.[] (fun [] ->
    from users (fun [uid; name; _] ->
      left_join posts ~on:(fun [_; owner; _] -> owner = uid) (fun [_; _; title] ->
        select Exprs.[name; outer title] ~row:(fun n t -> (n, t))))))
(* : (unit, string * string option, many) Request.t *)

let posting = S.(
  query Params.[] (fun [] ->
    from users (fun [uid; name; _] ->
      select Exprs.[name; scalar (from posts (fun [_; owner; _] ->
                             aggregate Exprs.[count_star] ~row:Fn.id ~where:(owner = uid)))]
        ~row:(fun n c -> (n, c))
        ~where:(exists (from posts (fun [_; owner; _] ->
                  select Exprs.[owner] ~row:Fn.id ~where:(owner = uid)))))))
(* : (unit, string * int64 option, many) Request.t *)
```

Positional binders keep type-checking when two columns of one type are
swapped in a declaration. `Table.fields` names them once, next to the
declaration, and callbacks project by handle; `.%?` reads a LEFT JOIN's
`outer` value:

```ocaml
let S.Named.[uid; _; _] = D.Table.fields users
let S.Named.[_; owner; title] = D.Table.fields posts

let with_posts = S.(
  query Params.[] (fun [] ->
    from users (fun u ->
      left_join posts ~on:(fun p -> p.%(owner) = u.%(uid)) (fun p ->
        select Exprs.[u.%(uid); outer p.%?(title)] ~row:(fun i t -> (i, t))))))
```

The same handles work in `join`, `update`, `delete`, `insert` and
`update_on`'s proposed row ([design](docs/design/named-binders.md)).

Also: `join`, `cross_join`, `select ~distinct:true`, `in_` (three-valued),
`union`, `union_all`, `intersect`, `except_`, and `value` for literals of any
codec (dates, timestamps, blobs, custom codecs).

`command` builds INSERT, UPDATE and DELETE the same way. Without `returning`
a statement returns the affected-row count; upserts are keyed by a declared
primary or unique key:

```ocaml
let users_by_id = D.Table.(declare "users"
  Columns.["id", int64; "name", string; "age", nullable int32]
  ~row:(fun id name age -> (id, name, age))
  ~constraints:(fun [id; _; _] -> Constraint.[ primary_key Key.[id] ]))

let rename = S.(command Params.[int64; string] (fun [id; name] ->
  update users_by_id (fun [uid; uname; _] -> set [uname := param name] ~where:(uid = param id))))
(* : (int64 * (string * unit), int64, one) Request.t, the rows changed *)

let save = S.(command Params.[int64; string] (fun [id; name] ->
  insert users_by_id (fun [uid; uname; _] ->
    values [uid := param id; uname := param name]
      ~on_conflict:(update_on Keys.[uid] (fun [_; proposed; _] -> [uname := proposed]))
    |> returning Exprs.[uid; uname] ~row:(fun i n -> (i, n)))))
(* : (int64 * (string * unit), int64 * string, many) Request.t *)
```

Also `delete … (filter …)`, `values []` (DEFAULT VALUES), `select_into`
(INSERT … SELECT) and `nothing_on`. Inside `S.( … )`, `:=` is assignment;
write `Stdlib.( := )` for references.

Window functions have their own kind, `'k windowed`, accepted only by
`select_over`'s list, QUALIFY and ORDER BY, so a window in WHERE, HAVING or
an aggregate does not compile. Other columns join a windowed list through
`lift`:

```ocaml
let sales = D.Table.(declare "sales"
  Columns.["region", string; "day", int32; "amount", int64]
  ~row:(fun region day amount -> (region, day, amount)))

(* Each region's three best days, with a running total per region. *)
let best_days = S.(
  query Params.[] (fun [] ->
    from sales (fun [region; day; amount] ->
      let by_amount = window ~partition_by:[part region] ~order_by:[desc amount] () in
      let running = window ~partition_by:[part region] ~order_by:[asc day]
          ~frame:(rows ~start:Unbounded_preceding ~end_:Current_row) () in
      select_over Exprs.[lift region; lift day; rank by_amount; Over.sum amount running]
        ~row:(fun r d k t -> (r, d, k, t))
        ~qualify:(row_number by_amount <= int64 3L) ~order_by:[asc (lift region); asc (lift day)])))
(* : (unit, string * int32 * int64 * int64 option, many) Request.t *)
```

Also `dense_rank`, `ntile`, `percent_rank`, `cume_dist`, `lag`/`lead` (and
`_or` with a default), `first_value`, `last_value`, `nth_value`,
`Over.count`/`min`/`max`/`avg`, RANGE frames, and windows over aggregates
inside `group_by`. See [typed SQL](docs/design/typed-sql.md),
[query composition](docs/design/query-composition.md),
[typed DML](docs/design/dml.md) and [window functions](docs/design/windows.md).

## Schema

A declaration can state the table's constraints. `Table.create` runs its
`CREATE TABLE`, `Table.verify` checks an existing table against it, and
`Table.lookup` reads by a declared key, typed as at most one row:

```ocaml
let users = D.Table.(declare "users"
  Columns.["id", int64; "email", string; "age", nullable int32]
  ~row:(fun id email age -> (id, email, age))
  ~constraints:(fun [id; email; age] -> Constraint.[
    primary_key Key.[id];
    unique Key.[email];
    default age D.Sql.(nullable (int32 18l));
    check_null D.Sql.(Null.(column age >= nullable (int32 0l))) ]))
let posts = D.Table.(declare "posts"
  Columns.["id", int64; "owner", int64; "title", string]
  ~row:(fun id owner title -> (id, owner, title))
  ~constraints:(fun [id; owner; _] -> Constraint.[
    primary_key Key.[id];
    foreign_key Key.[owner] ~references:(users, fun [id; _; _] -> Key.[id]) ]))

let by_email = D.Table.lookup users (fun [_; email; _] -> D.Table.Key.[email])
(* : (string * unit, int64 * string * int32 option, zero_or_one) Request.t *)
```

NOT NULL comes from the codecs. Keys take non-null columns only, a foreign
key must match the referenced key's types, and a default has the column's
type and nullability; the compiler rejects the rest (fixtures in
[`test/schema_compile`](test/schema_compile)). `check` fails on NULL;
`check_null` follows SQL, where NULL passes. Note DuckDB's foreign-key
limitation: a referenced row cannot be updated at all while it is
referenced. Details in [schema](docs/design/schema.md).

## Migrations

`Migration.apply` brings a database up to date from an ordered list of
numbered steps, each in its own transaction with its bookkeeping row:

```ocaml
module M = D.Migration

let migrations = M.[
  step 1 "create users" (create users);
  step 2 "create posts" (create posts);
  step 3 "seed" (run (fun tx -> D.Request.Session.exec tx seed D.Args.[]));
  step 4 "index" (sql "CREATE INDEX posts_owner ON posts(owner)") ]

let start (c @ local) = M.apply c migrations ~verify:M.[ table users; table posts ]
(* : (int list, Error.t) result, the versions this call applied *)
```

`create` and `add_column` take the declaration as it was when the step was
written: once a step is applied, keep its declaration as its own value
(`users_v1`) and declare later shapes separately, or the step reads as
edited. Other steps are `add_column` (a column picked from a declaration),
`drop_table`, `drop_column`, `rename_table` and `rename_column`. Migrations
go forward only. The applied history must match the start of the
list (version, name, checksum of the SQL); an edited, renamed or missing step
is a `Migration_mismatch`. DuckDB cannot add a column with constraints, so
`add_column` adds a non-null column with its default and then sets it NOT
NULL, and rejects a column that is part of a key, CHECK or foreign key.
Details in [migrations](docs/design/migrations.md).

## Sequencing with local handles

A `let*` continuation must be a global closure, so it cannot use a local
handle. Use `match` for several steps, `Result.bind … [@nontail]` for one, or
`ppx_let`'s `let%bindl_fun` (Base `Result.Let_syntax`) if you use ppx. A
helper that takes a handle is inferred `@ local`; when the compiler reports an
escape at a call site, annotate the parameter `(c @ local)`.

## Fast paths

For analytics, read columns instead of rows. A column view is checked once
per chunk; its numeric accessors return unboxed values and never allocate
(the build checks it):

```ocaml
module C = D.Statement.Column
module I64 = Stdlib_upstream_compatible.Int64_u

let[@zero_alloc] rec sum (v @ local) i n acc =
  if i = n then acc else sum v (i + 1) n (I64.add acc (C.int64 v i))

(* The sum of column 0; a NULL in it is an error. *)
let total (p @ local) =
  D.Statement.fold_chunks p ~init:0L ~f:(fun chunk acc ->
    match C.view chunk 0 D.Scalar.Int64 C.Non_null with
    | C.Rejected e -> Error e
    | C.Opened v -> Ok (D.Continue Int64.(acc + I64.to_int64 (sum v 0 (C.length v) #0L))))
```

`Bulk.collect` copies a whole column into a Bigarray with one native copy
per chunk, and `Table.append_columns` appends Bigarrays the same way, typed
by the table declaration:

```ocaml
let ids (p @ local) = D.Bulk.collect p ~column:0 (D.Bulk.Int64 D.Scalar.Int64) C.Non_null
let load a ~ids ~names ~ages ~valid =
  D.Table.append_columns a D.Bulk.Columns.[ Int64 (D.Scalar.Int64, ids);
    Strings (D.Scalar.String, names); Nullable (Int32 (D.Scalar.Int32, ages), valid) ]
```

Typed rows and `Table.append` use the same native paths internally.

Against the official Python and Rust bindings, reading 1M rows of two BIGINT
columns (one with NULLs):

| Path | Time |
|---|---|
| Python `fetchnumpy` | 63 ms |
| `duckdb-rs` `query_arrow` | 66 ms |
| duckdb.ml column views | 68 ms |
| duckdb.ml typed rows | 89 ms |
| `duckdb-rs` typed rows (`get::<i64>`) | 111 ms |
| Python `fetchall` | 485 ms |

Column views are level with numpy and Arrow, not faster. Typed rows beat
duckdb-rs's row API. All bindings were measured on one DuckDB thread
(`SET threads=1`; Python and Rust default to one per core), pinned to one core,
on DuckDB 1.5.5 in October 2026. The method, workloads and scripts are in
[performance](docs/design/performance.md).

## Documentation

- [Architecture](docs/architecture.md): the layers, modes, errors and adapters.
- [Core redesign](docs/design/core-redesign.md): design decisions, verified compiler facts and the roadmap.
- [Native dependencies](docs/native-dependency.md) and [development](docs/development.md).

## Building

For a provisioned checkout:

```sh
./tools/run build @all
./tools/run runtest --force
./tools/run exec examples/synchronous.exe
./tools/run exec examples/asynchronous.exe
./tools/run exec examples/eio.exe
./tools/run exec examples/sql.exe
bash test/install_adapters_smoke.sh
```

`python3 tools/bootstrap.py --install` provisions the project-local switch
and vendors [Hegel](https://github.com/hegeldev/hegel-ocaml) (pinned,
checksummed) into `vendor/hegel` for the property tests in
[`test/property`](test/property), which `runtest` runs at 100 cases each;
`PROPERTY_CASES=1000 ./tools/run runtest --force` searches further. They
never download anything: `tools/run` points Hegel at the vendored engine.

Every database is opened with DuckDB's `compressed_materialization`
optimizer disabled: in DuckDB 1.5.5 it bakes prepare-time statistics into a
plan, and the cached prepared statements this library reuses then return
corrupted values once the data changes
([property tests](docs/design/property-tests.md#failures-found)).

## Scope and roadmap

Local DuckDB databases and typed local Parquet reads and exports are
supported. Remote storage and credentials are out of scope. Done: the
performance work (columnar bulk reads, unboxed numbers, allocation-free
decoding; see [performance](docs/design/performance.md)) and the typed SQL
layer ([typed SQL](docs/design/typed-sql.md), with joins, subqueries and set
operations: [query composition](docs/design/query-composition.md)), schema declarations with
constraints ([schema](docs/design/schema.md)) and versioned migrations
([migrations](docs/design/migrations.md)). See the [core redesign](docs/design/core-redesign.md) note.
