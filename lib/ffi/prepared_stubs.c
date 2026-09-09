#include "query_native.h"
#include <caml/alloc.h>
#include <caml/custom.h>
#include <caml/fail.h>
#include <caml/memory.h>
#include <caml/threads.h>
#include <caml/signals.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#define Prepared(v) (*((prepared_owner **)Data_custom_val(v)))
prepared_owner *duckdb_ml_prepared(value v) { return Prepared(v); }
static void set_error(prepared_owner *p, const char *text) {
    p->status = 1; snprintf(p->message, sizeof(p->message), "%s", text ? text : "DuckDB operation failed");
}
static void clear_input(prepared_owner *p) {
    if (p && p->input) { free(p->input); p->input = NULL; duckdb_ml_released(); }
}
static void clear_result(prepared_owner *p, duckdb_ml_runtime runtime) {
    if (!p) return;
    duckdb_ml_native_cleanup_begin(p->parent, runtime);
    if (p->chunk) { duckdb_destroy_data_chunk(&p->chunk); duckdb_ml_released(); }
    if (p->has_result) { duckdb_destroy_result(&p->result); p->has_result = 0; duckdb_ml_released(); }
    duckdb_ml_native_cleanup_end(p->parent, runtime);
}
static void clear_prepared(prepared_owner *p, duckdb_ml_runtime runtime) {
    if (!p) return;
    duckdb_ml_native_cleanup_begin(p->parent, runtime);
    clear_result(p, runtime);
    if (p->prepared) { duckdb_destroy_prepare(&p->prepared); duckdb_ml_released(); }
    if (p->extracted) { duckdb_destroy_extracted(&p->extracted); duckdb_ml_released(); }
    clear_input(p);
    duckdb_ml_native_cleanup_end(p->parent, runtime);
}
static void delete_prepared(prepared_owner *p) {
    if (!p) return;
    clear_prepared(p, DUCKDB_ML_RUNTIME_HELD); duckdb_ml_connection_unref(p->parent); free(p); duckdb_ml_released();
}
static void finalize_prepared(value v) {
    if (Prepared(v)) { duckdb_ml_fallback(); delete_prepared(Prepared(v)); Prepared(v) = NULL; }
}
static struct custom_operations prepared_ops = {
    "duckdb.ffi.prepared", finalize_prepared, custom_compare_default, custom_hash_default,
    custom_serialize_default, custom_deserialize_default, custom_compare_ext_default,
    custom_fixed_length_default
};
CAMLprim value ml_duckdb_prepared_owner(value connection) {
    CAMLparam1(connection); CAMLlocal1(v);
    v = caml_alloc_custom(&prepared_ops, sizeof(prepared_owner *), 0, 1); Prepared(v) = NULL;
    prepared_owner *p = calloc(1, sizeof(*p));
    if (!p) caml_raise_out_of_memory();
    p->parent = duckdb_ml_connection_ref(connection); Prepared(v) = p; duckdb_ml_acquired();
    CAMLreturn(v);
}
CAMLprim value ml_duckdb_prepare(value v, value sql) {
    CAMLparam2(v, sql); prepared_owner *p = Prepared(v);
    size_t length = caml_string_length(sql);
    p->input = malloc(length + 1);
    if (!p->input) caml_raise_out_of_memory();
    duckdb_ml_acquired(); memcpy(p->input, String_val(sql), length); p->input[length] = 0;
    duckdb_connection connection = duckdb_ml_connection_handle(p->parent);
    caml_enter_blocking_section();
    duckdb_ml_native_work_begin(p->parent);
    p->status = 0;
    if (duckdb_ml_native_user_call_begin(p->parent) == DUCKDB_ML_CALL_CANCELLED) p->status = 3;
    else {
        idx_t count = duckdb_extract_statements(connection, p->input, &p->extracted);
        duckdb_ml_native_user_call_end(p->parent);
        if (p->extracted) duckdb_ml_acquired();
        const char *error = p->extracted ? duckdb_extract_statements_error(p->extracted) : "No extracted statements";
        if (error && *error) set_error(p, error);
        else if (count != 1) p->status = 2;
        else if (duckdb_ml_native_user_call_begin(p->parent) == DUCKDB_ML_CALL_CANCELLED) p->status = 3;
        else {
            duckdb_state state = duckdb_prepare_extracted_statement(connection, p->extracted, 0, &p->prepared);
            duckdb_ml_native_user_call_end(p->parent);
            if (p->prepared) duckdb_ml_acquired();
            if (state != DuckDBSuccess) set_error(p, p->prepared ? duckdb_prepare_error(p->prepared) : NULL);
            else if (!duckdb_ml_allowed_statement(duckdb_prepared_statement_type(p->prepared))) p->status = 2;
        }
    }
    duckdb_ml_native_cleanup_begin(p->parent, DUCKDB_ML_RUNTIME_RELEASED);
    if (p->extracted) { duckdb_destroy_extracted(&p->extracted); duckdb_ml_released(); }
    clear_input(p);
    duckdb_ml_native_cleanup_end(p->parent, DUCKDB_ML_RUNTIME_RELEASED);
    duckdb_ml_native_work_end(p->parent);
    caml_leave_blocking_section(); caml_process_pending_actions(); CAMLreturn(Val_unit);
}
CAMLprim value ml_duckdb_execute_prepared(value v) {
    CAMLparam1(v); prepared_owner *p = Prepared(v);
    caml_enter_blocking_section();
    duckdb_ml_native_work_begin(p->parent);
    p->status = 0;
    if (duckdb_ml_native_user_call_begin(p->parent) == DUCKDB_ML_CALL_CANCELLED) p->status = 3;
    else {
        p->has_result = 1; duckdb_ml_acquired();
        duckdb_state state = duckdb_execute_prepared(p->prepared, &p->result);
        duckdb_ml_native_user_call_end(p->parent);
        if (state != DuckDBSuccess) set_error(p, duckdb_result_error(&p->result));
    }
    duckdb_ml_native_work_end(p->parent);
    caml_leave_blocking_section(); caml_process_pending_actions(); CAMLreturn(Val_unit);
}
CAMLprim value ml_duckdb_fetch(value v) {
    CAMLparam1(v); prepared_owner *p = Prepared(v);
    caml_enter_blocking_section();
    duckdb_ml_native_work_begin(p->parent);
    duckdb_ml_native_cleanup_begin(p->parent, DUCKDB_ML_RUNTIME_RELEASED);
    if (p->chunk) { duckdb_destroy_data_chunk(&p->chunk); duckdb_ml_released(); }
    duckdb_ml_native_cleanup_end(p->parent, DUCKDB_ML_RUNTIME_RELEASED);
    p->status = 0;
    if (duckdb_ml_native_user_call_begin(p->parent) == DUCKDB_ML_CALL_CANCELLED) p->status = 3;
    else {
        p->chunk = duckdb_fetch_chunk(p->result);
        duckdb_ml_native_user_call_end(p->parent);
        if (p->chunk) duckdb_ml_acquired();
        else { const char *error = duckdb_result_error(&p->result); if (error && *error) set_error(p, error); }
    }
    duckdb_ml_native_work_end(p->parent);
    caml_leave_blocking_section(); caml_process_pending_actions();
    CAMLreturn(Val_int(p->status ? -1 : (p->chunk ? 1 : 0)));
}
CAMLprim value ml_duckdb_close_result(value v) {
    CAMLparam1(v); prepared_owner *p = Prepared(v);
    caml_enter_blocking_section(); clear_result(p, DUCKDB_ML_RUNTIME_RELEASED); caml_leave_blocking_section();
    caml_process_pending_actions(); CAMLreturn(Val_unit);
}
CAMLprim value ml_duckdb_finish_result_close(value v) { clear_result(Prepared(v), DUCKDB_ML_RUNTIME_HELD); return Val_unit; }
CAMLprim value ml_duckdb_close_prepared(value v) {
    CAMLparam1(v); prepared_owner *p = Prepared(v);
    caml_enter_blocking_section(); clear_prepared(p, DUCKDB_ML_RUNTIME_RELEASED); caml_leave_blocking_section();
    caml_process_pending_actions(); CAMLreturn(Val_unit);
}
CAMLprim value ml_duckdb_finish_prepared_close(value v) {
    delete_prepared(Prepared(v)); Prepared(v) = NULL; return Val_unit;
}
CAMLprim value ml_duckdb_clear_prepared_input(value v) { clear_input(Prepared(v)); return Val_unit; }
CAMLprim value ml_duckdb_prepared_status(value v) { return Val_int(Prepared(v)->status); }
CAMLprim value ml_duckdb_prepared_message(value v) {
    CAMLparam1(v); CAMLreturn(caml_copy_string(Prepared(v)->message));
}
CAMLprim value ml_duckdb_parameter_count(value v) { return Val_long(duckdb_nparams(Prepared(v)->prepared)); }
CAMLprim value ml_duckdb_parameter_type(value v, value index) {
    return Val_int(duckdb_param_type(Prepared(v)->prepared, Long_val(index)));
}
CAMLprim value ml_duckdb_column_count(value v) { return Val_long(duckdb_column_count(&Prepared(v)->result)); }
CAMLprim value ml_duckdb_column_type(value v, value index) {
    return Val_int(duckdb_column_type(&Prepared(v)->result, Long_val(index)));
}
CAMLprim value ml_duckdb_chunk_length(value v) { return Val_long(duckdb_data_chunk_get_size(Prepared(v)->chunk)); }
CAMLprim value ml_duckdb_prepared_kind(value v) {
    return Val_int(duckdb_prepared_statement_type(Prepared(v)->prepared));
}
CAMLprim value ml_duckdb_prepared_column_types(value v) {
    CAMLparam1(v); CAMLlocal1(types); prepared_owner *p = Prepared(v);
    idx_t count = duckdb_prepared_statement_column_count(p->prepared);
    types = caml_alloc(count, 0);
    for (idx_t i = 0; i < count; ++i)
        Store_field(types, i, Val_int(duckdb_prepared_statement_column_type(p->prepared, i)));
    CAMLreturn(types);
}
