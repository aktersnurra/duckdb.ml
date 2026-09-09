#include "native_borrow.h"
#include <caml/alloc.h>
#include <caml/custom.h>
#include <caml/fail.h>
#include <caml/memory.h>
#include <caml/mlvalues.h>
#include <caml/threads.h>
#include <stdatomic.h>

#define Owner(v) (*((stage2_owner **)Data_custom_val(v)))
static _Atomic int fallback_reclaims;
static void release_owner(value v) {
    stage2_delete(Owner(v)); Owner(v) = NULL;
}
static void finalize(value v) {
    if (Owner(v)) atomic_fetch_add(&fallback_reclaims, 1);
    release_owner(v);
}
static struct custom_operations ops = {
    "duckdb.stage2.owner", finalize, custom_compare_default, custom_hash_default,
    custom_serialize_default, custom_deserialize_default, custom_compare_ext_default,
    custom_fixed_length_default
};
CAMLprim value stage2_ffi_create(value unit) {
    CAMLparam1(unit);
    CAMLlocal1(v);
    v = caml_alloc_custom(&ops, sizeof(stage2_owner *), 0, 1);
    Owner(v) = NULL;
    Owner(v) = stage2_create();
    if (!Owner(v)) caml_raise_out_of_memory();
    CAMLreturn(v);
}
CAMLprim value stage2_ffi_prepare(value v, value sql) {
    CAMLparam2(v, sql);
    stage2_owner *o = Owner(v);
    if (stage2_set_sql(o, String_val(sql), caml_string_length(sql))) {
        /* All OCaml data copied/extracted BEFORE unlock. Native state is owned
           even if entering raises or a later poll delivers an async exception. */
        caml_enter_blocking_section();
        stage2_prepare(o);
        caml_leave_blocking_section();
    }
    CAMLreturn(Val_unit);
}
CAMLprim value stage2_ffi_next(value v) {
    CAMLparam1(v);
    stage2_owner *o = Owner(v);
    caml_enter_blocking_section();
    int status = stage2_next(o);
    caml_leave_blocking_section();
    CAMLreturn(Val_int(status));
}
/* Intentionally locked, nonallocating, no runtime callbacks/polls. Destruction
   may block: this is a bounded-scope prototype, not a scheduler-safe close API. */
CAMLprim value stage2_ffi_close(value v) { release_owner(v); return Val_unit; }
CAMLprim value stage2_ffi_fallback_reclaims(value unit) {
    (void)unit; return Val_int(atomic_load(&fallback_reclaims));
}
CAMLprim value stage2_ffi_status(value v) { return Val_int(stage2_status(Owner(v))); }
CAMLprim value stage2_ffi_message(value v) {
    CAMLparam1(v);
    CAMLreturn(caml_copy_string(stage2_message(Owner(v))));
}
CAMLprim value stage2_ffi_length(value v) { return Val_long(stage2_length(Owner(v))); }
CAMLprim value stage2_ffi_valid(value v, value i) {
    return Val_bool(stage2_valid(Owner(v), Long_val(i)));
}
CAMLprim int64_t stage2_ffi_value_unboxed(value v, value i) {
    return stage2_value(Owner(v), Long_val(i));
}
CAMLprim value stage2_ffi_value(value v, value i) {
    CAMLparam2(v, i);
    CAMLreturn(caml_copy_int64(stage2_ffi_value_unboxed(v, i)));
}
CAMLprim value stage2_ffi_live(value unit) {
    (void)unit; return Val_int(stage2_live_resources());
}
