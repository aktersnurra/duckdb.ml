#include "native_probe.h"
#include <caml/alloc.h>
#include <caml/custom.h>
#include <caml/fail.h>
#include <caml/memory.h>
#include <caml/mlvalues.h>
#include <caml/threads.h>
#include <stdlib.h>
#include <string.h>

/* The rooted custom block points to a stable native owner. Only that owner,
   never Data_custom_val, may be touched while the runtime lock is released. */
struct response_owner { char *sql; void *response; };
#define Owner(v) (*((struct response_owner **)Data_custom_val(v)))
#define Response(v) (Owner(v) ? Owner(v)->response : NULL)
static void finalize_response(value v) {
    struct response_owner *owner = Owner(v);
    if (owner) {
        stage1_free_sql(owner->sql);
        stage1_destroy(owner->response);
        free(owner);
        Owner(v) = NULL;
    }
}
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
    Owner(box) = NULL;
    struct response_owner *owner = calloc(1, sizeof(*owner));
    if (!owner) CAMLreturn(box);
    Owner(box) = owner;
    mlsize_t length = caml_string_length(sql);
    owner->sql = stage1_alloc_sql(length + 1);
    if (!owner->sql) CAMLreturn(box);
    memcpy(owner->sql, String_val(sql), length);
    owner->sql[length] = '\0';
    /* Release can raise a pending Sys.Break: the finalizer already owns SQL.
       Root the response in native storage before the reacquisition boundary. */
    caml_enter_blocking_section();
    owner->response = stage1_query(owner->sql);
    stage1_free_sql(owner->sql);
    owner->sql = NULL;
    caml_leave_blocking_section();
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
