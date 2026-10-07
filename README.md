# duckdb.ml

[![Ubuntu CI](https://github.com/aktersnurra/duckdb.ml/actions/workflows/ubuntu.yml/badge.svg)](https://github.com/aktersnurra/duckdb.ml/actions/workflows/ubuntu.yml)

`duckdb.ml` is an OxCaml binding for DuckDB in which the type checker does the
bookkeeping. Parameters, rows and table columns are typed by GADTs. Handles
are `@ local` to their scope, so use-after-close cannot be written. Separately
installable `duckdb-async` and `duckdb-eio` adapters provide the same typed API
over connection pools.

It is full OxCaml, not upstream OCaml: it uses modes (`local`, `unique`,
`global`), modalities and `int8`/`int16`/`float32`.

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
  ~row:(fun id name age -> { id; name; age }))
let create = R.exec D.Fields.[] "CREATE TABLE users(id BIGINT, name VARCHAR, age INTEGER)"
let adults = R.many D.Fields.[int32] D.Fields.[int64; string] ~row:(fun id name -> (id, name))
  "SELECT id, name FROM users WHERE age >= ? ORDER BY id"

(* [c] is local to its scope: it cannot be stored, returned or captured. *)
let run (c @ local) =
  match R.Session.exec c create D.Args.[] with
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

Typed rows and `Table.append` use the same native paths internally. Numbers:
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
bash test/install_adapters_smoke.sh
```

## Scope and roadmap

Local DuckDB databases and typed local Parquet reads and exports are
supported. Remote storage and credentials are out of scope. Done: the
performance work (columnar bulk reads, unboxed numbers, allocation-free
decoding; see [performance](docs/design/performance.md)). Planned, in order: a
typed SQL layer built from GADT expressions, and schema declarations with
migrations. See the [core redesign](docs/design/core-redesign.md) note.
