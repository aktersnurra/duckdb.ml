#include "native_probe.h"
#include <caml/mlvalues.h>
#include <caml/threads.h>
#include <signal.h>

/* Linked only into signal_tests. Inject a real OS signal immediately before
   the real pinned transition, not an OCaml exception in a mock transition. */
static int enter_countdown;
static int leave_countdown;
static int injections;
static int cleanup_signal;
static int sql_at_signal;
static int results_at_signal;
static void inject_signal(void) {
    sql_at_signal = stage1_live_sql_copies();
    results_at_signal = stage1_live_results();
    ++injections;
    raise(SIGUSR1);
}
void real_enter(void) __asm__("__real_caml_enter_blocking_section");
void real_leave(void) __asm__("__real_caml_leave_blocking_section");
void wrapped_enter(void) __asm__("__wrap_caml_enter_blocking_section");
void wrapped_enter(void) {
    if (enter_countdown > 0 && --enter_countdown == 0) {
        inject_signal();
    }
    real_enter();
}
void wrapped_leave(void) __asm__("__wrap_caml_leave_blocking_section");
void wrapped_leave(void) {
    if (leave_countdown > 0 && --leave_countdown == 0) {
        inject_signal();
    }
    real_leave();
}
CAMLprim value stage1_test_arm(value enter, value leave) {
    enter_countdown = Int_val(enter);
    leave_countdown = Int_val(leave);
    injections = 0;
    cleanup_signal = 0;
    return Val_unit;
}
CAMLprim value stage1_test_injections(value unit) {
    (void)unit;
    return Val_int(injections);
}
CAMLprim value stage1_test_live_sql(value unit) {
    (void)unit;
    return Val_int(stage1_live_sql_copies());
}

/* This generated symbol is deliberately wrapped only by the regression binary.
   Queue the signal before the destructor's first instruction, even when locked. */
value real_destroy_slot(value slot) __asm__("__real_stage1_cleanup_1_stage1_destroy_slot");
value wrapped_destroy_slot(value slot) __asm__("__wrap_stage1_cleanup_1_stage1_destroy_slot");
value wrapped_destroy_slot(value slot) {
    if (cleanup_signal) {
        cleanup_signal = 0;
        inject_signal();
    }
    return real_destroy_slot(slot);
}
CAMLprim value stage1_test_arm_cleanup(value unit) {
    (void)unit;
    cleanup_signal = 1;
    injections = 0;
    return Val_unit;
}

CAMLprim value stage1_test_sql_at_signal(value unit) {
    (void)unit;
    return Val_int(sql_at_signal);
}
CAMLprim value stage1_test_results_at_signal(value unit) {
    (void)unit;
    return Val_int(results_at_signal);
}
