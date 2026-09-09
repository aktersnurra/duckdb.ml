#define _POSIX_C_SOURCE 200809L
#include <stdatomic.h>
#include <stdbool.h>
#include <string.h>
#include <time.h>
#include <stdio.h>
#include <stdlib.h>
#include <duckdb.h>
#include <caml/mlvalues.h>
#include <caml/memory.h>
#include <caml/threads.h>
#include <caml/callback.h>
#include <caml/fail.h>
#include <assert.h>
/* GNU linker --wrap identifiers are required protocol, not exported safe API.
   These observers do not introduce runtime release at engine entry. */
static atomic_int open_calls, connect_calls, disconnect_calls, fail_connect;
static atomic_int interrupt_calls, execution_calls, error_calls, join_calls, locked_engine_calls, commit_calls;
static atomic_bool gates[16], selected_gate, selected_entry;
static atomic_int entries[16];
static atomic_bool close_failure, force_locked, indexed_failure;
static atomic_int rollback_failure;
static_assert(ATOMIC_POINTER_LOCK_FREE == 2, "noalloc pointer observer must be lock-free");
static _Atomic(duckdb_connection) interrupted[2], initial_connections[2];
static _Thread_local int disconnected_index;
static _Thread_local bool runtime_released;
static _Thread_local unsigned finish_depth, disconnect_serial;
static void wait_gate(atomic_bool *gate) {
  struct timespec start, now, delay = {0, 1000000};
  clock_gettime(CLOCK_MONOTONIC, &start);
  while (atomic_load(gate)) {
    clock_gettime(CLOCK_MONOTONIC, &now);
    if (now.tv_sec - start.tv_sec >= 20) { fputs("stage4c native gate watchdog\n", stderr); abort(); }
    nanosleep(&delay, NULL);
  }
}
static void boundary(int id) {
  bool locked = !runtime_released || finish_depth;
  if (locked) atomic_fetch_add(&locked_engine_calls, 1);
  if (!atomic_load(&gates[id])) return;
  atomic_fetch_add(&entries[id], 1);
  /* Broken locked-engine paths fail the independent oracle, never deadlock. */
  if (!locked) wait_gate(&gates[id]);
}
CAMLprim value stage4c_reset(value at) {
  atomic_store(&open_calls, 0); atomic_store(&connect_calls, 0);
  atomic_store(&disconnect_calls, 0); atomic_store(&fail_connect, Int_val(at));
  atomic_store(&interrupt_calls, 0); atomic_store(&execution_calls, 0);
  atomic_store(&error_calls, 0); atomic_store(&join_calls, 0);
  atomic_store(&locked_engine_calls, 0); atomic_store(&commit_calls, 0);
  for (int i = 0; i < 16; i++) { atomic_store(&gates[i], false); atomic_store(&entries[i], 0); }
  atomic_store(&selected_gate, false); atomic_store(&selected_entry, false);
  atomic_store(&close_failure, false); atomic_store(&rollback_failure, 0);
  atomic_store(&interrupted[0], NULL); atomic_store(&interrupted[1], NULL);
  atomic_store(&initial_connections[0], NULL); atomic_store(&initial_connections[1], NULL);
  atomic_store(&indexed_failure, false);
  return Val_unit;
}
#define COUNTER(name, counter) CAMLprim value stage4c_##name(value unit) { (void)unit; return Val_int(atomic_load(&counter)); }
COUNTER(opens, open_calls)
COUNTER(connects, connect_calls)
COUNTER(disconnects, disconnect_calls)
COUNTER(interrupts, interrupt_calls)
COUNTER(executions, execution_calls)
COUNTER(native_errors, error_calls)
COUNTER(joins, join_calls)
COUNTER(locked_calls, locked_engine_calls)
COUNTER(commits, commit_calls)
CAMLprim value stage4c_gate(value id, value enabled) { atomic_store(&gates[Int_val(id)], Bool_val(enabled)); return Val_unit; }
CAMLprim value stage4c_entered(value id) { return Val_int(atomic_load(&entries[Int_val(id)])); }
CAMLprim value stage4c_hold_selected(value enabled) { atomic_store(&selected_gate, Bool_val(enabled)); return Val_unit; }
CAMLprim value stage4c_selected_seen(value unit) { (void)unit; return Val_bool(atomic_load(&selected_entry)); }
CAMLprim value stage4c_fail_close(value enabled) { atomic_store(&close_failure, Bool_val(enabled)); return Val_unit; }
CAMLprim value stage4c_indexed_close_failure(value enabled) { atomic_store(&indexed_failure, Bool_val(enabled)); return Val_unit; }
CAMLprim value stage4c_fail_rollback(value mode) { atomic_store(&rollback_failure, Int_val(mode)); return Val_unit; }
CAMLprim value stage4c_distinct_interrupted(value unit) {
  (void)unit; return Val_int((atomic_load(&interrupted[0]) != NULL) + (atomic_load(&interrupted[1]) != NULL));
}
extern void __real_caml_enter_blocking_section(void);
void __wrap_caml_enter_blocking_section(void) { __real_caml_enter_blocking_section(); runtime_released = true; }
extern void __real_caml_leave_blocking_section(void);
void __wrap_caml_leave_blocking_section(void) { runtime_released = false; __real_caml_leave_blocking_section(); }
extern duckdb_state __real_duckdb_open_ext(const char *, duckdb_database *, duckdb_config, char **);
duckdb_state __wrap_duckdb_open_ext(const char *path, duckdb_database *db, duckdb_config config, char **error) {
  atomic_fetch_add(&open_calls, 1); boundary(0); return __real_duckdb_open_ext(path, db, config, error);
}
extern duckdb_state __real_duckdb_connect(duckdb_database, duckdb_connection *);
duckdb_state __wrap_duckdb_connect(duckdb_database db, duckdb_connection *connection) {
  int index = atomic_fetch_add(&connect_calls, 1); boundary(1);
  if (index == atomic_load(&fail_connect)) return DuckDBError;
  duckdb_state result = __real_duckdb_connect(db, connection);
  if (index < 2 && result == DuckDBSuccess) atomic_store(&initial_connections[index], *connection);
  return result;
}
extern void __real_duckdb_disconnect(duckdb_connection *);
void __wrap_duckdb_disconnect(duckdb_connection *connection) {
  disconnected_index = -1;
  for (int i = 0; i < 2; i++) if (*connection == atomic_load(&initial_connections[i])) disconnected_index = i;
  atomic_fetch_add(&disconnect_calls, 1); ++disconnect_serial; boundary(11); __real_duckdb_disconnect(connection);
}
extern duckdb_state __real_duckdb_execute_prepared(duckdb_prepared_statement, duckdb_result *);
duckdb_state __wrap_duckdb_execute_prepared(duckdb_prepared_statement p, duckdb_result *r) {
  atomic_fetch_add(&execution_calls, 1); boundary(2);
  duckdb_state result = __real_duckdb_execute_prepared(p, r);
  if (result != DuckDBSuccess) atomic_fetch_add(&error_calls, 1);
  boundary(3); return result;
}
extern duckdb_state __real_duckdb_query(duckdb_connection, const char *, duckdb_result *);
duckdb_state __wrap_duckdb_query(duckdb_connection c, const char *sql, duckdb_result *r) {
  if (!strcmp(sql, "ROLLBACK")) boundary(4);
  bool commit = !strcmp(sql, "COMMIT");
  if (commit) { atomic_fetch_add(&commit_calls, 1); boundary(14); }
  const char *actual = !strcmp(sql, "ROLLBACK") && atomic_load(&rollback_failure) == 1 ? "injected invalid rollback" : sql;
  duckdb_state result = __real_duckdb_query(c, actual, r);
  if (commit) boundary(15);
  return result;
}
#define DESTROY(name, id, parameters, args) \
  extern void __real_##name parameters; \
  void __wrap_##name parameters { boundary(id); __real_##name args; }
/* Negative control performs actual finite engine destruction under the runtime
   lock. The independent boundary observer declines to hold a broken path, so
   no scheduler-dependent releaser is needed and no noalloc path is unlocked. */
CAMLprim value stage4c_force_locked_destructor(value enabled) { atomic_store(&force_locked, Bool_val(enabled)); return Val_unit; }
extern void __real_duckdb_destroy_result(duckdb_result *);
void __wrap_duckdb_destroy_result(duckdb_result *r) {
  bool negative = atomic_load(&force_locked) && runtime_released;
  if (negative) caml_leave_blocking_section();
  boundary(5); __real_duckdb_destroy_result(r);
  if (negative) caml_enter_blocking_section();
}
DESTROY(duckdb_destroy_prepare, 6, (duckdb_prepared_statement *p), (p))
DESTROY(duckdb_destroy_extracted, 7, (duckdb_extracted_statements *e), (e))
DESTROY(duckdb_destroy_data_chunk, 8, (duckdb_data_chunk *c), (c))
DESTROY(duckdb_close, 12, (duckdb_database *db), (db))
extern duckdb_state __real_duckdb_appender_clear(duckdb_appender);
duckdb_state __wrap_duckdb_appender_clear(duckdb_appender a) { boundary(9); return __real_duckdb_appender_clear(a); }
extern duckdb_state __real_duckdb_appender_destroy(duckdb_appender *);
duckdb_state __wrap_duckdb_appender_destroy(duckdb_appender *a) { boundary(10); return __real_duckdb_appender_destroy(a); }
extern duckdb_data_chunk __real_duckdb_fetch_chunk(duckdb_result);
duckdb_data_chunk __wrap_duckdb_fetch_chunk(duckdb_result r) { boundary(13); return __real_duckdb_fetch_chunk(r); }
extern void __real_duckdb_interrupt(duckdb_connection);
void __wrap_duckdb_interrupt(duckdb_connection c) {
  atomic_fetch_add(&interrupt_calls, 1);
  for (int i = 0; i < 2; ++i) {
    duckdb_connection expected = NULL;
    if (atomic_compare_exchange_strong(&interrupted[i], &expected, c) || expected == c) break;
  }
  __real_duckdb_interrupt(c);
}
extern value __real_caml_thread_join(value);
value __wrap_caml_thread_join(value thread) {
  CAMLparam1(thread); value result = __real_caml_thread_join(thread);
  atomic_fetch_add(&join_calls, 1); CAMLreturn(result);
}
/* Accepted normal-ABI Bridge delivery primitive, NOT its noalloc reserve/try
   chain. Keep the argument rooted across the test-only selected-ticket wait. */
extern value __real_ml_duckdb_native_request_deliver(value);
value __wrap_ml_duckdb_native_request_deliver(value request) {
  CAMLparam1(request);
  if (atomic_load(&selected_gate)) {
    caml_enter_blocking_section(); atomic_store(&selected_entry, true);
    wait_gate(&selected_gate); caml_leave_blocking_section();
  }
  value result = __real_ml_duckdb_native_request_deliver(request); CAMLreturn(result);
}
#define FINISH(name) \
  extern value __real_##name(value); \
  value __wrap_##name(value v) { ++finish_depth; value result = __real_##name(v); --finish_depth; return result; }
FINISH(ml_duckdb_clear_work)
FINISH(ml_duckdb_finish_result_close)
FINISH(ml_duckdb_finish_prepared_close)
FINISH(ml_duckdb_finish_appender_close)
FINISH(ml_duckdb_finish_connection_close)
FINISH(ml_duckdb_finish_database_close)
/* Ordinary-ABI exception injections retain the real acquired/closed inventory. */
extern value __real_ml_duckdb_close_connection(value);
value __wrap_ml_duckdb_close_connection(value owner) {
  CAMLparam1(owner); unsigned before = disconnect_serial;
  value result = __real_ml_duckdb_close_connection(owner);
  if (atomic_load(&close_failure) && disconnect_serial != before) {
    if (atomic_load(&indexed_failure)) caml_raise_with_arg(*caml_named_value("stage4c_cleanup_failure_index"), Val_int(disconnected_index));
    caml_raise_constant(*caml_named_value("stage4c_cleanup_failure"));
  }
  CAMLreturn(result);
}
extern value __real_ml_duckdb_execute_control(value, value);
value __wrap_ml_duckdb_execute_control(value owner, value statement) {
  CAMLparam2(owner, statement);
  if (Int_val(statement) == 2 && atomic_load(&rollback_failure) == 2)
    caml_raise_constant(*caml_named_value("stage4c_cleanup_failure"));
  CAMLreturn(__real_ml_duckdb_execute_control(owner, statement));
}
