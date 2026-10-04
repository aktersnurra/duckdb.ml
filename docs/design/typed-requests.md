# Typed requests (design note)

Status: approved and implemented (Phase 2, on top of `refactor/composable-core`
at `7d8eafbe`). [Implementation notes](#implementation-notes) lists where the
implementation differs from this proposal.

A throwaway prototype of `Codec`/`Fields`/`Args`/`Request`/`Table.Columns`
(stub bodies, the signatures below) was compiled with the project-local OxCaml
(`_opam/bin/ocamlc`). Its positive file was accepted. Fixtures F1, F2, F4–F7,
F9–F13, F15 and F16 were each rejected, and the "expected error contains"
column quotes those compiler messages. F3, F8, F14 and F17–F21 are not
prototyped yet.

## Goal and layers

| Layer | What it is | Status |
|---|---|---|
| L0 | Scoped resources, raw SQL, `bind`/`column` checked against engine types at run time, `Row.t` decoders, `cell` appender rows | exists, unchanged |
| L1 | Request values: SQL text + typed parameter list + typed row list + multiplicity phantom. Prepared-statement cache owned by the connection. Backend-generic `CONNECTION` signature with sync, Async and Eio instances | proposed |
| L2 | Typed table declarations: typed appender rows (no `cell`), a typed `SELECT` of the declared columns, typed `INSERT`, checked against DuckDB catalog metadata when used | proposed |
| L3 | GADT SQL expression DSL | out of scope (`docs/architecture.md` excludes a SQL DSL; at most a separate optional `duckdb-query` package) |

L1 and L2 are purely additive: no existing value, type or constructor in
`duckdb.mli`, `duckdb_async.mli`, `duckdb_eio.mli` or `duckdb_worker.mli`
changes. In particular `Duckdb.error`, `Duckdb_async.error` and
`Duckdb_eio.error` get no new constructors (that would break exhaustive
matches such as `examples/synchronous.ml`'s `error_name`). The new layers have
their own error type instead (see [Errors](#errors)).

## Static guarantees and what stays dynamic

| Property | Enforced by | Proof |
|---|---|---|
| `find` needs exactly-one, `find_opt` at most one, `exec` zero rows | multiplicity phantom (polymorphic-variant bound) | compile-failure fixtures F1–F4 |
| Parameter arity and per-position OCaml type | `'params` index shared by `Fields.t` and `Args.t` | F5–F8 |
| NULL only where declared nullable | `Codec.nullable` changes `'a` to `'a option` | F9 |
| No `nullable (nullable _)`; custom codecs never see NULL | nullability phantom on `Codec.t` | F10, F11 |
| Row constructor matches declared columns (types, and too few arguments) | `'fn` index of `Fields.t` | F12, F13 |
| Requests/tables/codecs cannot be forged or inspected | abstract types, no exposed constructors | F14 |
| Appended rows match the declared table | `'columns` index of `Table.t` | F15–F18 |
| Transaction-only instance is not a connection instance | distinct `t` types | F19 |
| Adapter instances do not accept raw core owners | abstract `t` | F20, F21 |
| Engine parameter types / result column types match the declaration | **runtime**, at first prepare, rechecked at execution | R1–R4 |
| Exactly one / at most one row | **runtime**, `Row_count` | R5, R6 |
| Declared table matches the catalog (names, types, order, count) | **runtime**, at appender open / first prepare | R7–R9 |
| Custom codec conversion succeeds | **runtime**, `Encode_rejected` / `Decode_rejected` | R10, R11 |

Not guaranteed, by design or because OCaml cannot express it:

- A row constructor with *more* arguments than columns (`~row:(fun a b c -> ...)`
  for two columns) type checks: the row type becomes a function. This is
  harmless (each row decodes to a closure) but not rejected.
- `exec` does not inspect the statement's result. DuckDB `INSERT` returns a
  one-column `Count` result, so "zero rows" means "nothing is decoded", as in
  L0 `execute`.
- `find_opt`/`collect` accept an `exec` request (row type `unit`), as in
  Caqti. This is harmless and keeps the bounds simple.

## Design decisions

### One heterogeneous list, three indices

The handover sketched `('f, 'r) t` with a curried index. That works for rows,
but parameters run into a problem. A request is stored as a value, and its
parameter list would need to stay polymorphic in `'r` (`(unit, error) result`
for sync, `... Deferred.t` for Async), which OCaml cannot express without
higher kinds. Fixing `'r := unit` also fails for L2: a table's columns must
drive both the curried row decoder (ending in `'row`) and the insert/append
parameters, and no type function relates `int64 -> string -> 'row` to
`int64 -> string -> unit`.

The fix is to add a type-level list index alongside the curried one:

```ocaml
type ('list, 'fn, 'result) t =
  | [] : (unit, 'result, 'result) t
  | (::) : ('a, _) Codec.t * ('list, 'fn, 'result) t
      -> ('a * 'list, 'a -> 'fn, 'result) t
```

- Parameters are identified by `'list` alone. Callers supply values as a flat
  heterogeneous list `Args.[42L; "text"] : (int64 * (string * unit)) Args.t`.
  Arity and types are checked, there is no tuple-arity limit, and no nested
  pairs appear in values.
- Rows decode through `'fn` straight into a curried constructor
  (`~row:(fun value note -> { value; note })`, or `fun a b -> (a, b)` for flat
  tuples).
- A table keeps `'list` for appending and inserting and `'fn` for decoding,
  derived from one column list.

The nested pair `int64 * (string * unit)` appears only as a type index, and
therefore in compiler messages. That readability cost is accepted. `Row.t`
stays as it is for compatibility.

### Multiplicity

Caqti's encoding, which makes illegal uses a type error with no runtime
dispatch:

```ocaml
type zero = [ `Zero ]
type one = [ `One ]
type zero_or_one = [ `Zero | `One ]
type many = [ `Zero | `One | `Many ]
(* exec: [< `Zero]   find: [< `One]   find_opt: [< `Zero | `One]   collect/fold: any *)
```

### Codecs

`('a, 'nullability) Codec.t` is abstract. The shorthands (`int64`, `string`,
...) cover every `Scalar.t` witness. `nullable` accepts only `non_null` and
returns `nullable`, so `'a option option` cannot be declared. `custom` maps a
`non_null` codec, so a custom decoder never receives NULL; write
`nullable (custom ...)`. `of_field` lifts an existing `Scalar.field` for
interop.

### Validation at first prepare

When a request is first prepared on a connection:

1. The engine parameter count must equal the declared count
   (`Parameter_count`). Each known engine parameter type must equal the
   declared base witness. Unresolved `ANY`/`INVALID` accepts the declaration,
   with the same rule as L0 `bind`.
2. Result columns, from `duckdb_prepared_statement_column_type` (already behind
   `F.prepared_column_types`): the count must equal the declared row count, and
   each resolved type must match. Unresolved types are deferred.
3. At execution, the existing L0 result-schema check runs again (it already
   runs before fetching, even for empty results) and catches anything deferred.

The validated plan is stored with the cache entry, so later executions skip
steps 1 and 2.

### Prepared-statement cache

- Owned by the connection, keyed by the request's identity (a unique id
  assigned at construction), not by SQL text. Two requests with the same text
  and different declarations never share an entry.
- Cached statements are internal children that do **not** count as
  `Live_children`. `close_connection` and `with_connection` close them first,
  then the connection. A cached statement never has a live result between
  calls.
- `~oneshot:true` prepares, executes and closes, without touching the cache.
  Use it for dynamically built SQL.
- Inside `with_transaction`, the transaction-instance operations execute the
  connection-owned cached statement under the transaction's admission. This
  needs one new internal Query path (`execute_cached`); the public L0 rule that
  transaction-prepared statements are revoked at settlement is unchanged.
- Bounded by a per-connection LRU, default 64 entries, set with
  `Config.create ?statement_cache` (0 disables caching; negative values are
  `Invalid_configuration`). Eviction closes the evicted native statement.
- Schema changes are detected with a schema epoch, not by re-preparing (see
  below).

### Schema epoch (replaces per-execution re-prepare)

Today L0 `execute_prepared` prepares the SQL a second time on every execution
to check that the engine's parameter types still equal those seen at
preparation (`Parameter_schema_changed`). Without that check, a schema change
could make DuckDB silently cast a bound value to a different type. The check
costs one full parse/bind per execution, which would cancel most of the
cache's benefit.

The cheaper rule: parameter and column types can only change through a
schema-changing statement, and every statement already passes the single C
allow-list (`duckdb_ml_allowed_statement`), whose kind is known before
execution. Of the allowed kinds, only `CREATE`, `ALTER` and `DROP` change
schemas. (`ATTACH`, `SET`, `COPY FROM DATABASE`, `PRAGMA`-with-effects, SQL
`PREPARE` and transaction control are all rejected today.)

- A process-wide atomic **schema epoch** (C, `Duckdb_ffi.schema_epoch`)
  advances *before and after* every `CREATE`/`ALTER`/`DROP` execution, and when
  a transaction that ran one commits or rolls back (`BEGIN` clears that
  per-connection flag, because autocommit DDL already advanced afterwards).
- A prepared statement records the epoch only from a validation in a fresh
  snapshot, meaning outside any explicit transaction, and only if the epoch
  was equal before and after that validation. Statements prepared inside an
  explicit transaction never record an epoch, so they always re-check.
- At execution: a parameterless statement needs no check. Otherwise, if the
  epoch equals the recorded one, the re-prepare is skipped. DuckDB starts a
  snapshot lazily, at the first catalog access, which here is the execution
  itself. So after a skipped check, the epoch is read again after execution.
  If it moved (and not merely because this statement is itself DDL), the
  fresh re-prepare runs in that same snapshot before anything is published. A
  mismatch returns `Parameter_schema_changed`, and the snapshot owner rolls
  back.
- Soundness: every schema change advances the epoch before it runs and again
  after it becomes visible (autocommit end, or settlement). So an unchanged
  epoch across [validation] and across [check, execution] means no change
  became visible in either window. Another *process* cannot change the
  schema: DuckDB locks a read-write file exclusively, and read-only handles
  cannot run DDL. Native code that bypasses `duckdb` through `duckdb-ffi` is
  outside the safe API, as today.
- This is an internal change in `Query`. It applies to L0 `execute_prepared`
  too, with the same documented outcome and no interface change, so L0 also
  gets faster. Implemented first (step A): `test/test_schema_epoch.ml` covers
  the epoch rules and the skip. `test_query_concurrency` races DDL against the
  skip path, and disabling the post-execution re-check turns it red.
- Adapters: Async and Eio retire the connection after every typed request,
  which discards the cache. The adapter instances therefore always behave as
  oneshot until that retirement policy changes. Changing it is out of scope.

### Errors

```ocaml
type context = Query of string | Table of { schema : string; name : string }
type cause =
  | Core of Duckdb.error                    (* includes Data_error type/column mismatches *)
  | Parameter_count of { expected : int; actual : int }
  | Row_count of { expected : [ `One | `Zero_or_one ]; actual : [ `Zero | `More_than_one ] }
  | Unknown_column of { name : string }      (* declared, not in the catalog *)
  | Missing_column of { name : string }      (* omitted, catalog has no default *)
  | Encode_rejected of { index : int; reason : Base.Error.t }
  | Decode_rejected of { column : int; row : int; reason : Base.Error.t }
  | Rollback_failed of { primary : request_error; rollback : Duckdb.error }
and request_error = { context : context; cause : cause }
```

Every error names its SQL text (or table) and stays a named ADT. Because the
core scopes (`with_transaction`, `with_appender`) are fixed to
`Duckdb.error`, the request layer provides its own `with_transaction`. It
reuses the core scope internally, via an error-injection parameter on the
private `Resource.with_transaction`, so rollback, poisoning and revocation
behave identically.

## Interfaces

### Additions to `lib/duckdb/duckdb.mli`

```ocaml
(* In Config: one new optional argument; everything else unchanged. *)
val create : ?threads:int -> ?memory_limit_bytes:int -> ?statement_cache:int -> ?access:access ->
  storage -> (t, error) result

module Codec : sig
  type non_null
  type nullable
  type ('a, 'nullability) t
  (** Shorthands; included by [Fields] and [Table.Columns] for list literals. *)
  module Values : sig
    val bool : (bool, non_null) t
    val int8 : (int, non_null) t
    val int16 : (int, non_null) t
    val int32 : (int32, non_null) t
    val int64 : (int64, non_null) t
    val float32 : (float, non_null) t
    val float64 : (float, non_null) t
    val string : (string, non_null) t
    val blob : (string, non_null) t
    val date : (int32, non_null) t
    val timestamp_s : (int64, non_null) t
    val timestamp_ms : (int64, non_null) t
    val timestamp_us : (int64, non_null) t
    val timestamp_ns : (int64, non_null) t
    val timestamp_tz : (int64, non_null) t
    val of_scalar : 'a Scalar.t -> ('a, non_null) t

    (** NULL is [None]. Only a non-null codec can be made nullable. *)
    val nullable : ('a, non_null) t -> ('a option, nullable) t

    (** Encoding runs before binding/appending; decoding runs after the base value
        is read. [reason] is reported in [Encode_rejected]/[Decode_rejected]. *)
    val custom : encode:('a -> 'b Base.Or_error.t) -> decode:('b -> 'a Base.Or_error.t) ->
      ('b, non_null) t -> ('a, non_null) t
  end
end

(** Declared parameter or result columns. [Fields.[int64; nullable string]]. *)
module Fields : sig
  include module type of Codec.Values
  type ('list, 'fn, 'result) t =
    | [] : (unit, 'result, 'result) t
    | (::) : ('a, _) Codec.t * ('list, 'fn, 'result) t -> ('a * 'list, 'a -> 'fn, 'result) t
end

(** Parameter values or appended rows. [Args.[42L; Some "x"]]. *)
module Args : sig
  type 'list t = [] : unit t | (::) : 'a * 'list t -> ('a * 'list) t
end

module Request : sig
  type zero = [ `Zero ]
  type one = [ `One ]
  type zero_or_one = [ `Zero | `One ]
  type many = [ `Zero | `One | `Many ]

  (** SQL text, typed parameters, typed rows, multiplicity. Pure data: safe to
      share across connections, workers and adapters. *)
  type ('params, 'row, 'multiplicity) t

  (** [oneshot] (default false) bypasses the connection statement cache. *)
  val exec : ?oneshot:bool -> ('params, _, _) Fields.t -> string -> ('params, unit, zero) t
  val one : ?oneshot:bool -> ('params, _, _) Fields.t -> (_, 'fn, 'row) Fields.t -> row:'fn ->
    string -> ('params, 'row, one) t
  val zero_or_one : ?oneshot:bool -> ('params, _, _) Fields.t -> (_, 'fn, 'row) Fields.t -> row:'fn ->
    string -> ('params, 'row, zero_or_one) t
  val many : ?oneshot:bool -> ('params, _, _) Fields.t -> (_, 'fn, 'row) Fields.t -> row:'fn ->
    string -> ('params, 'row, many) t
  val query : (_, _, _) t -> string
  val query_of_context : context -> string

  type context = Query of string | Table of { schema : string; name : string }
  type cause =
    | Core of error
    | Parameter_count of { expected : int; actual : int }
    | Row_count of { expected : [ `One | `Zero_or_one ]; actual : [ `Zero | `More_than_one ] }
    | Unknown_column of { name : string }
    | Missing_column of { name : string }
    | Encode_rejected of { index : int; reason : Base.Error.t }
    | Decode_rejected of { column : int; row : int; reason : Base.Error.t }
    | Rollback_failed of { primary : request_error; rollback : error }
  and request_error = { context : context; cause : cause }

  (** Operations over one synchronous owner, or one adapter pool. *)
  module type QUERY = sig
    type owner
    type error
    type 'a future
    val exec : owner -> ('params, unit, [< `Zero ]) t -> 'params Args.t -> (unit, error) result future
    val find : owner -> ('params, 'row, [< `One ]) t -> 'params Args.t -> ('row, error) result future
    val find_opt : owner -> ('params, 'row, [< `Zero | `One ]) t -> 'params Args.t ->
      ('row option, error) result future
    val collect : owner -> ('params, 'row, [< `Zero | `One | `Many ]) t -> 'params Args.t ->
      ('row list, error) result future

    (** [f] runs synchronously on the owning thread/worker, as in L0 [fold_rows]. *)
    val fold : owner -> ('params, 'row, [< `Zero | `One | `Many ]) t -> 'params Args.t ->
      init:'a -> f:('row -> 'a -> ('a step, request_error) result) -> ('a, error) result future
  end

  module type CONNECTION = sig
    include QUERY

    (** Same semantics as core [with_transaction]; the callback is synchronous. *)
    val with_transaction : owner -> f:(transaction -> ('a, request_error) result) -> ('a, error) result future

    (** Complete transaction + typed appender lifecycle, as adapter [ingest]. *)
    val ingest : owner -> ('columns, _) Table.t -> 'columns Args.t list list -> flush:bool ->
      (unit, error) result future
  end

  module Connection : CONNECTION
    with type owner = connection and type error = request_error and type 'a future = 'a
  module Transaction : QUERY
    with type owner = transaction and type error = request_error and type 'a future = 'a
end

(** L2. A declared table: name, ordered column names and codecs, row decoder. *)
module Table : sig
  type ('columns, 'row) t
  module Columns : sig
    include module type of Codec.Values
    type ('list, 'fn, 'result) t =
      | [] : (unit, 'result, 'result) t
      | (::) : (string * ('a, _) Codec.t) * ('list, 'fn, 'result) t -> ('a * 'list, 'a -> 'fn, 'result) t
  end

  (** Names must be NUL-free; they are quoted, never spliced unquoted. Columns
      are matched to the catalog by name, in any order; omitted catalog columns
      must have a default. Checked when an appender opens or a generated
      request is first prepared. *)
  val declare : ?schema:string -> string -> ('columns, 'fn, 'row) Columns.t -> row:'fn -> ('columns, 'row) t

  (** [SELECT "c1", ... FROM "schema"."table"] with the declared decoder. *)
  val select : ('columns, 'row) t -> (unit, 'row, Request.many) Request.t
  val insert : ('columns, _) t -> ('columns, unit, Request.zero) Request.t

  type ('columns, 'row) appender

  (** Opens the core appender, then checks catalog names (table description) and
      appender column types against the declaration before any row is accepted. *)
  val with_appender : connection -> ('columns, 'row) t ->
    f:(('columns, 'row) appender -> ('a, Request.request_error) result) -> ('a, Request.request_error) result
  val with_appender_transaction : transaction -> ('columns, 'row) t ->
    f:(('columns, 'row) appender -> ('a, Request.request_error) result) -> ('a, Request.request_error) result

  (** Same batch/poisoning semantics as [append_rows]. *)
  val append : ('columns, _) appender -> 'columns Args.t list -> (unit, Request.request_error) result
  val flush : (_, _) appender -> (unit, Request.request_error) result
end

(* In Parquet (Q6), core only; same per-file schema rules as fold_rows. *)
val fold : connection -> path list -> (_, 'fn, 'row) Fields.t -> row:'fn -> init:'a ->
  f:('row -> 'a -> ('a step, Request.request_error) result) -> ('a, Request.request_error) result
val fold_table : connection -> path list -> (_, 'row) Table.t -> init:'a ->
  f:('row -> 'a -> ('a step, Request.request_error) result) -> ('a, Request.request_error) result
```

(`Request.Connection.ingest` and `Table` are mutually referenced. In the real
`.mli`, `Table` is declared before `Request`'s `CONNECTION`, with the error
types in a small `Request_error` module that both use. The order above is
for reading.)

### Additions to `lib/worker/duckdb_worker.mli` (`module type S`)

```ocaml
val request_exec : slot -> Duckdb.Bridge.request -> ('p, unit, [< `Zero ]) Duckdb.Request.t ->
  'p Duckdb.Args.t -> (unit, Duckdb.Request.request_error) result
val request_find_opt : ...   (* one per QUERY operation, same shape *)
val request_fold : slot -> Duckdb.Bridge.request -> ('p, 'row, _) Duckdb.Request.t -> 'p Duckdb.Args.t ->
  init:'a -> f:('row -> 'a -> ('a Duckdb.step, Duckdb.Request.request_error) result) ->
  ('a, Duckdb.Request.request_error) result
val request_transaction : slot -> Duckdb.Bridge.request ->
  f:(Duckdb.transaction -> ('a, Duckdb.Request.request_error) result) -> ('a, Duckdb.Request.request_error) result
val table_ingest : slot -> Duckdb.Bridge.request -> ('c, _) Duckdb.Table.t -> 'c Duckdb.Args.t list list ->
  flush:bool -> (unit, Duckdb.Request.request_error) result
```

`Bridge.run` is fixed to `Duckdb.error`. Each worker operation therefore runs
`Bridge.run ~f:(fun c -> Ok (Request.Connection.op c ...))` and flattens the
result. A cancellation that wins against an L1 error leaves the L1 error in
place: Bridge only replaces otherwise successful outcomes, so the documented
rule is unchanged.

### Additions to adapters

```ocaml
(* duckdb_async.mli *)
module Request : sig
  type error = Adapter of failure | Request of Duckdb.Request.request_error
  include Duckdb.Request.CONNECTION
    with type owner = t and type error := error and type 'a future = 'a Async.Deferred.t

  (* Q4: cancellable forms reuse the existing request/completion/cancel. *)
  val submit_exec : t -> ('p, unit, [< `Zero ]) Duckdb.Request.t -> 'p Duckdb.Args.t ->
    ((unit, Duckdb.Request.request_error) result request, Duckdb_async.error) result
  val submit_find : t -> ('p, 'row, [< `One ]) Duckdb.Request.t -> 'p Duckdb.Args.t ->
    (('row, Duckdb.Request.request_error) result request, Duckdb_async.error) result
  (* ... submit_find_opt, submit_collect, submit_fold, submit_ingest likewise *)
end

(* duckdb_eio.mli *)
module Request : sig
  type nonrec error = Adapter of error | Request of Duckdb.Request.request_error
  include Duckdb.Request.CONNECTION with type owner = t and type error := error and type 'a future = 'a
end
```

Admission, queueing, retirement, shutdown and Eio cancellation semantics are
those of the existing typed operations (`query`/`fold_rows`/`ingest`). The
generic Async instance waits for completion and cannot be cancelled; the
`submit_*` forms can (Q4).

## Compile-failure fixtures

New directory `test/request_compile/`, driven by `test/check_request_types.sh`
using the same pattern as `check_query_modes.sh`: compile `duckdb.mli`, then
`positive.ml`; each `*.ml.fail` must be rejected, and its output must contain
the listed text. Adapter fixtures go in the existing adapter compile
directories.

| # | Fixture | Body (abridged) | Expected error contains |
|---|---|---|---|
| F1 | `find_zero` | `Connection.find c (exec Fields.[] "...") Args.[]` | `` `Zero `` / `` `One `` |
| F2 | `find_many` | `find c (many ...)` | `` `Many `` |
| F3 | `find_opt_many` | `find_opt c (many ...)` | `` `Many `` |
| F4 | `exec_one` | `exec c (one ... ~row:Fn.id ...)` | `` `One `` |
| F5 | `param_type` | `exec c ins Args.[42L; 7]` (ins: `[int64; string]`) | `"int"`, `"string"` |
| F6 | `param_missing` | `Args.[42L]` | `"unit Args.t"`, `string * unit` |
| F7 | `param_extra` | `Args.[42L; "x"; true]` | `is not compatible with type "unit"` |
| F8 | `param_tuple` | `Args.[(42L, "x")]` | `int64 * string` |
| F9 | `null_required` | `Args.[None]` for `[int64]` | `option`, `int64` |
| F10 | `nested_nullable` | `nullable (nullable int64)` | `Codec.nullable`, `Codec.non_null` |
| F11 | `custom_nullable_base` | `custom ~encode ~decode (nullable int64)` | `Codec.nullable`, `Codec.non_null` |
| F12 | `row_type` | `one Fields.[] Fields.[int64] ~row:(fun (s : string) -> s)` | `string`, `int64` |
| F13 | `row_arity_short` | `~row:(fun v -> v)` for `[int64; string]` | `"string -> 'a"` |
| F14 | `forge` | `Request.{ sql = "x" }` / `Codec.Int64` | `Unbound record field` / `Unbound constructor` |
| F15 | `append_type` | `Table.append a [Args.["x"; 1L]]` for `(int64, string)` | `string`, `int64` |
| F16 | `append_arity` | `Table.append a [Args.[1L]]` | `"unit Args.t"`, `string * unit` |
| F17 | `append_other_table` | appender of `t1` with rows of `t2` (different types) | `Args.t` |
| F18 | `append_cells` | `Table.append a [[Cell (...)]]` | `Duckdb.cell` |
| F19 | `tx_instance_on_connection` | `Request.Transaction.exec connection ...` | `Duckdb.connection`, `Duckdb.transaction` |
| F20 | `async_raw_connection` | `Duckdb_async.Request.find (c : Duckdb.connection) ...` | `Duckdb_async.t` |
| F21 | `eio_future_as_deferred` | `Duckdb_eio.Request.find p r a >>= ...` | `Deferred.t` |

`positive.ml` exercises every accepted form: each multiplicity with each of
the operations it allows, `nullable`, `custom`, `nullable (custom ...)`,
curried and tuple row constructors, `Table.select`/`insert`/`append`, and both
sync instances.

## Runtime tests (dynamic checks)

| # | Case | Expected |
|---|---|---|
| R1 | declared `int64`, engine `INTEGER` parameter | `Core (Data_error (Type_mismatch _))` on first prepare; nothing executed |
| R2 | declared 2 params, SQL has 3 | `Parameter_count {expected = 2; actual = 3}` |
| R3 | declared row `[int64]`, `SELECT 1::INT, 2` | `Core (Data_error (Column_count _))` at prepare |
| R4 | `ALTER TABLE` (same or other connection) between two executions of a cached request | epoch bumped → fresh re-check → `Parameter_schema_changed` or result schema mismatch; entry evicted. Unchanged epoch → no re-prepare (native prepare count via hooks). Mutation: drop the bump → R4 red |
| R5 | `find` on 0 / 2 rows | `Row_count` with `` `Zero `` / `` `More_than_one ``; result closed |
| R6 | `find_opt` on 2 rows | `Row_count {expected = `Zero_or_one; ...}` |
| R7 | table declared `(value, note)`, catalog `(note, value)` | accepted; rows land in the right columns. Declared `(valu)` → `Unknown_column` before any append |
| R8 | declared type differs from catalog | `Core (Data_error (Type_mismatch _))` at open |
| R9 | declared 2 of 3 columns; third has a default / has none | default applied / `Missing_column` at open |
| R10 | custom encode rejects | `Encode_rejected`; nothing bound; transaction poisoned like an L0 validation error |
| R11 | custom decode rejects | `Decode_rejected {column; row; _}`; result closed |
| R12 | cache: same request twice → one entry; `~oneshot` → zero entries; `close_connection` with cached statements succeeds and closes them (native live counts via existing hooks) | |
| R13 | every error carries `context = Query sql` / `Table {...}` | |
| R14 | Async/Eio instances: the existing queue/cancel/shutdown cases rerun through the generic instance | |

## Example: `examples/synchronous.ml`

Before (current, abridged to the relevant parts):

```ocaml
require "create example table" (D.execute connection "create table example(value bigint, note varchar)");
require "run insert transaction" (D.with_transaction connection ~f:(fun transaction ->
  D.with_prepared_transaction transaction "insert into example values (?, ?)" ~f:(fun statement ->
    require "bind integer parameter" (D.bind statement 1 (D.Scalar.Required D.Scalar.Int64) 42L);
    require "bind string parameter" (D.bind statement 2 (D.Scalar.Required D.Scalar.String) "owned\000text");
    D.close_result (require "execute prepared insert" (D.execute_prepared statement)))));
require "append owned rows" (D.with_appender connection "example" ~f:(fun appender ->
  D.append_rows appender [[D.Cell (D.Scalar.Required D.Scalar.Int64, 9007199254740993L);
    D.Cell (D.Scalar.Required D.Scalar.String, "bulk\000row")]]));
...
let decoder = D.Row.(Map (Column (D.Scalar.Required D.Scalar.Int64,
  Column (D.Scalar.Required D.Scalar.String, Empty)), fun (value, (note, ())) -> value, note)) in
D.Parquet.fold_rows connection [path] decoder ~init:[] ~f:(fun row rows -> Ok (D.Continue (row :: rows)))
```

After:

```ocaml
module R = D.Request

let example = D.Table.(declare "example" Columns.[ "value", int64; "note", string ]
  ~row:(fun value note -> value, note))
let create_example = R.exec D.Fields.[] "create table example(value bigint, note varchar)"
let insert_example = D.Table.insert example
let read_back = R.many D.Fields.[] D.Fields.[int64; string] ~row:(fun value note -> value, note)
  "select value, note from example order by value"

let request_error_name (e : R.request_error) = match e.cause with
  | R.Core core -> error_name core | Parameter_count _ -> "Parameter_count" | Row_count _ -> "Row_count"
  | Unknown_column _ -> "Unknown_column" | Missing_column _ -> "Missing_column"
  | Encode_rejected _ -> "Encode_rejected"
  | Decode_rejected _ -> "Decode_rejected" | Rollback_failed _ -> "Rollback_failed"
let require_request label = function
  | Ok value -> value
  | Error e -> failwith (label ^ ": " ^ request_error_name e ^ " in " ^ R.query_of_context e.context)

(* inside with_connection: *)
require_request "create example table" (R.Connection.exec connection create_example D.Args.[]);
require_request "run insert transaction" (R.Connection.with_transaction connection ~f:(fun tx ->
  R.Transaction.exec tx insert_example D.Args.[42L; "owned\000text"]));
require_request "append owned rows" (D.Table.with_appender connection example ~f:(fun appender ->
  D.Table.append appender [D.Args.[9007199254740993L; "bulk\000row"]]));
let rows = require_request "read back" (R.Connection.collect connection read_back D.Args.[]) in
(* Parquet export unchanged; reading back uses the declared table (Q6). *)
D.Parquet.fold_table connection [path] example ~init:[] ~f:(fun row rows -> Ok (D.Continue (row :: rows)))
```

The existing `error_name` is unchanged: the new causes live in
`Request.cause`.

## Implementation notes

Where the implementation differs from the proposal above, or settles a
detail the proposal left open:

- **Interface layout.** The abstract table type lives in `Request` as
  `('columns, 'row) Request.table`, and `Table.t` is an alias for it. This
  avoids a dependency cycle between `Request.CONNECTION.ingest` and `Table`.
  The typed appender is implemented in `request.ml` for the same reason.
- **Errors.** `context` has an extra `Transaction` case, for BEGIN/COMMIT of a
  request-layer transaction. `Request.Cleanup_exception of request_error * exn`
  retains a request error when the rollback cleanup that follows it raises. It
  is the counterpart of the core `Cleanup_exception`. `Resource.settle` and
  `combine` take the error-injection `outcome` needed for this.
- **Statement cache.** Bridge facades never cache (their children are revoked
  with the request), so adapter instances always prepare per call. Only the
  connection instance, outside explicit transactions, inserts entries. The
  transaction instance reuses a hit by lending the cached statement to the
  transaction for one operation; on a miss it prepares a one-off statement in
  the transaction. A failed post-execution schema check on a lent statement
  poisons the transaction. `Parameter_schema_changed` evicts the entry.
- **Schema epoch.** It advances before and after the DDL statement itself, and
  on COMMIT/ROLLBACK of a transaction that ran DDL (`BEGIN` clears the flag).
  The post-execution re-check is skipped for parameterless statements and for
  a statement that is itself DDL.
- **Catalog checks.** These read `duckdb_columns()` (name and whether a default
  exists) through a typed request in the appender's own transaction snapshot,
  instead of the `duckdb_table_description` API. One new C entry point
  (`appender_select_columns`) applies a declared subset or order through
  `duckdb_appender_add_column`. A nullable column without a default must be
  declared; `DEFAULT NULL` allows omitting it.
- **Codec rejections in `Table.append`** reject the whole batch before any
  native row and do not poison the appender. Core validation failures in
  `append_rows` still do.
- **Adapters.** Each adapter's `Request` exposes its operations with concrete
  result types. The backend-generic instance is `Request.Generic`; with an
  alias at `Request.future`, compiler messages printed `Async.Deferred.t` as
  `Duckdb_async.Request.future`, which the install smoke test caught.
- **Base in the public interface.** `Base.Error.t` and `Base.Or_error.t` appear
  in `duckdb.mli`, so the standalone interface drivers now add Base's include
  directory.
- **Fixtures.** F1–F19 are in `test/request_compile`
  (`test/check_request_types.sh`; F14 is split into `forge_request` and
  `forge_codec`, giving 20). F20 is `test/async/compile/request_raw_connection`.
  Note that `test/async/check_interfaces.sh` is not wired into any Dune rule
  or CI step; that gap predates this work. F21 is
  `test/eio/compile/request_promise`: Eio results are not promises.
- **Runtime tests.** `test/test_request.ml` (R1–R6, R10–R13),
  `test/test_table.ml` (R7–R9, Parquet), `test/test_schema_epoch.ml`, and the
  lent-statement race in `test/test_query_concurrency.ml`.
  `test/async/typed_request_async.ml` and `test/eio/request_eio.ml` cover R14.

## Decisions

- **Q1. Parameter re-check.** Decided: replace the per-execution re-prepare
  with the schema epoch (above), for L0 and L1, in Phase 2.
- **Q2. Cache bound.** Decided: per-connection LRU, default 64, set with
  `Config.create ?statement_cache:int`. This is an additive optional argument:
  existing callers are unaffected.
- **Q3. Codec failures.** Decided: `Base.Or_error.t` from `custom`, carried as
  `reason : Base.Error.t`. No string payloads remain.
- **Q4. Async cancellation.** Recommended: provide both. The generic
  `Duckdb_async.Request` instance (`'a future = 'a Deferred.t`) serves
  backend-portable code and cannot be cancelled. Next to it, cancellable
  variants (`submit_find`, `submit_collect`, ...) return the *existing*
  `Duckdb_async.request` type, with the request outcome as its payload,
  `(('row, request_error) result) request`, so the existing `completion` and
  `cancel` work unchanged. The generic instance is `submit` + `completion` +
  flattening. Eio needs nothing extra: cancelling the caller's fiber already
  cancels the work.
- **Q5. Adapter connection retirement.** Unchanged (out of scope). Adapter
  instances therefore don't benefit from the cache.
- **Q6. Parquet.** Recommended: add a core-only
  `Parquet.fold : connection -> path list -> (_, 'fn, 'row) Fields.t -> row:'fn -> ...`
  (and `Parquet.fold_table` for a declared table), built on the same fallible
  decoder. This removes the last nested-tuple `Row.t` from the example. Adapter
  Parquet folds keep `Row.t`; adapter siblings are added only if asked for.
- **Q7. Partial column sets.** Recommended: allow them. A declaration may name a
  subset of the catalog's columns in any order, matched by name (via
  `duckdb_appender_add_column` for appenders, and an explicit column list for
  `INSERT`). Every omitted catalog column must have a default
  (`duckdb_column_has_default`), otherwise the appender open fails with a new
  cause `Missing_column of { name : string }`. This supports the common table
  with an `id` sequence or a `created_at DEFAULT now()` column. `Table.select`
  reads only the declared columns.
