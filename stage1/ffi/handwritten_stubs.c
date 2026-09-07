#include "native_probe.h"
#include <caml/alloc.h>
#include <caml/custom.h>
#include <caml/fail.h>
#include <caml/memory.h>
#include <caml/mlvalues.h>
#include <caml/threads.h>
#include <stdlib.h>
#include <string.h>

#define Response(v) (*((void **)Data_custom_val(v)))
static void finalize_response(value v) { stage1_destroy(Response(v)); Response(v) = NULL; }
static struct custom_operations response_ops = {
    .identifier = "duckdb.stage1.response",
    .finalize = finalize_response,
    .compare = custom_compare_default,
    .hash = custom_hash_default,
    .serialize = custom_serialize_default,
    .deserialize = custom_deserialize_default,
    .compare_ext = custom_compare_ext_default,
    .fixed_length = custom_fixed_length_default
};
CAMLprim value stage1_hand_query(value sql) {
    CAMLparam1(sql);
    CAMLlocal1(box);
    box = caml_alloc_custom(&response_ops, sizeof(void *), 0, 1);
    Response(box) = NULL;
    mlsize_t length = caml_string_length(sql);
    char *native_sql = malloc(length + 1);
    if (!native_sql) CAMLreturn(box);
    memcpy(native_sql, String_val(sql), length);
    native_sql[length] = '\0';
    /* Only native stack/allocated data are accessed in this interval. */
    caml_enter_blocking_section();
    void *response = stage1_query(native_sql);
    free(native_sql);
    caml_leave_blocking_section();
    Response(box) = response;
    CAMLreturn(box);
}
CAMLprim value stage1_hand_destroy(value box) { finalize_response(box); return Val_unit; }
CAMLprim value stage1_hand_status(value box) { return Val_int(stage1_status(Response(box))); }
CAMLprim value stage1_hand_count(value box) { return Val_int(stage1_count(Response(box))); }
CAMLprim value stage1_hand_error(value box) {
    CAMLparam1(box);
    CAMLreturn(caml_copy_string(stage1_error(Response(box))));
}
CAMLprim value stage1_hand_value(value box, value index) {
    CAMLparam2(box, index);
    int64_t result = stage1_value(Response(box), Int_val(index));
    CAMLreturn(caml_copy_int64(result));
}
/* Genuine native bits64 return, not an OCaml-side unboxing of a boxed accessor. */
CAMLprim int64_t stage1_hand_value_unboxed(value box, value index) {
    return stage1_value(Response(box), Int_val(index));
}
CAMLprim value stage1_hand_slow(value unit) {
    CAMLparam1(unit);
    caml_enter_blocking_section();
    stage1_slow();
    caml_leave_blocking_section();
    CAMLreturn(Val_unit);
}
CAMLprim value stage1_hand_slow_locked(value unit) {
    (void)unit;
    stage1_slow();
    return Val_unit;
}
CAMLprim value stage1_hand_active(value unit) { (void)unit; return Val_int(stage1_active()); }
CAMLprim value stage1_hand_live(value unit) { (void)unit; return Val_int(stage1_live_results()); }
