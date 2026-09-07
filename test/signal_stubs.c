#include <caml/mlvalues.h>
#include <signal.h>
static int enter_countdown, leave_countdown, injections, live_at_signal;
extern value ml_duckdb_live_resources(value);
static void inject(void) {
    live_at_signal = Int_val(ml_duckdb_live_resources(Val_unit));
    ++injections; raise(SIGUSR1);
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
CAMLprim value signal_arm(value enter, value leave) {
    enter_countdown = Int_val(enter); leave_countdown = Int_val(leave); injections = 0;
    return Val_unit;
}
CAMLprim value signal_trigger(value unit) { (void)unit; inject(); return Val_unit; }
CAMLprim value signal_injections(value unit) { (void)unit; return Val_int(injections); }

CAMLprim value signal_live(value unit) { (void)unit; return Val_int(live_at_signal); }
