#define _POSIX_C_SOURCE 200809L
#include <duckdb.h>
#include <caml/mlvalues.h>
#include <caml/memory.h>
#include <caml/threads.h>
#include <caml/callback.h>
#include <caml/fail.h>
#include <assert.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <string.h>
#include <time.h>
#include <stdio.h>
#include <stdlib.h>
/* Test-only actual native boundaries. No gate releases the runtime. The runtime
   transition observer and finish depth are independent of scheduler heartbeat. */
static _Atomic bool gates[12];
static _Atomic int entries[12], interrupt_count, error_count, execution_count, join_count, finishes, locked_calls;
static _Thread_local bool active, runtime_released, rollback_failure;
static _Thread_local unsigned finish_depth;
/* Only compared during the two simultaneously live saturation requests. Reset
   after both workers/controllers join, before another connection can be used. */
static_assert(ATOMIC_POINTER_LOCK_FREE == 2, "test noalloc interrupt observer requires lock-free pointers");
static _Atomic(duckdb_connection) interrupted[2];
static bool observe_engine(void) {
    bool locked = active && (!runtime_released || finish_depth);
    if (locked) atomic_fetch_add(&locked_calls, 1);
    return locked;
}
static void boundary(int id) {
    if (!active) return;
    bool locked = observe_engine();
    if (!atomic_load(&gates[id])) return;
    atomic_fetch_add(&entries[id], 1);
    /* A regression into held-runtime cleanup must yield an assertion failure,
       not deadlock the observing scheduler. Never artificially unlock it. */
    if (locked) return;
    struct timespec start, now, delay = {0, 1000000};
    clock_gettime(CLOCK_MONOTONIC, &start);
    while (atomic_load(&gates[id])) {
        clock_gettime(CLOCK_MONOTONIC, &now);
        if (now.tv_sec - start.tv_sec >= 20) {
            fputs("responsiveness native gate watchdog: process failure\n", stderr); abort();
        }
        nanosleep(&delay, NULL);
    }
}
CAMLprim value responsiveness_reset(value unit) {
    (void)unit;
    for (int i = 0; i < 12; ++i) { atomic_store(&gates[i], false); atomic_store(&entries[i], 0); }
    atomic_store(&interrupt_count, 0); atomic_store(&error_count, 0); atomic_store(&execution_count, 0); atomic_store(&join_count, 0);
    atomic_store(&finishes, 0); atomic_store(&locked_calls, 0);
    atomic_store(&interrupted[0], NULL); atomic_store(&interrupted[1], NULL); return Val_unit;
}
CAMLprim value responsiveness_activate(value unit) { (void)unit; active = true; return Val_unit; }
CAMLprim value responsiveness_deactivate(value unit) { (void)unit; active = false; return Val_unit; }
CAMLprim value responsiveness_gate(value id, value enabled) { atomic_store(&gates[Int_val(id)], Bool_val(enabled)); return Val_unit; }
CAMLprim value responsiveness_entered(value id) { return Val_int(atomic_load(&entries[Int_val(id)])); }
#define COUNTER(name, counter) CAMLprim value name(value unit) { (void)unit; return Val_int(atomic_load(&counter)); }
COUNTER(responsiveness_interrupts, interrupt_count)
CAMLprim value responsiveness_interrupted_connections(value unit) {
    (void)unit;
    return Val_int((atomic_load(&interrupted[0]) != NULL) + (atomic_load(&interrupted[1]) != NULL));
}
COUNTER(responsiveness_native_errors, error_count)
COUNTER(responsiveness_executions, execution_count)
COUNTER(responsiveness_joins, join_count)
COUNTER(responsiveness_finish_calls, finishes)
COUNTER(responsiveness_locked_engine_calls, locked_calls)
CAMLprim value responsiveness_fail_rollback(value enabled) { rollback_failure = Bool_val(enabled); return Val_unit; }
void __real_caml_enter_blocking_section(void);
void __wrap_caml_enter_blocking_section(void) { __real_caml_enter_blocking_section(); runtime_released = true; }
void __real_caml_leave_blocking_section(void);
void __wrap_caml_leave_blocking_section(void) { runtime_released = false; __real_caml_leave_blocking_section(); }

duckdb_state __real_duckdb_execute_prepared(duckdb_prepared_statement, duckdb_result *);
duckdb_state __wrap_duckdb_execute_prepared(duckdb_prepared_statement p, duckdb_result *r) {
    if (active) atomic_fetch_add(&execution_count, 1);
    boundary(0);
    duckdb_state result = __real_duckdb_execute_prepared(p, r);
    if (active && result != DuckDBSuccess) atomic_fetch_add(&error_count, 1);
    return result;
}
duckdb_state __real_duckdb_query(duckdb_connection, const char *, duckdb_result *);
duckdb_state __wrap_duckdb_query(duckdb_connection c, const char *sql, duckdb_result *r) {
    if (!strcmp(sql, "ROLLBACK")) boundary(1);
    return __real_duckdb_query(c, sql, r);
}
#define DESTRUCTOR(name, id, parameters, arguments) \
 void __real_##name parameters; \
 void __wrap_##name parameters { boundary(id); __real_##name arguments; }
DESTRUCTOR(duckdb_destroy_result, 2, (duckdb_result *r), (r))
DESTRUCTOR(duckdb_destroy_prepare, 3, (duckdb_prepared_statement *p), (p))
DESTRUCTOR(duckdb_destroy_extracted, 4, (duckdb_extracted_statements *e), (e))
DESTRUCTOR(duckdb_destroy_data_chunk, 5, (duckdb_data_chunk *c), (c))
DESTRUCTOR(duckdb_disconnect, 8, (duckdb_connection *c), (c))
DESTRUCTOR(duckdb_close, 9, (duckdb_database *d), (d))
#define UNGATED_DESTRUCTOR(name, parameters, arguments) \
 void __real_##name parameters; \
 void __wrap_##name parameters { (void)observe_engine(); __real_##name arguments; }
UNGATED_DESTRUCTOR(duckdb_destroy_config, (duckdb_config *c), (c))
UNGATED_DESTRUCTOR(duckdb_destroy_value, (duckdb_value *v), (v))
UNGATED_DESTRUCTOR(duckdb_destroy_logical_type, (duckdb_logical_type *t), (t))
UNGATED_DESTRUCTOR(duckdb_destroy_error_data, (duckdb_error_data *e), (e))
duckdb_state __real_duckdb_appender_clear(duckdb_appender);
duckdb_state __wrap_duckdb_appender_clear(duckdb_appender a) { boundary(6); return __real_duckdb_appender_clear(a); }
duckdb_state __real_duckdb_appender_destroy(duckdb_appender *);
duckdb_state __wrap_duckdb_appender_destroy(duckdb_appender *a) { boundary(7); return __real_duckdb_appender_destroy(a); }
void __real_duckdb_interrupt(duckdb_connection);
void __wrap_duckdb_interrupt(duckdb_connection c) {
    atomic_fetch_add(&interrupt_count, 1);
    for (int i = 0; i < 2; ++i) {
        duckdb_connection expected = NULL;
        if (atomic_compare_exchange_strong(&interrupted[i], &expected, c) || expected == c) break;
    }
    __real_duckdb_interrupt(c);
}
int __real_link(const char *, const char *);
int __wrap_link(const char *source, const char *destination) { boundary(10); return __real_link(source, destination); }
int __real_unlink(const char *);
int __wrap_unlink(const char *source) { boundary(11); return __real_unlink(source); }
/* All finish ABIs are noalloc: no allocation, callback, wait or runtime release.
   Observe every actual engine call transitively, including last-parent unref. */
#define FINISH(name) \
 value __real_##name(value); \
 value __wrap_##name(value v) { \
    if (active) atomic_fetch_add(&finishes, 1); \
    ++finish_depth; value result = __real_##name(v); --finish_depth; return result; }
FINISH(ml_duckdb_clear_work)
FINISH(ml_duckdb_finish_result_close)
FINISH(ml_duckdb_finish_prepared_close)
FINISH(ml_duckdb_finish_appender_close)
FINISH(ml_duckdb_finish_connection_close)
FINISH(ml_duckdb_finish_database_close)
FINISH(ml_duckdb_finish_local_file_work)
value __real_caml_thread_join(value);
value __wrap_caml_thread_join(value thread) {
    CAMLparam1(thread);
    value result = __real_caml_thread_join(thread);
    if (active) atomic_fetch_add(&join_count, 1);
    CAMLreturn(result);
}
value __real_ml_duckdb_execute_control(value, value);
value __wrap_ml_duckdb_execute_control(value owner, value statement) {
    CAMLparam2(owner, statement);
    value result = __real_ml_duckdb_execute_control(owner, statement);
    if (active && rollback_failure && Int_val(statement) == 2)
        caml_raise_constant(*caml_named_value("responsiveness_cleanup_failure"));
    CAMLreturn(result);
}
