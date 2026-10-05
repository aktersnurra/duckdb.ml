#define _POSIX_C_SOURCE 200809L
#define DUCKDB_API_NO_DEPRECATED
#include <duckdb.h>
#include <caml/mlvalues.h>
#include <stdatomic.h>
#include <time.h>
static _Atomic int armed, entered, proceed, close_trace;
static void pause_at(int point) {
    if (atomic_load(&armed) != point) return;
    atomic_store(&entered, point);
    struct timespec interval = {0, 1000000};
    while (!atomic_load(&proceed)) nanosleep(&interval, NULL);
}
duckdb_state real_execute(duckdb_prepared_statement, duckdb_result *) __asm__("__real_duckdb_execute_prepared");
duckdb_state wrapped_execute(duckdb_prepared_statement, duckdb_result *) __asm__("__wrap_duckdb_execute_prepared");
duckdb_state wrapped_execute(duckdb_prepared_statement p, duckdb_result *r) {
    pause_at(1); return real_execute(p, r);
}
void real_disconnect(duckdb_connection *) __asm__("__real_duckdb_disconnect");
void wrapped_disconnect(duckdb_connection *) __asm__("__wrap_duckdb_disconnect");
void wrapped_disconnect(duckdb_connection *c) {
    pause_at(2);
    atomic_store(&close_trace, (atomic_load(&close_trace) % 1000) * 10 + 1);
    real_disconnect(c);
}
CAMLprim value test_arm(value point) {
    atomic_store(&entered, 0); atomic_store(&proceed, 0);
    atomic_store(&armed, Int_val(point)); return Val_unit;
}
CAMLprim value test_entered(value unit) { (void)unit; return Val_int(atomic_load(&entered)); }
CAMLprim value test_release(value unit) { (void)unit; atomic_store(&proceed, 1); return Val_unit; }
#include <string.h>
static _Atomic int rollback_failure;
duckdb_state real_query(duckdb_connection, const char *, duckdb_result *) __asm__("__real_duckdb_query");
duckdb_state wrapped_query(duckdb_connection, const char *, duckdb_result *) __asm__("__wrap_duckdb_query");
duckdb_state wrapped_query(duckdb_connection c, const char *sql, duckdb_result *result) {
    if (strcmp(sql, "ROLLBACK") == 0 && atomic_exchange(&rollback_failure, 0))
        return real_query(c, "select error('injected rollback failure')", result);
    return real_query(c, sql, result);
}
void real_close(duckdb_database *) __asm__("__real_duckdb_close");
void wrapped_close(duckdb_database *) __asm__("__wrap_duckdb_close");
void wrapped_close(duckdb_database *db) {
    atomic_store(&close_trace, (atomic_load(&close_trace) % 1000) * 10 + 2); real_close(db);
}
CAMLprim value test_fail_rollback(value unit) { (void)unit; atomic_store(&rollback_failure, 1); return Val_unit; }
CAMLprim value test_trace_reset(value unit) { (void)unit; atomic_store(&close_trace, 0); return Val_unit; }
CAMLprim value test_trace(value unit) { (void)unit; return Val_int(atomic_load(&close_trace)); }
