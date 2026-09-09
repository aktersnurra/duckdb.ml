#include "native_borrow.h"
#include <caml/mlvalues.h>
#include <signal.h>
/* Test-only GNU linker wrappers, real signals at exact runtime transitions. */
static int enter_countdown, leave_countdown, cleanup, injections, live_at_signal;
static void inject(void) {
    live_at_signal = stage2_live_resources(); ++injections; raise(SIGUSR1);
}
void real_enter(void) __asm__("__real_caml_enter_blocking_section");
void wrapped_enter(void) __asm__("__wrap_caml_enter_blocking_section");
void wrapped_enter(void) {
    if (enter_countdown > 0 && --enter_countdown == 0) inject();
    real_enter();
}
void real_leave(void) __asm__("__real_caml_leave_blocking_section");
void wrapped_leave(void) __asm__("__wrap_caml_leave_blocking_section");
void wrapped_leave(void) {
    if (leave_countdown > 0 && --leave_countdown == 0) inject();
    real_leave();
}
value real_close(value) __asm__("__real_stage2_ffi_close");
value wrapped_close(value) __asm__("__wrap_stage2_ffi_close");
value wrapped_close(value v) {
    if (cleanup) { cleanup = 0; inject(); }
    return real_close(v);
}
CAMLprim value stage2_test_arm(value enter, value leave, value close) {
    enter_countdown = Int_val(enter); leave_countdown = Int_val(leave);
    cleanup = Bool_val(close); injections = 0; live_at_signal = 0;
    return Val_unit;
}
CAMLprim value stage2_test_trigger(value unit) { (void)unit; inject(); return Val_unit; }
CAMLprim value stage2_test_injections(value unit) { (void)unit; return Val_int(injections); }
CAMLprim value stage2_test_live_at_signal(value unit) { (void)unit; return Val_int(live_at_signal); }
