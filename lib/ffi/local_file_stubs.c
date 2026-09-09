#include "query_native.h"
#include <caml/alloc.h>
#include <caml/custom.h>
#include <caml/fail.h>
#include <caml/memory.h>
#include <caml/signals.h>
#include <caml/threads.h>
#include <errno.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

typedef struct { char *source, *destination; connection_owner *parent; } file_work;
#define Work(v) (*((file_work **)Data_custom_val(v)))
static void finish(value v) {
    file_work *w = Work(v);
    if (w) {
        if (w->source) { free(w->source); duckdb_ml_released(); }
        if (w->destination) { free(w->destination); duckdb_ml_released(); }
        if (w->parent) duckdb_ml_connection_unref(w->parent);
        free(w);
        Work(v) = NULL; duckdb_ml_released();
    }
}
static void finalize(value v) { if (Work(v)) { duckdb_ml_fallback(); finish(v); } }
static struct custom_operations ops = {
    "duckdb.ffi.local_file_work", finalize, custom_compare_default, custom_hash_default,
    custom_serialize_default, custom_deserialize_default, custom_compare_ext_default,
    custom_fixed_length_default
};
CAMLprim value ml_duckdb_local_file_work(value unit) {
    CAMLparam1(unit); CAMLlocal1(v);
    v = caml_alloc_custom(&ops, sizeof(file_work *), 0, 1); Work(v) = NULL;
    file_work *w = calloc(1, sizeof(*w));
    if (!w) caml_raise_out_of_memory();
    Work(v) = w; duckdb_ml_acquired(); CAMLreturn(v);
}
static char *copy(value v) {
    size_t n = caml_string_length(v); char *s = malloc(n + 1);
    if (!s) caml_raise_out_of_memory();
    memcpy(s, String_val(v), n); s[n] = 0; return s;
}
CAMLprim value ml_duckdb_publish_local_file(value v, value source, value destination) {
    CAMLparam3(v, source, destination); file_work *w = Work(v);
    w->source = copy(source); duckdb_ml_acquired();
    w->destination = copy(destination); duckdb_ml_acquired();
    caml_enter_blocking_section();
    int result = link(w->source, w->destination) == 0 ? 0 : errno;
    caml_leave_blocking_section(); caml_process_pending_actions(); CAMLreturn(Val_int(result));
}
CAMLprim value ml_duckdb_publish_local_file_admitted(value connection, value v, value source, value destination) {
    CAMLparam4(connection, v, source, destination); file_work *w = Work(v);
    w->source = copy(source); duckdb_ml_acquired();
    w->destination = copy(destination); duckdb_ml_acquired();
    /* The work owns this reference before a raising runtime transition. The
       safe caller also roots the live connection slot through exclusive work. */
    w->parent = duckdb_ml_connection_ref(connection);
    caml_enter_blocking_section();
    duckdb_ml_native_work_begin(w->parent);
    int result;
    if (duckdb_ml_native_noninterruptible_call_begin(w->parent) == DUCKDB_ML_CALL_CANCELLED) result = -1;
    else result = link(w->source, w->destination) == 0 ? 0 : errno;
    duckdb_ml_native_work_end(w->parent);
    caml_leave_blocking_section(); caml_process_pending_actions(); CAMLreturn(Val_int(result));
}
CAMLprim value ml_duckdb_remove_local_file(value v, value source) {
    CAMLparam2(v, source); file_work *w = Work(v);
    w->source = copy(source); duckdb_ml_acquired();
    caml_enter_blocking_section();
    int result = unlink(w->source) == 0 ? 0 : errno;
    if (result == ENOENT) result = 0; /* Resource retries a single interrupted cleanup. */
    caml_leave_blocking_section(); caml_process_pending_actions(); CAMLreturn(Val_int(result));
}
CAMLprim value ml_duckdb_finish_local_file_work(value v) { finish(v); return Val_unit; }
CAMLprim value ml_duckdb_file_error_message(value e) { CAMLparam1(e); CAMLreturn(caml_copy_string(strerror(Int_val(e)))); }
CAMLprim value ml_duckdb_file_exists_error(value e) { return Val_bool(Int_val(e) == EEXIST); }
