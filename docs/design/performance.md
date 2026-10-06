# Performance (sub-project 1b)

Status: design approved, not yet implemented.

Sub-project 1 made the API type-safe; this note makes it fast. Three workloads,
in order of payoff: bulk analytic reads, typed rows, and ingest. The approach
is `[@@noalloc]` C externals that return unboxed values, views type-checked once
per chunk, and one C call per chunk for bulk copies. Raw unchecked loads from
OCaml (Bigarray proxies over vector memory, unsafe reads) were rejected: they
would put unsafe casts in the safe API.

## Baseline

AMD Ryzen 5 2600X, `taskset -c 0`, DuckDB v1.5.5 with one engine thread,
median of 10 after 2 warmups. Query, 1M rows:

```sql
SELECT i::BIGINT, CASE WHEN i % 10 = 0 THEN NULL ELSE i::BIGINT END
FROM range(1000000) t(i) ORDER BY i
```

| Path | Time | Minor words |
|---|---|---|
| Engine only (`sum(a)` computed in DuckDB) | 38 ms | — |
| duckdb.ml: engine + fetch, no decode (`Statement.execute`, best of 10) | 55.5 ms | — |
| Python `duckdb` `fetchnumpy` | 63 ms | — |
| Rust `duckdb-rs` `query_arrow` (+ sum of column 0) | 66 ms | — |
| Rust `duckdb-rs` rows, `get::<i64>`/`get::<Option<i64>>` (+ sum) | 111 ms | — |
| duckdb.ml: typed rows (`owned_rows`) | 280 ms | 63.2M |
| duckdb.ml: borrowed chunks (`Statement.column`) | 290 ms | 55.2M |
| Python `duckdb` `fetchall` (+ sum) | 485 ms | — |

Ingest of 1M rows × 2 BIGINT columns in 1,000-row batches through
`Table.append`: 566 ms (best of 5). Engine-only `INSERT … SELECT … range(1e6)`:
37.4 ms.

Python and Rust start one DuckDB thread per core by default. Pinned to one CPU,
that doubles their engine time (~74 ms), so their numbers above were measured
after `SET threads=1`. duckdb.ml defaults to one thread. Any published
comparison must state the thread count.

Reproduction: duckdb.ml numbers come from
`./tools/run exec -- python3 bench/run_benchmarks.py --rows 1000000 --warmups 2 --samples 10 --output-dir <dir>`.
Python used `duckdb==1.5.5` from pip in a scratch virtualenv. Rust used crate
`duckdb = "=1.10505.0"` built with
`DUCKDB_LIB_DIR=.deps/duckdb DUCKDB_INCLUDE_DIR=.deps/duckdb`, so it links the
same `libduckdb.so`. The scripts are in Appendix A.

### Where the time goes

Fetching costs 17 ms over the engine; decoding costs ~230 ms (~115 ns per
value, ~80% of the total). Per cell, today:

- `Borrowed_chunk.read` boxes the `int64#` the FFI already returns
  (`F.box_int64 (F.chunk_int64 …)`).
- Every access re-runs `check_type` and `column_count`.
- Identity codecs still allocate `Or_error.return`, then `Ok`, then `Some`.
- `Request.decode_row` applies the row function one argument at a time, which
  allocates a partial application per field per row.
- `Request.fold_decoded` runs a cancellation checkpoint per row.
- Ingest builds a 5-tuple per cell (`append_cell = int * bool * int64 * float * string`)
  in an array of arrays, validates with `Result.all`, then appends value by
  value.

## 1. Borrowed column views

A column view is a typed window onto one column of the current chunk. It is
type-checked once per chunk; after that every read is a bounds check and one
`[@@noalloc]` C call.

```ocaml
module Statement.Column : sig
  type ('a, 'n) t                      (* local to the chunk callback *)

  type _ nulls =
    | Non_null : Codec.non_null nulls
    | Nullable : Codec.nullable nulls

  val view : chunk @ local -> int -> 'a Scalar.t -> 'n nulls
             -> (('a, 'n) t, Error.t) result @ local
  val length : _ t @ local -> int

  (* Non-null views: total. [@zero_alloc]. *)
  val int64   : (int64,   Codec.non_null) t @ local -> int -> int64#
  val float   : (float,   Codec.non_null) t @ local -> int -> float#
  val int32   : (int32,   Codec.non_null) t @ local -> int -> int32#
  val float32 : (float32, Codec.non_null) t @ local -> int -> float32#
  val int16   : (int16,   Codec.non_null) t @ local -> int -> int16
  val int8    : (int8,    Codec.non_null) t @ local -> int -> int8
  val bool    : (bool,    Codec.non_null) t @ local -> int -> bool
  val string  : (string,  Codec.non_null) t @ local -> int -> string   (* owned copy *)

  (* Nullable views: the caller names what NULL means. [@zero_alloc]. *)
  val is_null    : (_, Codec.nullable) t @ local -> int -> bool
  val int64_or   : (int64,   Codec.nullable) t @ local -> default:int64# -> int -> int64#
  val float_or   : (float,   Codec.nullable) t @ local -> default:float# -> int -> float#
  val int32_or   : (int32,   Codec.nullable) t @ local -> default:int32# -> int -> int32#
  val float32_or : (float32, Codec.nullable) t @ local -> default:float32# -> int -> float32#
  val int16_or   : (int16,   Codec.nullable) t @ local -> default:int16 -> int -> int16
  val int8_or    : (int8,    Codec.nullable) t @ local -> default:int8 -> int -> int8
  val bool_or    : (bool,    Codec.nullable) t @ local -> default:bool -> int -> bool
  val string_opt : (string,  Codec.nullable) t @ local -> int -> string option
end
```

Semantics:

- The `'a` index comes from `Scalar.t`. `Timestamp_us : int64 Scalar.t`, so
  `Column.int64` reads timestamps and `Column.int32` reads dates. An accessor
  of the wrong type is a compile error.
- `Non_null` costs one check per chunk: free when DuckDB reports no validity
  mask, otherwise a word-at-a-time scan of the mask. A NULL fails the view with
  `Null { row }` (chunk-relative, as for `Statement.column`).
- Plain accessors exist only on non-null views and `is_null`/`_or` only on
  nullable views, so a silent zero or a forgotten NULL check is a compile
  error. Neither path raises or returns a `Result` per value.
- A wrong engine type is `Type_mismatch`; a bad column index is the existing
  index error. A row index outside `[0, length)` raises `Invalid_argument`,
  like `Array.get` (`[@zero_alloc]` permits allocation on raising paths).
- Views are local: they cannot escape the chunk callback.

Precedent: `duckdb-rs`'s row API returns a checked `Result` per value; its
Arrow API's `value(i)` returns an unspecified value at NULL slots and leaves
`is_null` to the caller. The phantom index gives us both speed and totality.

Deferred: an accessor returning value and validity together as an unboxed
tuple `#(bool * int64#)`. Not probed with `[@@noalloc]` externals yet.

## 2. Collect into Bigarrays

```ocaml
module Statement.Bulk : sig
  (* 'a is the view's type, 'k/'e the Bigarray element; dates and timestamps
     share int32/int64 and carry their scalar *)
  type ('a, 'k, 'e) kind =
    | Int64   : int64 Scalar.t -> (int64, int64, Bigarray.int64_elt) kind
    | Int32   : int32 Scalar.t -> (int32, int32, Bigarray.int32_elt) kind
    | Int16   : (int16, int, Bigarray.int16_signed_elt) kind
    | Int8    : (int8, int, Bigarray.int8_signed_elt) kind
    | Bool    : (bool, int, Bigarray.int8_unsigned_elt) kind   (* 0/1 bytes, as DuckDB stores them *)
    | Float64 : (float, float, Bigarray.float64_elt) kind
    | Float32 : (float32, float, Bigarray.float32_elt) kind

  type 'n validity =
    | All_valid : Codec.non_null validity
    | Mask : (int, Bigarray.int8_unsigned_elt, Bigarray.c_layout) Bigarray.Array1.t
             -> Codec.nullable validity                    (* 1 = valid, one byte per row *)

  type ('k, 'e, 'n) t =
    { data : ('k, 'e, Bigarray.c_layout) Bigarray.Array1.t; validity : 'n validity }

  val blit : ('a, _) Column.t @ local -> ('a, 'k, 'e) kind
             -> into:('k, 'e, Bigarray.c_layout) Bigarray.Array1.t -> pos:int -> unit
  val blit_validity : (_, Codec.nullable) Column.t @ local
             -> into:(int, Bigarray.int8_unsigned_elt, Bigarray.c_layout) Bigarray.Array1.t -> pos:int -> unit
end

module Statement : sig
  …
  val collect : prepared @ local -> column:int -> ('a, 'k, 'e) Bulk.kind -> 'n Column.nulls
                -> (('k, 'e, 'n) Bulk.t, Error.t) result

  type _ strings =
    | Strings : string array -> Codec.non_null strings
    | Strings_opt : string option array -> Codec.nullable strings
  val collect_strings : prepared @ local -> column:int -> 'n Column.nulls
                        -> ('n strings, Error.t) result
end
```

- `Bulk.blit` copies one chunk's column with one C call (`memcpy` from the
  DuckDB vector) and writes 0 at NULL slots, so the output is deterministic.
  `blit_validity` copies the validity as one byte per row. Both raise
  `Invalid_argument` if `into` is too short, and both are `[@zero_alloc]`.
  The kind is indexed by the view's type, so a mismatched kind is a compile
  error; for `Int64`/`Int32`, `collect` opens the view with the kind's scalar,
  so the engine type is checked once (`Type_mismatch`).
- `collect` executes the statement, folds its chunks and blits each one. The
  result grows by doubling and is returned as an `Array1.sub` (shared memory,
  no copy). If the materialized result's row count is exposed by the FFI, the
  plan allocates exactly once instead; the implementation plan checks this.
- Matching on `validity` of a non-null collect has the single case
  `All_valid`.
- Several columns in one pass: a `fold_chunks` with one `Bulk.blit` (and
  `blit_validity` for nullable columns) per column.
  A multi-column `collect` is not provided.
- Bigarray rather than OxCaml unboxed arrays (`int64# array`): off-heap, so
  large results cost the GC nothing; `memcpy`-compatible with DuckDB vectors;
  usable from Owl and other Bigarray consumers.

## 3. Fast typed rows (internal)

No API change. `Request`, `Table`, Parquet reads and both adapters share the
`Request` fold, so all of them get faster.

| Cost today | Change |
|---|---|
| Engine type and column count checked per cell | Opened once per chunk as `Column` views |
| Boxing, `Or_error.return` and `Ok` per cell | New `Identity` case in `Codec.plan` for base scalars without a custom decoder: read straight from the view. Custom codecs keep the `Or_error` path. |
| Partial application per field per row | Saturated application: for arities 1–8, the fold matches the `Fields` spine shape and calls `fn a b …` once. Matching `[f1; f2]` refines `'fn` to `a -> b -> 'r`. Longer rows fall back to the curried path. |
| NULL check per cell | Non-null fields use the per-chunk `Non_null` check; nullable fields read the validity bit and allocate `Some` only for non-NULL values |
| Cancellation checkpoint per row | One checkpoint per chunk (2,048 rows) |

What remains per row is what the caller asked for: the row value, boxed
`int64` fields, `Some` for nullable fields and the list cell for `collect`.
Errors are unchanged: request-level `Null { row }` stays absolute,
`Decode_rejected` still comes from custom codecs, `Type_mismatch` from schema
validation.

## 4. Ingest

### 4a. Row ingest (internal)

- The appender owns a reusable pool of 2,048-row DuckDB data chunks in C.
  Encoding writes straight into vector memory through `[@@noalloc]` externals
  taking unboxed arguments (`stage_int64 : appender -> int -> int -> int64# -> unit`,
  …) and sets validity bits for `None`. No tuples, no array of arrays.
- Batch atomicity is unchanged. The whole batch is staged; only after every
  value has encoded are the chunks handed to `duckdb_append_data_chunk`. On a
  codec rejection the staged chunks are cleared and the table is not touched.
- `Identity` plans skip `Or_error` here too.
- Engine failures poison the appender as today.

### 4b. Columnar `Table.append_columns`

```ocaml
module Bulk.Columns : sig
  type _ col =
    | Int64   : int64 Scalar.t * (int64, Bigarray.int64_elt, Bigarray.c_layout) Bigarray.Array1.t -> int64 col
    | Int32   : int32 Scalar.t * (int32, Bigarray.int32_elt, Bigarray.c_layout) Bigarray.Array1.t -> int32 col
    | Int16   : (int, Bigarray.int16_signed_elt, Bigarray.c_layout) Bigarray.Array1.t -> int16 col
    | Int8    : (int, Bigarray.int8_signed_elt, Bigarray.c_layout) Bigarray.Array1.t -> int8 col
    | Bool    : (int, Bigarray.int8_unsigned_elt, Bigarray.c_layout) Bigarray.Array1.t -> bool col
    | Float64 : (float, Bigarray.float64_elt, Bigarray.c_layout) Bigarray.Array1.t -> float col
    | Float32 : (float, Bigarray.float32_elt, Bigarray.c_layout) Bigarray.Array1.t -> float32 col
    | Strings : string array -> string col
    | Nullable : 'a col * (int, Bigarray.int8_unsigned_elt, Bigarray.c_layout) Bigarray.Array1.t
                 -> 'a option col
  type _ t = [] : unit t | (::) : 'a col * 'l t -> ('a * 'l) t
end

val Table.append_columns : ('columns, _) appender @ local -> 'columns Bulk.Columns.t
                           -> (unit, Error.t) result
```

Usage with the README's `users` table:

```ocaml
Table.append_columns a Bulk.Columns.[ Int64 (Int64, ids); Strings names; Nullable (Int32 (Int32, ages), valid) ]
```

- Compile time: missing, extra or reordered columns, a wrong element type, a
  NULL mask on a non-null column, and any column whose declared codec is custom
  (no constructor produces `user_id col`).
- Runtime, before any native work, reported as `Error.t`: unequal lengths
  across columns and masks, and an engine scalar that differs from the
  appender's catalog type (`Type_mismatch`).
- C: per 2,048-row slice, one `memcpy` per fixed-width column, validity built
  from the mask, then `duckdb_append_data_chunk`. Strings are copied per
  element; DuckDB must own them.
- Engine failures poison the appender exactly as `append` does.

## 5. Verification

### Correctness (TDD, existing suite)

- Column views: every scalar round-trips; `Non_null` over a chunk with a NULL
  fails with `Null { row }`; `_or` returns the default at NULL slots; index out
  of bounds raises; type mismatch; a result spanning a chunk boundary.
- Collect: equal to the typed-row path on the same query for every
  `Bulk.kind`, with and without NULLs, and for an empty result.
- Typed rows: the request, table, Parquet and adapter suites pass unchanged.
  New: arities 1, 8 and 9 (curried fallback); cancellation mid-result.
- Ingest: a codec rejection in a batch's last row leaves the table untouched;
  poisoning; `append_columns` with unequal lengths, a wrong engine scalar, and
  NULL masks.
- The new C stubs (vector copies, staging pool) run under the existing
  native-ffi ASan harness.

### Compile-time guarantees

- `-zero-alloc-check default` is added to `lib/duckdb`'s flags. The numeric
  accessors, `_or` accessors and `Bulk.blit` are `[@zero_alloc]`, so an
  allocation regression is a build failure.
- New rejection fixtures in `test/request_compile`: plain accessor on a
  nullable view; `is_null` on a non-null view; a view escaping its callback;
  `append_columns` with a missing column, a reordered column, a wrong element
  type, a NULL mask on a non-null column, and a custom-codec column.

### Benchmarks

The harness gains `column_views` (zero-alloc sum of both columns), `collect`
(both columns), `row_ingest` and `columnar_ingest`, each recording time,
`minor_words` and `major_words`. It sets `threads=1` and records it.

Targets are acceptance criteria for this sub-project. Time targets are not CI
gates (too noisy); allocation targets are deterministic and asserted by a
test.

| Path | Time | Allocation |
|---|---|---|
| Column views | ≤ 65 ms | 0 words per value (asserted) |
| Collect | ≤ 70 ms | O(1) OCaml words independent of row count (asserted) |
| Typed rows | ≤ 110 ms | ≤ 16 words per row |
| Row ingest | ≤ 190 ms | dominated by the caller's row values |
| Columnar ingest | ≤ 75 ms | O(1) OCaml words (asserted) |

### Docs

This note gets the measured results when implemented. README gains a short
"Fast paths" section and marks roadmap item 1b done; `CHANGELOG.md` records the
new API. The "Notes for sub-project 1b" section of
[core-redesign.md](core-redesign.md) points here.

## Appendix A: comparison scripts

Python (`duckdb==1.5.5`, `numpy`):

```python
import duckdb, time, statistics, gc
Q = "SELECT i::BIGINT, CASE WHEN i % 10 = 0 THEN NULL ELSE i::BIGINT END FROM range(1000000) t(i) ORDER BY i"
con = duckdb.connect(); con.execute("SET threads=1")
def run(name, f, n=10, w=2):
    for _ in range(w): f()
    ts = []
    for _ in range(n):
        gc.collect(); t = time.perf_counter_ns(); f(); ts.append(time.perf_counter_ns() - t)
    print(f"{name:28s} median {statistics.median(ts)/1e6:7.1f} ms  best {min(ts)/1e6:7.1f} ms")
def fetchall():
    s = 0
    for a, b in con.execute(Q).fetchall():
        s += a + (b or 0)
    return s
def fetchnumpy():
    d = con.execute(Q).fetchnumpy()
    return int(d[list(d)[0]].sum())
run("python fetchall (+sum)", fetchall)
run("python fetchnumpy", fetchnumpy)
```

Rust (`duckdb = "=1.10505.0"`, release profile):

```rust
use duckdb::Connection;
use std::time::Instant;
const Q: &str = "SELECT i::BIGINT, CASE WHEN i % 10 = 0 THEN NULL ELSE i::BIGINT END FROM range(1000000) t(i) ORDER BY i";
fn run<F: FnMut() -> i64>(name: &str, mut f: F) {
    for _ in 0..2 { std::hint::black_box(f()); }
    let mut ts: Vec<f64> = (0..10).map(|_| { let t = Instant::now(); std::hint::black_box(f()); t.elapsed().as_secs_f64() * 1e3 }).collect();
    ts.sort_by(|a, b| a.partial_cmp(b).unwrap());
    println!("{:28} median {:7.1} ms  best {:7.1} ms", name, (ts[4] + ts[5]) / 2.0, ts[0]);
}
fn main() {
    let c = Connection::open_in_memory().unwrap(); c.execute_batch("SET threads=1").unwrap();
    run("rust rows get::<i64>", || {
        let mut st = c.prepare(Q).unwrap();
        let mut rows = st.query([]).unwrap();
        let mut s = 0i64;
        while let Some(r) = rows.next().unwrap() { let a: i64 = r.get(0).unwrap(); let b: Option<i64> = r.get(1).unwrap(); s += a + b.unwrap_or(0); }
        s
    });
    run("rust query_arrow", || {
        use duckdb::arrow::array::{Array, Int64Array};
        let mut st = c.prepare(Q).unwrap();
        let mut s = 0i64;
        for b in st.query_arrow([]).unwrap() {
            let a = b.column(0).as_any().downcast_ref::<Int64Array>().unwrap();
            s += a.values().iter().sum::<i64>();
        }
        s
    });
}
```
