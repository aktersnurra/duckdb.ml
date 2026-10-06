#include "query_native.h"
#include <caml/alloc.h>
#include <caml/bigarray.h>
#include <caml/custom.h>
#include <caml/fail.h>
#include <caml/memory.h>
#include <caml/signals.h>
#include <caml/threads.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
    connection_owner *parent;
    duckdb_appender appender;
    int status;
    char message[DUCKDB_ML_MESSAGE_SIZE];
    char *schema, *table;
    int *types;
    bool *nullable;
    idx_t columns;
    duckdb_logical_type *logical;   /* active column types, for staging chunks */
    duckdb_data_chunk *staged;      /* reusable staging chunks */
    size_t staged_capacity, staged_rows;
    /* A staging failure is kept apart from [status]: a later codec rejection
       in the same batch drops it without poisoning; [append_staged] turns it
       into the status. */
    bool stage_failed;
    char stage_message[DUCKDB_ML_MESSAGE_SIZE];
} appender_owner;
#define Appender(v) (*((appender_owner **)Data_custom_val(v)))
/* Staging chunks kept between batches; larger batches grow the pool for
   themselves and shrink it back after appending. */
#define STAGED_RETAINED 16
static void error(appender_owner *p, const char *message) {
    if (p->status) return;
    p->status = DUCKDB_ML_STATUS_ERROR;
    snprintf(p->message, sizeof(p->message), "%s", message ? message : "DuckDB appender failed");
}
/* Status ABI: 0 success, 1 native diagnostic, 3 suppressed cancellation.
   Never replace a native failure with a later cancellation classification. */
static bool admit_user(appender_owner *p) {
    if (p->status) return false;
    if (duckdb_ml_native_user_call_begin(p->parent) == DUCKDB_ML_CALL_CANCELLED) {
        p->status = DUCKDB_ML_STATUS_CANCELLED; return false;
    }
    return true;
}
static bool admit_scalar(appender_owner *p) {
    if (p->status) return false;
    if (duckdb_ml_native_noninterruptible_call_begin(p->parent) == DUCKDB_ML_CALL_CANCELLED) {
        p->status = DUCKDB_ML_STATUS_CANCELLED; return false;
    }
    return true;
}
static void check(appender_owner *p, duckdb_state state, duckdb_ml_runtime runtime) {
    if (state != DuckDBSuccess) {
        duckdb_error_data data = duckdb_appender_error_data(p->appender);
        error(p, data ? duckdb_error_data_message(data) : NULL);
        if (data) {
            duckdb_ml_native_cleanup_begin(p->parent, runtime);
            duckdb_destroy_error_data(&data);
            duckdb_ml_native_cleanup_end(p->parent, runtime);
        }
    }
}
static void clear_input(appender_owner *p) {
    if (p) { p->staged_rows = 0; p->stage_failed = false; }
}
/* Frees the staging chunks and the active column types they were built from.
   Runs while [p->columns] still counts those types: engine cleanup when the
   appender is destroyed, or before the active columns change. */
static void release_staging(appender_owner *p) {
    for (size_t k = 0; k < p->staged_capacity; ++k) { duckdb_destroy_data_chunk(&p->staged[k]); duckdb_ml_released(); }
    if (p->staged) { free(p->staged); p->staged = NULL; duckdb_ml_released(); }
    p->staged_capacity = p->staged_rows = 0;
    if (p->logical) {
        for (idx_t i = 0; i < p->columns; ++i) duckdb_destroy_logical_type(&p->logical[i]);
        free(p->logical); p->logical = NULL; duckdb_ml_released();
    }
}
/* Clear BEFORE destroy: DuckDB destroy calls close, and the C++ destructor
   can close again. No destructor may silently flush discarded buffered rows. */
static void close_native(appender_owner *p, bool flush, duckdb_ml_runtime runtime) {
    if (!p) return;
    if (p->appender) {
        if (flush && !p->status) {
            /* Only the ordinary unlocked close requests a user flush. */
            duckdb_ml_native_work_begin(p->parent);
            if (admit_user(p)) {
                duckdb_state state = duckdb_appender_close(p->appender);
                duckdb_ml_native_user_call_end(p->parent);
                check(p, state, runtime);
            }
            duckdb_ml_native_work_end(p->parent);
        }
        duckdb_ml_native_cleanup_begin(p->parent, runtime);
        check(p, duckdb_appender_clear(p->appender), runtime);
        duckdb_appender_destroy(&p->appender); duckdb_ml_released();
        release_staging(p);
        duckdb_ml_native_cleanup_end(p->parent, runtime);
    }
    clear_input(p);
}
static void delete_owner(appender_owner *p) {
    if (!p) return;
    close_native(p, false, DUCKDB_ML_RUNTIME_HELD);
    release_staging(p); /* defensive: close_native always leaves staging empty */
    if (p->schema) { free(p->schema); duckdb_ml_released(); }
    if (p->table) { free(p->table); duckdb_ml_released(); }
    if (p->types) { free(p->types); duckdb_ml_released(); }
    if (p->nullable) { free(p->nullable); duckdb_ml_released(); }
    duckdb_ml_connection_unref(p->parent); free(p); duckdb_ml_released();
}
static void finalize(value v) {
    if (Appender(v)) { duckdb_ml_fallback(); delete_owner(Appender(v)); Appender(v) = NULL; }
}
static struct custom_operations ops = {
    "duckdb.ffi.appender", finalize, custom_compare_default, custom_hash_default,
    custom_serialize_default, custom_deserialize_default, custom_compare_ext_default,
    custom_fixed_length_default
};
CAMLprim value ml_duckdb_appender_owner(value connection) {
    CAMLparam1(connection); CAMLlocal1(v);
    v = caml_alloc_custom(&ops, sizeof(appender_owner *), 0, 1); Appender(v) = NULL;
    appender_owner *p = calloc(1, sizeof(*p));
    if (!p) caml_raise_out_of_memory();
    p->parent = duckdb_ml_connection_ref(connection); Appender(v) = p; duckdb_ml_acquired();
    CAMLreturn(v);
}
static char *copy_string(value v) {
    size_t n = caml_string_length(v);
    char *s = malloc(n + 1);
    if (!s) caml_raise_out_of_memory();
    memcpy(s, String_val(v), n); s[n] = 0; return s;
}
CAMLprim value ml_duckdb_create_appender(value v, value schema, value table) {
    CAMLparam3(v, schema, table); appender_owner *p = Appender(v);
    p->schema = copy_string(schema); duckdb_ml_acquired();
    p->table = copy_string(table); duckdb_ml_acquired();
    duckdb_connection c = duckdb_ml_connection_handle(p->parent);
    caml_enter_blocking_section();
    duckdb_ml_native_work_begin(p->parent);
    /* The explicit transaction is already active. Metadata and appender bind
       to the same catalog snapshot; the safe child then reserves admission. */
    duckdb_prepared_statement statement = NULL;
    duckdb_extracted_statements extracted = NULL;
    duckdb_result result = {0};
    const char *sql = "SELECT database_name,is_nullable FROM duckdb_columns() WHERE database_name=current_database() AND schema_name=? AND table_name=? ORDER BY column_index";
    if (admit_user(p)) {
        idx_t count = duckdb_extract_statements(c, sql, &extracted);
        duckdb_ml_native_user_call_end(p->parent);
        if (count != 1) error(p, extracted ? duckdb_extract_statements_error(extracted) : NULL);
    }
    if (admit_user(p)) {
        duckdb_state state = duckdb_prepare_extracted_statement(c, extracted, 0, &statement);
        duckdb_ml_native_user_call_end(p->parent);
        if (state != DuckDBSuccess) error(p, statement ? duckdb_prepare_error(statement) : NULL);
    }
    if (admit_scalar(p) && duckdb_bind_varchar(statement, 1, p->schema) != DuckDBSuccess) error(p, "Cannot bind appender metadata");
    if (admit_scalar(p) && duckdb_bind_varchar(statement, 2, p->table) != DuckDBSuccess) error(p, "Cannot bind appender metadata");
    if (admit_user(p)) {
        duckdb_state state = duckdb_execute_prepared(statement, &result);
        duckdb_ml_native_user_call_end(p->parent);
        if (state != DuckDBSuccess) error(p, duckdb_result_error(&result));
    }
    duckdb_data_chunk chunk = NULL;
    if (admit_user(p)) {
        chunk = duckdb_fetch_chunk(result);
        duckdb_ml_native_user_call_end(p->parent);
        if (duckdb_result_error(&result)) error(p, duckdb_result_error(&result));
        else if (!chunk || duckdb_data_chunk_get_size(chunk) == 0) error(p, "Table not found in current database");
    }
    if (admit_user(p)) {
        /* A full first chunk can match the physical count even with generated
           columns. Require exhaustion before accepting its positional metadata. */
        duckdb_data_chunk extra = duckdb_fetch_chunk(result);
        duckdb_ml_native_user_call_end(p->parent);
        if (extra) {
            error(p, "Generated-column or very wide tables are not supported by appender");
            duckdb_ml_native_cleanup_begin(p->parent, DUCKDB_ML_RUNTIME_RELEASED);
            duckdb_destroy_data_chunk(&extra);
            duckdb_ml_native_cleanup_end(p->parent, DUCKDB_ML_RUNTIME_RELEASED);
        } else if (duckdb_result_error(&result)) error(p, duckdb_result_error(&result));
    }
    if (admit_scalar(p)) {
        idx_t n = duckdb_data_chunk_get_size(chunk);
        duckdb_string_t *names = duckdb_vector_get_data(duckdb_data_chunk_get_vector(chunk, 0));
        uint32_t len = duckdb_string_t_length(names[0]);
        char *catalog = malloc((size_t)len + 1);
        if (!catalog) error(p, "Cannot allocate catalog name");
        else {
            memcpy(catalog, duckdb_string_t_data(&names[0]), len); catalog[len] = 0;
            if (admit_scalar(p)) {
                duckdb_state state = duckdb_appender_create_ext(c, catalog, p->schema, p->table, &p->appender);
                if (p->appender) duckdb_ml_acquired();
                check(p, state, DUCKDB_ML_RUNTIME_RELEASED);
            }
            free(catalog);
        }
        if (admit_scalar(p)) {
            p->columns = duckdb_appender_column_count(p->appender);
            /* Reject generated columns rather than confusing physical positions.
               Very wide metadata spanning chunks is likewise rejected explicitly. */
            if (n != p->columns) error(p, "Generated-column or very wide tables are not supported by appender");
            else {
                p->types = calloc(n, sizeof(int)); if (p->types) duckdb_ml_acquired();
                p->nullable = calloc(n, sizeof(bool)); if (p->nullable) duckdb_ml_acquired();
                if (!p->types || !p->nullable) error(p, "Cannot allocate appender schema");
                else for (idx_t i = 0; i < n && admit_scalar(p); ++i) {
                    duckdb_logical_type t = duckdb_appender_column_type(p->appender, i);
                    p->types[i] = duckdb_get_type_id(t);
                    duckdb_ml_native_cleanup_begin(p->parent, DUCKDB_ML_RUNTIME_RELEASED);
                    duckdb_destroy_logical_type(&t);
                    duckdb_ml_native_cleanup_end(p->parent, DUCKDB_ML_RUNTIME_RELEASED);
                    p->nullable[i] = ((bool *)duckdb_vector_get_data(duckdb_data_chunk_get_vector(chunk, 1)))[i];
                }
            }
        }
    }
    duckdb_ml_native_cleanup_begin(p->parent, DUCKDB_ML_RUNTIME_RELEASED);
    if (chunk) duckdb_destroy_data_chunk(&chunk);
    duckdb_destroy_result(&result); if (statement) duckdb_destroy_prepare(&statement);
    if (extracted) duckdb_destroy_extracted(&extracted);
    duckdb_ml_native_cleanup_end(p->parent, DUCKDB_ML_RUNTIME_RELEASED);
    duckdb_ml_native_work_end(p->parent);
    caml_leave_blocking_section(); caml_process_pending_actions(); CAMLreturn(Val_unit);
}
/* Prepares staging for [rows] rows: ceil(rows / vector size) chunks of the
   active column types, reset to empty. Allocation failure leaves the
   appender's status set and stages nothing. Runs with the runtime held; it
   touches only this appender's own buffers. */
CAMLprim value ml_duckdb_stage_begin(value v, value rows) {
    appender_owner *p = Appender(v); size_t size = duckdb_vector_size();
    clear_input(p);
    if (!p || !p->appender || p->status || Long_val(rows) < 0) return Val_unit;
    size_t n = (size_t)Long_val(rows), chunks = (n + size - 1) / size;
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
        while (p->staged_capacity < chunks) {
            duckdb_data_chunk chunk = duckdb_create_data_chunk(p->logical, p->columns);
            if (!chunk) { error(p, "Cannot allocate staging chunks"); return Val_unit; }
            duckdb_ml_acquired();
            p->staged[p->staged_capacity++] = chunk;
        }
    }
    for (size_t k = 0; k < chunks; ++k) {
        duckdb_data_chunk_reset(p->staged[k]);
        /* An unwritten string slot must still be a valid (empty) string. */
        size_t held = n - k * size < size ? n - k * size : size;
        for (idx_t i = 0; i < p->columns; ++i)
            if (p->types[i] == DUCKDB_TYPE_VARCHAR || p->types[i] == DUCKDB_TYPE_BLOB)
                memset(duckdb_vector_get_data(duckdb_data_chunk_get_vector(p->staged[k], i)), 0,
                       held * sizeof(duckdb_string_t));
    }
    p->staged_rows = n;
    return Val_unit;
}
/* The staging data of (column, row), or NULL when out of range or closed. */
static void *slot(appender_owner *p, value column, value row, duckdb_vector *out, idx_t *index) {
    intnat c = Long_val(column), r = Long_val(row); size_t size = duckdb_vector_size();
    if (!p || c < 0 || (idx_t)c >= p->columns || r < 0 || (size_t)r >= p->staged_rows) return NULL;
    *out = duckdb_data_chunk_get_vector(p->staged[(size_t)r / size], (idx_t)c); *index = (idx_t)((size_t)r % size);
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
/* DuckDB copies the bytes into the vector's own string heap. Invalid UTF-8
   in a VARCHAR column fails the whole batch: the engine's diagnostic is kept
   as the staging failure and nothing stays staged, so [append_staged]
   appends no chunk and reports it (DuckDB itself would store a NULL). */
value ml_duckdb_stage_string(value v, value column, value row, value s) {
    appender_owner *p = Appender(v); duckdb_vector vec; idx_t i;
    if (!slot(p, column, row, &vec, &i)) return Val_unit;
    int t = p->types[Long_val(column)];
    const char *bytes = String_val(s); idx_t length = caml_string_length(s);
    if (t == DUCKDB_TYPE_VARCHAR) {
        duckdb_error_data invalid = duckdb_valid_utf8_check(bytes, length);
        if (invalid) {
            const char *message = duckdb_error_data_message(invalid);
            /* Not connection-owned and the runtime is held: no cleanup bracket. */
            snprintf(p->stage_message, sizeof(p->stage_message), "%s",
                     message ? message : "Invalid UTF-8 in VARCHAR value");
            duckdb_destroy_error_data(&invalid);
            p->staged_rows = 0; p->stage_failed = true;
            return Val_unit;
        }
        duckdb_unsafe_vector_assign_string_element_len(vec, i, bytes, length);
    } else if (t == DUCKDB_TYPE_BLOB)
        duckdb_vector_assign_string_element_len(vec, i, bytes, length);
    return Val_unit;
}
value ml_duckdb_stage_null(value v, value column, value row) {
    appender_owner *p = Appender(v); duckdb_vector vec; idx_t i;
    if (!slot(p, column, row, &vec, &i)) return Val_unit;
    duckdb_vector_ensure_validity_writable(vec);
    duckdb_validity_set_row_invalid(duckdb_vector_get_validity(vec), i);
    return Val_unit;
}
/* The Bigarray kind whose elements are this column type's physical values,
   or -1 when the column cannot be blitted. */
static int stage_kind(int t) {
    switch (t) {
    case DUCKDB_TYPE_BOOLEAN: return CAML_BA_UINT8;
    case DUCKDB_TYPE_TINYINT: return CAML_BA_SINT8;
    case DUCKDB_TYPE_SMALLINT: return CAML_BA_SINT16;
    case DUCKDB_TYPE_INTEGER: case DUCKDB_TYPE_DATE: return CAML_BA_INT32;
    case DUCKDB_TYPE_FLOAT: return CAML_BA_FLOAT32;
    case DUCKDB_TYPE_DOUBLE: return CAML_BA_FLOAT64;
    case DUCKDB_TYPE_BIGINT: case DUCKDB_TYPE_TIMESTAMP: case DUCKDB_TYPE_TIMESTAMP_S:
    case DUCKDB_TYPE_TIMESTAMP_MS: case DUCKDB_TYPE_TIMESTAMP_NS: case DUCKDB_TYPE_TIMESTAMP_TZ:
        return CAML_BA_INT64;
    default: return -1;
    }
}
/* Whether staging rows [0, n) of [column] (one chunk, n > 0) can take input
   rows [at, at + n) of the one-dimensional Bigarray [b]. */
static bool stage_range(appender_owner *p, intnat c, const struct caml_ba_array *b, intnat at, intnat n) {
    return p && p->staged && p->staged_capacity > 0 && c >= 0 && (idx_t)c < p->columns && n > 0
        && (size_t)n <= p->staged_rows && (size_t)n <= duckdb_vector_size()
        && b->num_dims == 1 && at >= 0 && at <= b->dim[0] - n;
}
/* A columnar write that cannot be honoured fails the batch (as invalid UTF-8
   does) instead of leaving stale staging data to be appended. The first
   staging failure is kept. */
static void stage_fail(appender_owner *p, const char *message) {
    if (!p || p->stage_failed) return;
    snprintf(p->stage_message, sizeof(p->stage_message), "%s", message);
    p->staged_rows = 0; p->stage_failed = true;
}
/* Copies [n] elements of [ba] from [pos] into staging rows [0, n) of
   [column]. Booleans are normalized to 0/1. A kind mismatch or out-of-range
   request copies nothing and fails the batch; OCaml checks both first. */
value ml_duckdb_stage_blit(value v, value column, value ba, value pos, value count) {
    appender_owner *p = Appender(v); intnat c = Long_val(column), at = Long_val(pos), n = Long_val(count);
    const struct caml_ba_array *b = Caml_ba_array_val(ba);
    if (!stage_range(p, c, b, at, n)) { stage_fail(p, "Bulk column range mismatch"); return Val_unit; }
    int t = p->types[c];
    size_t w = duckdb_ml_type_width((duckdb_type)t);
    if (!w || stage_kind(t) != (int)(b->flags & CAML_BA_KIND_MASK)) {
        stage_fail(p, "Bulk column kind mismatch"); return Val_unit;
    }
    char *d = duckdb_vector_get_data(duckdb_data_chunk_get_vector(p->staged[0], (idx_t)c));
    const char *s = (const char *)b->data + (size_t)at * w;
    if (t == DUCKDB_TYPE_BOOLEAN) for (intnat i = 0; i < n; ++i) ((bool *)d)[i] = s[i] != 0;
    else memcpy(d, s, (size_t)n * w);
    return Val_unit;
}
/* Marks staging rows [0, n) of [column] NULL where [mask] (from [pos]) is 0.
   A bad mask or range fails the batch as [stage_blit] does. */
value ml_duckdb_stage_mask(value v, value column, value mask, value pos, value count) {
    appender_owner *p = Appender(v); intnat c = Long_val(column), at = Long_val(pos), n = Long_val(count);
    const struct caml_ba_array *b = Caml_ba_array_val(mask);
    if (!stage_range(p, c, b, at, n) || (b->flags & CAML_BA_KIND_MASK) != CAML_BA_UINT8) {
        stage_fail(p, "Bulk mask kind or range mismatch"); return Val_unit;
    }
    const uint8_t *m = (const uint8_t *)b->data + at;
    duckdb_vector vec = duckdb_data_chunk_get_vector(p->staged[0], (idx_t)c);
    uint64_t *validity = NULL;
    for (intnat i = 0; i < n; ++i) if (!m[i]) {
        if (!validity) { duckdb_vector_ensure_validity_writable(vec); validity = duckdb_vector_get_validity(vec); }
        duckdb_validity_set_row_invalid(validity, (idx_t)i);
    }
    return Val_unit;
}
/* DuckDB's rows per vector (and per staging chunk). */
value ml_duckdb_vector_size(value unit) { (void)unit; return Val_long(duckdb_vector_size()); }
value ml_duckdb_clear_stage(value v) { clear_input(Appender(v)); return Val_unit; }
/* Appends every staged chunk. Each chunk is one interruptible engine call
   (it can automatically flush through a real INSERT); the first failure stops
   the batch and is reported through the status. */
CAMLprim value ml_duckdb_append_staged(value v) {
    CAMLparam1(v); appender_owner *p = Appender(v);
    if (!p) CAMLreturn(Val_unit);
    if (!p->appender) { error(p, "Appender is closed"); clear_input(p); CAMLreturn(Val_unit); }
    if (p->stage_failed) { error(p, p->stage_message); clear_input(p); CAMLreturn(Val_unit); }
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
    if (p->staged_capacity > STAGED_RETAINED) {
        /* Keep at most STAGED_RETAINED chunks between batches. */
        duckdb_ml_native_cleanup_begin(p->parent, DUCKDB_ML_RUNTIME_RELEASED);
        for (size_t k = STAGED_RETAINED; k < p->staged_capacity; ++k) {
            duckdb_destroy_data_chunk(&p->staged[k]); duckdb_ml_released();
        }
        p->staged_capacity = STAGED_RETAINED;
        duckdb_ml_native_cleanup_end(p->parent, DUCKDB_ML_RUNTIME_RELEASED);
    }
    duckdb_ml_native_work_end(p->parent);
    caml_leave_blocking_section(); caml_process_pending_actions(); CAMLreturn(Val_unit);
}
CAMLprim value ml_duckdb_flush_appender(value v) {
    CAMLparam1(v); appender_owner *p = Appender(v);
    caml_enter_blocking_section();
    duckdb_ml_native_work_begin(p->parent);
    if (admit_user(p)) {
        duckdb_state state = duckdb_appender_flush(p->appender);
        duckdb_ml_native_user_call_end(p->parent);
        check(p, state, DUCKDB_ML_RUNTIME_RELEASED);
    }
    duckdb_ml_native_work_end(p->parent);
    caml_leave_blocking_section(); caml_process_pending_actions(); CAMLreturn(Val_unit);
}
CAMLprim value ml_duckdb_close_appender(value v, value flush) {
    CAMLparam2(v, flush); appender_owner *p = Appender(v); bool do_flush = Bool_val(flush);
    caml_enter_blocking_section(); close_native(p, do_flush, DUCKDB_ML_RUNTIME_RELEASED);
    caml_leave_blocking_section(); caml_process_pending_actions(); CAMLreturn(Val_unit);
}
/* Restricts the appender to [names] (catalog columns at physical [indices]);
   omitted columns take their defaults. Types and NULL-ability are remapped to
   the active order. On failure the physical schema is kept. */
CAMLprim value ml_duckdb_appender_select_columns(value v, value names, value indices) {
    CAMLparam3(v, names, indices); appender_owner *p = Appender(v);
    idx_t n = Wosize_val(names);
    char **copies = calloc(n ? n : 1, sizeof(char *));
    int *types = calloc(n ? n : 1, sizeof(int));
    bool *nullable = calloc(n ? n : 1, sizeof(bool));
    if (!copies || !types || !nullable) { free(copies); free(types); free(nullable); caml_raise_out_of_memory(); }
    duckdb_ml_acquired(); duckdb_ml_acquired(); duckdb_ml_acquired();
    for (idx_t i = 0; i < n; ++i) {
        idx_t index = (idx_t)Long_val(Field(indices, i));
        if (index >= p->columns) { error(p, "Declared column index outside the catalog"); break; }
        types[i] = p->types[index]; nullable[i] = p->nullable[index];
        copies[i] = copy_string(Field(names, i)); duckdb_ml_acquired();
    }
    caml_enter_blocking_section();
    if (p->logical || p->staged) {
        /* Staging follows the active columns, which change now. */
        duckdb_ml_native_cleanup_begin(p->parent, DUCKDB_ML_RUNTIME_RELEASED);
        release_staging(p);
        duckdb_ml_native_cleanup_end(p->parent, DUCKDB_ML_RUNTIME_RELEASED);
    }
    duckdb_ml_native_work_begin(p->parent);
    for (idx_t i = 0; i < n && admit_scalar(p); ++i)
        check(p, duckdb_appender_add_column(p->appender, copies[i]), DUCKDB_ML_RUNTIME_RELEASED);
    duckdb_ml_native_work_end(p->parent);
    caml_leave_blocking_section();
    for (idx_t i = 0; i < n; ++i) if (copies[i]) { free(copies[i]); duckdb_ml_released(); }
    free(copies); duckdb_ml_released();
    if (p->status) { free(types); free(nullable); }
    else {
        free(p->types); free(p->nullable);
        p->types = types; p->nullable = nullable; p->columns = n;
    }
    duckdb_ml_released(); duckdb_ml_released();
    caml_process_pending_actions(); CAMLreturn(Val_unit);
}
CAMLprim value ml_duckdb_finish_appender_close(value v) { delete_owner(Appender(v)); Appender(v) = NULL; return Val_unit; }
CAMLprim value ml_duckdb_appender_is_closed(value v) { return Val_bool(Appender(v) == NULL); }
CAMLprim value ml_duckdb_appender_status(value v) { return Val_int(Appender(v)->status); }
CAMLprim value ml_duckdb_appender_message(value v) { CAMLparam1(v); CAMLreturn(caml_copy_string(Appender(v)->message)); }
CAMLprim value ml_duckdb_appender_types(value v) {
    CAMLparam1(v); CAMLlocal1(a); appender_owner *p = Appender(v);
    a = caml_alloc(p->columns, 0); for(idx_t i=0;i<p->columns;++i) Store_field(a,i,Val_int(p->types[i])); CAMLreturn(a);
}
CAMLprim value ml_duckdb_appender_nullable(value v) {
    CAMLparam1(v); CAMLlocal1(a); appender_owner *p = Appender(v);
    a = caml_alloc(p->columns, 0); for(idx_t i=0;i<p->columns;++i) Store_field(a,i,Val_bool(p->nullable[i])); CAMLreturn(a);
}
