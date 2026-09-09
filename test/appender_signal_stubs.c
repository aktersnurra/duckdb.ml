/* Test-only exact-runtime boundary injection; not installed. */
#include "signal_stubs.c"
static int target, on_leave;
CAMLprim value stage3c_target(value point, value leave) {
    target = Int_val(point); on_leave = Bool_val(leave); return Val_unit;
}
static void select_target(int point) {
    if (target == point) {
        target = 0;
        signal_arm(Val_int(on_leave ? 0 : 1), Val_int(on_leave ? 1 : 0));
    }
}
value real_copy(value) __asm__("__real_ml_duckdb_execute_prepared");
value wrapped_copy(value) __asm__("__wrap_ml_duckdb_execute_prepared");
value wrapped_copy(value p) { select_target(1); return real_copy(p); }
/* Dedicated export now uses the admitted entry; target its actual runtime
   transition rather than the retained unsafe legacy publication primitive. */
value real_publish(value,value,value,value) __asm__("__real_ml_duckdb_publish_local_file_admitted");
value wrapped_publish(value,value,value,value) __asm__("__wrap_ml_duckdb_publish_local_file_admitted");
value wrapped_publish(value c,value w,value s,value d) { select_target(2);return real_publish(c,w,s,d); }
value real_remove(value,value) __asm__("__real_ml_duckdb_remove_local_file");
value wrapped_remove(value,value) __asm__("__wrap_ml_duckdb_remove_local_file");
value wrapped_remove(value w,value s) { select_target(3);return real_remove(w,s); }
/* Normal close's flush is now separate. Preserve the original signal oracle
   at actual clear/destroy, not at the preceding flush runtime transition. */
value real_appender_close(value,value) __asm__("__real_ml_duckdb_close_appender");
value wrapped_appender_close(value,value) __asm__("__wrap_ml_duckdb_close_appender");
value wrapped_appender_close(value a,value flush) { select_target(4);return real_appender_close(a,flush); }
