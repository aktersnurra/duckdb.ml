# Performance (sub-project 1b) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make bulk reads, typed rows and ingest fast and allocation-free where
the types allow it, per [docs/design/performance.md](docs/design/performance.md).

**Architecture:** `[@@noalloc]` C stubs return unboxed values read from
per-chunk cached vector pointers; local column views are type-checked once per
chunk; `Bulk` copies whole chunks with one `memcpy`; the typed-row fold reads
through the same cache with saturated row application; the appender stages
rows into reusable DuckDB data chunks and appends them with
`duckdb_append_data_chunk`.

**Tech Stack:** OxCaml 5.2.0+ox (`-extension-universe beta`, modes,
`[@zero_alloc]`, unboxed `int64#`/`int32#`/`float#`/`float32#`), DuckDB v1.5.5
C API, dune, jj.

---

## Ground rules for every task

- Use `jj`, never `git`. One task = one described change: finish with
  `jj describe -m "<message>" && jj new`. Messages end with
  `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>` (subagents may use
  their own model name).
- Build and test through `./tools/run` (it wraps the project opam switch):
  `./tools/run build @all`, `./tools/run runtest --force`. Never install
  anything into the opam switch.
- TDD: write the failing test or compile fixture, run it and see it fail, then
  implement.
- No unsafe casts (`Obj.magic`, unchecked loads) in `lib/duckdb`. Native reads
  must be bounds-checked in OCaml and memory-safe in C even if called wrongly.
- C stubs keep the resource-accounting discipline already in
  `lib/ffi/*.c`: every `malloc`/`duckdb_create_*` that outlives the call is
  paired with `duckdb_ml_acquired()`, every free with `duckdb_ml_released()`.
  Tests assert `Duckdb_ffi.live_resources () = 0` after each scope.
- Qualify constructors from other modules (`D.Error.Null`, `D.Bulk.Mask`,
  `Statement.Column.Opened`) wherever the compiler warns about names out of
  scope (warnings 40-42); the dev profile may treat them as errors.
- Facts already verified by probes (do not re-litigate):
  - `[@@noalloc]` externals returning `int64#`, `int32#`, `float#`,
    `float32#` and untagged `int` compile; bytecode needs a separate boxed stub
    (`caml_copy_int64`, `caml_copy_int32`, `caml_copy_double`,
    `caml_copy_float32` from `<caml/float32.h>`).
  - A `[@zero_alloc]` accessor with an `invalid_arg` bounds check passes
    `-zero-alloc-check default` (raising paths are exempt).
  - A local value returned in a local variant whose error payload has the
    `@@ global` modality lets a callback return `Error e`, and the view in the
    other constructor still cannot escape.
  - A function that stack-allocates a value and passes it to a callback must
    mark the call `[@nontail]`.

## Design amendments found while planning

These refine the approved design; Task 10 copies them into
`docs/design/performance.md`.

1. `Column.view` returns `('a, 'n) opened = Opened of ('a, 'n) t | Rejected of
   Error.t @@ global`, not a `result`: a local `result`'s `Error` payload would
   be local and could not be returned from a chunk callback.
2. `Bulk` is a top-level module (`Duckdb.Bulk`) after `Statement`, holding
   `kind`, `validity`, `t`, `blit`, `blit_validity`, `collect`,
   `collect_strings` and `Columns`. `collect_strings` takes the
   `string Scalar.t` (`String` or `Blob`). `collect` reports `Null` rows
   absolute within the result.
3. `append_columns` rejects a column whose declared codec is custom at runtime
   with `Encode_rejected { index; reason }` when its OCaml type equals the base
   type (e.g. a validating `int64` codec); other custom types are already
   rejected by the types. Unequal lengths are a new cause
   `Length_mismatch { column; expected; actual }`.
4. Row ingest stages a batch **outside** connection admission (codec encoders
   are user code, as today), writing only the appender's own staging chunks.
   The append itself runs inside admission. Error precedence is unchanged:
   codec rejections first (row-major), then poisoning/closed/busy, then a NULL
   in a NOT NULL column, then engine errors. A codec rejection never poisons.
5. The typed-row allocation target is defined on the decoder alone: a fold
   whose callback returns a preallocated `Ok (Continue ())` must allocate at
   most 12 words per row for `Fields.[int64; nullable int64]`.
6. Fast paths read through a per-chunk vector cache (`data`, `validity` and
   type per column) filled in C when a chunk is fetched, so a read is one
   indirection instead of three DuckDB calls.

## File structure

| File | Responsibility |
|---|---|
| `lib/ffi/query_native.h` | `duckdb_ml_vector` cache type; `vectors`/`vector_count` fields on `prepared_owner` |
| `lib/ffi/prepared_stubs.c` | fill the cache on fetch, free it with the result |
| `lib/ffi/view_stubs.c` (new) | per-element view reads, first-NULL scan, chunk blits |
| `lib/ffi/appender_stubs.c` | staging pool, `stage_*` writers, `append_staged`; row-by-row `append_rows` removed |
| `lib/ffi/duckdb_ffi.ml{,i}` | externals for the above |
| `lib/duckdb/column.ml{,i}` (new) | local typed column views |
| `lib/duckdb/bulk.ml{,i}` (new) | Bigarray kinds, blit, `Columns` spine |
| `lib/duckdb/codec.ml{,i}` | `Identity` plan |
| `lib/duckdb/decode.ml{,i}` (new) | fast per-chunk row decoding with saturated application |
| `lib/duckdb/request.ml` | fast fold, staged `append`, `append_columns` |
| `lib/duckdb/appender.ml{,i}` | staged append operations |
| `lib/duckdb/failure.ml{,i}`, `duckdb.mli` | `Length_mismatch` cause; public `Statement.Column`, `Bulk`, `Table.append_columns` |
| `test/test_column.ml`, `test/test_bulk.ml`, `test/test_allocation.ml` (new) | runtime tests |
| `test/request_compile/*`, `test/scope_compile/*` | compile-rejection fixtures |
| `bench/benchmark_processing.ml`, `bench/run_benchmarks.py`, `bench/test_benchmark_summary.py` | new paths |

---

### Task 1: Per-chunk vector cache and column views

**Files:**
- Modify: `lib/ffi/query_native.h`, `lib/ffi/prepared_stubs.c`, `lib/ffi/dune`,
  `lib/ffi/duckdb_ffi.ml`, `lib/ffi/duckdb_ffi.mli`
- Create: `lib/ffi/view_stubs.c`, `lib/duckdb/column.ml`, `lib/duckdb/column.mli`
- Modify: `lib/duckdb/dune`, `lib/duckdb/duckdb.ml`, `lib/duckdb/duckdb.mli`
- Create: `test/test_column.ml`; modify `test/dune`
- Create: `test/request_compile/view_plain_on_nullable.ml.fail`,
  `test/request_compile/view_is_null_on_non_null.ml.fail`,
  `test/scope_compile/view_escape.ml.fail`; modify
  `test/check_request_types.sh`, `test/check_scope_types.sh`

- [ ] **Step 1: Write the compile fixtures**

`test/request_compile/view_plain_on_nullable.ml.fail`:

```ocaml
module D = Duckdb
module C = D.Statement.Column
let f (v : (int64, D.Codec.nullable) C.t @ local) = C.int64 v 0
```

`test/request_compile/view_is_null_on_non_null.ml.fail`:

```ocaml
module D = Duckdb
module C = D.Statement.Column
let f (v : (int64, D.Codec.non_null) C.t @ local) = C.is_null v 0
```

`test/scope_compile/view_escape.ml.fail`:

```ocaml
module D = Duckdb
module C = D.Statement.Column
let leak (p @ local) =
  D.Statement.fold_chunks p ~init:None ~f:(fun chunk _ ->
    match C.view chunk 0 D.Scalar.Int64 C.Non_null with
    | C.Opened v -> Ok (D.Stop (Some v))
    | C.Rejected e -> Error e)
```

In `test/check_request_types.sh`, before the final `echo`, add:

```bash
expect view_plain_on_nullable 'Duckdb.Codec.nullable' 'Duckdb.Codec.non_null'
expect view_is_null_on_non_null 'Duckdb.Codec.non_null' 'Duckdb.Codec.nullable'
```

and change "21 intended rejections" to "23 intended rejections".

In `test/check_scope_types.sh`, before the final `echo`, add
`expect view_escape 'is "local"'` and change "12 intended rejections" to
"13 intended rejections".

- [ ] **Step 2: Write the runtime test**

`test/test_column.ml`:

```ocaml
open! Base
module D = Duckdb
module C = D.Statement.Column
module I64 = Stdlib_upstream_compatible.Int64_u
module I32 = Stdlib_upstream_compatible.Int32_u
module F64 = Stdlib_upstream_compatible.Float_u
module F32 = Stdlib_stable.Float32_u
let ok = function Ok x -> x | Error (e : D.Error.t) -> failwith (match e.cause with Native s -> s | _ -> "unexpected error")
let clean () = assert (Duckdb_ffi.live_resources () = 0); assert (Duckdb_ffi.fallback_reclaims () = 0)
let connected f =
  let db = ok (D.Owned.open_database (ok (D.Config.create Memory))) in
  Exn.protect ~finally:(fun () -> ok (D.Owned.close_database db)) ~f:(fun () ->
    let c = ok (D.Owned.connect db) in
    Exn.protect ~finally:(fun () -> ok (D.Owned.close_connection c)) ~f:(fun () -> f c));
  clean ()
(* Sums a non-null BIGINT view without allocating. *)
let[@zero_alloc] rec sum (v @ local) i n acc =
  if i = n then acc else sum v (i + 1) n (I64.add acc (C.int64 v i))
let[@zero_alloc] rec sum_or (v @ local) i n acc =
  if i = n then acc else sum_or v (i + 1) n (I64.add acc (C.int64_or v ~default:#0L i))
let fold_views c sql ~init ~f = ok (D.Statement.with_prepared c sql ~f:(fun p ->
  D.Statement.fold_chunks p ~init ~f))

(* Every scalar reads back exactly through its accessor. *)
let () =
  connected (fun c ->
    let sql = "SELECT 7::BIGINT, 8::INTEGER, 9::SMALLINT, 10::TINYINT, true, 1.5::DOUBLE, 2.5::FLOAT, \
               'hi', DATE '1970-01-03', TIMESTAMP '1970-01-01 00:00:01'" in
    fold_views c sql ~init:() ~f:(fun chunk () ->
      let open_ (type a) column (scalar : a D.Scalar.t) k =
        match C.view chunk column scalar C.Non_null with
        | C.Rejected e -> Error e
        | C.Opened v -> k v in
      ignore (open_ 0 D.Scalar.Int64 (fun v -> assert (I64.equal (C.int64 v 0) #7L); Ok ()) : (unit, _) result);
      ignore (open_ 1 D.Scalar.Int32 (fun v -> assert (Int32.equal (I32.to_int32 (C.int32 v 0)) 8l); Ok ()) : (unit, _) result);
      ignore (open_ 2 D.Scalar.Int16 (fun v -> assert (Stdlib_stable.Int16.to_int (C.int16 v 0) = 9); Ok ()) : (unit, _) result);
      ignore (open_ 3 D.Scalar.Int8 (fun v -> assert (Stdlib_stable.Int8.to_int (C.int8 v 0) = 10); Ok ()) : (unit, _) result);
      ignore (open_ 4 D.Scalar.Bool (fun v -> assert (C.bool v 0); Ok ()) : (unit, _) result);
      ignore (open_ 5 D.Scalar.Float64 (fun v -> assert (Float.equal (F64.to_float (C.float v 0)) 1.5); Ok ()) : (unit, _) result);
      ignore (open_ 6 D.Scalar.Float32 (fun v -> assert (Float.equal (Stdlib_stable.Float32.to_float (F32.to_float32 (C.float32 v 0))) 2.5); Ok ()) : (unit, _) result);
      ignore (open_ 7 D.Scalar.String (fun v -> assert (String.equal (C.string v 0) "hi"); Ok ()) : (unit, _) result);
      ignore (open_ 8 D.Scalar.Date (fun v -> assert (Int32.equal (I32.to_int32 (C.int32 v 0)) 2l); Ok ()) : (unit, _) result);
      ignore (open_ 9 D.Scalar.Timestamp_us (fun v -> assert (I64.equal (C.int64 v 0) #1_000_000L); Ok ()) : (unit, _) result);
      Ok (D.Continue ())));
  Stdlib.print_endline "column: every scalar reads back=ok"

(* Sums across chunk boundaries; NULLs read as the explicit default. *)
let () =
  connected (fun c ->
    let total = fold_views c
      "SELECT i::BIGINT, CASE WHEN i % 10 = 0 THEN NULL ELSE i::BIGINT END FROM range(5000) t(i) ORDER BY i"
      ~init:(0L, 0L) ~f:(fun chunk (a, b) ->
        match C.view chunk 0 D.Scalar.Int64 C.Non_null, C.view chunk 1 D.Scalar.Int64 C.Nullable with
        | C.Rejected e, _ | _, C.Rejected e -> Error e
        | C.Opened x, C.Opened y ->
          let n = C.length x in
          assert (C.length y = n);
          Ok (D.Continue (Int64.(a + I64.to_int64 (sum x 0 n #0L)), Int64.(b + I64.to_int64 (sum_or y 0 n #0L))))) in
    assert (Poly.equal total (12_497_500L, 11_250_000L)));
  Stdlib.print_endline "column: sums across chunks with explicit NULL defaults=ok"

(* View failures: wrong type, bad index, NULL in a non-null view. *)
let () =
  connected (fun c ->
    let cause sql column (type a) (scalar : a D.Scalar.t) nulls_nn =
      let r = ref None in
      ignore (fold_views c sql ~init:() ~f:(fun chunk () ->
        (if nulls_nn then
           (match C.view chunk column scalar C.Non_null with C.Rejected e -> r := Some e.cause | C.Opened _ -> ())
         else
           (match C.view chunk column scalar C.Nullable with C.Rejected e -> r := Some e.cause | C.Opened _ -> ()));
        Ok (D.Stop ())) : unit);
      !r in
    (match cause "SELECT 1::INTEGER" 0 D.Scalar.Int64 true with
     | Some (Type_mismatch { index = 0; expected = "BIGINT"; actual = "INTEGER" }) -> ()
     | _ -> failwith "type mismatch expected");
    (match cause "SELECT 1::BIGINT" 3 D.Scalar.Int64 true with
     | Some (Index { index = 3; length = 1 }) -> () | _ -> failwith "index expected");
    (match cause "SELECT * FROM (VALUES (1::BIGINT), (NULL)) t(x)" 0 D.Scalar.Int64 true with
     | Some (Null { column = 0; row = 1 }) -> () | _ -> failwith "null expected");
    (match cause "SELECT * FROM (VALUES (1::BIGINT), (NULL)) t(x)" 0 D.Scalar.Int64 false with
     | None -> () | Some _ -> failwith "nullable view opens"));
  Stdlib.print_endline "column: type, index and NULL rejections=ok"

(* An index outside the chunk raises, like Array.get. *)
let () =
  connected (fun c ->
    fold_views c "SELECT 1::BIGINT" ~init:() ~f:(fun chunk () ->
      match C.view chunk 0 D.Scalar.Int64 C.Non_null with
      | C.Rejected e -> Error e
      | C.Opened v ->
        (match C.int64 v 1 with
         | _ -> failwith "out of bounds read accepted"
         | exception Invalid_argument _ -> ());
        Ok (D.Continue ())));
  Stdlib.print_endline "column: out-of-bounds read raises=ok"
```

In `test/dune` add:

```
(test (name test_column) (modules test_column)
 (libraries base duckdb duckdb-ffi stdlib_stable stdlib_upstream_compatible))
```

- [ ] **Step 3: Run and verify it fails**

Run: `./tools/run runtest --force 2>&1 | tail -20`
Expected: `test_column.ml` fails to compile with `Unbound module D.Statement.Column`
(or similar), and both fixture scripts report `unexpected acceptance` or a
missing message for the new fixtures.

- [ ] **Step 4: Native vector cache**

`lib/ffi/query_native.h`, before `typedef struct prepared_owner`:

```c
/* Per-chunk cache of each column's vector, filled at fetch. Valid while
   [chunk] lives; [validity] is NULL when every row is valid. */
typedef struct { void *data; uint64_t *validity; duckdb_type type; } duckdb_ml_vector;
```

Add two fields at the end of `prepared_owner`:

```c
    duckdb_ml_vector *vectors;
    idx_t vector_count;
```

`lib/ffi/prepared_stubs.c`:
- In `clear_result`, after the chunk is destroyed:

```c
    if (p->vectors) { free(p->vectors); p->vectors = NULL; p->vector_count = 0; duckdb_ml_released(); }
```

- Add above `ml_duckdb_fetch`:

```c
/* Fills the vector cache for the fetched chunk. The cache is sized once per
   result (its column count never changes) and freed with the result. */
static void cache_vectors(prepared_owner *p) {
    idx_t n = duckdb_data_chunk_get_column_count(p->chunk);
    if (!p->vectors && n) {
        p->vectors = calloc(n, sizeof(duckdb_ml_vector));
        if (!p->vectors) { set_error(p, "Cannot allocate the vector cache"); return; }
        duckdb_ml_acquired(); p->vector_count = n;
    }
    for (idx_t c = 0; c < n && c < p->vector_count; ++c) {
        duckdb_vector vector = duckdb_data_chunk_get_vector(p->chunk, c);
        p->vectors[c].data = duckdb_vector_get_data(vector);
        p->vectors[c].validity = duckdb_vector_get_validity(vector);
        p->vectors[c].type = duckdb_column_type(&p->result, c);
    }
}
```

- In `ml_duckdb_fetch`, replace `if (p->chunk) duckdb_ml_acquired();` with
  `if (p->chunk) { duckdb_ml_acquired(); cache_vectors(p); }`.

- [ ] **Step 5: View stubs**

Create `lib/ffi/view_stubs.c`:

```c
#include "query_native.h"
#include <caml/alloc.h>
#include <caml/bigarray.h>
#include <caml/float32.h>
#include <stdint.h>
#include <string.h>
/* Reads through the per-chunk vector cache. OCaml checks the column's type
   once per view and every row index against the chunk length; these stubs
   additionally refuse a column outside the cache, so a wrong call reads
   nothing rather than out of bounds. */
static duckdb_ml_vector *cached(value v, value column) {
    prepared_owner *p = duckdb_ml_prepared(v); intnat c = Long_val(column);
    return (p && p->chunk && c >= 0 && (idx_t)c < p->vector_count) ? &p->vectors[c] : NULL;
}
static int valid_row(duckdb_ml_vector *x, intnat i) {
    return !x->validity || ((x->validity[i / 64] >> (i % 64)) & 1);
}
#define READ(T, x, i) ((x) ? ((T *)(x)->data)[i] : (T)0)
int64_t ml_duckdb_view_int64(value v, value c, value i) { return READ(int64_t, cached(v, c), Long_val(i)); }
value ml_duckdb_view_int64_byte(value v, value c, value i) { return caml_copy_int64(ml_duckdb_view_int64(v, c, i)); }
int32_t ml_duckdb_view_int32(value v, value c, value i) { return READ(int32_t, cached(v, c), Long_val(i)); }
value ml_duckdb_view_int32_byte(value v, value c, value i) { return caml_copy_int32(ml_duckdb_view_int32(v, c, i)); }
double ml_duckdb_view_double(value v, value c, value i) { return READ(double, cached(v, c), Long_val(i)); }
value ml_duckdb_view_double_byte(value v, value c, value i) { return caml_copy_double(ml_duckdb_view_double(v, c, i)); }
float ml_duckdb_view_float(value v, value c, value i) { return READ(float, cached(v, c), Long_val(i)); }
value ml_duckdb_view_float_byte(value v, value c, value i) { return caml_copy_float32(ml_duckdb_view_float(v, c, i)); }
value ml_duckdb_view_int16(value v, value c, value i) { return Val_long(READ(int16_t, cached(v, c), Long_val(i))); }
value ml_duckdb_view_int8(value v, value c, value i) { return Val_long(READ(int8_t, cached(v, c), Long_val(i))); }
value ml_duckdb_view_bool(value v, value c, value i) { return Val_bool(READ(bool, cached(v, c), Long_val(i))); }
value ml_duckdb_view_valid(value v, value c, value i) {
    duckdb_ml_vector *x = cached(v, c); return Val_bool(x && valid_row(x, Long_val(i)));
}
/* First NULL row in [0, length), or -1. Scans the mask a word at a time. */
value ml_duckdb_view_first_null(value v, value c, value length) {
    duckdb_ml_vector *x = cached(v, c); intnat n = Long_val(length);
    if (!x || !x->validity) return Val_long(-1);
    for (intnat w = 0; w * 64 < n; ++w) {
        uint64_t bits = x->validity[w];
        intnat in_word = n - w * 64 < 64 ? n - w * 64 : 64;
        uint64_t wanted = in_word == 64 ? UINT64_MAX : ((UINT64_C(1) << in_word) - 1);
        uint64_t missing = ~bits & wanted;
        if (missing) return Val_long(w * 64 + __builtin_ctzll(missing));
    }
    return Val_long(-1);
}
static size_t width(duckdb_type t) {
    switch (t) {
    case DUCKDB_TYPE_BOOLEAN: case DUCKDB_TYPE_TINYINT: return 1;
    case DUCKDB_TYPE_SMALLINT: return 2;
    case DUCKDB_TYPE_INTEGER: case DUCKDB_TYPE_DATE: case DUCKDB_TYPE_FLOAT: return 4;
    case DUCKDB_TYPE_BIGINT: case DUCKDB_TYPE_DOUBLE: case DUCKDB_TYPE_TIMESTAMP:
    case DUCKDB_TYPE_TIMESTAMP_S: case DUCKDB_TYPE_TIMESTAMP_MS: case DUCKDB_TYPE_TIMESTAMP_NS:
    case DUCKDB_TYPE_TIMESTAMP_TZ: return 8;
    default: return 0;
    }
}
/* Copies [length] rows of a fixed-width column into [ba] at [pos] and writes
   0 at NULL rows. Refuses (copies nothing) when the element widths differ or
   the destination is too short; OCaml checks both first. */
value ml_duckdb_view_blit(value v, value c, value length, value ba, value pos) {
    duckdb_ml_vector *x = cached(v, c); intnat n = Long_val(length), at = Long_val(pos);
    struct caml_ba_array *b = Caml_ba_array_val(ba);
    size_t w = x ? width(x->type) : 0;
    if (!w || w != (size_t)caml_ba_element_size[b->flags & CAML_BA_KIND_MASK]) return Val_unit;
    if (n < 0 || at < 0 || at > b->dim[0] - n) return Val_unit;
    char *out = (char *)b->data + (size_t)at * w;
    memcpy(out, x->data, (size_t)n * w);
    if (x->validity) for (intnat i = 0; i < n; ++i) if (!valid_row(x, i)) memset(out + (size_t)i * w, 0, w);
    return Val_unit;
}
/* Writes one byte per row into a uint8 Bigarray: 1 valid, 0 NULL. */
value ml_duckdb_view_blit_validity(value v, value c, value length, value ba, value pos) {
    duckdb_ml_vector *x = cached(v, c); intnat n = Long_val(length), at = Long_val(pos);
    struct caml_ba_array *b = Caml_ba_array_val(ba);
    if (!x || (b->flags & CAML_BA_KIND_MASK) != CAML_BA_UINT8) return Val_unit;
    if (n < 0 || at < 0 || at > b->dim[0] - n) return Val_unit;
    uint8_t *out = (uint8_t *)b->data + at;
    for (intnat i = 0; i < n; ++i) out[i] = (uint8_t)valid_row(x, i);
    return Val_unit;
}
```

`lib/ffi/dune`: add `view_stubs` to `(names …)`.

`lib/ffi/duckdb_ffi.ml`, after `chunk_string`:

```ocaml
external view_int64 : prepared @ local -> int -> int -> int64#
  = "ml_duckdb_view_int64_byte" "ml_duckdb_view_int64" [@@noalloc]
external view_int32 : prepared @ local -> int -> int -> int32#
  = "ml_duckdb_view_int32_byte" "ml_duckdb_view_int32" [@@noalloc]
external view_double : prepared @ local -> int -> int -> float#
  = "ml_duckdb_view_double_byte" "ml_duckdb_view_double" [@@noalloc]
external view_float : prepared @ local -> int -> int -> float32#
  = "ml_duckdb_view_float_byte" "ml_duckdb_view_float" [@@noalloc]
external view_int16 : prepared @ local -> int -> int -> int = "ml_duckdb_view_int16" [@@noalloc]
external view_int8 : prepared @ local -> int -> int -> int = "ml_duckdb_view_int8" [@@noalloc]
external view_bool : prepared @ local -> int -> int -> bool = "ml_duckdb_view_bool" [@@noalloc]
external view_valid : prepared @ local -> int -> int -> bool = "ml_duckdb_view_valid" [@@noalloc]
external view_first_null : prepared @ local -> int -> int -> int = "ml_duckdb_view_first_null" [@@noalloc]
external view_blit : prepared @ local -> int -> int -> ('a, 'b, Bigarray.c_layout) Bigarray.Array1.t @ local -> int -> unit
  = "ml_duckdb_view_blit" [@@noalloc]
external view_blit_validity : prepared @ local -> int -> int ->
  (int, Bigarray.int8_unsigned_elt, Bigarray.c_layout) Bigarray.Array1.t @ local -> int -> unit
  = "ml_duckdb_view_blit_validity" [@@noalloc]
```

Mirror each as a `val` (with the same `@ local` modes and return layouts) in
`duckdb_ffi.mli` next to `chunk_string`; externals may stay `external` in the
`.mli` as `chunk_int64` does.

- [ ] **Step 6: The `Column` module**

`lib/duckdb/dune`: flags become
`(:standard -extension-universe beta -zero-alloc-check default)`; add
`column` to `private_modules`; add `stdlib_upstream_compatible` to
`libraries`.

`lib/duckdb/column.mli`:

```ocaml
(* Local typed views of one column of a borrowed chunk. *)
type ('a, 'n) t
type _ nulls = Non_null : Codec.non_null nulls | Nullable : Codec.nullable nulls
type ('a, 'n) opened = Opened of ('a, 'n) t | Rejected of Failure.t @@ global
val view : Borrowed_chunk.t @ local -> int -> 'a Scalar.t -> 'n nulls -> ('a, 'n) opened @ local
val length : _ t @ local -> int
val int64 : (int64, Codec.non_null) t @ local -> int -> int64# [@@zero_alloc]
val float : (float, Codec.non_null) t @ local -> int -> float# [@@zero_alloc]
val int32 : (int32, Codec.non_null) t @ local -> int -> int32# [@@zero_alloc]
val float32 : (float32, Codec.non_null) t @ local -> int -> float32# [@@zero_alloc]
val int16 : (int16, Codec.non_null) t @ local -> int -> int16 [@@zero_alloc]
val int8 : (int8, Codec.non_null) t @ local -> int -> int8 [@@zero_alloc]
val bool : (bool, Codec.non_null) t @ local -> int -> bool [@@zero_alloc]
val string : (string, Codec.non_null) t @ local -> int -> string
val is_null : (_, Codec.nullable) t @ local -> int -> bool [@@zero_alloc]
val int64_or : (int64, Codec.nullable) t @ local -> default:int64# -> int -> int64# [@@zero_alloc]
val float_or : (float, Codec.nullable) t @ local -> default:float# -> int -> float# [@@zero_alloc]
val int32_or : (int32, Codec.nullable) t @ local -> default:int32# -> int -> int32# [@@zero_alloc]
val float32_or : (float32, Codec.nullable) t @ local -> default:float32# -> int -> float32# [@@zero_alloc]
val int16_or : (int16, Codec.nullable) t @ local -> default:int16 -> int -> int16 [@@zero_alloc]
val int8_or : (int8, Codec.nullable) t @ local -> default:int8 -> int -> int8 [@@zero_alloc]
val bool_or : (bool, Codec.nullable) t @ local -> default:bool -> int -> bool [@@zero_alloc]
val string_opt : (string, Codec.nullable) t @ local -> int -> string option

(* Private, for Bulk: copy this chunk's column (0 at NULL rows) or its
   validity into [into] at [pos]; raise [Invalid_argument] if [into] is too
   short. *)
val blit : (_, _) t @ local -> into:('k, 'e, Bigarray.c_layout) Bigarray.Array1.t @ local -> pos:int -> unit [@@zero_alloc]
val blit_validity : (_, Codec.nullable) t @ local ->
  into:(int, Bigarray.int8_unsigned_elt, Bigarray.c_layout) Bigarray.Array1.t @ local -> pos:int -> unit [@@zero_alloc]
```

`lib/duckdb/column.ml`:

```ocaml
open! Base
open Failure
module F = Duckdb_ffi
module I16 = Stdlib_stable.Int16
module I8 = Stdlib_stable.Int8
type ('a, 'n) t = { native : F.prepared; column : int; length : int }
type _ nulls = Non_null : Codec.non_null nulls | Nullable : Codec.nullable nulls
type ('a, 'n) opened = Opened of ('a, 'n) t | Rejected of Failure.t @@ global

let view : type a n. Borrowed_chunk.t @ local -> int -> a Scalar.t -> n nulls -> (a, n) opened @ local =
  fun chunk column scalar nulls ->
  let native = chunk.Borrowed_chunk.native in
  let reject cause = Rejected { context = Query chunk.sql; cause } in
  let columns = F.column_count native in
  if column < 0 || column >= columns then exclave_ reject (Index { index = column; length = columns })
  else
    let actual = F.column_type native column in
    if actual <> Scalar.native_id scalar then
      exclave_ reject (Type_mismatch { index = column; expected = Scalar.name scalar; actual = type_name actual })
    else
      let length = F.chunk_length native in
      let first_null = match nulls with Non_null -> F.view_first_null native column length | Nullable -> -1 in
      if first_null >= 0 then exclave_ reject (Null { column; row = first_null })
      else exclave_ Opened { native; column; length }

let length (v @ local) = v.length
let[@inline] check (v @ local) i =
  if i < 0 || i >= v.length then invalid_arg "Duckdb.Statement.Column: row index out of bounds"
let[@zero_alloc] int64 (v @ local) i = check v i; F.view_int64 v.native v.column i
let[@zero_alloc] float (v @ local) i = check v i; F.view_double v.native v.column i
let[@zero_alloc] int32 (v @ local) i = check v i; F.view_int32 v.native v.column i
let[@zero_alloc] float32 (v @ local) i = check v i; F.view_float v.native v.column i
let[@zero_alloc] int16 (v @ local) i = check v i; I16.of_int (F.view_int16 v.native v.column i)
let[@zero_alloc] int8 (v @ local) i = check v i; I8.of_int (F.view_int8 v.native v.column i)
let[@zero_alloc] bool (v @ local) i = check v i; F.view_bool v.native v.column i
let string (v @ local) i = check v i; F.chunk_string v.native v.column i
let[@zero_alloc] is_null (v @ local) i = check v i; not (F.view_valid v.native v.column i)
let[@zero_alloc] int64_or (v @ local) ~default i = if is_null v i then default else F.view_int64 v.native v.column i
let[@zero_alloc] float_or (v @ local) ~default i = if is_null v i then default else F.view_double v.native v.column i
let[@zero_alloc] int32_or (v @ local) ~default i = if is_null v i then default else F.view_int32 v.native v.column i
let[@zero_alloc] float32_or (v @ local) ~default i = if is_null v i then default else F.view_float v.native v.column i
let[@zero_alloc] int16_or (v @ local) ~default i = if is_null v i then default else I16.of_int (F.view_int16 v.native v.column i)
let[@zero_alloc] int8_or (v @ local) ~default i = if is_null v i then default else I8.of_int (F.view_int8 v.native v.column i)
let[@zero_alloc] bool_or (v @ local) ~default i = if is_null v i then default else F.view_bool v.native v.column i
let string_opt (v @ local) i = if is_null v i then None else Some (F.chunk_string v.native v.column i)
let[@inline] room (v @ local) into ~pos =
  if pos < 0 || pos > Bigarray.Array1.dim into - v.length then
    invalid_arg "Duckdb.Bulk.blit: destination too short"
let[@zero_alloc] blit (v @ local) ~into ~pos = room v into ~pos; F.view_blit v.native v.column v.length into pos
let[@zero_alloc] blit_validity (v @ local) ~into ~pos =
  room v into ~pos; F.view_blit_validity v.native v.column v.length into pos
```

If the compiler reports that `type_name` or a cause constructor is not in
scope, they come from `Failure` (`open Failure` is above) exactly as in
`borrowed_chunk.ml`.

`lib/duckdb/duckdb.ml`, inside `module Statement`, after `column`: `module Column = Column`.

`lib/duckdb/duckdb.mli`, inside `module Statement` after `val column`:

```ocaml
  (** Typed views of one column of a chunk, type-checked once per chunk. A
      view is local to the chunk callback. Plain accessors exist only on
      non-null views; nullable views offer [is_null] and accessors with an
      explicit [default]. Numeric accessors never allocate ([@zero_alloc],
      checked by the build). A row index outside [0, length) raises
      [Invalid_argument]. Strings are owned copies. *)
  module Column : sig
    type ('a, 'n) t
    type _ nulls =
      | Non_null : Codec.non_null nulls
      (** The view is rejected with [Null] (chunk-relative row) if the
          column has a NULL in this chunk. *)
      | Nullable : Codec.nullable nulls
    type ('a, 'n) opened = Opened of ('a, 'n) t | Rejected of Error.t @@ global
    val view : chunk @ local -> int -> 'a Scalar.t -> 'n nulls -> ('a, 'n) opened @ local
    val length : _ t @ local -> int
    val int64 : (int64, Codec.non_null) t @ local -> int -> int64# [@@zero_alloc]
    val float : (float, Codec.non_null) t @ local -> int -> float# [@@zero_alloc]
    val int32 : (int32, Codec.non_null) t @ local -> int -> int32# [@@zero_alloc]
    val float32 : (float32, Codec.non_null) t @ local -> int -> float32# [@@zero_alloc]
    val int16 : (int16, Codec.non_null) t @ local -> int -> int16 [@@zero_alloc]
    val int8 : (int8, Codec.non_null) t @ local -> int -> int8 [@@zero_alloc]
    val bool : (bool, Codec.non_null) t @ local -> int -> bool [@@zero_alloc]
    val string : (string, Codec.non_null) t @ local -> int -> string
    val is_null : (_, Codec.nullable) t @ local -> int -> bool [@@zero_alloc]
    val int64_or : (int64, Codec.nullable) t @ local -> default:int64# -> int -> int64# [@@zero_alloc]
    val float_or : (float, Codec.nullable) t @ local -> default:float# -> int -> float# [@@zero_alloc]
    val int32_or : (int32, Codec.nullable) t @ local -> default:int32# -> int -> int32# [@@zero_alloc]
    val float32_or : (float32, Codec.nullable) t @ local -> default:float32# -> int -> float32# [@@zero_alloc]
    val int16_or : (int16, Codec.nullable) t @ local -> default:int16 -> int -> int16 [@@zero_alloc]
    val int8_or : (int8, Codec.nullable) t @ local -> default:int8 -> int -> int8 [@@zero_alloc]
    val bool_or : (bool, Codec.nullable) t @ local -> default:bool -> int -> bool [@@zero_alloc]
    val string_opt : (string, Codec.nullable) t @ local -> int -> string option
  end
```

`duckdb.ml`'s `Statement.Column = Column` exposes `blit`/`blit_validity` too;
the `.mli` above hides them from users (Bulk re-exports them in Task 2).

- [ ] **Step 7: Run and verify it passes**

Run: `./tools/run build @all 2>&1 | tail -20 && ./tools/run runtest --force 2>&1 | grep -E "column:|intended rejections|FAIL|Error" | head -20`
Expected: the four `column: …=ok` lines,
`request types: positive forms and 23 intended rejections …=ok`,
`scope types: positive forms and 13 intended rejections …=ok`, and runtest
exits 0. If `-zero-alloc-check` rejects a function, the message names it and
the allocation: fix the code, do not drop the attribute.

- [ ] **Step 8: Commit**

```bash
jj describe -m "feat(statement): zero-alloc typed column views over a per-chunk vector cache

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>" && jj new
```

---

### Task 2: `Bulk` — blit and collect into Bigarrays

**Files:**
- Create: `lib/duckdb/bulk.ml`, `lib/duckdb/bulk.mli`, `test/test_bulk.ml`
- Modify: `lib/duckdb/dune` (`bulk` private module), `lib/duckdb/duckdb.ml`,
  `lib/duckdb/duckdb.mli`, `test/dune`
- Create: `test/request_compile/bulk_kind_mismatch.ml.fail`; modify
  `test/check_request_types.sh`

- [ ] **Step 1: Write the compile fixture**

`test/request_compile/bulk_kind_mismatch.ml.fail`:

```ocaml
module D = Duckdb
let f (v : (float, D.Codec.non_null) D.Statement.Column.t @ local) into =
  D.Bulk.blit v (D.Bulk.Int64 D.Scalar.Int64) ~into ~pos:0
```

In `check_request_types.sh` add `expect bulk_kind_mismatch 'type "float"' 'type "int64"'`
and bump the count to 24.

- [ ] **Step 2: Write the runtime test**

`test/test_bulk.ml`:

```ocaml
open! Base
module D = Duckdb
module A1 = Stdlib.Bigarray.Array1
let ok = function Ok x -> x | Error (e : D.Error.t) -> failwith (match e.cause with Native s -> s | _ -> "error")
let clean () = assert (Duckdb_ffi.live_resources () = 0); assert (Duckdb_ffi.fallback_reclaims () = 0)
let connected f =
  let db = ok (D.Owned.open_database (ok (D.Config.create Memory))) in
  Exn.protect ~finally:(fun () -> ok (D.Owned.close_database db)) ~f:(fun () ->
    let c = ok (D.Owned.connect db) in
    Exn.protect ~finally:(fun () -> ok (D.Owned.close_connection c)) ~f:(fun () -> f c));
  clean ()
let sql = "SELECT i::BIGINT, CASE WHEN i % 10 = 0 THEN NULL ELSE i::DOUBLE END, i::INTEGER % 3 = 0, \
           CASE WHEN i % 7 = 0 THEN NULL ELSE 's' || i END FROM range(5000) t(i) ORDER BY i"
let collect c column kind nulls = ok (D.Statement.with_prepared c sql ~f:(fun p -> D.Bulk.collect p ~column kind nulls))

(* Non-null BIGINT: every value, no mask; nullable DOUBLE: 0 at NULL rows. *)
let () =
  connected (fun c ->
    let { D.Bulk.data; validity = D.Bulk.All_valid } = collect c 0 (D.Bulk.Int64 D.Scalar.Int64) D.Statement.Column.Non_null in
    assert (A1.dim data = 5000);
    for i = 0 to 4999 do assert (Int64.equal data.{i} (Int64.of_int i)) done;
    let { D.Bulk.data; validity = D.Bulk.Mask mask } = collect c 1 D.Bulk.Float64 D.Statement.Column.Nullable in
    for i = 0 to 4999 do
      if i % 10 = 0 then (assert (mask.{i} = 0); assert (Float.equal data.{i} 0.))
      else (assert (mask.{i} = 1); assert (Float.equal data.{i} (Float.of_int i)))
    done;
    let { D.Bulk.data; _ } = collect c 2 D.Bulk.Bool D.Statement.Column.Non_null in
    for i = 0 to 4999 do assert (data.{i} = if i % 3 = 0 then 1 else 0) done);
  Stdlib.print_endline "bulk: collect int64, nullable float64 and bool across chunks=ok"

(* Strings, and a NULL in a non-null collect reported with its absolute row. *)
let () =
  connected (fun c ->
    (match ok (D.Statement.with_prepared c sql ~f:(fun p ->
       D.Bulk.collect_strings p ~column:3 D.Scalar.String D.Statement.Column.Nullable)) with
     | D.Bulk.Strings_opt values ->
       assert (Array.length values = 5000);
       assert (Option.is_none values.(0));
       assert (Option.equal String.equal values.(4999) (Some "s4999")));
    match D.Statement.with_prepared c sql ~f:(fun p ->
      D.Bulk.collect p ~column:1 D.Bulk.Float64 D.Statement.Column.Non_null) with
    | Error { cause = Null { column = 1; row = 0 }; _ } -> ()
    | _ -> failwith "expected Null at row 0");
  Stdlib.print_endline "bulk: strings and absolute NULL rows=ok"

(* Empty results collect to empty arrays. *)
let () =
  connected (fun c ->
    let { D.Bulk.data; _ } = ok (D.Statement.with_prepared c "SELECT 1::BIGINT WHERE false" ~f:(fun p ->
      D.Bulk.collect p ~column:0 (D.Bulk.Int64 D.Scalar.Int64) D.Statement.Column.Non_null)) in
    assert (A1.dim data = 0));
  Stdlib.print_endline "bulk: empty result=ok"
```

`test/dune`:

```
(test (name test_bulk) (modules test_bulk) (libraries base duckdb duckdb-ffi))
```

- [ ] **Step 3: Run and verify it fails**

Run: `./tools/run runtest --force 2>&1 | tail -20`
Expected: `Unbound module D.Bulk`; the fixture script reports the new fixture.

- [ ] **Step 4: Implement `Bulk`**

`lib/duckdb/bulk.mli`:

```ocaml
type ('a, 'k, 'e) kind =
  | Int64 : int64 Scalar.t -> (int64, int64, Bigarray.int64_elt) kind
  | Int32 : int32 Scalar.t -> (int32, int32, Bigarray.int32_elt) kind
  | Int16 : (int16, int, Bigarray.int16_signed_elt) kind
  | Int8 : (int8, int, Bigarray.int8_signed_elt) kind
  | Bool : (bool, int, Bigarray.int8_unsigned_elt) kind
  | Float64 : (float, float, Bigarray.float64_elt) kind
  | Float32 : (float32, float, Bigarray.float32_elt) kind
type mask = (int, Bigarray.int8_unsigned_elt, Bigarray.c_layout) Bigarray.Array1.t
type 'n validity = All_valid : Codec.non_null validity | Mask : mask -> Codec.nullable validity
type ('k, 'e, 'n) t = { data : ('k, 'e, Bigarray.c_layout) Bigarray.Array1.t; validity : 'n validity }
type _ strings =
  | Strings : string array -> Codec.non_null strings
  | Strings_opt : string option array -> Codec.nullable strings
val scalar : ('a, _, _) kind -> 'a Scalar.t
val bigarray_kind : (_, 'k, 'e) kind -> ('k, 'e) Bigarray.kind
val blit : ('a, _) Column.t @ local -> ('a, 'k, 'e) kind ->
  into:('k, 'e, Bigarray.c_layout) Bigarray.Array1.t @ local -> pos:int -> unit [@@zero_alloc]
val blit_validity : ('a, Codec.nullable) Column.t @ local -> into:mask @ local -> pos:int -> unit [@@zero_alloc]
```

`lib/duckdb/bulk.ml`:

```ocaml
open! Base
type ('a, 'k, 'e) kind =
  | Int64 : int64 Scalar.t -> (int64, int64, Bigarray.int64_elt) kind
  | Int32 : int32 Scalar.t -> (int32, int32, Bigarray.int32_elt) kind
  | Int16 : (int16, int, Bigarray.int16_signed_elt) kind
  | Int8 : (int8, int, Bigarray.int8_signed_elt) kind
  | Bool : (bool, int, Bigarray.int8_unsigned_elt) kind
  | Float64 : (float, float, Bigarray.float64_elt) kind
  | Float32 : (float32, float, Bigarray.float32_elt) kind
type mask = (int, Bigarray.int8_unsigned_elt, Bigarray.c_layout) Bigarray.Array1.t
type 'n validity = All_valid : Codec.non_null validity | Mask : mask -> Codec.nullable validity
type ('k, 'e, 'n) t = { data : ('k, 'e, Bigarray.c_layout) Bigarray.Array1.t; validity : 'n validity }
type _ strings =
  | Strings : string array -> Codec.non_null strings
  | Strings_opt : string option array -> Codec.nullable strings
let scalar : type a k e. (a, k, e) kind -> a Scalar.t = function
  | Int64 s -> s | Int32 s -> s | Int16 -> Scalar.Int16 | Int8 -> Scalar.Int8
  | Bool -> Scalar.Bool | Float64 -> Scalar.Float64 | Float32 -> Scalar.Float32
let bigarray_kind : type a k e. (a, k, e) kind -> (k, e) Bigarray.kind = function
  | Int64 _ -> Bigarray.int64 | Int32 _ -> Bigarray.int32 | Int16 -> Bigarray.int16_signed
  | Int8 -> Bigarray.int8_signed | Bool -> Bigarray.int8_unsigned
  | Float64 -> Bigarray.float64 | Float32 -> Bigarray.float32
(* The kind only fixes the types: the view's column type was checked when it
   was opened, and the C copy refuses a width mismatch. *)
let[@zero_alloc] blit (v @ local) (_ : (_, _, _) kind) ~into ~pos = Column.blit v ~into ~pos
let[@zero_alloc] blit_validity (v @ local) ~into ~pos = Column.blit_validity v ~into ~pos
```

`lib/duckdb/dune`: add `bulk` to `private_modules`.

`lib/duckdb/duckdb.ml`, after `module Statement … end`:

```ocaml
module Bulk = struct
  include Bulk
  module A1 = Bigarray.Array1
  (* Grows by doubling; the result is a [sub] of the final buffer (shared, no copy). *)
  let grow make a ~used ~need =
    if A1.dim a >= need then a
    else let b = make (Int.max need (2 * A1.dim a)) in
      A1.blit (A1.sub a 0 used) (A1.sub b 0 used); b
  let absolute ~used (e : Error.t) = match e.cause with
    | Null { column; row } -> { e with cause = Null { column; row = used + row } }
    | _ -> e
  let collect (type a k e n) (p : Statement.prepared @ local) ~column (kind : (a, k, e) kind)
      (nulls : n Statement.Column.nulls) : ((k, e, n) t, Error.t) result =
    let make n = A1.create (bigarray_kind kind) Bigarray.c_layout n in
    let make_mask n = A1.create Bigarray.int8_unsigned Bigarray.c_layout n in
    let initial = 2048 in
    let folded = Statement.fold_chunks p ~init:(make initial, make_mask (match nulls with Statement.Column.Non_null -> 0 | Statement.Column.Nullable -> initial), 0)
      ~f:(fun chunk (data, mask, used) ->
        match Statement.Column.view chunk column (scalar kind) nulls with
        | Statement.Column.Rejected e -> Error (absolute ~used e)
        | Statement.Column.Opened v ->
          let n = Statement.Column.length v in
          let data = grow make data ~used ~need:(used + n) in
          blit v kind ~into:data ~pos:used;
          let mask = match nulls with
            | Statement.Column.Non_null -> mask
            | Statement.Column.Nullable -> let mask = grow make_mask mask ~used ~need:(used + n) in
              blit_validity v ~into:mask ~pos:used; mask in
          Ok (Continue (data, mask, used + n))) in
    Result.map folded ~f:(fun (data, mask, used) ->
      let validity : n validity = match nulls with
        | Statement.Column.Non_null -> All_valid
        | Statement.Column.Nullable -> Mask (A1.sub mask 0 used) in
      { data = A1.sub data 0 used; validity })
  let collect_strings (type n) (p : Statement.prepared @ local) ~column scalar (nulls : n Statement.Column.nulls)
      : (n strings, Error.t) result =
    let read (type m) (v : (string, m) Statement.Column.t @ local) (nulls : m Statement.Column.nulls) i : string option =
      match nulls with
      | Statement.Column.Non_null -> Some (Statement.Column.string v i)
      | Statement.Column.Nullable -> Statement.Column.string_opt v i in
    let folded = Statement.fold_chunks p ~init:([], 0) ~f:(fun chunk (parts, used) ->
      match Statement.Column.view chunk column scalar nulls with
      | Statement.Column.Rejected e -> Error (absolute ~used e)
      | Statement.Column.Opened v ->
        let n = Statement.Column.length v in
        Ok (Continue (Array.init n ~f:(fun i -> read v nulls i) :: parts, used + n))) in
    Result.map folded ~f:(fun (parts, _) ->
      let all = Array.concat (List.rev parts) in
      match nulls with
      | Statement.Column.Non_null -> Strings (Array.map all ~f:(fun s -> Option.value_exn s))
      | Statement.Column.Nullable -> Strings_opt all)
end
```

`Array.init`'s closure captures the local view; if the compiler rejects it,
replace it with an explicit loop filling `Array.create ~len:n None` (a `for`
loop, not a recursive closure, per probe P7).

`lib/duckdb/duckdb.mli`, after `module Statement … end`:

```ocaml
(** Whole columns as Bigarrays: one native copy per chunk, nothing on the
    OCaml heap per value. *)
module Bulk : sig
  (** ['a] is the view's type, ['k]/['e] the Bigarray element. Dates and
      timestamps share int32/int64 and carry their scalar. *)
  type ('a, 'k, 'e) kind =
    | Int64 : int64 Scalar.t -> (int64, int64, Bigarray.int64_elt) kind
    | Int32 : int32 Scalar.t -> (int32, int32, Bigarray.int32_elt) kind
    | Int16 : (int16, int, Bigarray.int16_signed_elt) kind
    | Int8 : (int8, int, Bigarray.int8_signed_elt) kind
    | Bool : (bool, int, Bigarray.int8_unsigned_elt) kind (** 0 or 1 *)
    | Float64 : (float, float, Bigarray.float64_elt) kind
    | Float32 : (float32, float, Bigarray.float32_elt) kind
  (** One byte per row: 1 valid, 0 NULL. *)
  type mask = (int, Bigarray.int8_unsigned_elt, Bigarray.c_layout) Bigarray.Array1.t
  type 'n validity = All_valid : Codec.non_null validity | Mask : mask -> Codec.nullable validity
  (** NULL rows hold 0. *)
  type ('k, 'e, 'n) t = { data : ('k, 'e, Bigarray.c_layout) Bigarray.Array1.t; validity : 'n validity }
  type _ strings =
    | Strings : string array -> Codec.non_null strings
    | Strings_opt : string option array -> Codec.nullable strings

  (** Copy one chunk's column into [into] at [pos]; raises [Invalid_argument]
      if [into] is too short. *)
  val blit : ('a, _) Statement.Column.t @ local -> ('a, 'k, 'e) kind ->
    into:('k, 'e, Bigarray.c_layout) Bigarray.Array1.t @ local -> pos:int -> unit [@@zero_alloc]
  val blit_validity : ('a, Codec.nullable) Statement.Column.t @ local -> into:mask @ local -> pos:int -> unit [@@zero_alloc]

  (** Executes the statement and collects one column. A NULL in a [Non_null]
      collect is [Null] with the row absolute within the result. *)
  val collect : Statement.prepared @ local -> column:int -> ('a, 'k, 'e) kind ->
    'n Statement.Column.nulls -> (('k, 'e, 'n) t, Error.t) result
  val collect_strings : Statement.prepared @ local -> column:int -> string Scalar.t ->
    'n Statement.Column.nulls -> ('n strings, Error.t) result
end
```

For `Bulk.blit` to accept a public `Statement.Column.t`, `duckdb.mli`'s
`Statement.Column.t` must be the same type as `Column.t`; keep it abstract in
the `.mli` and let `duckdb.ml` define `module Column = Column`, which already
makes them equal inside the implementation.

- [ ] **Step 5: Run and verify it passes**

Run: `./tools/run build @all 2>&1 | tail -20 && ./tools/run runtest --force 2>&1 | grep -E "bulk:|intended rejections|FAIL|Error" | head`
Expected: three `bulk: …=ok` lines and `24 intended rejections`; exit 0.

- [ ] **Step 6: Commit**

```bash
jj describe -m "feat(bulk): collect columns into Bigarrays with one native copy per chunk

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>" && jj new
```

---

### Task 3: `Identity` codec plan

A refactor with no behaviour change: base-scalar codecs stop allocating
`Or_error.return` per value.

**Files:**
- Modify: `lib/duckdb/codec.ml`, `lib/duckdb/codec.mli`,
  `lib/duckdb/request.ml` (`encode_value`, `scalar_id`),
  `lib/duckdb/borrowed_chunk.ml` (`column`), and any other match on
  `Codec.Plan` (`grep -rn "Codec.Plan\|(Plan " lib`)

- [ ] **Step 1: Confirm the regression net is green**

Run: `./tools/run runtest --force 2>&1 | tail -3; echo exit=$?`
Expected: exit 0. These existing tests (codecs, custom codecs, NULL, decode
rejection) are this task's tests.

- [ ] **Step 2: Implement**

`codec.ml` and `codec.mli`, the plan type:

```ocaml
type 'a plan =
  | Identity : 'a Scalar.t -> 'a plan
  | Plan : { scalar : 'b Scalar.t; decode : 'b -> 'a Or_error.t; encode : 'a -> 'b Or_error.t } -> 'a plan
```

`codec.ml`:

```ocaml
  let of_scalar scalar = Non_null (Identity scalar)
  …
  let custom ~encode ~decode (Non_null base) =
    match base with
    | Identity scalar -> Non_null (Plan { scalar; decode; encode })
    | Plan base ->
      Non_null (Plan { scalar = base.scalar;
                       decode = (fun b -> Or_error.bind (base.decode b) ~f:decode);
                       encode = (fun a -> Or_error.bind (encode a) ~f:base.encode) })
```

`request.ml`:

```ocaml
let encode_plan : type a. a Codec.plan -> a -> bound Or_error.t = fun plan value ->
  match plan with
  | Codec.Identity scalar -> Ok (Bound (scalar, Some value))
  | Codec.Plan plan -> Or_error.map (plan.encode value) ~f:(fun b -> Bound (plan.scalar, Some b))
let encode_value : type a n. (a, n) Codec.t -> a -> bound Or_error.t = fun codec value ->
  match codec with
  | Codec.Non_null plan -> encode_plan plan value
  | Codec.Nullable plan ->
    match value with
    | None -> Ok (Bound ((match plan with Codec.Identity s -> Codec.Packed_scalar s | Codec.Plan p -> Codec.Packed_scalar p.scalar) |> fun (Codec.Packed_scalar s) -> Bound (s, None)) |> Result.ok |> Option.value_exn)
    | Some value -> encode_plan plan value
```

That `None` arm is clumsy; instead add to `codec.ml{,i}` a helper and use it
everywhere a plan's scalar is needed:

```ocaml
(* The base scalar a plan crosses the native boundary as. *)
type packed_scalar = Packed_scalar : 'b Scalar.t -> packed_scalar
let plan_scalar : type a. a plan -> packed_scalar = function
  | Identity s -> Packed_scalar s
  | Plan p -> Packed_scalar p.scalar
```

so the `None` arm is
`let (Codec.Packed_scalar s) = Codec.plan_scalar plan in Ok (Bound (s, None))`,
and `scalar_id` becomes:

```ocaml
let scalar_id : type a n. (a, n) Codec.t -> int * string = fun codec ->
  let (Codec.Packed_scalar s) = match codec with
    | Codec.Non_null plan -> Codec.plan_scalar plan
    | Codec.Nullable plan -> Codec.plan_scalar plan in
  Scalar.native_id s, Scalar.name s
```

`borrowed_chunk.ml`, `column`: replace the two plan arms by one helper that
reads the base value and decodes it, with `Identity` returning the value
unchanged:

```ocaml
      let decode_plan : type b. b Codec.plan -> (b option, Resource.error) result = function
        | Codec.Identity scalar -> get scalar
        | Codec.Plan plan ->
          (match get plan.scalar with
           | Error e -> Error e
           | Ok None -> Ok None
           | Ok (Some b) -> Result.map (decoded plan.decode b) ~f:Option.some) in
      match codec with
      | Codec.Nullable plan -> decode_plan plan
      | Codec.Non_null plan ->
        (match decode_plan plan with
         | Error e -> Error e
         | Ok None -> Error (Null { column; row })
         | Ok (Some a) -> Ok a)
```

Apply the same `Identity` split to every other `Codec.Plan` match the grep
finds (Parquet's type mapping, if any).

- [ ] **Step 3: Run the full suite**

Run: `./tools/run build @all 2>&1 | tail -5 && ./tools/run runtest --force 2>&1 | tail -5; echo exit=$?`
Expected: exit 0, no test output changed.

- [ ] **Step 4: Commit**

```bash
jj describe -m "refactor(codec): Identity plan for base scalars

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>" && jj new
```

---

### Task 4: Fast typed rows

**Files:**
- Create: `lib/duckdb/decode.ml`, `lib/duckdb/decode.mli`
- Modify: `lib/duckdb/dune` (`decode` private module), `lib/duckdb/request.ml`
  (`fold_decoded`)
- Modify: `test/test_request.ml`

- [ ] **Step 1: Write the failing tests**

Append to `test/test_request.ml`:

```ocaml
(* Arity 1, 8 (largest saturated) and 9 (curried fallback) decode identically. *)
let () =
  connected (fun c ->
    let one = R.many D.Fields.[] D.Fields.[int64] ~row:Fn.id "SELECT i::BIGINT FROM range(3000) t(i) ORDER BY i" in
    assert (List.length (ok (C.collect c one D.Args.[])) = 3000);
    let eight = R.many D.Fields.[] D.Fields.[int64; int64; int64; int64; int64; int64; int64; int64]
      ~row:(fun a b c d e f g h -> Int64.(a + b + c + d + e + f + g + h))
      "SELECT i, i, i, i, i, i, i, i FROM (SELECT i::BIGINT i FROM range(3000) t(i)) ORDER BY i" in
    let nine = R.many D.Fields.[] D.Fields.[int64; int64; int64; int64; int64; int64; int64; int64; nullable int64]
      ~row:(fun a b c d e f g h k -> Int64.(a + b + c + d + e + f + g + h + Option.value k ~default:0L))
      "SELECT i, i, i, i, i, i, i, i, CASE WHEN i % 2 = 0 THEN NULL ELSE i END FROM (SELECT i::BIGINT i FROM range(3000) t(i)) ORDER BY i" in
    let sum rows = List.fold rows ~init:0L ~f:Int64.( + ) in
    assert (Int64.equal (sum (ok (C.collect c eight D.Args.[]))) Int64.(8L * 4_498_500L));
    assert (Int64.equal (sum (ok (C.collect c nine D.Args.[]))) Int64.(8L * 4_498_500L + 2_250_000L)));
  Stdlib.print_endline "request: arities 1, 8 and 9 decode identically=ok"

(* A NULL after a Stop is never read; a NULL before it is reported with its absolute row. *)
let () =
  connected (fun c ->
    let q = R.many D.Fields.[] D.Fields.[int64] ~row:Fn.id
      "SELECT CASE WHEN i = 2100 THEN NULL ELSE i::BIGINT END FROM range(3000) t(i) ORDER BY i" in
    assert (Int64.equal (ok (C.fold c q D.Args.[] ~init:0L ~f:(fun x _ -> Ok (if Int64.(x = 5L) then D.Stop x else D.Continue x)))) 5L);
    ignore (failed "null row" (fun e -> match e.cause with Null { column = 0; row = 2100 } -> true | _ -> false)
      (C.collect c q D.Args.[]) : D.Error.t));
  Stdlib.print_endline "request: NULL reported at its absolute row, never after Stop=ok"

(* Within one row, the leftmost failing column is reported. *)
let () =
  connected (fun c ->
    let bad = D.Codec.Values.custom ~encode:Or_error.return
      ~decode:(fun (n : int64) -> if Int64.(n = 2049L) then Or_error.error_string "bad" else Ok n) D.Codec.Values.int64 in
    let q = R.many D.Fields.[] D.Fields.[bad; int64] ~row:(fun a b -> Int64.(a + b))
      "SELECT i::BIGINT, CASE WHEN i = 2049 THEN NULL ELSE i::BIGINT END FROM range(3000) t(i) ORDER BY i" in
    ignore (failed "leftmost" (fun e -> match e.cause with Decode_rejected { column = 0; row = 2049; _ } -> true | _ -> false)
      (C.collect c q D.Args.[]) : D.Error.t));
  Stdlib.print_endline "request: leftmost column failure wins within a row=ok"
```

(`C` here is the module alias the file already uses for `R.Session`; check the
top of the file and use the same name.)

- [ ] **Step 2: Run them**

Run: `./tools/run runtest --force 2>&1 | grep -E "request: (arities|NULL reported|leftmost)|FAIL"`
Expected: all three already pass on the slow path. They pin the semantics the
fast path must keep; continue.

- [ ] **Step 3: Implement `Decode`**

`lib/duckdb/decode.mli`:

```ocaml
(* Fast decoding of whole rows from a borrowed chunk whose result types were
   validated. *)
exception Rejected of { column : int; reason : Base.Error.t }

(* Rows [0, limit) can take the fast path: every declared column has exactly
   its declared engine type in this chunk and no non-null column has a NULL
   before [limit]. *)
val limit : (_, _, _) Fields.t -> Borrowed_chunk.t @ local -> length:int -> int

(* Decodes row [row]; raises [Rejected] for a custom decoder's rejection,
   evaluating columns left to right. Only for rows below [limit]. *)
val row : ('l, 'f, 'r) Fields.t -> 'f -> Borrowed_chunk.t @ local -> int -> 'r
```

`lib/duckdb/decode.ml`:

```ocaml
open! Base
module F = Duckdb_ffi
module S = Scalar
module I64 = Stdlib_upstream_compatible.Int64_u
module I32 = Stdlib_upstream_compatible.Int32_u
module F64 = Stdlib_upstream_compatible.Float_u
module F32 = Stdlib_stable.Float32_u
exception Rejected of { column : int; reason : Base.Error.t }

let rec limit_from : type l f r. (l, f, r) Fields.t -> F.prepared @ local -> column:int -> length:int -> int =
  fun fields p ~column ~length ->
  match fields with
  | Fields.[] -> length
  | Fields.(codec :: rest) ->
    let (Codec.Packed_scalar s), nullable = match codec with
      | Codec.Non_null plan -> Codec.plan_scalar plan, false
      | Codec.Nullable plan -> Codec.plan_scalar plan, true in
    if F.column_type p column <> S.native_id s then 0
    else
      let here = if nullable then length
        else match F.view_first_null p column length with -1 -> length | row -> row in
      Int.min here (limit_from rest p ~column:(column + 1) ~length)
let limit fields (chunk @ local) ~length =
  if F.column_count chunk.Borrowed_chunk.native < Fields.length fields then 0
  else limit_from fields chunk.native ~column:0 ~length

let base : type a. a S.t -> F.prepared @ local -> int -> int -> a = fun scalar p column row ->
  match scalar with
  | S.Int64 | S.Timestamp_s | S.Timestamp_ms | S.Timestamp_us | S.Timestamp_ns | S.Timestamp_tz ->
    I64.to_int64 (F.view_int64 p column row)
  | S.Int32 | S.Date -> I32.to_int32 (F.view_int32 p column row)
  | S.Int16 -> Stdlib_stable.Int16.of_int (F.view_int16 p column row)
  | S.Int8 -> Stdlib_stable.Int8.of_int (F.view_int8 p column row)
  | S.Bool -> F.view_bool p column row
  | S.Float64 -> F64.to_float (F.view_double p column row)
  | S.Float32 -> F32.to_float32 (F.view_float p column row)
  | S.String | S.Blob -> F.chunk_string p column row
let plan : type a. a Codec.plan -> F.prepared @ local -> int -> int -> a = fun plan p column row ->
  match plan with
  | Codec.Identity s -> base s p column row
  | Codec.Plan { scalar; decode; _ } ->
    match decode (base scalar p column row) with
    | Ok a -> a
    | Error reason -> raise_notrace (Rejected { column; reason })
let get : type a n. (a, n) Codec.t -> F.prepared @ local -> int -> int -> a = fun codec p column row ->
  match codec with
  | Codec.Non_null pl -> plan pl p column row
  | Codec.Nullable pl -> if F.view_valid p column row then Some (plan pl p column row) else None

let rec curried : type l f r. (l, f, r) Fields.t -> f -> F.prepared @ local -> column:int -> int -> r =
  fun fields fn p ~column row ->
  match fields with
  | Fields.[] -> fn
  | Fields.(c :: rest) -> let x = get c p column row in curried rest (fn x) p ~column:(column + 1) row

(* Saturated application up to arity 8. Each argument is bound in column
   order, so the leftmost failure is the one raised. *)
let row : type l f r. (l, f, r) Fields.t -> f -> Borrowed_chunk.t @ local -> int -> r =
  fun fields fn chunk row ->
  let p = chunk.Borrowed_chunk.native in
  match fields with
  | Fields.[] -> fn
  | Fields.[ a ] -> fn (get a p 0 row)
  | Fields.[ a; b ] -> let a = get a p 0 row in let b = get b p 1 row in fn a b
  | Fields.[ a; b; c ] ->
    let a = get a p 0 row in let b = get b p 1 row in let c = get c p 2 row in fn a b c
  | Fields.[ a; b; c; d ] ->
    let a = get a p 0 row in let b = get b p 1 row in let c = get c p 2 row in
    let d = get d p 3 row in fn a b c d
  | Fields.[ a; b; c; d; e ] ->
    let a = get a p 0 row in let b = get b p 1 row in let c = get c p 2 row in
    let d = get d p 3 row in let e = get e p 4 row in fn a b c d e
  | Fields.[ a; b; c; d; e; f ] ->
    let a = get a p 0 row in let b = get b p 1 row in let c = get c p 2 row in
    let d = get d p 3 row in let e = get e p 4 row in let f = get f p 5 row in fn a b c d e f
  | Fields.[ a; b; c; d; e; f; g ] ->
    let a = get a p 0 row in let b = get b p 1 row in let c = get c p 2 row in
    let d = get d p 3 row in let e = get e p 4 row in let f = get f p 5 row in
    let g = get g p 6 row in fn a b c d e f g
  | Fields.(a :: b :: c :: d :: e :: f :: g :: h :: rest) ->
    let a = get a p 0 row in let b = get b p 1 row in let c = get c p 2 row in
    let d = get d p 3 row in let e = get e p 4 row in let f = get f p 5 row in
    let g = get g p 6 row in let h = get h p 7 row in
    curried rest (fn a b c d e f g h) p ~column:8 row
```

`Fields.length` exists (from `Spine.Make`). `limit` reads `chunk_length`
through its caller; it checks types per chunk, so the fast reads are
memory-safe even if result validation ever accepted an unresolved type.

- [ ] **Step 4: Use it in `fold_decoded`**

`lib/duckdb/request.ml`, replace `fold_decoded`:

```ocaml
(* Folds decoded rows. The accumulator carries a request failure as an early
   Stop so the core fold still closes the result on every exit. Cancellation
   is checked once per chunk. Rows below [Decode.limit] decode on the fast
   path; from there on the per-cell path reports exactly the error it always
   did (NULL in a non-null column, a mistyped column). *)
let fold_decoded context fields fn ~validate result ~init ~f =
  let+ outcome, _ = within context (Query.fold_validated ~context result ~validate ~init:(Ok init, 0)
    ~f:(fun (chunk @ local) (acc, seen) ->
      let length = Query.chunk_length chunk in
      let limit = Decode.limit fields chunk ~length in
      let stop e row = Ok (Query.Stop (Error e, seen + row)) in
      let continue_with row acc value loop =
        match f value acc with
        | Error e -> stop e row
        | Ok (Query.Stop acc) -> Ok (Query.Stop (Ok acc, seen + row + 1))
        | Ok (Query.Continue acc) -> loop (row + 1) acc in
      let rec loop row acc =
        if row = length then Ok (Query.Continue (Ok acc, seen + length))
        else if row < limit then
          match Decode.row fields fn chunk row with
          | exception Decode.Rejected { column; reason } ->
            stop { context; cause = Decode_rejected { column; row = seen + row; reason } } row
          | value -> continue_with row acc value loop
        else
          match decode_row fields fn chunk ~column:0 ~row ~seen with
          | Error cause -> stop { context; cause } row
          | Ok value -> continue_with row acc value loop in
      match acc with
      | Error _ -> Ok (Query.Stop (acc, seen))
      | Ok acc ->
        match Query.result_checkpoint result with
        | Error cause -> Ok (Query.Stop (Error { context; cause }, seen))
        | Ok () -> loop 0 acc [@nontail])) in
  outcome
```

`decode.ml` needs `Query.chunk = Borrowed_chunk.t`; `Query.chunk` is already
that type (`query.ml:12`). If `Query.chunk` is abstract in `query.mli`, expose
`type chunk = Borrowed_chunk.t` there. If the compiler rejects
`continue_with`'s `loop` argument (a local closure passed in a tail call,
probe P7), inline `continue_with` into both arms instead.

Add `decode` to `private_modules` in `lib/duckdb/dune`.

- [ ] **Step 5: Run the full suite and the benchmark**

Run: `./tools/run build @all 2>&1 | tail -5 && ./tools/run runtest --force 2>&1 | tail -5; echo exit=$?`
Expected: exit 0, including the three new tests and every adapter, table,
Parquet, signal and cancellation test. If a cancellation test relied on a
checkpoint between rows of one chunk, report it as a concern (do not weaken
the test); the design accepts per-chunk checkpoints.

Run: `./tools/run exec -- python3 bench/run_benchmarks.py --rows 1000000 --warmups 2 --samples 10 --output-dir .local/perf/task4 && python3 -c "import json; s=json.load(open('.local/perf/task4/run-1-summary.json'))['summary']; print({p: (s[p]['process_ns']['median']/1e6, s[p]['minor_words']['median']) for p in s})"`
Expected: `owned_rows` median at or below ~110 ms. Record the numbers in the
commit message.

- [ ] **Step 6: Commit**

```bash
jj describe -m "perf(request): decode typed rows through the vector cache with saturated application

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>" && jj new
```

---

### Task 5: Staged row ingest

**Files:**
- Modify: `lib/ffi/appender_stubs.c`, `lib/ffi/duckdb_ffi.ml{,i}`,
  `lib/duckdb/appender.ml{,i}`, `lib/duckdb/request.ml` (`append`)
- Modify test hooks: `test/appender_hooks.c`, `test/dune` (wrap list of the
  appender test), `test/native_delivery/delivery_hooks.c`,
  `test/native_delivery/dune`, `test/eio/foundation_hooks.c`, `test/eio/dune`,
  `test/async/dune` and the async hook file it names, plus the OCaml tests
  that drive those hooks
- Modify: `test/test_table.ml`

- [ ] **Step 1: Write the failing tests**

Append to `test/test_table.ml` (reuse its helpers for connecting and counting;
read the top of the file first):

```ocaml
(* A batch larger than one native chunk lands whole and in order. *)
let () =
  connected (fun c ->
    ok (D.execute c "CREATE TABLE big(a BIGINT, b VARCHAR, f DOUBLE, d DATE)");
    let big = D.Table.(declare "big" Columns.["a", int64; "b", nullable string; "f", float64; "d", date]
      ~row:(fun a b f d -> (a, b, f, d))) in
    let rows = List.init 5000 ~f:(fun i ->
      D.Args.[Int64.of_int i; (if i % 3 = 0 then None else Some (Int.to_string i)); Float.of_int i; Int32.of_int_exn i]) in
    ok (D.Table.with_appender c big ~f:(fun a -> D.Table.append a rows));
    let back = ok (D.Request.Session.collect c
      (D.Request.many D.Fields.[] D.Fields.[int64; nullable string; float64; date] ~row:(fun a b f d -> (a, b, f, d))
         "SELECT a, b, f, d FROM big ORDER BY a") D.Args.[]) in
    assert (List.length back = 5000);
    List.iteri back ~f:(fun i (a, b, f, d) ->
      assert (Int64.equal a (Int64.of_int i));
      assert (Option.equal String.equal b (if i % 3 = 0 then None else Some (Int.to_string i)));
      assert (Float.equal f (Float.of_int i) && Int32.equal d (Int32.of_int_exn i))));
  Stdlib.print_endline "table: a 5000-row batch lands whole and in order=ok"

(* A codec rejection in the last row leaves the table untouched and does not
   poison the appender; it wins over a NULL in a NOT NULL column earlier. *)
let () =
  connected (fun c ->
    ok (D.execute c "CREATE TABLE strict(a BIGINT NOT NULL, b BIGINT)");
    let positive = D.Codec.Values.custom ~encode:(fun (n : int64) ->
      if Int64.(n > 0L) then Ok n else Or_error.error_string "not positive") ~decode:Or_error.return D.Codec.Values.int64 in
    let strict = D.Table.(declare "strict" Columns.["a", nullable int64; "b", positive] ~row:(fun a b -> (a, b))) in
    let outcome = D.Table.with_appender c strict ~f:(fun a ->
      (match D.Table.append a [ D.Args.[None; 1L]; D.Args.[Some 1L; 1L]; D.Args.[Some 2L; 0L] ] with
       | Error { cause = Encode_rejected { index = 2; _ }; _ } -> ()
       | _ -> failwith "expected Encode_rejected at the second column");
      D.Table.append a [ D.Args.[Some 3L; 3L] ]) in
    ok outcome;
    assert (Int64.equal (count c "strict") 1L));
  Stdlib.print_endline "table: codec rejection is atomic, unpoisoning and precedes NULL=ok"
```

(`count` and `connected` are the helpers of `test_table.ml`; if it lacks a
`count`, copy the one from `test_request.ml`. Adjust `index = 2` to what the
current code reports for the second declared column — run the test once
against the old code and use the value it reports, because this test pins
existing behaviour.)

- [ ] **Step 2: Run them against the current code**

Run: `./tools/run runtest --force 2>&1 | grep -E "table: (a 5000|codec rejection)|FAIL"`
Expected: both pass on the current row-by-row path (they pin behaviour).
Fix the `index` value if needed, then continue.

- [ ] **Step 3: Native staging pool**

`lib/ffi/appender_stubs.c`:

- Delete `append_cell`, `make_value`, `ml_duckdb_append_rows`, and the
  `cells`/`cell_count`/`rows` fields. `clear_input` becomes:

```c
static void clear_input(appender_owner *p) {
    if (p) p->staged_rows = 0;
}
```

- Add fields to `appender_owner`:

```c
    duckdb_logical_type *logical;   /* active column types, for staging chunks */
    duckdb_data_chunk *staged;      /* reusable staging chunks */
    size_t staged_capacity, staged_rows;
```

- Add a releaser, called from `delete_owner` (before freeing `types`) and at
  the start of a successful `ml_duckdb_appender_select_columns` remap (the
  active columns changed):

```c
static void release_staging(appender_owner *p) {
    for (size_t k = 0; k < p->staged_capacity; ++k) { duckdb_destroy_data_chunk(&p->staged[k]); duckdb_ml_released(); }
    if (p->staged) { free(p->staged); p->staged = NULL; duckdb_ml_released(); }
    p->staged_capacity = p->staged_rows = 0;
    if (p->logical) {
        for (idx_t i = 0; i < p->columns; ++i) duckdb_destroy_logical_type(&p->logical[i]);
        free(p->logical); p->logical = NULL; duckdb_ml_released();
    }
}
```

In `select_columns`, call `release_staging(p)` before replacing `p->columns`
(it destroys `p->columns` logical types, so it must run while the old count is
current).

- Add the staging stubs:

```c
/* Prepares staging for [rows] rows: ceil(rows / vector size) chunks of the
   active column types, reset to empty. Allocation failure leaves the
   appender's status set and stages nothing. Runs with the runtime held; it
   touches only this appender's own buffers. */
CAMLprim value ml_duckdb_stage_begin(value v, value rows) {
    appender_owner *p = Appender(v); size_t n = (size_t)Long_val(rows), size = duckdb_vector_size();
    if (!p || !p->appender) return Val_unit;
    size_t chunks = (n + size - 1) / size;
    if (!p->logical && p->columns) {
        p->logical = calloc(p->columns, sizeof(duckdb_logical_type));
        if (!p->logical) { error(p, "Cannot allocate staging types"); return Val_unit; }
        duckdb_ml_acquired();
        for (idx_t i = 0; i < p->columns; ++i) p->logical[i] = duckdb_appender_column_type(p->appender, i);
    }
    if (chunks > p->staged_capacity) {
        duckdb_data_chunk *grown = realloc(p->staged, chunks * sizeof(duckdb_data_chunk));
        if (!grown) { error(p, "Cannot allocate staging chunks"); return Val_unit; }
        if (!p->staged) duckdb_ml_acquired();
        p->staged = grown;
        for (size_t k = p->staged_capacity; k < chunks; ++k) {
            p->staged[k] = duckdb_create_data_chunk(p->logical, p->columns); duckdb_ml_acquired();
        }
        p->staged_capacity = chunks;
    }
    for (size_t k = 0; k < chunks; ++k) duckdb_data_chunk_reset(p->staged[k]);
    p->staged_rows = n;
    return Val_unit;
}
/* The staging slot of (column, row), or NULL when out of range. */
static void *slot(appender_owner *p, value column, value row, duckdb_vector *out, idx_t *index) {
    intnat c = Long_val(column), r = Long_val(row); size_t size = duckdb_vector_size();
    if (!p || c < 0 || (idx_t)c >= p->columns || r < 0 || (size_t)r >= p->staged_rows) return NULL;
    *out = duckdb_data_chunk_get_vector(p->staged[r / size], c); *index = r % size;
    return duckdb_vector_get_data(*out);
}
value ml_duckdb_stage_int64(value v, value column, value row, int64_t x) {
    appender_owner *p = Appender(v); duckdb_vector vec; idx_t i;
    void *d = slot(p, column, row, &vec, &i); if (!d) return Val_unit;
    switch (p->types[Long_val(column)]) {
    case DUCKDB_TYPE_BOOLEAN: ((bool *)d)[i] = x != 0; break;
    case DUCKDB_TYPE_TINYINT: ((int8_t *)d)[i] = (int8_t)x; break;
    case DUCKDB_TYPE_SMALLINT: ((int16_t *)d)[i] = (int16_t)x; break;
    case DUCKDB_TYPE_INTEGER: case DUCKDB_TYPE_DATE: ((int32_t *)d)[i] = (int32_t)x; break;
    case DUCKDB_TYPE_BIGINT: case DUCKDB_TYPE_TIMESTAMP: case DUCKDB_TYPE_TIMESTAMP_S:
    case DUCKDB_TYPE_TIMESTAMP_MS: case DUCKDB_TYPE_TIMESTAMP_NS: case DUCKDB_TYPE_TIMESTAMP_TZ:
        ((int64_t *)d)[i] = x; break;
    default: break;
    }
    return Val_unit;
}
value ml_duckdb_stage_int64_byte(value v, value c, value r, value x) { return ml_duckdb_stage_int64(v, c, r, Int64_val(x)); }
value ml_duckdb_stage_float(value v, value column, value row, double x) {
    appender_owner *p = Appender(v); duckdb_vector vec; idx_t i;
    void *d = slot(p, column, row, &vec, &i); if (!d) return Val_unit;
    switch (p->types[Long_val(column)]) {
    case DUCKDB_TYPE_FLOAT: ((float *)d)[i] = (float)x; break;
    case DUCKDB_TYPE_DOUBLE: ((double *)d)[i] = x; break;
    default: break;
    }
    return Val_unit;
}
value ml_duckdb_stage_float_byte(value v, value c, value r, value x) { return ml_duckdb_stage_float(v, c, r, Double_val(x)); }
/* DuckDB copies the bytes into the vector's own string heap. */
value ml_duckdb_stage_string(value v, value column, value row, value s) {
    appender_owner *p = Appender(v); duckdb_vector vec; idx_t i;
    if (!slot(p, column, row, &vec, &i)) return Val_unit;
    int t = p->types[Long_val(column)];
    if (t == DUCKDB_TYPE_VARCHAR || t == DUCKDB_TYPE_BLOB)
        duckdb_vector_assign_string_element_len(vec, i, String_val(s), caml_string_length(s));
    return Val_unit;
}
value ml_duckdb_stage_null(value v, value column, value row) {
    appender_owner *p = Appender(v); duckdb_vector vec; idx_t i;
    if (!slot(p, column, row, &vec, &i)) return Val_unit;
    duckdb_vector_ensure_validity_writable(vec);
    duckdb_validity_set_row_invalid(duckdb_vector_get_validity(vec), i);
    return Val_unit;
}
value ml_duckdb_clear_stage(value v) { clear_input(Appender(v)); return Val_unit; }
/* Appends every staged chunk. Each chunk is one interruptible engine call;
   the first failure stops the batch and is reported through the status. */
CAMLprim value ml_duckdb_append_staged(value v) {
    CAMLparam1(v); appender_owner *p = Appender(v);
    size_t size = duckdb_vector_size(), rows = p->staged_rows, chunks = (rows + size - 1) / size;
    for (size_t k = 0; k < chunks; ++k)
        duckdb_data_chunk_set_size(p->staged[k], k + 1 < chunks ? size : rows - k * size);
    caml_enter_blocking_section();
    duckdb_ml_native_work_begin(p->parent);
    for (size_t k = 0; k < chunks && admit_user(p); ++k) {
        duckdb_state state = duckdb_append_data_chunk(p->appender, p->staged[k]);
        duckdb_ml_native_user_call_end(p->parent);
        check(p, state, DUCKDB_ML_RUNTIME_RELEASED);
    }
    clear_input(p);
    duckdb_ml_native_work_end(p->parent);
    caml_leave_blocking_section(); caml_process_pending_actions(); CAMLreturn(Val_unit);
}
```

`duckdb_ffi.ml` (and matching declarations in `duckdb_ffi.mli`): delete
`append_cell` and `append_rows`; add

```ocaml
external stage_begin : appender -> int -> unit = "ml_duckdb_stage_begin" [@@noalloc]
external stage_int64 : appender -> int -> int -> int64# -> unit
  = "ml_duckdb_stage_int64_byte" "ml_duckdb_stage_int64" [@@noalloc]
external stage_float : appender -> int -> int -> float# -> unit
  = "ml_duckdb_stage_float_byte" "ml_duckdb_stage_float" [@@noalloc]
external stage_string : appender -> int -> int -> string -> unit = "ml_duckdb_stage_string" [@@noalloc]
external stage_null : appender -> int -> int -> unit = "ml_duckdb_stage_null" [@@noalloc]
external clear_stage : appender -> unit = "ml_duckdb_clear_stage" [@@noalloc]
external append_staged : appender -> unit = "ml_duckdb_append_staged"
```

- [ ] **Step 4: Appender and `Table.append`**

`lib/duckdb/appender.mli`: delete `cell`/`append_rows`; add

```ocaml
(* Staging writes only this appender's own chunks and runs outside admission.
   [append_staged] then appends them in one admission: a poisoned/closed
   appender reports its failure first, then [null] (a NULL staged into a NOT
   NULL column, as (column, row)) poisons, then engine errors poison. Staging
   is cleared on every exit. *)
val native : appender -> Duckdb_ffi.appender
val nullable : appender -> int -> bool
val append_staged : appender -> null:(int * int) option -> (unit, error) result
```

`lib/duckdb/appender.ml`: delete `cell`, `encode`, `validate_cell`,
`validate_row`, `append_rows`; add

```ocaml
let native a = a.native
let nullable a column = a.nullable.(column)
let append_staged a ~null =
  Exn.protect ~finally:(fun () -> F.clear_stage a.native) ~f:(fun () ->
    operation a (fun () ->
      match null with
      | Some (column, row) -> Error (Null { column; row })
      | None ->
        let* () = checkpoint (connection a) in
        F.append_staged a.native;
        status a.native))
```

`lib/duckdb/request.ml`, replace `append`:

```ocaml
(* Staging. Values are written straight into the appender's staging chunks;
   a custom encoder's rejection aborts the batch before any native append. *)
exception Stage_rejected of { index : int; reason : Base.Error.t }
module I64u = Stdlib_upstream_compatible.Int64_u
module F64u = Stdlib_upstream_compatible.Float_u
let stage_base : type b. Duckdb_ffi.appender -> b Scalar.t -> column:int -> row:int -> b -> unit =
  fun native scalar ~column ~row value ->
  let int n = Duckdb_ffi.stage_int64 native column row (I64u.of_int n) in
  match scalar with
  | Scalar.Int64 | Timestamp_s | Timestamp_ms | Timestamp_us | Timestamp_ns | Timestamp_tz ->
    Duckdb_ffi.stage_int64 native column row (I64u.of_int64 value)
  | Int32 | Date -> Duckdb_ffi.stage_int64 native column row (I64u.of_int32 value)
  | Int16 -> int (Stdlib_stable.Int16.to_int value)
  | Int8 -> int (Stdlib_stable.Int8.to_int value)
  | Bool -> int (if value then 1 else 0)
  | Float64 -> Duckdb_ffi.stage_float native column row (F64u.of_float value)
  | Float32 -> Duckdb_ffi.stage_float native column row (F64u.of_float (Stdlib_stable.Float32.to_float value))
  | String | Blob -> Duckdb_ffi.stage_string native column row value
let stage_plan : type a. Duckdb_ffi.appender -> a Codec.plan -> column:int -> row:int -> index:int -> a -> unit =
  fun native plan ~column ~row ~index value ->
  match plan with
  | Codec.Identity scalar -> stage_base native scalar ~column ~row value
  | Codec.Plan p ->
    match p.encode value with
    | Ok b -> stage_base native p.scalar ~column ~row b
    | Error reason -> raise_notrace (Stage_rejected { index; reason })
(* Returns the first column of this row holding a NULL the catalog forbids. *)
let rec stage_row : type l f r. Appender.appender -> (l, f, r) Fields.t -> l Args.t -> column:int -> row:int -> int option =
  fun a fields args ~column ~row ->
  let native = Appender.native a in
  match fields, args with
  | Fields.[], Args.[] -> None
  | Fields.(codec :: fields), Args.(value :: args) ->
    let index = column + 1 in
    let here = match codec, value with
      | Codec.Non_null plan, value -> stage_plan native plan ~column ~row ~index value; None
      | Codec.Nullable _, None ->
        Duckdb_ffi.stage_null native column row;
        if Appender.nullable a column then None else Some column
      | Codec.Nullable plan, Some value -> stage_plan native plan ~column ~row ~index value; None in
    let rest = stage_row a fields args ~column:(column + 1) ~row in
    (match here with Some _ -> here | None -> rest)
(* A codec rejection rejects the whole batch before any native row. *)
let append (type c) (a : (c, _) appender) (rows : c Args.t list) =
  let (Table_def t) = a.table in
  let context = table_context a.table in
  let fields = fields_of_columns t.columns in
  let native = Appender.native a.core in
  Duckdb_ffi.stage_begin native (List.length rows);
  match List.foldi rows ~init:None ~f:(fun row first args ->
    let here = stage_row a.core fields args ~column:0 ~row in
    match first with Some _ -> first | None -> Option.map here ~f:(fun column -> column, row)) with
  | exception Stage_rejected { index; reason } ->
    Duckdb_ffi.clear_stage native;
    Error { context; cause = Encode_rejected { index; reason } }
  | exception exn -> Duckdb_ffi.clear_stage native; raise exn
  | null -> within context (Appender.append_staged a.core ~null)
```

`Stage_rejected`'s `index` must equal what the old path reported
(`encode_args … ~index:1` numbered columns from 1); the Step 1 test pins it.
`I64u.of_int32` exists in `Stdlib_upstream_compatible.Int64_u`. Add
`stdlib_upstream_compatible` to `lib/duckdb/dune`'s `libraries` if Task 1 did
not.

The old path checked the declared type against the catalog per cell; that
check already happens once in `open_typed` (`check_types … Appender.types`),
so it is not repeated.

- [ ] **Step 5: Migrate the native test hooks**

The appender no longer calls `duckdb_appender_begin_row`,
`duckdb_append_value` or `duckdb_appender_end_row`, and `ml_duckdb_append_rows`
is gone. Every hook that gated, counted or failed those calls now targets
`duckdb_append_data_chunk` (one call per staged chunk), and every hook on
`ml_duckdb_append_rows` targets `ml_duckdb_append_staged` (one argument:
replace `ENTRY2(ml_duckdb_append_rows, 35)` with
`ENTRY1(ml_duckdb_append_staged, 35)`).

Find them: `grep -rn "append_value\|appender_begin_row\|appender_end_row\|append_rows" test`.

For each:
- In the dune `link_flags`, replace the `--wrap` of the three row calls with
  one `-Wl,--wrap=duckdb_append_data_chunk`.
- In the C hook, rewrite the wrapper with the same gate/counter/fault logic
  around `__real_duckdb_append_data_chunk(duckdb_appender, duckdb_data_chunk)`.
- A gate that waited for "row N" (`typed_row`, `appender_auto_row`) now waits
  for "chunk N". The OCaml tests that set it pass a chunk number: a test that
  paused at row 1 now pauses at chunk 1. A test that relied on an automatic
  flush at a particular row must now produce it with a batch large enough that
  DuckDB auto-flushes inside `duckdb_append_data_chunk` (DuckDB flushes after
  its row group is full; use the existing test's batch size and check the
  hook fires; if the original intent cannot be reproduced, keep the test's
  claim with the nearest chunk-level equivalent and state the mapping in the
  commit message).
- Counter assertions that counted rows now count chunks.

The claims to preserve (read each test's comment): a pause during native
append lets cancellation and poisoning be observed; an engine error during
append (including an automatic flush) poisons the appender and the
transaction; delivery counters stay balanced.

- [ ] **Step 6: Run everything**

Run: `./tools/run build @all 2>&1 | tail -5 && ./tools/run runtest --force 2>&1 | tail -10; echo exit=$?`
Expected: exit 0, including both new table tests, `test_appender*`,
`native_delivery`, `async`, `eio` and `resource_lifecycle`.

Run the sanitizer build of the table tests:

```bash
ASAN_OPTIONS=detect_leaks=0:halt_on_error=1 UBSAN_OPTIONS=halt_on_error=1 \
  ./tools/run exec --profile stage3a-sanitize --build-dir "$PWD/.local/build-sanitize" test/test_table.exe
```

Expected: the test's `=ok` lines, no sanitizer report.

- [ ] **Step 7: Commit**

```bash
jj describe -m "perf(table): stage appended rows into data chunks

Rows are encoded straight into reusable native chunks and appended with
duckdb_append_data_chunk; the per-cell tuples and duckdb_value round trips
are gone. Error precedence and batch atomicity are unchanged. Test hooks
that gated row-level appender calls now gate chunk appends.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>" && jj new
```

---

### Task 6: Columnar `Table.append_columns`

**Files:**
- Modify: `lib/ffi/appender_stubs.c`, `lib/ffi/duckdb_ffi.ml{,i}`,
  `lib/duckdb/bulk.ml{,i}` (`Columns`), `lib/duckdb/failure.ml{,i}`,
  `lib/duckdb/appender.ml{,i}`, `lib/duckdb/request.ml`, `lib/duckdb/table.ml`,
  `lib/duckdb/duckdb.ml`, `lib/duckdb/duckdb.mli`
- Modify: `test/test_bulk.ml`, `test/request_compile/positive.ml`
- Create fixtures in `test/request_compile/`: `columns_missing.ml.fail`,
  `columns_order.ml.fail`, `columns_type.ml.fail`, `columns_null_mask.ml.fail`,
  `columns_custom.ml.fail`; modify `test/check_request_types.sh`

- [ ] **Step 1: Write the compile fixtures**

Each fixture starts with:

```ocaml
module D = Duckdb
module A1 = Bigarray.Array1
let ids = A1.create Bigarray.int64 Bigarray.c_layout 2
let mask = A1.create Bigarray.int8_unsigned Bigarray.c_layout 2
let users = D.Table.(declare "users" Columns.["id", int64; "name", string; "age", nullable int32]
  ~row:(fun id name age -> (id, name, age)))
```

and ends with one line:

- `columns_missing.ml.fail`:
  `let f (a @ local) = D.Table.append_columns a D.Bulk.Columns.[Int64 (D.Scalar.Int64, ids); Strings (D.Scalar.String, [| "a"; "b" |])]`
  (with `a : (_, _) D.Table.appender` for `users`; write the parameter as
  `(a : (int64 * (string * (int32 option * unit)), _) D.Table.appender @ local)`)
- `columns_order.ml.fail`: same parameter, columns
  `[Strings (D.Scalar.String, [||]); Int64 (D.Scalar.Int64, ids); Nullable (Int32 (D.Scalar.Int32, A1.create Bigarray.int32 Bigarray.c_layout 2), mask)]`
- `columns_type.ml.fail`: columns
  `[Float64 (A1.create Bigarray.float64 Bigarray.c_layout 2); Strings (D.Scalar.String, [||]); Nullable (Int32 (D.Scalar.Int32, A1.create Bigarray.int32 Bigarray.c_layout 2), mask)]`
- `columns_null_mask.ml.fail`: columns
  `[Nullable (Int64 (D.Scalar.Int64, ids), mask); Strings (D.Scalar.String, [||]); Nullable (Int32 (D.Scalar.Int32, A1.create Bigarray.int32 Bigarray.c_layout 2), mask)]`
- `columns_custom.ml.fail`: declare instead
  `type user_id = User_id of int64` and a table whose first column is
  `D.Codec.Values.custom ~encode:(fun (User_id n) -> Ok n) ~decode:(fun n -> Ok (User_id n)) D.Codec.Values.int64`,
  then append `[Int64 (D.Scalar.Int64, ids)]` to it.

In `check_request_types.sh` add (each needle is a type the error names):

```bash
expect columns_missing '"unit"' 'int32 option * unit'
expect columns_order 'type "string"' 'type "int64"'
expect columns_type 'type "float"' 'type "int64"'
expect columns_null_mask 'int64 option' 'type "int64"'
expect columns_custom 'user_id' 'type "int64"'
```

bump the count to 29, and add to `positive.ml`:

```ocaml
let _columns (a : (int64 * (string * (int32 option * unit)), _) D.Table.appender @ local) =
  let module A1 = Bigarray.Array1 in
  D.Table.append_columns a D.Bulk.Columns.[
    Int64 (D.Scalar.Int64, A1.create Bigarray.int64 Bigarray.c_layout 0);
    Strings (D.Scalar.String, [||]);
    Nullable (Int32 (D.Scalar.Int32, A1.create Bigarray.int32 Bigarray.c_layout 0),
              A1.create Bigarray.int8_unsigned Bigarray.c_layout 0) ]
```

Run the script once against the finished implementation and tighten each
needle to the message the compiler actually prints (keep two needles each).

- [ ] **Step 2: Write the runtime test**

Append to `test/test_bulk.ml`:

```ocaml
(* Columnar ingest across chunk boundaries, with NULL masks and strings. *)
let () =
  connected (fun c ->
    ok (D.execute c "CREATE TABLE users(id BIGINT, name VARCHAR, age INTEGER)");
    let users = D.Table.(declare "users" Columns.["id", int64; "name", string; "age", nullable int32]
      ~row:(fun id name age -> (id, name, age))) in
    let n = 5000 in
    let ids = A1.init Bigarray.int64 Bigarray.c_layout n Int64.of_int in
    let ages = A1.init Bigarray.int32 Bigarray.c_layout n Int32.of_int_trunc in
    let valid = A1.init Bigarray.int8_unsigned Bigarray.c_layout n (fun i -> if i % 4 = 0 then 0 else 1) in
    let names = Array.init n ~f:(fun i -> "u" ^ Int.to_string i) in
    ok (D.Table.with_appender c users ~f:(fun a ->
      D.Table.append_columns a D.Bulk.Columns.[
        Int64 (D.Scalar.Int64, ids); Strings (D.Scalar.String, names); Nullable (Int32 (D.Scalar.Int32, ages), valid) ]));
    let back = ok (D.Request.Session.collect c (D.Table.select users) D.Args.[]) in
    let back = List.sort back ~compare:(fun (a, _, _) (b, _, _) -> Int64.compare a b) in
    assert (List.length back = n);
    List.iteri back ~f:(fun i (id, name, age) ->
      assert (Int64.equal id (Int64.of_int i) && String.equal name ("u" ^ Int.to_string i));
      assert (Option.equal Int32.equal age (if i % 4 = 0 then None else Some (Int32.of_int_trunc i)))));
  Stdlib.print_endline "bulk: append_columns across chunks with masks and strings=ok"

(* Runtime rejections, all before any native work. Masks are all-valid except
   in the NULL case, so each attempt trips exactly one check. *)
let () =
  connected (fun c ->
    ok (D.execute c "CREATE TABLE t(a BIGINT NOT NULL, ts TIMESTAMP, v BIGINT)");
    let positive = D.Codec.Values.custom ~encode:(fun (n : int64) -> if Int64.(n > 0L) then Ok n else Or_error.error_string "neg")
      ~decode:Or_error.return D.Codec.Values.int64 in
    let custom = D.Table.(declare "t" Columns.["a", nullable int64; "ts", timestamp_us; "v", positive] ~row:(fun a ts v -> (a, ts, v))) in
    let plain = D.Table.(declare "t" Columns.["a", nullable int64; "ts", timestamp_us; "v", int64] ~row:(fun a ts v -> (a, ts, v))) in
    let i64 n = A1.create Bigarray.int64 Bigarray.c_layout n in
    let valid n = A1.init Bigarray.int8_unsigned Bigarray.c_layout n (fun _ -> 1) in
    let hole n = A1.init Bigarray.int8_unsigned Bigarray.c_layout n (fun i -> if i = 1 then 0 else 1) in
    let attempt table cols = D.Table.with_appender c table ~f:(fun a -> D.Table.append_columns a cols) in
    (match attempt plain D.Bulk.Columns.[Nullable (Int64 (D.Scalar.Int64, i64 3), valid 3); Int64 (D.Scalar.Timestamp_us, i64 2); Int64 (D.Scalar.Int64, i64 3)] with
     | Error { cause = Length_mismatch { column = 1; expected = 3; actual = 2 }; _ } -> ()
     | _ -> failwith "length mismatch expected");
    (match attempt plain D.Bulk.Columns.[Nullable (Int64 (D.Scalar.Int64, i64 3), valid 3); Int64 (D.Scalar.Int64, i64 3); Int64 (D.Scalar.Int64, i64 3)] with
     | Error { cause = Type_mismatch { index = 1; _ }; _ } -> ()
     | _ -> failwith "engine scalar mismatch expected");
    (match attempt custom D.Bulk.Columns.[Nullable (Int64 (D.Scalar.Int64, i64 3), valid 3); Int64 (D.Scalar.Timestamp_us, i64 3); Int64 (D.Scalar.Int64, i64 3)] with
     | Error { cause = Encode_rejected { index = 3; _ }; _ } -> ()
     | _ -> failwith "custom codec rejection expected");
    (match attempt plain D.Bulk.Columns.[Nullable (Int64 (D.Scalar.Int64, i64 3), hole 3); Int64 (D.Scalar.Timestamp_us, i64 3); Int64 (D.Scalar.Int64, i64 3)] with
     | Error { cause = Null { column = 0; row = 1 }; _ } -> ()
     | _ -> failwith "NULL in NOT NULL column expected");
    assert (Int64.equal (ok (D.Request.Session.find c (D.Request.one D.Fields.[] D.Fields.[int64] ~row:Fn.id
      "SELECT count(*)::BIGINT FROM t") D.Args.[])) 0L));
  Stdlib.print_endline "bulk: append_columns rejects lengths, scalars, custom codecs and NULLs before native work=ok"
```

`Encode_rejected.index = 3` for the third column follows the row path's
one-based numbering (Task 5 pinned it; if Task 5 found a different base, use
it here too). `Length_mismatch.column` is zero-based like `Null.column`.

- [ ] **Step 3: Run and verify both fail**

Run: `./tools/run runtest --force 2>&1 | tail -20`
Expected: `Unbound module D.Bulk.Columns` / `Unbound value D.Table.append_columns`.

- [ ] **Step 4: Native column blits**

`lib/ffi/appender_stubs.c`:

```c
static size_t stage_width(int t) {
    switch (t) {
    case DUCKDB_TYPE_BOOLEAN: case DUCKDB_TYPE_TINYINT: return 1;
    case DUCKDB_TYPE_SMALLINT: return 2;
    case DUCKDB_TYPE_INTEGER: case DUCKDB_TYPE_DATE: case DUCKDB_TYPE_FLOAT: return 4;
    case DUCKDB_TYPE_BIGINT: case DUCKDB_TYPE_DOUBLE: case DUCKDB_TYPE_TIMESTAMP:
    case DUCKDB_TYPE_TIMESTAMP_S: case DUCKDB_TYPE_TIMESTAMP_MS: case DUCKDB_TYPE_TIMESTAMP_NS:
    case DUCKDB_TYPE_TIMESTAMP_TZ: return 8;
    default: return 0;
    }
}
/* Copies [n] elements of [ba] from [pos] into staging rows [0, n) of
   [column]. Booleans are normalized to 0/1. Copies nothing on a width
   mismatch or out-of-range request; OCaml checks both first. */
value ml_duckdb_stage_blit(value v, value column, value ba, value pos, value count) {
    appender_owner *p = Appender(v); intnat c = Long_val(column), at = Long_val(pos), n = Long_val(count);
    struct caml_ba_array *b = Caml_ba_array_val(ba);
    if (!p || c < 0 || (idx_t)c >= p->columns || n < 0 || (size_t)n > p->staged_rows || n > (intnat)duckdb_vector_size()) return Val_unit;
    size_t w = stage_width(p->types[c]);
    if (!w || w != (size_t)caml_ba_element_size[b->flags & CAML_BA_KIND_MASK] || at < 0 || at > b->dim[0] - n) return Val_unit;
    char *d = duckdb_vector_get_data(duckdb_data_chunk_get_vector(p->staged[0], c));
    const char *s = (const char *)b->data + (size_t)at * w;
    if (p->types[c] == DUCKDB_TYPE_BOOLEAN) for (intnat i = 0; i < n; ++i) ((bool *)d)[i] = s[i] != 0;
    else memcpy(d, s, (size_t)n * w);
    return Val_unit;
}
/* Marks staging rows [0, n) of [column] NULL where [mask] is 0. */
value ml_duckdb_stage_mask(value v, value column, value mask, value pos, value count) {
    appender_owner *p = Appender(v); intnat c = Long_val(column), at = Long_val(pos), n = Long_val(count);
    struct caml_ba_array *b = Caml_ba_array_val(mask);
    if (!p || c < 0 || (idx_t)c >= p->columns || n < 0 || (size_t)n > p->staged_rows || n > (intnat)duckdb_vector_size()) return Val_unit;
    if ((b->flags & CAML_BA_KIND_MASK) != CAML_BA_UINT8 || at < 0 || at > b->dim[0] - n) return Val_unit;
    const uint8_t *m = (const uint8_t *)b->data + at;
    duckdb_vector vec = duckdb_data_chunk_get_vector(p->staged[0], c);
    for (intnat i = 0; i < n; ++i) if (!m[i]) {
        duckdb_vector_ensure_validity_writable(vec);
        duckdb_validity_set_row_invalid(duckdb_vector_get_validity(vec), i);
    }
    return Val_unit;
}
```

Add `#include <caml/bigarray.h>` at the top. `duckdb_ffi.ml{,i}`:

```ocaml
external stage_blit : appender -> int -> ('a, 'b, Bigarray.c_layout) Bigarray.Array1.t -> int -> int -> unit
  = "ml_duckdb_stage_blit" [@@noalloc]
external stage_mask : appender -> int -> (int, Bigarray.int8_unsigned_elt, Bigarray.c_layout) Bigarray.Array1.t -> int -> int -> unit
  = "ml_duckdb_stage_mask" [@@noalloc]
```

- [ ] **Step 5: `Length_mismatch`, `Bulk.Columns`, `append_columns`**

`failure.ml` and `failure.mli`, in `cause` after `Index`:

```ocaml
  | Length_mismatch of { column : int; expected : int; actual : int }
```

`duckdb.mli`, `Error.cause`, same place:

```ocaml
    | Length_mismatch of { column : int; expected : int; actual : int }
    (** [Table.append_columns]: this zero-based column (or its NULL mask) has
        [actual] rows where the first column has [expected]. *)
```

Add a `Length_mismatch _ -> "Length_mismatch"` arm anywhere the tests or
library pretty-print causes exhaustively (`grep -rn "Destination_exists ->" lib test`).

`bulk.ml` and `bulk.mli` (in `bulk.mli` write the type definitions in full,
same text):

```ocaml
module Columns = struct
  type _ col =
    | Int64 : int64 Scalar.t * (int64, Bigarray.int64_elt, Bigarray.c_layout) Bigarray.Array1.t -> int64 col
    | Int32 : int32 Scalar.t * (int32, Bigarray.int32_elt, Bigarray.c_layout) Bigarray.Array1.t -> int32 col
    | Int16 : (int, Bigarray.int16_signed_elt, Bigarray.c_layout) Bigarray.Array1.t -> int16 col
    | Int8 : (int, Bigarray.int8_signed_elt, Bigarray.c_layout) Bigarray.Array1.t -> int8 col
    | Bool : (int, Bigarray.int8_unsigned_elt, Bigarray.c_layout) Bigarray.Array1.t -> bool col
    | Float64 : (float, Bigarray.float64_elt, Bigarray.c_layout) Bigarray.Array1.t -> float col
    | Float32 : (float, Bigarray.float32_elt, Bigarray.c_layout) Bigarray.Array1.t -> float32 col
    | Strings : string Scalar.t * string array -> string col
    | Nullable : 'a col * mask -> 'a option col
  type _ t = [] : unit t | (::) : 'a col * 'l t -> ('a * 'l) t
end
```

Copy the same `Columns` signature into `duckdb.mli`'s `Bulk` with this doc:
`(** Whole columns for [Table.append_columns], indexed by the table's declared
column types. [Nullable] pairs a column with its mask (1 valid, 0 NULL). *)`

`appender.ml{,i}`:

```ocaml
(* Appends [rows] rows slice by slice inside one admission: [stage ~pos ~n]
   fills staging rows [0, n) from input rows [pos, pos + n), then the slice is
   appended. Cancellation is checked per slice; failures poison as
   [append_staged]. *)
val append_slices : appender -> rows:int -> stage:(pos:int -> n:int -> unit) -> (unit, error) result
```

```ocaml
let append_slices a ~rows ~stage =
  let size = 2048 in
  Exn.protect ~finally:(fun () -> F.clear_stage a.native) ~f:(fun () ->
    operation a (fun () ->
      let rec slice pos =
        if pos >= rows then Ok ()
        else
          let n = Int.min size (rows - pos) in
          let* () = checkpoint (connection a) in
          F.stage_begin a.native n;
          stage ~pos ~n;
          F.append_staged a.native;
          let* () = status a.native in
          slice (pos + n) in
      slice 0))
```

(`2048` is DuckDB's vector size; `stage_begin` with `n ≤ 2048` makes exactly
one staging chunk, which `stage_blit`/`stage_mask` write as chunk 0.)

`request.ml`:

```ocaml
(* Columnar ingest. Every check runs before any native work. *)
let rec bulk_length : type a. a Bulk.Columns.col -> int = function
  | Bulk.Columns.Int64 (_, d) -> Bigarray.Array1.dim d | Int32 (_, d) -> Bigarray.Array1.dim d
  | Int16 d -> Bigarray.Array1.dim d | Int8 d -> Bigarray.Array1.dim d
  | Bool d -> Bigarray.Array1.dim d | Float64 d -> Bigarray.Array1.dim d
  | Float32 d -> Bigarray.Array1.dim d | Strings (_, s) -> Array.length s
  | Nullable (inner, _) -> bulk_length inner
let rec bulk_scalar : type a. a Bulk.Columns.col -> Codec.packed_scalar = function
  | Bulk.Columns.Int64 (s, _) -> Codec.Packed_scalar s | Int32 (s, _) -> Codec.Packed_scalar s
  | Int16 _ -> Codec.Packed_scalar Scalar.Int16 | Int8 _ -> Codec.Packed_scalar Scalar.Int8
  | Bool _ -> Codec.Packed_scalar Scalar.Bool | Float64 _ -> Codec.Packed_scalar Scalar.Float64
  | Float32 _ -> Codec.Packed_scalar Scalar.Float32 | Strings (s, _) -> Codec.Packed_scalar s
  | Nullable (inner, _) -> bulk_scalar inner
let first_zero mask ~len =
  let rec go i = if i = len then None else if mask.{i} = 0 then Some i else go (i + 1) in go 0
let rec check_columns_bulk : type l f r. Appender.appender -> (l, f, r) Columns.t -> l Bulk.Columns.t ->
  column:int -> rows:int -> (unit, cause) Result.t = fun a declared bulk ~column ~rows ->
  match declared, bulk with
  | Columns.[], Bulk.Columns.[] -> Ok ()
  | Columns.((_, codec) :: declared), Bulk.Columns.(col :: bulk) ->
    let length = bulk_length col in
    let mask_length = match col with Nullable (_, m) -> Bigarray.Array1.dim m | _ -> length in
    let custom = match codec with
      | Codec.Non_null (Codec.Plan _) | Codec.Nullable (Codec.Plan _) -> true
      | Codec.Non_null (Codec.Identity _) | Codec.Nullable (Codec.Identity _) -> false in
    let (Codec.Packed_scalar s) = bulk_scalar col in
    let actual = (Appender.types a).(column) in
    let* () =
      if length <> rows then Error (Length_mismatch { column; expected = rows; actual = length })
      else if mask_length <> rows then Error (Length_mismatch { column; expected = rows; actual = mask_length })
      else if custom then
        Error (Encode_rejected { index = column + 1;
          reason = Base.Error.of_string "a column with a custom codec cannot be appended in bulk" })
      else if actual <> Scalar.native_id s then
        Error (Type_mismatch { index = column; expected = Scalar.name s; actual = type_name actual })
      else match col with
        | Nullable (_, m) when not (Appender.nullable a column) ->
          (match first_zero m ~len:rows with Some row -> Error (Null { column; row }) | None -> Ok ())
        | _ -> Ok () in
    check_columns_bulk a declared bulk ~column:(column + 1) ~rows
let rec stage_columns : type l. Duckdb_ffi.appender -> l Bulk.Columns.t -> column:int -> pos:int -> n:int -> unit =
  fun native bulk ~column ~pos ~n ->
  let rec stage_col : type a. a Bulk.Columns.col -> unit = function
    | Int64 (_, d) -> Duckdb_ffi.stage_blit native column d pos n
    | Int32 (_, d) -> Duckdb_ffi.stage_blit native column d pos n
    | Int16 d -> Duckdb_ffi.stage_blit native column d pos n
    | Int8 d -> Duckdb_ffi.stage_blit native column d pos n
    | Bool d -> Duckdb_ffi.stage_blit native column d pos n
    | Float64 d -> Duckdb_ffi.stage_blit native column d pos n
    | Float32 d -> Duckdb_ffi.stage_blit native column d pos n
    | Strings (_, s) -> for i = 0 to n - 1 do Duckdb_ffi.stage_string native column i s.(pos + i) done
    | Nullable (inner, m) -> stage_col inner; Duckdb_ffi.stage_mask native column m pos n in
  match bulk with
  | Bulk.Columns.[] -> ()
  | Bulk.Columns.(col :: rest) -> stage_col col; stage_columns native rest ~column:(column + 1) ~pos ~n
let append_columns (type c) (a : (c, _) appender) (bulk : c Bulk.Columns.t) =
  let (Table_def t) = a.table in
  let context = table_context a.table in
  let rows = match bulk with Bulk.Columns.[] -> 0 | Bulk.Columns.(col :: _) -> bulk_length col in
  let* () = within context (check_columns_bulk a.core t.columns bulk ~column:0 ~rows) in
  within context (Appender.append_slices a.core ~rows ~stage:(fun ~pos ~n ->
    stage_columns (Appender.native a.core) bulk ~column:0 ~pos ~n))
```

A `Strings` column under a NULL mask stages the string and then `stage_mask`
marks the row NULL, so the masked value is ignored.

The pre-checks run outside `operation`, so a rejected call does not poison
the appender (they do no native work). `Null` from a mask is reported the
same way as the row path's, but before admission; document this.

`table.ml`:

```ocaml
let append_columns ({ appender } @ local) columns = Request.append_columns appender columns
```

`duckdb.mli`, in `Table` after `append`:

```ocaml
  (** Appends whole columns. The column list is typed by the declaration;
      columns with a custom codec are rejected ([Encode_rejected]). Before
      any native work, and without poisoning: unequal lengths
      ([Length_mismatch]), an engine type other than the catalog's
      ([Type_mismatch]), a NULL mask entry in a NOT NULL column ([Null]).
      Engine failures poison as [append]. *)
  val append_columns : ('columns, _) appender @ local -> 'columns Bulk.Columns.t -> (unit, Error.t) result
```

`Table` comes after `Bulk` in `duckdb.mli`, so the reference resolves.

- [ ] **Step 6: Run and verify**

Run: `./tools/run build @all 2>&1 | tail -5 && ./tools/run runtest --force 2>&1 | grep -E "bulk:|intended rejections|FAIL|Error" | head; echo exit=$?`
Expected: five `bulk: …=ok` lines, `29 intended rejections`, exit 0.

```bash
ASAN_OPTIONS=detect_leaks=0:halt_on_error=1 UBSAN_OPTIONS=halt_on_error=1 \
  ./tools/run exec --profile stage3a-sanitize --build-dir "$PWD/.local/build-sanitize" test/test_bulk.exe
```

Expected: the `bulk:` lines, no sanitizer report.

- [ ] **Step 7: Commit**

```bash
jj describe -m "feat(table): typed columnar append_columns from Bigarrays

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>" && jj new
```

---

### Task 7: Allocation assertions

**Files:**
- Create: `test/test_allocation.ml`; modify `test/dune`

- [ ] **Step 1: Write the test**

```ocaml
open! Base
module D = Duckdb
module C = D.Statement.Column
module I64 = Stdlib_upstream_compatible.Int64_u
module A1 = Stdlib.Bigarray.Array1
let ok = function Ok x -> x | Error _ -> failwith "DuckDB operation failed"
let connected f =
  let db = ok (D.Owned.open_database (ok (D.Config.create Memory))) in
  Exn.protect ~finally:(fun () -> ok (D.Owned.close_database db)) ~f:(fun () ->
    let c = ok (D.Owned.connect db) in
    Exn.protect ~finally:(fun () -> ok (D.Owned.close_connection c)) ~f:(fun () -> f c))
let words f = Stdlib.Gc.full_major (); let before = Stdlib.Gc.minor_words () in f (); Stdlib.Gc.minor_words () -. before
let sql n = Printf.sprintf
  "SELECT i::BIGINT, CASE WHEN i %% 10 = 0 THEN NULL ELSE i::BIGINT END FROM range(%d) t(i) ORDER BY i" n
let[@zero_alloc] rec sum (v @ local) i n acc = if i = n then acc else sum v (i + 1) n (I64.add acc (C.int64_or v ~default:#0L i))
(* Words per row, from the difference between two sizes, so fixed costs cancel. *)
let per_row run = let small = words (run 100_000) and large = words (run 1_000_000) in (large -. small) /. 900_000.

let () =
  connected (fun c ->
    let views n () = ignore (ok (D.Statement.with_prepared c (sql n) ~f:(fun p ->
      D.Statement.fold_chunks p ~init:0L ~f:(fun chunk acc ->
        match C.view chunk 1 D.Scalar.Int64 C.Nullable with
        | C.Rejected e -> Error e
        | C.Opened v -> Ok (D.Continue Int64.(acc + I64.to_int64 (sum v 0 (C.length v) #0L)))))) : int64) in
    let w = per_row views in
    Stdlib.Printf.printf "allocation: column views %.4f words/row\n" w;
    assert (Float.(w < 0.05));
    let collect n () = ignore (ok (D.Statement.with_prepared c (sql n) ~f:(fun p ->
      D.Bulk.collect p ~column:1 (D.Bulk.Int64 D.Scalar.Int64) C.Nullable)) : (int64, _, _) D.Bulk.t) in
    let w = per_row collect in
    Stdlib.Printf.printf "allocation: collect %.4f words/row\n" w;
    assert (Float.(w < 0.05));
    let continue_unit = Ok (D.Continue ()) in
    let rows = D.Request.many D.Fields.[] D.Fields.[int64; nullable int64] ~row:(fun a b -> (a, b)) in
    let typed n () = ok (D.Request.Session.fold c (rows (sql n)) D.Args.[] ~init:() ~f:(fun _ () -> continue_unit)) in
    let w = per_row typed in
    Stdlib.Printf.printf "allocation: typed rows %.2f words/row\n" w;
    assert (Float.(w <= 12.));
    ok (D.execute c "CREATE TABLE ingest(a BIGINT, b BIGINT)");
    let ingest = D.Table.(declare "ingest" Columns.["a", int64; "b", nullable int64] ~row:(fun a b -> (a, b))) in
    (* [columnar n] builds its input before returning the measured thunk, so
       [words] counts only the append. *)
    let columnar n =
      let a = A1.init Bigarray.int64 Bigarray.c_layout n Int64.of_int in
      let m = A1.init Bigarray.int8_unsigned Bigarray.c_layout n (fun i -> if i % 10 = 0 then 0 else 1) in
      fun () -> ok (D.Table.with_appender c ingest ~f:(fun ap ->
        D.Table.append_columns ap D.Bulk.Columns.[Int64 (D.Scalar.Int64, a); Nullable (Int64 (D.Scalar.Int64, a), m)])) in
    let w = per_row columnar in
    Stdlib.Printf.printf "allocation: columnar ingest %.4f words/row\n" w;
    assert (Float.(w < 0.05)));
  Stdlib.print_endline "allocation: views, collect and columnar ingest allocate nothing per row; typed rows <= 12 words=ok"
```

`test/dune`:

```
(test (name test_allocation) (modules test_allocation)
 (libraries base duckdb stdlib_upstream_compatible))
```

- [ ] **Step 2: Run it**

Run: `./tools/run runtest --force test 2>&1 | grep allocation:`
Expected: four measurement lines and the `=ok` line. A failing bound means
an allocation crept into a fast path: find it (the measurement line says
which path) and fix the code, not the bound.

- [ ] **Step 3: Commit**

```bash
jj describe -m "test(perf): assert per-row allocation of the fast paths

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>" && jj new
```

---

### Task 8: Benchmark paths

**Files:**
- Modify: `bench/benchmark_processing.ml`, `bench/run_benchmarks.py`,
  `bench/test_benchmark_summary.py`

- [ ] **Step 1: Update the Python tests first**

In `bench/test_benchmark_summary.py`, the fixtures write rows for the paths
`borrowed_chunks`/`owned_rows` with order `owned_first`. Change the fixture
helpers to emit one row per path in
`("borrowed_chunks", "owned_rows", "column_views", "collect", "row_ingest", "columnar_ingest")`
with order `first=<path of sample 0>`, and add a test that an order not of
the form `first=<known path>` is rejected and that a checksum differing on
any one path is rejected.

Run: `python3 -m unittest bench.test_benchmark_summary`
Expected: failures (the runner still knows two paths).

- [ ] **Step 2: Generalize the runner**

`bench/run_benchmarks.py`:

```python
PATHS = ("borrowed_chunks", "owned_rows", "column_views", "collect", "row_ingest", "columnar_ingest")
```

In `parse_tsv`, replace the order check with:

```python
        order = row["order"]
        if row["path"] not in PATHS or not (
            order.startswith("first=") and order[len("first="):] in PATHS
        ):
            raise ValueError("unknown path or order")
```

In `validate_rows`, compare every path's `(sample, rows, checksum, nulls)`
list against `PATHS[0]`'s:

```python
    reference = [
        (row["sample"], row["rows"], row["checksum"], row["nulls"])
        for row in grouped[PATHS[0]]
    ]
    for path in PATHS[1:]:
        other = [
            (row["sample"], row["rows"], row["checksum"], row["nulls"])
            for row in grouped[path]
        ]
        if reference != other:
            raise ValueError("checksum/count mismatch")
```

The coefficient-of-variation rerun check already loops over `PATHS`.

Run: `python3 -m unittest bench.test_benchmark_summary`
Expected: OK.

- [ ] **Step 3: The OCaml benchmark**

`bench/benchmark_processing.ml`:
- Open the database with `D.Config.create ~threads:1 Memory` and print
  `threads=1` in the `#` header line.
- Add the read paths (each returns the same `totals` as the others):

```ocaml
module C = Duckdb.Statement.Column
module I64 = Stdlib_upstream_compatible.Int64_u
let[@zero_alloc] rec sum_required (v @ local) i n acc = if i = n then acc else sum_required v (i + 1) n (I64.add acc (C.int64 v i))
let[@zero_alloc] rec sum_nullable (v @ local) i n acc = if i = n then acc else sum_nullable v (i + 1) n (I64.add acc (C.int64_or v ~default:#0L i))
let rec count_nulls (v @ local) i n acc = if i = n then acc else count_nulls v (i + 1) n (if C.is_null v i then acc + 1 else acc)
let column_views prepared () =
  fail_error (Duckdb.Statement.fold_chunks prepared ~init:{ rows = 0; nulls = 0; checksum = 0L } ~f:(fun chunk totals ->
    match C.view chunk 0 Duckdb.Scalar.Int64 C.Non_null, C.view chunk 1 Duckdb.Scalar.Int64 C.Nullable with
    | C.Rejected e, _ | _, C.Rejected e -> Error e
    | C.Opened a, C.Opened b ->
      let n = C.length a in
      Ok (Duckdb.Continue { rows = totals.rows + n; nulls = totals.nulls + count_nulls b 0 n 0;
        checksum = Int64.(totals.checksum + I64.to_int64 (sum_required a 0 n #0L) + I64.to_int64 (sum_nullable b 0 n #0L)) })))
let collect prepared () =
  let { Duckdb.Bulk.data = a; _ } = fail_error (Duckdb.Bulk.collect prepared ~column:0 (Duckdb.Bulk.Int64 Duckdb.Scalar.Int64) C.Non_null) in
  let { Duckdb.Bulk.data = b; validity = Duckdb.Bulk.Mask m } = fail_error (Duckdb.Bulk.collect prepared ~column:1 (Duckdb.Bulk.Int64 Duckdb.Scalar.Int64) C.Nullable) in
  let checksum = ref 0L and nulls = ref 0 in
  for i = 0 to Bigarray.Array1.dim a - 1 do
    checksum := Int64.(!checksum + a.{i} + b.{i});
    if m.{i} = 0 then Int.incr nulls
  done;
  { rows = Bigarray.Array1.dim a; nulls = !nulls; checksum = !checksum }
```

  `collect` executes the query twice (one column each); note that in a
  comment, since it is the honest cost of the one-column helper.
- Add the ingest paths. Their `execute` phase (timed separately as
  `execute_ns`) runs `CREATE OR REPLACE TABLE ingest(a BIGINT, b BIGINT)` and
  builds the input; `process` appends it and then computes the totals with
  one aggregate query (included in the time; say so in a comment):

```ocaml
let ingest_table = Duckdb.Table.(declare "ingest" Columns.["a", int64; "b", nullable int64] ~row:(fun a b -> (a, b)))
let totals_query = Duckdb.Request.one Duckdb.Fields.[] Duckdb.Fields.[int64; int64; int64]
  ~row:(fun rows nulls checksum -> { rows = Int64.to_int_exn rows; nulls = Int64.to_int_exn nulls; checksum })
  "SELECT count(*)::BIGINT, count(*) FILTER (WHERE b IS NULL)::BIGINT, (sum(a) + coalesce(sum(b), 0))::BIGINT FROM ingest"
let fresh connection = fail_error (Duckdb.execute connection "CREATE OR REPLACE TABLE ingest(a BIGINT, b BIGINT)")
let row_batches rows =
  List.chunks_of (List.init rows ~f:(fun i ->
    Duckdb.Args.[Int64.of_int i; (if i % 10 = 0 then None else Some (Int64.of_int i))])) ~length:1000
let row_ingest connection batches () =
  fail_error (Duckdb.Table.with_appender connection ingest_table ~f:(fun a ->
    List.fold batches ~init:(Ok ()) ~f:(fun acc rows -> match acc with Ok () -> Duckdb.Table.append a rows | e -> e)));
  fail_error (Duckdb.Request.Session.find connection totals_query Duckdb.Args.[])
let columnar_input rows =
  Bigarray.Array1.init Bigarray.int64 Bigarray.c_layout rows Int64.of_int,
  Bigarray.Array1.init Bigarray.int8_unsigned Bigarray.c_layout rows (fun i -> if i % 10 = 0 then 0 else 1)
let columnar_ingest connection (a, m) () =
  fail_error (Duckdb.Table.with_appender connection ingest_table ~f:(fun ap ->
    Duckdb.Table.append_columns ap Duckdb.Bulk.Columns.[Int64 (Duckdb.Scalar.Int64, a); Nullable (Int64 (Duckdb.Scalar.Int64, a), m)]));
  fail_error (Duckdb.Request.Session.find connection totals_query Duckdb.Args.[])
```

  Wire them through `measure` with `execute` = `fun () -> fresh connection;
  <build input>` and `process` = the path applied to that input.
- Replace the two-path alternation with a rotation: sample `s` runs the six
  paths starting at index `s mod 6`, and every row of that sample has order
  `first=<name of that starting path>`.
- Add `stdlib_upstream_compatible` to `bench/dune`'s `libraries`.

- [ ] **Step 4: Run the correctness mode and a measured run**

Run: `./tools/run build @all 2>&1 | tail -3 && python3 bench/run_benchmarks.py --correctness-only --rows 1000 --warmups 0 --samples 1 --output-dir .local/perf/bench-check`
Expected: exits 0.

Run: `./tools/run exec -- python3 bench/run_benchmarks.py --rows 1000000 --warmups 2 --samples 10 --output-dir .local/perf/final && python3 -c "import json; s=json.load(open('.local/perf/final/run-1-summary.json'))['summary']; [print(p, round(s[p]['process_ns']['median']/1e6,1), 'ms', int(s[p]['minor_words']['median']), 'words') for p in sorted(s)]"`
Expected: six paths with medians. Compare against the targets
(column views ≤ 65, collect ≤ 70 for two columns ×2 executions — report it
as measured, typed rows ≤ 110, row ingest ≤ 190, columnar ingest ≤ 75 ms).
Record the table in the commit message. A missed target is reported, not
hidden: Task 9 records it in the design note.

- [ ] **Step 5: Commit**

```bash
jj describe -m "bench: column views, collect, row and columnar ingest paths

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>" && jj new
```

---

### Task 9: Documentation and full verification

**Files:**
- Modify: `docs/design/performance.md`, `README.md`, `CHANGELOG.md`,
  `docs/architecture.md`

- [ ] **Step 1: Design note**

In `docs/design/performance.md`:
- Status line: `Status: implemented.`
- Apply the six "Design amendments" from the top of this plan to the
  sections they change (section 1 `view`'s return type, section 2 `Bulk`'s
  location and `collect_strings`, section 4b's custom-codec rule and
  `Length_mismatch`, section 4a's staging outside admission and error
  precedence, section 5's typed-row allocation definition, and a sentence on
  the vector cache in the introduction).
- Add `## Results` after `## Baseline`: the Task 8 table (time and minor
  words per path, same machine and settings) and the Task 7 allocation
  lines, each against its target, marking any missed target and why.

- [ ] **Step 2: README, CHANGELOG, architecture**

`README.md`: after "Sequencing with local handles", add:

````markdown
## Fast paths

For analytics, read columns instead of rows. A column view is checked once
per chunk; its numeric accessors return unboxed values and never allocate
(the build checks it):

```ocaml
let[@zero_alloc] rec sum v i n acc =
  if i = n then acc else sum v (i + 1) n (Int64_u.add acc (Column.int64 v i))
```

`Bulk.collect` copies a whole column into a Bigarray with one native copy
per chunk, and `Table.append_columns` appends Bigarrays the same way, typed
by the table declaration. Typed rows and `Table.append` use the same native
paths internally. Numbers: [performance](docs/design/performance.md).
````

  and change the roadmap paragraph so performance is listed as done.
- `CHANGELOG.md`: a section for this work listing `Statement.Column`,
  `Bulk` (`collect`, `collect_strings`, `blit`, `Columns`),
  `Table.append_columns`, the `Length_mismatch` cause, faster typed rows and
  `Table.append`, per-chunk cancellation checkpoints in typed folds, and the
  benchmark's new paths and `threads=1`.
- `docs/architecture.md`: one paragraph on the per-chunk vector cache and the
  appender's staging chunks, where it describes the native layer.

- [ ] **Step 3: Full verification (the CI list)**

```bash
./tools/run build @all 2>&1 | tee .local/perf/build.log | tail -3
python3 -m unittest test.soak.test_run_soak bench.test_benchmark_summary tools.test_bootstrap
./tools/run runtest --force 2>&1 | tee .local/perf/runtest.log | tail -5
./tools/run exec --no-build examples/synchronous.exe
./tools/run exec --no-build examples/asynchronous.exe
./tools/run exec --no-build examples/eio.exe
bash test/install_adapters_smoke.sh
./tools/run exec --no-build test/soak/test_soak_support.exe
python3 test/soak/run_model_soak.py --seed 104729 --episodes 8 --output .local/perf/model-soak.log
python3 test/soak/run_soak.py --seed 104729 --repetitions 1 --output .local/perf/selector-soak.log
python3 bench/run_benchmarks.py --correctness-only --rows 1000 --warmups 0 --samples 1 --output-dir .local/perf/benchmark
ASAN_OPTIONS=detect_leaks=0:halt_on_error=1 UBSAN_OPTIONS=halt_on_error=1 \
  ./tools/run exec --profile stage3a-sanitize --build-dir "$PWD/.local/build-sanitize" test/test_duckdb.exe
```

Expected: every command exits 0. Report any failure with its output; do not
commit over a failure.

- [ ] **Step 4: Commit**

```bash
jj describe -m "docs: performance results, fast paths in the README, changelog

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>" && jj new
```
