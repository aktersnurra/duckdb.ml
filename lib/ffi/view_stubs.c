#include "query_native.h"
#include <caml/alloc.h>
#include <caml/bigarray.h>
#include <caml/float32.h>
#include <stdint.h>
#include <string.h>
/* Reads through the per-chunk vector cache. OCaml checks the column's type
   once per view and every row index against the chunk length. These stubs
   are memory-safe even when called wrongly: they refuse (read 0/false, copy
   nothing) a column outside the cache, a row outside the cached chunk, and an
   element read or blit whose width differs from the column's. A read of the
   right width but another type of the same width reinterprets bits but stays
   in bounds. */
static duckdb_ml_vector *cached(value v, value column, idx_t *rows) {
    prepared_owner *p = duckdb_ml_prepared(v); intnat c = Long_val(column);
    if (!(p && p->chunk && c >= 0 && (idx_t)c < p->vector_count)) return NULL;
    *rows = p->chunk_rows; return &p->vectors[c];
}
/* The column's cache entry when [row] lies in [0, chunk_rows), else NULL. */
static duckdb_ml_vector *cached_row(value v, value column, value row) {
    idx_t rows = 0; duckdb_ml_vector *x = cached(v, column, &rows); intnat i = Long_val(row);
    return (x && i >= 0 && (idx_t)i < rows) ? x : NULL;
}
static int valid_row(duckdb_ml_vector *x, intnat i) {
    return !x->validity || ((x->validity[i / 64] >> (i % 64)) & 1);
}
/* [x] must also store elements of exactly sizeof(T) bytes. */
#define READ(T, x, i) (((x) && (x)->width == sizeof(T)) ? ((T *)(x)->data)[i] : (T)0)
int64_t ml_duckdb_view_int64(value v, value c, value i) { return READ(int64_t, cached_row(v, c, i), Long_val(i)); }
value ml_duckdb_view_int64_byte(value v, value c, value i) { return caml_copy_int64(ml_duckdb_view_int64(v, c, i)); }
int32_t ml_duckdb_view_int32(value v, value c, value i) { return READ(int32_t, cached_row(v, c, i), Long_val(i)); }
value ml_duckdb_view_int32_byte(value v, value c, value i) { return caml_copy_int32(ml_duckdb_view_int32(v, c, i)); }
double ml_duckdb_view_double(value v, value c, value i) { return READ(double, cached_row(v, c, i), Long_val(i)); }
value ml_duckdb_view_double_byte(value v, value c, value i) { return caml_copy_double(ml_duckdb_view_double(v, c, i)); }
float ml_duckdb_view_float(value v, value c, value i) { return READ(float, cached_row(v, c, i), Long_val(i)); }
value ml_duckdb_view_float_byte(value v, value c, value i) { return caml_copy_float32(ml_duckdb_view_float(v, c, i)); }
value ml_duckdb_view_int16(value v, value c, value i) { return Val_long(READ(int16_t, cached_row(v, c, i), Long_val(i))); }
value ml_duckdb_view_int8(value v, value c, value i) { return Val_long(READ(int8_t, cached_row(v, c, i), Long_val(i))); }
/* Loaded as a byte: a non-0/1 byte must not be read as a C bool. */
value ml_duckdb_view_bool(value v, value c, value i) { return Val_bool(READ(uint8_t, cached_row(v, c, i), Long_val(i)) != 0); }
value ml_duckdb_view_valid(value v, value c, value i) {
    duckdb_ml_vector *x = cached_row(v, c, i); return Val_bool(x && valid_row(x, Long_val(i)));
}
/* First NULL row in [0, length), or -1. Scans the mask a word at a time. */
value ml_duckdb_view_first_null(value v, value c, value length) {
    idx_t rows = 0; duckdb_ml_vector *x = cached(v, c, &rows); intnat n = Long_val(length);
    if (!x || !x->validity) return Val_long(-1);
    if (n > (intnat)rows) n = (intnat)rows;
    for (intnat w = 0; w * 64 < n; ++w) {
        uint64_t bits = x->validity[w];
        intnat in_word = n - w * 64 < 64 ? n - w * 64 : 64;
        uint64_t wanted = in_word == 64 ? UINT64_MAX : ((UINT64_C(1) << in_word) - 1);
        uint64_t missing = ~bits & wanted;
        if (missing) return Val_long(w * 64 + __builtin_ctzll(missing));
    }
    return Val_long(-1);
}
/* The element width of [b]; 0 for an empty array (nothing can be copied). */
static size_t element_size(struct caml_ba_array *b) {
    uintnat n = caml_ba_num_elts(b); return n ? (size_t)(caml_ba_byte_size(b) / n) : 0;
}
/* Copies [length] rows of a fixed-width column into [ba] at [pos] and writes
   0 at NULL rows. Refuses (copies nothing) when the element widths differ,
   [length] exceeds the cached chunk or the destination is too short; OCaml
   checks all three first. */
value ml_duckdb_view_blit(value v, value c, value length, value ba, value pos) {
    idx_t rows = 0; duckdb_ml_vector *x = cached(v, c, &rows); intnat n = Long_val(length), at = Long_val(pos);
    struct caml_ba_array *b = Caml_ba_array_val(ba);
    if (n > (intnat)rows) return Val_unit;
    size_t w = x ? x->width : 0;
    if (!w || w != element_size(b)) return Val_unit;
    if (n < 0 || at < 0 || at > b->dim[0] - n) return Val_unit;
    char *out = (char *)b->data + (size_t)at * w;
    memcpy(out, x->data, (size_t)n * w);
    if (x->validity) for (intnat i = 0; i < n; ++i) if (!valid_row(x, i)) memset(out + (size_t)i * w, 0, w);
    return Val_unit;
}
/* Writes one byte per row into a uint8 Bigarray: 1 valid, 0 NULL. */
value ml_duckdb_view_blit_validity(value v, value c, value length, value ba, value pos) {
    idx_t rows = 0; duckdb_ml_vector *x = cached(v, c, &rows); intnat n = Long_val(length), at = Long_val(pos);
    struct caml_ba_array *b = Caml_ba_array_val(ba);
    if (!x || n > (intnat)rows || (b->flags & CAML_BA_KIND_MASK) != CAML_BA_UINT8) return Val_unit;
    if (n < 0 || at < 0 || at > b->dim[0] - n) return Val_unit;
    uint8_t *out = (uint8_t *)b->data + at;
    for (intnat i = 0; i < n; ++i) out[i] = (uint8_t)valid_row(x, i);
    return Val_unit;
}
