#define _POSIX_C_SOURCE 200809L
#define DUCKDB_API_NO_DEPRECATED
#include <duckdb.h>
#include <caml/mlvalues.h>
#include <stdatomic.h>
#include <time.h>

static _Atomic int armed, entry, proceed, expired;
static _Atomic int executions, interrupts, disconnects, begins, commits, rollbacks;
static void pause_at(int point) {
    if (atomic_load(&armed) != point) return;
    atomic_store(&entry, point);
    struct timespec start, now, interval = {0, 1000000};
    clock_gettime(CLOCK_MONOTONIC, &start);
    while (!atomic_load(&proceed)) {
        clock_gettime(CLOCK_MONOTONIC, &now);
        if (now.tv_sec - start.tv_sec >= 10) { atomic_store(&expired, 1); break; }
        nanosleep(&interval, NULL);
    }
}
duckdb_state real_execute(duckdb_prepared_statement, duckdb_result *) __asm__("__real_duckdb_execute_prepared");
duckdb_state wrapped_execute(duckdb_prepared_statement, duckdb_result *) __asm__("__wrap_duckdb_execute_prepared");
duckdb_state wrapped_execute(duckdb_prepared_statement p, duckdb_result *r) {
    atomic_fetch_add(&executions, 1);
    pause_at(1);
    duckdb_state result = real_execute(p, r);
    pause_at(2);
    return result;
}
void real_interrupt(duckdb_connection) __asm__("__real_duckdb_interrupt");
void wrapped_interrupt(duckdb_connection) __asm__("__wrap_duckdb_interrupt");
/* This entire noalloc chain keeps the runtime lock. In particular, NO gate,
   allocation, exception, callback or blocking-section transition belongs here. */
void wrapped_interrupt(duckdb_connection c) {
    atomic_fetch_add(&interrupts, 1);
    real_interrupt(c);
}
void real_disconnect(duckdb_connection *) __asm__("__real_duckdb_disconnect");
void wrapped_disconnect(duckdb_connection *) __asm__("__wrap_duckdb_disconnect");
void wrapped_disconnect(duckdb_connection *c) {
    pause_at(4);
    atomic_fetch_add(&disconnects, 1);
    real_disconnect(c);
}
#include <string.h>
duckdb_state real_query(duckdb_connection, const char *, duckdb_result *) __asm__("__real_duckdb_query");
duckdb_state wrapped_query(duckdb_connection, const char *, duckdb_result *) __asm__("__wrap_duckdb_query");
duckdb_state wrapped_query(duckdb_connection c, const char *sql, duckdb_result *r) {
    if (strcmp(sql, "BEGIN TRANSACTION") == 0) atomic_fetch_add(&begins, 1);
    if (strcmp(sql, "COMMIT") == 0) atomic_fetch_add(&commits, 1);
    if (strcmp(sql, "ROLLBACK") == 0) atomic_fetch_add(&rollbacks, 1);
    return real_query(c, sql, r);
}
CAMLprim value stage4_arm(value point) {
    atomic_store(&entry, 0); atomic_store(&proceed, 0); atomic_store(&expired, 0);
    atomic_store(&armed, Int_val(point)); return Val_unit;
}
CAMLprim value stage4_entered(value unit) { (void)unit; return Val_int(atomic_load(&entry)); }
CAMLprim value stage4_release(value unit) { (void)unit; atomic_store(&proceed, 1); return Val_unit; }
CAMLprim value stage4_interrupt_count(value unit) { (void)unit; return Val_int(atomic_load(&interrupts)); }
CAMLprim value stage4_disconnect_count(value unit) { (void)unit; return Val_int(atomic_load(&disconnects)); }
CAMLprim value stage4_execute_count(value unit) { (void)unit; return Val_int(atomic_load(&executions)); }
CAMLprim value stage4_expired(value unit) { (void)unit; return Val_bool(atomic_load(&expired)); }
CAMLprim value stage4_control_count(value kind) {
    return Val_int(Int_val(kind) == 0 ? atomic_load(&begins) :
                   Int_val(kind) == 1 ? atomic_load(&commits) : atomic_load(&rollbacks));
}
