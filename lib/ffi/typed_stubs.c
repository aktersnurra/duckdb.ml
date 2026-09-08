#include "query_native.h"
#include <caml/alloc.h>
#include <caml/fail.h>
#include <caml/memory.h>
#include <caml/threads.h>
#include <caml/signals.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static void bind_status(prepared_owner *p, duckdb_state state) {
    p->status = state == DuckDBSuccess ? 0 : 1;
    if (p->status) snprintf(p->message, sizeof(p->message), "%s", "DuckDB parameter binding failed");
}
CAMLprim value ml_duckdb_bind_null(value v, value index) {
    CAMLparam2(v, index); prepared_owner *p = duckdb_ml_prepared(v); idx_t i = Long_val(index);
    caml_enter_blocking_section(); bind_status(p, duckdb_bind_null(p->prepared, i));
    caml_leave_blocking_section(); caml_process_pending_actions(); CAMLreturn(Val_unit);
}
CAMLprim value ml_duckdb_bind_int64(value v, value index, value typ, value number) {
    CAMLparam4(v, index, typ, number); prepared_owner *p = duckdb_ml_prepared(v);
    idx_t i = Long_val(index); int type = Int_val(typ); int64_t x = Int64_val(number);
    caml_enter_blocking_section();
    duckdb_state state = DuckDBError; duckdb_value temporal = NULL;
    switch (type) {
    case DUCKDB_TYPE_BOOLEAN: state = duckdb_bind_boolean(p->prepared, i, x != 0); break;
    case DUCKDB_TYPE_TINYINT: state = duckdb_bind_int8(p->prepared, i, (int8_t)x); break;
    case DUCKDB_TYPE_SMALLINT: state = duckdb_bind_int16(p->prepared, i, (int16_t)x); break;
    case DUCKDB_TYPE_INTEGER: state = duckdb_bind_int32(p->prepared, i, (int32_t)x); break;
    case DUCKDB_TYPE_BIGINT: state = duckdb_bind_int64(p->prepared, i, x); break;
    case DUCKDB_TYPE_DATE: state = duckdb_bind_date(p->prepared, i, (duckdb_date){(int32_t)x}); break;
    case DUCKDB_TYPE_TIMESTAMP: state = duckdb_bind_timestamp(p->prepared, i, (duckdb_timestamp){x}); break;
    case DUCKDB_TYPE_TIMESTAMP_TZ: state = duckdb_bind_timestamp_tz(p->prepared, i, (duckdb_timestamp){x}); break;
    case DUCKDB_TYPE_TIMESTAMP_S: temporal = duckdb_create_timestamp_s((duckdb_timestamp_s){x}); break;
    case DUCKDB_TYPE_TIMESTAMP_MS: temporal = duckdb_create_timestamp_ms((duckdb_timestamp_ms){x}); break;
    case DUCKDB_TYPE_TIMESTAMP_NS: temporal = duckdb_create_timestamp_ns((duckdb_timestamp_ns){x}); break;
    default: break;
    }
    if (temporal) { state = duckdb_bind_value(p->prepared, i, temporal); duckdb_destroy_value(&temporal); }
    bind_status(p, state);
    caml_leave_blocking_section(); caml_process_pending_actions(); CAMLreturn(Val_unit);
}
CAMLprim value ml_duckdb_bind_float(value v, value index, value typ, value number) {
    CAMLparam4(v, index, typ, number); prepared_owner *p = duckdb_ml_prepared(v);
    idx_t i = Long_val(index); int type = Int_val(typ); double x = Double_val(number);
    caml_enter_blocking_section();
    bind_status(p, type == DUCKDB_TYPE_FLOAT ? duckdb_bind_float(p->prepared, i, (float)x)
                                           : duckdb_bind_double(p->prepared, i, x));
    caml_leave_blocking_section(); caml_process_pending_actions(); CAMLreturn(Val_unit);
}
CAMLprim value ml_duckdb_bind_string(value v, value index, value typ, value text) {
    CAMLparam4(v, index, typ, text); prepared_owner *p = duckdb_ml_prepared(v);
    idx_t i = Long_val(index), length = caml_string_length(text); int type = Int_val(typ);
    p->input = malloc(length ? length : 1);
    if (!p->input) caml_raise_out_of_memory();
    duckdb_ml_acquired(); memcpy(p->input, String_val(text), length);
    caml_enter_blocking_section();
    bind_status(p, type == DUCKDB_TYPE_BLOB ? duckdb_bind_blob(p->prepared, i, p->input, length)
        : duckdb_bind_varchar_length(p->prepared, i, p->input, length));
    free(p->input); p->input = NULL; duckdb_ml_released();
    caml_leave_blocking_section(); caml_process_pending_actions(); CAMLreturn(Val_unit);
}
CAMLprim value ml_duckdb_reset(value v) {
    CAMLparam1(v); prepared_owner *p = duckdb_ml_prepared(v);
    caml_enter_blocking_section(); bind_status(p, duckdb_clear_bindings(p->prepared));
    caml_leave_blocking_section(); caml_process_pending_actions(); CAMLreturn(Val_unit);
}
static duckdb_vector vector(prepared_owner *p, intnat column) {
    return duckdb_data_chunk_get_vector(p->chunk, (idx_t)column);
}
CAMLprim value ml_duckdb_chunk_valid(value v, value column, value row) {
    uint64_t *validity = duckdb_vector_get_validity(vector(duckdb_ml_prepared(v), Long_val(column)));
    idx_t i = Long_val(row);
    return Val_bool(!validity || ((validity[i / 64] >> (i % 64)) & 1));
}
CAMLprim int64_t ml_duckdb_chunk_int64_unboxed(value v, value column, value row) {
    prepared_owner *p = duckdb_ml_prepared(v); idx_t c = Long_val(column), i = Long_val(row);
    void *data = duckdb_vector_get_data(vector(p, c));
    switch (duckdb_column_type(&p->result, c)) {
    case DUCKDB_TYPE_BOOLEAN: return ((bool *)data)[i];
    case DUCKDB_TYPE_TINYINT: return ((int8_t *)data)[i];
    case DUCKDB_TYPE_SMALLINT: return ((int16_t *)data)[i];
    case DUCKDB_TYPE_INTEGER: case DUCKDB_TYPE_DATE: return ((int32_t *)data)[i];
    default: return ((int64_t *)data)[i];
    }
}
CAMLprim value ml_duckdb_chunk_int64(value v, value column, value row) {
    CAMLparam3(v, column, row); CAMLreturn(caml_copy_int64(ml_duckdb_chunk_int64_unboxed(v, column, row)));
}
CAMLprim value ml_duckdb_chunk_float(value v, value column, value row) {
    CAMLparam3(v, column, row); prepared_owner *p = duckdb_ml_prepared(v);
    idx_t c = Long_val(column), i = Long_val(row); void *data = duckdb_vector_get_data(vector(p, c));
    double x = duckdb_column_type(&p->result, c) == DUCKDB_TYPE_FLOAT ? ((float *)data)[i] : ((double *)data)[i];
    CAMLreturn(caml_copy_double(x));
}
CAMLprim value ml_duckdb_chunk_string(value v, value column, value row) {
    CAMLparam3(v, column, row); CAMLlocal1(out);
    duckdb_string_t *data = duckdb_vector_get_data(vector(duckdb_ml_prepared(v), Long_val(column)));
    duckdb_string_t *text = &data[Long_val(row)];
    uint32_t length = duckdb_string_t_length(*text); const char *bytes = duckdb_string_t_data(text);
    out = caml_alloc_string(length); memcpy(Bytes_val(out), bytes, length); CAMLreturn(out);
}
