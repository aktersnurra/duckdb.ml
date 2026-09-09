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
static atomic_int publication_entries_count, temporary_unlink_count;
static atomic_bool gates[19], selected_gate, selected_entry, publication_gate;
static atomic_int entries[19];
static atomic_int appender_end_rows, appender_end_row_errors, appender_flushes, metadata_changes;
static atomic_int selected_appender_end_row;
static atomic_bool close_failure, force_locked, indexed_failure, parquet_selection;
static atomic_int rollback_failure, parquet_second_exec;
static _Atomic(void *) parquet_first_prepared;
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
  atomic_store(&publication_entries_count, 0); atomic_store(&temporary_unlink_count, 0);
  atomic_store(&appender_end_rows, 0); atomic_store(&appender_end_row_errors, 0);
  atomic_store(&appender_flushes, 0); atomic_store(&metadata_changes, 0);
  atomic_store(&selected_appender_end_row, -1);
  for (int i = 0; i < 19; i++) { atomic_store(&gates[i], false); atomic_store(&entries[i], 0); }
  atomic_store(&selected_gate, false); atomic_store(&selected_entry, false);
  atomic_store(&publication_gate, false);
  atomic_store(&close_failure, false); atomic_store(&rollback_failure, 0);
  atomic_store(&interrupted[0], NULL); atomic_store(&interrupted[1], NULL);
  atomic_store(&initial_connections[0], NULL); atomic_store(&initial_connections[1], NULL);
  atomic_store(&indexed_failure, false); atomic_store(&parquet_selection, false);
  atomic_store(&parquet_second_exec, 0); atomic_store(&parquet_first_prepared, NULL);
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
COUNTER(parquet_second_exec, parquet_second_exec)
COUNTER(publication_entries, publication_entries_count)
COUNTER(temporary_unlinks, temporary_unlink_count)
COUNTER(appender_end_rows, appender_end_rows)
COUNTER(appender_end_row_errors, appender_end_row_errors)
COUNTER(appender_flushes, appender_flushes)
COUNTER(metadata_changes, metadata_changes)
CAMLprim value stage4c_select_parquet_first(value enabled) {
  atomic_store(&parquet_first_prepared, NULL); atomic_store(&parquet_second_exec, 0);
  atomic_store(&parquet_selection, Bool_val(enabled)); return Val_unit;
}
CAMLprim value stage4c_gate(value id, value enabled) { atomic_store(&gates[Int_val(id)], Bool_val(enabled)); return Val_unit; }
CAMLprim value stage4c_entered(value id) { return Val_int(atomic_load(&entries[Int_val(id)])); }
CAMLprim value stage4c_hold_selected(value enabled) { atomic_store(&selected_gate, Bool_val(enabled)); return Val_unit; }
CAMLprim value stage4c_hold_publication(value enabled) { atomic_store(&publication_gate, Bool_val(enabled)); return Val_unit; }
/* Test-only bounded selector: gate exactly one real end-row call. */
CAMLprim value stage4c_select_appender_end_row(value row) {
  atomic_store(&selected_appender_end_row, Int_val(row)); return Val_unit;
}
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
  atomic_fetch_add(&execution_calls, 1);
  if (atomic_load(&parquet_selection)) {
    void *expected = NULL;
    if (!atomic_compare_exchange_strong(&parquet_first_prepared, &expected, (void *)p))
      atomic_fetch_add(&parquet_second_exec, 1);
  }
  boundary(2);
  duckdb_state result = __real_duckdb_execute_prepared(p, r);
  if (result != DuckDBSuccess) atomic_fetch_add(&error_calls, 1);
  boundary(3); return result;
}
extern duckdb_state __real_duckdb_query(duckdb_connection, const char *, duckdb_result *);
duckdb_state __wrap_duckdb_query(duckdb_connection c, const char *sql, duckdb_result *r) {
  if (!strcmp(sql, "ROLLBACK")) boundary(4);
  if (!strncmp(sql, "ALTER TABLE", 11)) atomic_fetch_add(&metadata_changes, 1);
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
extern void __real_duckdb_destroy_prepare(duckdb_prepared_statement *p);
void __wrap_duckdb_destroy_prepare(duckdb_prepared_statement *p) {
  bool selected = atomic_load(&parquet_selection) && (void *)*p == atomic_load(&parquet_first_prepared);
  boundary(6); __real_duckdb_destroy_prepare(p);
  /* Selected first-file owner only; never block finish/finalizer cleanup. */
  if (selected && runtime_released && !finish_depth) boundary(16);
}
DESTROY(duckdb_destroy_extracted, 7, (duckdb_extracted_statements *e), (e))
DESTROY(duckdb_destroy_data_chunk, 8, (duckdb_data_chunk *c), (c))
DESTROY(duckdb_close, 12, (duckdb_database *db), (db))
extern duckdb_state __real_duckdb_appender_clear(duckdb_appender);
duckdb_state __wrap_duckdb_appender_clear(duckdb_appender a) { boundary(9); return __real_duckdb_appender_clear(a); }
extern duckdb_state __real_duckdb_appender_destroy(duckdb_appender *);
duckdb_state __wrap_duckdb_appender_destroy(duckdb_appender *a) { boundary(10); return __real_duckdb_appender_destroy(a); }
extern duckdb_state __real_duckdb_appender_end_row(duckdb_appender);
duckdb_state __wrap_duckdb_appender_end_row(duckdb_appender a) {
  int row = atomic_fetch_add(&appender_end_rows, 1) + 1;
  int selected = atomic_load(&selected_appender_end_row);
  if (selected < 0 || selected == row) boundary(17);
  duckdb_state result = __real_duckdb_appender_end_row(a);
  if (result != DuckDBSuccess) atomic_fetch_add(&appender_end_row_errors, 1);
  return result;
}
extern duckdb_state __real_duckdb_appender_flush(duckdb_appender);
duckdb_state __wrap_duckdb_appender_flush(duckdb_appender a) {
  atomic_fetch_add(&appender_flushes, 1); boundary(18); return __real_duckdb_appender_flush(a);
}
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
/* These wrap the public core file-operation externals.  Publication waits
   only after the real link has returned success, so the request is active while
   its own final already exists; cleanup counts actual core-owned unlinks. */
extern value __real_ml_duckdb_publish_local_file_admitted(value, value, value, value);
value __wrap_ml_duckdb_publish_local_file_admitted(value connection, value work, value source, value destination) {
  CAMLparam4(connection, work, source, destination);
  value result = __real_ml_duckdb_publish_local_file_admitted(connection, work, source, destination);
  if (Int_val(result) == 0 && atomic_load(&publication_gate)) {
    caml_enter_blocking_section(); atomic_fetch_add(&publication_entries_count, 1);
    wait_gate(&publication_gate); caml_leave_blocking_section();
  }
  CAMLreturn(result);
}
extern value __real_ml_duckdb_remove_local_file(value, value);
value __wrap_ml_duckdb_remove_local_file(value work, value source) {
  CAMLparam2(work, source);
  value result = __real_ml_duckdb_remove_local_file(work, source);
  if (Int_val(result) == 0) atomic_fetch_add(&temporary_unlink_count, 1);
  CAMLreturn(result);
}
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
