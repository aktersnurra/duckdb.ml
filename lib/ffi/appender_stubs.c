#include "query_native.h"
#include <caml/alloc.h>
#include <caml/custom.h>
#include <caml/fail.h>
#include <caml/memory.h>
#include <caml/signals.h>
#include <caml/threads.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
    int type, null;
    int64_t integer;
    double floating;
    size_t length;
    char *bytes;
} append_cell;
typedef struct {
    connection_owner *parent;
    duckdb_appender appender;
    int status;
    char message[512];
    char *schema, *table;
    int *types;
    bool *nullable;
    idx_t columns;
    append_cell *cells;
    size_t cell_count, rows;
} appender_owner;
#define Appender(v) (*((appender_owner **)Data_custom_val(v)))
static void error(appender_owner *p, const char *message) {
    if (p->status) return;
    p->status = 1;
    snprintf(p->message, sizeof(p->message), "%s", message ? message : "DuckDB appender failed");
}
static void check(appender_owner *p, duckdb_state state) {
    if (state != DuckDBSuccess) {
        duckdb_error_data data = duckdb_appender_error_data(p->appender);
        error(p, data ? duckdb_error_data_message(data) : NULL);
        if (data) duckdb_destroy_error_data(&data);
    }
}
static void clear_input(appender_owner *p) {
    if (!p) return;
    if (p->cells) {
        for (size_t i = 0; i < p->cell_count; ++i) if (p->cells[i].bytes) {
            free(p->cells[i].bytes); duckdb_ml_released();
        }
        free(p->cells); p->cells = NULL; duckdb_ml_released();
    }
    p->cell_count = p->rows = 0;
}
/* Clear BEFORE destroy: DuckDB destroy calls close, and the C++ destructor
   can close again. No destructor may silently flush discarded buffered rows. */
static void close_native(appender_owner *p, bool flush) {
    if (!p) return;
    if (p->appender) {
        if (flush && !p->status) check(p, duckdb_appender_close(p->appender));
        check(p, duckdb_appender_clear(p->appender));
        duckdb_appender_destroy(&p->appender); duckdb_ml_released();
    }
    clear_input(p);
}
static void delete_owner(appender_owner *p) {
    if (!p) return;
    close_native(p, false);
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
    /* The explicit transaction is already active. Metadata and appender bind
       to the same catalog snapshot; the safe child then reserves admission. */
    duckdb_prepared_statement statement = NULL;
    duckdb_result result = {0};
    const char *sql = "SELECT database_name,is_nullable FROM duckdb_columns() WHERE database_name=current_database() AND schema_name=? AND table_name=? ORDER BY column_index";
    if (duckdb_prepare(c, sql, &statement) != DuckDBSuccess) error(p, statement ? duckdb_prepare_error(statement) : NULL);
    if (!p->status && (duckdb_bind_varchar(statement, 1, p->schema) || duckdb_bind_varchar(statement, 2, p->table))) error(p, "Cannot bind appender metadata");
    if (!p->status && duckdb_execute_prepared(statement, &result) != DuckDBSuccess) error(p, duckdb_result_error(&result));
    duckdb_data_chunk chunk = NULL;
    if (!p->status) chunk = duckdb_fetch_chunk(result);
    if (!p->status && (!chunk || duckdb_data_chunk_get_size(chunk) == 0)) error(p, "Table not found in current database");
    if (!p->status) {
        /* A full first chunk can match the physical count even with generated
           columns. Require exhaustion before accepting its positional metadata. */
        duckdb_data_chunk extra = duckdb_fetch_chunk(result);
        if (extra) {
            error(p, "Generated-column or very wide tables are not supported by appender");
            duckdb_destroy_data_chunk(&extra);
        } else if (duckdb_result_error(&result)) error(p, duckdb_result_error(&result));
    }
    if (!p->status) {
        idx_t n = duckdb_data_chunk_get_size(chunk);
        duckdb_string_t *names = duckdb_vector_get_data(duckdb_data_chunk_get_vector(chunk, 0));
        uint32_t len = duckdb_string_t_length(names[0]);
        char *catalog = malloc((size_t)len + 1);
        if (!catalog) error(p, "Cannot allocate catalog name");
        else {
            memcpy(catalog, duckdb_string_t_data(&names[0]), len); catalog[len] = 0;
            duckdb_state state = duckdb_appender_create_ext(c, catalog, p->schema, p->table, &p->appender);
            free(catalog);
            if (p->appender) duckdb_ml_acquired();
            check(p, state);
        }
        if (!p->status) {
            p->columns = duckdb_appender_column_count(p->appender);
            /* Reject generated columns rather than confusing physical positions.
               Very wide metadata spanning chunks is likewise rejected explicitly. */
            if (n != p->columns) error(p, "Generated-column or very wide tables are not supported by appender");
            else {
                p->types = calloc(n, sizeof(int)); if (p->types) duckdb_ml_acquired();
                p->nullable = calloc(n, sizeof(bool)); if (p->nullable) duckdb_ml_acquired();
                if (!p->types || !p->nullable) error(p, "Cannot allocate appender schema");
                else for (idx_t i = 0; i < n; ++i) {
                    duckdb_logical_type t = duckdb_appender_column_type(p->appender, i);
                    p->types[i] = duckdb_get_type_id(t); duckdb_destroy_logical_type(&t);
                    p->nullable[i] = ((bool *)duckdb_vector_get_data(duckdb_data_chunk_get_vector(chunk, 1)))[i];
                }
            }
        }
    }
    if (chunk) duckdb_destroy_data_chunk(&chunk);
    duckdb_destroy_result(&result); if (statement) duckdb_destroy_prepare(&statement);
    caml_leave_blocking_section(); caml_process_pending_actions(); CAMLreturn(Val_unit);
}
static duckdb_value make_value(append_cell *c) {
    if (c->null) return duckdb_create_null_value();
    switch(c->type) {
    case DUCKDB_TYPE_BOOLEAN: return duckdb_create_bool(c->integer != 0);
    case DUCKDB_TYPE_TINYINT: return duckdb_create_int8((int8_t)c->integer);
    case DUCKDB_TYPE_SMALLINT: return duckdb_create_int16((int16_t)c->integer);
    case DUCKDB_TYPE_INTEGER: return duckdb_create_int32((int32_t)c->integer);
    case DUCKDB_TYPE_BIGINT: return duckdb_create_int64(c->integer);
    case DUCKDB_TYPE_FLOAT: return duckdb_create_float((float)c->floating);
    case DUCKDB_TYPE_DOUBLE: return duckdb_create_double(c->floating);
    case DUCKDB_TYPE_VARCHAR: return duckdb_create_varchar_length(c->bytes, c->length);
    case DUCKDB_TYPE_BLOB: return duckdb_create_blob((const uint8_t *)c->bytes, c->length);
    case DUCKDB_TYPE_DATE: return duckdb_create_date((duckdb_date){(int32_t)c->integer});
    case DUCKDB_TYPE_TIMESTAMP: return duckdb_create_timestamp((duckdb_timestamp){c->integer});
    case DUCKDB_TYPE_TIMESTAMP_S: return duckdb_create_timestamp_s((duckdb_timestamp_s){c->integer});
    case DUCKDB_TYPE_TIMESTAMP_MS: return duckdb_create_timestamp_ms((duckdb_timestamp_ms){c->integer});
    case DUCKDB_TYPE_TIMESTAMP_NS: return duckdb_create_timestamp_ns((duckdb_timestamp_ns){c->integer});
    case DUCKDB_TYPE_TIMESTAMP_TZ: return duckdb_create_timestamp_tz((duckdb_timestamp){c->integer});
    default: return NULL;
    }
}
CAMLprim value ml_duckdb_append_rows(value v, value rows) {
    CAMLparam2(v, rows); appender_owner *p = Appender(v);
    p->rows = Wosize_val(rows);
    if (p->columns && p->rows > SIZE_MAX / p->columns / sizeof(append_cell)) caml_raise_out_of_memory();
    p->cell_count = p->rows * p->columns;
    if (p->cell_count) {
        p->cells = calloc(p->cell_count, sizeof(append_cell));
        if (!p->cells) caml_raise_out_of_memory();
        duckdb_ml_acquired();
    }
    for (size_t row = 0; row < p->rows; ++row) for (idx_t col = 0; col < p->columns; ++col) {
        value cell = Field(Field(rows, row), col);
        append_cell *c = &p->cells[row * p->columns + col];
        c->type = Int_val(Field(cell, 0)); c->null = Bool_val(Field(cell, 1));
        c->integer = Int64_val(Field(cell, 2)); c->floating = Double_val(Field(cell, 3));
        value bytes = Field(cell, 4); c->length = caml_string_length(bytes);
        if (c->type == DUCKDB_TYPE_VARCHAR || c->type == DUCKDB_TYPE_BLOB) {
            c->bytes = copy_string(bytes); duckdb_ml_acquired();
        }
    }
    caml_enter_blocking_section();
    for (size_t row = 0; row < p->rows && !p->status; ++row) {
        check(p, duckdb_appender_begin_row(p->appender));
        for (idx_t col = 0; col < p->columns && !p->status; ++col) {
            duckdb_value cell = make_value(&p->cells[row * p->columns + col]);
            if (!cell) error(p, "Cannot construct appender value");
            else { check(p, duckdb_append_value(p->appender, cell)); duckdb_destroy_value(&cell); }
        }
        if (!p->status) check(p, duckdb_appender_end_row(p->appender));
    }
    clear_input(p);
    caml_leave_blocking_section(); caml_process_pending_actions(); CAMLreturn(Val_unit);
}
CAMLprim value ml_duckdb_flush_appender(value v) {
    CAMLparam1(v); appender_owner *p = Appender(v);
    caml_enter_blocking_section(); if (!p->status) check(p, duckdb_appender_flush(p->appender));
    caml_leave_blocking_section(); caml_process_pending_actions(); CAMLreturn(Val_unit);
}
CAMLprim value ml_duckdb_close_appender(value v, value flush) {
    CAMLparam2(v, flush); appender_owner *p = Appender(v); bool do_flush = Bool_val(flush);
    caml_enter_blocking_section(); close_native(p, do_flush);
    caml_leave_blocking_section(); caml_process_pending_actions(); CAMLreturn(Val_unit);
}
CAMLprim value ml_duckdb_finish_appender_close(value v) { delete_owner(Appender(v)); Appender(v) = NULL; return Val_unit; }
CAMLprim value ml_duckdb_appender_is_closed(value v) { return Val_bool(Appender(v) == NULL); }
CAMLprim value ml_duckdb_clear_appender_input(value v) { clear_input(Appender(v)); return Val_unit; }
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
