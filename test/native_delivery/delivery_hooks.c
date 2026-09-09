#define _POSIX_C_SOURCE 200809L
#include <duckdb.h>
#include <caml/mlvalues.h>
#include <caml/memory.h>
#include <caml/threads.h>
#include <caml/callback.h>
#include <caml/fail.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <string.h>
#include <time.h>
#include <stdio.h>
#include <stdlib.h>
#include <errno.h>
#include <unistd.h>
/* Independently releasable already-unlocked native boundaries, plus a normal-
   ABI selected pause. No test wait belongs to the noalloc interrupt chain. */
static _Atomic int gates[96], entries[96], counts[96];
static _Atomic bool selected_gate, selected_entered, fail_start;
static _Thread_local bool request_worker, controller_expected, drain_wait_armed;
static _Atomic bool drain_wait_entered, query_only;
static _Atomic int appender_auto_row, control_failure, unlink_failure;
static _Thread_local bool copy_work;
static _Atomic bool snapshot_exception;
static void wait_gate(_Atomic int *gate) {
  struct timespec start, now, delay = {0, 1000000};
  clock_gettime(CLOCK_MONOTONIC, &start);
  while (atomic_load(gate)) {
    clock_gettime(CLOCK_MONOTONIC, &now);
    if (now.tv_sec - start.tv_sec >= 20) {
      fputs("native delivery gate watchdog: process failure\n", stderr); abort();
    }
    nanosleep(&delay, NULL);
  }
}
static void boundary(int id) {
  if (atomic_load(&query_only) && !request_worker) return;
  if (!atomic_load(&gates[id])) return;
  atomic_fetch_add(&entries[id], 1); wait_gate(&gates[id]);
}
CAMLprim value delivery_gate(value id, value enabled) {
  atomic_store(&gates[Int_val(id)], Bool_val(enabled)); return Val_unit;
}
CAMLprim value delivery_entered(value id) { return Val_int(atomic_load(&entries[Int_val(id)])); }
CAMLprim value delivery_count(value id) { return Val_int(atomic_load(&counts[Int_val(id)])); }
CAMLprim value delivery_selected_gate(value enabled) {
  atomic_store(&selected_gate, Bool_val(enabled)); return Val_unit;
}
CAMLprim value delivery_selected_entered(value unit) { (void)unit; return Val_bool(atomic_load(&selected_entered)); }
CAMLprim value delivery_fail_start(value enabled) { atomic_store(&fail_start, Bool_val(enabled)); return Val_unit; }
/* Arm on the request worker immediately before its callback raises. TLS plus
   the installed-request marker excludes the controller, observer and foreign
   child. This one-shot observation adds no wait or runtime transition. */
CAMLprim value delivery_arm_drain_wait(value enabled) {
  drain_wait_armed = request_worker && Bool_val(enabled); return Val_unit;
}
CAMLprim value delivery_drain_wait_entered(value unit) {
  (void)unit; return Val_bool(atomic_load(&drain_wait_entered));
}
value real_condition_wait(value, value) __asm__("__real_caml_ml_condition_wait");
value wrapped_condition_wait(value, value) __asm__("__wrap_caml_ml_condition_wait");
value wrapped_condition_wait(value condition, value mutex) {
  if (request_worker && drain_wait_armed) {
    drain_wait_armed = false;
    atomic_store(&drain_wait_entered, true);
  }
  return real_condition_wait(condition, mutex);
}
CAMLprim value delivery_reset(value unit) {
  (void)unit;
  for (int i = 0; i < 96; ++i) { atomic_store(&gates[i], 0); atomic_store(&entries[i], 0); }
  for (int i = 0; i < 96; ++i) atomic_store(&counts[i], 0);
  atomic_store(&selected_gate, false); atomic_store(&selected_entered, false);
  atomic_store(&appender_auto_row, 0);
  atomic_store(&control_failure, 0); atomic_store(&unlink_failure, 0);
  atomic_store(&snapshot_exception, false); copy_work = false;
  atomic_store(&fail_start, false); atomic_store(&query_only, false);
  /* reset runs only between cases, after all workers have joined; the armed
     worker clears its own TLS in finally (and on successful uninstall). */
  atomic_store(&drain_wait_entered, false); drain_wait_armed = false;
  return Val_unit;
}
idx_t __real_duckdb_extract_statements(duckdb_connection, const char *, duckdb_extracted_statements *);
idx_t __wrap_duckdb_extract_statements(duckdb_connection c, const char *s, duckdb_extracted_statements *e) {
  atomic_fetch_add(&counts[0], 1); if (request_worker && copy_work) atomic_fetch_add(&counts[45], 1); boundary(1);
  idx_t result = __real_duckdb_extract_statements(c, s, e); boundary(2); return result;
}
duckdb_state __real_duckdb_prepare_extracted_statement(duckdb_connection, duckdb_extracted_statements, idx_t, duckdb_prepared_statement *);
duckdb_state __wrap_duckdb_prepare_extracted_statement(duckdb_connection c, duckdb_extracted_statements e, idx_t i, duckdb_prepared_statement *p) {
  atomic_fetch_add(&counts[1], 1); if (request_worker && copy_work) atomic_fetch_add(&counts[46], 1); boundary(3);
  duckdb_state result = __real_duckdb_prepare_extracted_statement(c, e, i, p); boundary(4); return result;
}
duckdb_state __real_duckdb_execute_prepared(duckdb_prepared_statement, duckdb_result *);
duckdb_state __wrap_duckdb_execute_prepared(duckdb_prepared_statement p, duckdb_result *r) {
  atomic_fetch_add(&counts[2], 1); if (request_worker && copy_work) { atomic_fetch_add(&counts[47], 1); boundary(81); } boundary(5);
  duckdb_state result = __real_duckdb_execute_prepared(p, r);
  if (result != DuckDBSuccess) atomic_fetch_add(&counts[3], 1);
  boundary(6); return result;
}
void __real_duckdb_interrupt(duckdb_connection);
void __wrap_duckdb_interrupt(duckdb_connection c) {
  atomic_fetch_add(&counts[4], 1); __real_duckdb_interrupt(c);
}
#define DESTROY(name, id, parameters, arguments) \
  void __real_##name parameters; \
  void __wrap_##name parameters { boundary(id); __real_##name arguments; }
DESTROY(duckdb_destroy_result, 7, (duckdb_result *r), (r))
DESTROY(duckdb_destroy_prepare, 8, (duckdb_prepared_statement *p), (p))
DESTROY(duckdb_destroy_extracted, 9, (duckdb_extracted_statements *e), (e))
void __real_duckdb_disconnect(duckdb_connection *);
void __wrap_duckdb_disconnect(duckdb_connection *c) {
  boundary(10); atomic_fetch_add(&counts[5], 1); __real_duckdb_disconnect(c);
}
duckdb_state __real_duckdb_query(duckdb_connection, const char *, duckdb_result *);
duckdb_state __wrap_duckdb_query(duckdb_connection c, const char *s, duckdb_result *r) {
  if (!strcmp(s, "BEGIN TRANSACTION")) atomic_fetch_add(&counts[6], 1);
  if (!strcmp(s, "COMMIT")) { atomic_fetch_add(&counts[7], 1); boundary(67); }
  if (!strcmp(s, "ROLLBACK")) { atomic_fetch_add(&counts[8], 1); boundary(11); }
  const char *actual = !strcmp(s, "ROLLBACK") && atomic_load(&control_failure) == 1 ? "invalid rollback injected" : s;
  duckdb_state result = __real_duckdb_query(c, actual, r);
  if (!strcmp(s, "BEGIN TRANSACTION")) boundary(66);
  if (!strcmp(s, "COMMIT")) boundary(68);
  return result;
}
/* Both wrapped entries have the normal allocating ABI. Root before release;
   the gate observes only C atomics, then actual production admission rechecks. */
value __real_ml_duckdb_native_request_create(value);
value __wrap_ml_duckdb_native_request_create(value unit) {
  CAMLparam1(unit);
  caml_enter_blocking_section(); boundary(12); caml_leave_blocking_section();
  CAMLreturn(__real_ml_duckdb_native_request_create(unit));
}
value __real_ml_duckdb_execute(value, value, value);
value __wrap_ml_duckdb_execute(value owner, value sql, value control) {
  CAMLparam3(owner, sql, control);
  if (!Bool_val(control)) {
    caml_enter_blocking_section(); boundary(13); caml_leave_blocking_section();
  }
  if (Bool_val(control)) {
    int point = !strcmp(String_val(sql), "BEGIN TRANSACTION") ? 64 : !strcmp(String_val(sql), "COMMIT") ? 65 : 0;
    caml_enter_blocking_section(); if (point) boundary(point); caml_leave_blocking_section();
  }
  CAMLreturn(__real_ml_duckdb_execute(owner, sql, control));
}
value __real_ml_duckdb_native_request_install(value, value);
value __wrap_ml_duckdb_native_request_install(value c, value r) {
  value result = __real_ml_duckdb_native_request_install(c, r);
  if (Int_val(result) == 0) {
    atomic_fetch_add(&counts[9], 1); request_worker = true; controller_expected = true;
  }
  return result;
}
value __real_caml_thread_new(value);
value __wrap_caml_thread_new(value closure) {
  CAMLparam1(closure);
  if (controller_expected) {
    controller_expected = false; atomic_fetch_add(&counts[10], 1);
    if (atomic_load(&fail_start)) caml_raise_constant(*caml_named_value("delivery_start_failure"));
  }
  CAMLreturn(__real_caml_thread_new(closure));
}
value __real_caml_thread_join(value);
value __wrap_caml_thread_join(value thread) {
  CAMLparam1(thread);
  bool controller = request_worker;
  if (controller) atomic_fetch_add(&counts[11], 1);
  value result = __real_caml_thread_join(thread);
  if (controller) atomic_fetch_add(&counts[12], 1);
  CAMLreturn(result);
}
value __real_ml_duckdb_native_request_uninstall(value);
value __wrap_ml_duckdb_native_request_uninstall(value r) {
  value result = __real_ml_duckdb_native_request_uninstall(r);
  if (Int_val(result) == 0) {
    atomic_fetch_add(&counts[13], 1);
    request_worker = false; controller_expected = false; drain_wait_armed = false; copy_work = false;
  }
  return result;
}
value __real_ml_duckdb_native_request_deliver(value);
value __wrap_ml_duckdb_native_request_deliver(value r) {
  CAMLparam1(r);
  atomic_fetch_add(&counts[14], 1);
  if (atomic_load(&selected_gate)) {
    caml_enter_blocking_section();
    atomic_store(&selected_entered, true);
    struct timespec start, now, delay = {0, 1000000};
    clock_gettime(CLOCK_MONOTONIC, &start);
    while (atomic_load(&selected_gate)) {
      clock_gettime(CLOCK_MONOTONIC, &now);
      if (now.tv_sec - start.tv_sec >= 20) abort();
      nanosleep(&delay, NULL);
    }
    caml_leave_blocking_section();
  }
  value result = __real_ml_duckdb_native_request_deliver(r);
  if (Int_val(result) == 0) atomic_fetch_add(&counts[15], 1);
  if (Int_val(result) == 1) atomic_fetch_add(&counts[16], 1);
  CAMLreturn(result);
}
value __real_ml_duckdb_native_request_retire_delivery(value);
value __wrap_ml_duckdb_native_request_retire_delivery(value r) {
  value result = __real_ml_duckdb_native_request_retire_delivery(r);
  atomic_fetch_add(&counts[17], 1); return result;
}

/* Query mode filters every held gate to the installed request worker. The old
   foreign-child drain test leaves this mode disabled. No representation reads. */
CAMLprim value delivery_query_mode(value unit) {
  (void)unit; atomic_store(&query_only, true); return Val_unit;
}
static void query_entry(int id) {
  if (atomic_load(&query_only) && request_worker) {
    caml_enter_blocking_section(); boundary(id); caml_leave_blocking_section();
  }
}
#define ENTRY1(name, id) \
 value __real_##name(value); \
 value __wrap_##name(value v) { CAMLparam1(v); query_entry(id); CAMLreturn(__real_##name(v)); }
#define ENTRY2(name, id) \
 value __real_##name(value, value); \
 value __wrap_##name(value v, value x) { CAMLparam2(v, x); query_entry(id); CAMLreturn(__real_##name(v, x)); }
#define ENTRY4(name, id) \
 value __real_##name(value, value, value, value); \
 value __wrap_##name(value v, value i, value t, value x) { CAMLparam4(v, i, t, x); query_entry(id); CAMLreturn(__real_##name(v, i, t, x)); }
value __real_ml_duckdb_prepare(value, value);
value __wrap_ml_duckdb_prepare(value v, value sql) {
  CAMLparam2(v, sql);
  if (request_worker) copy_work = !strncmp(String_val(sql), "COPY (", 6);
  if (copy_work) query_entry(77);
  query_entry(14);
  value result = __real_ml_duckdb_prepare(v, sql);
  query_entry(19); CAMLreturn(result);
}
ENTRY1(ml_duckdb_reset, 15)
ENTRY2(ml_duckdb_bind_null, 16)
ENTRY4(ml_duckdb_bind_int64, 16)
ENTRY4(ml_duckdb_bind_float, 16)
value __real_ml_duckdb_bind_string(value, value, value, value);
value __wrap_ml_duckdb_bind_string(value v, value i, value t, value x) {
  CAMLparam4(v, i, t, x); if (copy_work) query_entry(78); query_entry(16);
  CAMLreturn(__real_ml_duckdb_bind_string(v, i, t, x));
}
value __real_ml_duckdb_execute_prepared(value);
value __wrap_ml_duckdb_execute_prepared(value v) {
  CAMLparam1(v); if (copy_work) query_entry(80); query_entry(17);
  value result = __real_ml_duckdb_execute_prepared(v);
  if (request_worker && atomic_load(&snapshot_exception)) caml_raise_constant(*caml_named_value("control_snapshot_failure"));
  CAMLreturn(result);
}
ENTRY1(ml_duckdb_fetch, 18)
#define BIND(name, parameters, arguments) \
 duckdb_state __real_##name parameters; \
 duckdb_state __wrap_##name parameters { \
   atomic_fetch_add(&counts[20], 1); if (request_worker && copy_work) atomic_fetch_add(&counts[48], 1); boundary(21); \
   duckdb_state result = __real_##name arguments; boundary(22); return result; }
BIND(duckdb_bind_null, (duckdb_prepared_statement p, idx_t i), (p, i))
BIND(duckdb_bind_int64, (duckdb_prepared_statement p, idx_t i, int64_t x), (p, i, x))
BIND(duckdb_bind_double, (duckdb_prepared_statement p, idx_t i, double x), (p, i, x))
BIND(duckdb_bind_varchar_length, (duckdb_prepared_statement p, idx_t i, const char *x, idx_t n), (p, i, x, n))
duckdb_state __real_duckdb_clear_bindings(duckdb_prepared_statement);
duckdb_state __wrap_duckdb_clear_bindings(duckdb_prepared_statement p) {
  atomic_fetch_add(&counts[21], 1); boundary(23);
  duckdb_state result = __real_duckdb_clear_bindings(p); boundary(24); return result;
}
duckdb_value __real_duckdb_create_timestamp_s(duckdb_timestamp_s);
duckdb_value __wrap_duckdb_create_timestamp_s(duckdb_timestamp_s x) {
  atomic_fetch_add(&counts[22], 1); boundary(25);
  duckdb_value result = __real_duckdb_create_timestamp_s(x); boundary(26); return result;
}
duckdb_state __real_duckdb_bind_value(duckdb_prepared_statement, idx_t, duckdb_value);
duckdb_state __wrap_duckdb_bind_value(duckdb_prepared_statement p, idx_t i, duckdb_value v) {
  atomic_fetch_add(&counts[23], 1); boundary(27);
  duckdb_state result = __real_duckdb_bind_value(p, i, v); boundary(28); return result;
}
void __real_duckdb_destroy_value(duckdb_value *);
void __wrap_duckdb_destroy_value(duckdb_value *v) {
  atomic_fetch_add(&counts[26], 1); boundary(29); __real_duckdb_destroy_value(v);
}
duckdb_data_chunk __real_duckdb_fetch_chunk(duckdb_result);
duckdb_data_chunk __wrap_duckdb_fetch_chunk(duckdb_result r) {
  int fetch = atomic_fetch_add(&counts[24], 1) + 1; boundary(30);
  duckdb_data_chunk chunk = __real_duckdb_fetch_chunk(r);
  if (fetch == 2) boundary(63);
  boundary(31); return chunk;
}
void __real_duckdb_destroy_data_chunk(duckdb_data_chunk *);
void __wrap_duckdb_destroy_data_chunk(duckdb_data_chunk *c) {
  atomic_fetch_add(&counts[25], 1); boundary(32); __real_duckdb_destroy_data_chunk(c);
}

/* Appender gates share the existing request-worker filter and reservation hook.
   Normal ABI entry gates root ML arguments; engine gates are already unlocked. */
value __real_ml_duckdb_create_appender(value, value, value);
value __wrap_ml_duckdb_create_appender(value v, value schema, value table) {
  CAMLparam3(v, schema, table); query_entry(33);
  value result = __real_ml_duckdb_create_appender(v, schema, table);
  query_entry(34); CAMLreturn(result);
}
ENTRY2(ml_duckdb_append_rows, 35)
ENTRY1(ml_duckdb_flush_appender, 36)
ENTRY2(ml_duckdb_close_appender, 37)
duckdb_state __real_duckdb_prepare(duckdb_connection, const char *, duckdb_prepared_statement *);
duckdb_state __wrap_duckdb_prepare(duckdb_connection c, const char *sql, duckdb_prepared_statement *p) {
  atomic_fetch_add(&counts[27], 1); return __real_duckdb_prepare(c, sql, p);
}
duckdb_state __real_duckdb_bind_varchar(duckdb_prepared_statement, idx_t, const char *);
duckdb_state __wrap_duckdb_bind_varchar(duckdb_prepared_statement p, idx_t i, const char *s) {
  atomic_fetch_add(&counts[37], 1); boundary(40);
  duckdb_state result = __real_duckdb_bind_varchar(p, i, s); boundary(41); return result;
}
duckdb_state __real_duckdb_appender_create_ext(duckdb_connection, const char *, const char *, const char *, duckdb_appender *);
duckdb_state __wrap_duckdb_appender_create_ext(duckdb_connection c, const char *catalog, const char *schema, const char *table, duckdb_appender *a) {
  atomic_fetch_add(&counts[28], 1); boundary(38);
  duckdb_state result = __real_duckdb_appender_create_ext(c, catalog, schema, table, a); boundary(39); return result;
}
#define APPENDER(name, counter, before, after, parameters, arguments) \
 duckdb_state __real_##name parameters; \
 duckdb_state __wrap_##name parameters { \
   atomic_fetch_add(&counts[counter], 1); boundary(before); \
   duckdb_state result = __real_##name arguments; boundary(after); return result; }
APPENDER(duckdb_appender_begin_row, 29, 42, 43, (duckdb_appender a), (a))
APPENDER(duckdb_append_value, 30, 46, 47, (duckdb_appender a, duckdb_value v), (a, v))
CAMLprim value delivery_appender_auto_gate(value row) {
  atomic_store(&appender_auto_row, Int_val(row)); return Val_unit;
}
duckdb_state __real_duckdb_appender_end_row(duckdb_appender);
duckdb_state __wrap_duckdb_appender_end_row(duckdb_appender a) {
  int row = atomic_fetch_add(&counts[31], 1) + 1;
  boundary(44);
  if (row == atomic_load(&appender_auto_row)) boundary(59);
  duckdb_state result = __real_duckdb_appender_end_row(a);
  if (result != DuckDBSuccess) { atomic_fetch_add(&counts[39], 1); boundary(60); }
  if (row == atomic_load(&appender_auto_row)) boundary(61);
  boundary(45); return result;
}
APPENDER(duckdb_appender_flush, 32, 53, 54, (duckdb_appender a), (a))
APPENDER(duckdb_appender_close, 33, 55, 56, (duckdb_appender a), (a))
duckdb_state __real_duckdb_appender_clear(duckdb_appender);
duckdb_state __wrap_duckdb_appender_clear(duckdb_appender a) {
  atomic_fetch_add(&counts[34], 1);
  /* Capture the causal ordering, even if a non-selected controller joins and
     the worker reaches destruction before the observer is scheduled again. */
  atomic_store(&counts[40], atomic_load(&counts[12]));
  boundary(48);
  duckdb_state result = __real_duckdb_appender_clear(a); boundary(57); return result;
}
APPENDER(duckdb_appender_destroy, 35, 49, 58, (duckdb_appender *a), (a))
idx_t __real_duckdb_appender_column_count(duckdb_appender);
idx_t __wrap_duckdb_appender_column_count(duckdb_appender a) {
  atomic_fetch_add(&counts[36], 1); boundary(52); return __real_duckdb_appender_column_count(a);
}
DESTROY(duckdb_destroy_error_data, 50, (duckdb_error_data *d), (d))
DESTROY(duckdb_destroy_logical_type, 51, (duckdb_logical_type *t), (t))

value __real_ml_duckdb_appender_nullable(value);
value __wrap_ml_duckdb_appender_nullable(value v) {
  CAMLparam1(v); CAMLlocal1(result);
  result = __real_ml_duckdb_appender_nullable(v); query_entry(62); CAMLreturn(result);
}

/* File gates are actual worker-owned unlocked calls. No DuckDB interrupt can
   cancel these syscalls; before-entry ABI wrappers distinguish admission. */
value __real_ml_duckdb_publish_local_file(value, value, value);
value __wrap_ml_duckdb_publish_local_file(value work, value source, value destination) {
  CAMLparam3(work, source, destination);
  query_entry(70);
  CAMLreturn(__real_ml_duckdb_publish_local_file(work, source, destination));
}
int __real_link(const char *, const char *);
int __wrap_link(const char *source, const char *destination) {
  if (request_worker) atomic_fetch_add(&counts[41], 1);
  boundary(71);
  int result = __real_link(source, destination); int saved_errno = errno;
  boundary(72); errno = saved_errno; return result;
}
int __real_unlink(const char *);
int __wrap_unlink(const char *source) {
  if (request_worker) { atomic_fetch_add(&counts[42], 1); atomic_store(&counts[49], atomic_load(&counts[12])); }
  boundary(73);
  if (request_worker && atomic_load(&unlink_failure)) { errno = EACCES; return -1; }
  return __real_unlink(source);
}
value __real_ml_duckdb_execute_control(value, value);
value __wrap_ml_duckdb_execute_control(value owner, value statement) {
  CAMLparam2(owner, statement);
  if (Int_val(statement) < 2) query_entry(Int_val(statement) == 0 ? 64 : 65);
  if (Int_val(statement) == 2 && atomic_load(&control_failure) == 2) caml_raise_constant(*caml_named_value("control_rollback_failure"));
  value result = __real_ml_duckdb_execute_control(owner, statement);
  if (Int_val(statement) == 1 && atomic_load(&control_failure) == 3) caml_raise_constant(*caml_named_value("control_commit_return_failure"));
  CAMLreturn(result);
}
value __real_ml_duckdb_publish_local_file_admitted(value, value, value, value);
value __wrap_ml_duckdb_publish_local_file_admitted(value owner, value work, value source, value destination) {
  CAMLparam4(owner, work, source, destination);
  query_entry(70);
  CAMLreturn(__real_ml_duckdb_publish_local_file_admitted(owner, work, source, destination));
}

CAMLprim value delivery_control_failure(value mode) { atomic_store(&control_failure, Int_val(mode)); return Val_unit; }
CAMLprim value delivery_unlink_failure(value enabled) { atomic_store(&unlink_failure, Bool_val(enabled)); return Val_unit; }
value __real_ml_duckdb_admit_local_file(value);
value __wrap_ml_duckdb_admit_local_file(value owner) {
  CAMLparam1(owner); query_entry(74);
  value result = __real_ml_duckdb_admit_local_file(owner);
  if (Int_val(result) == 0) atomic_fetch_add(&counts[43], 1);
  query_entry(75); CAMLreturn(result);
}
value __real_caml_sys_open(value, value, value);
value __wrap_caml_sys_open(value path, value flags, value permissions) {
  CAMLparam3(path, flags, permissions);
  bool temporary = request_worker && strstr(String_val(path), "/.duckdb-parquet-") != NULL;
  value result = __real_caml_sys_open(path, flags, permissions);
  if (temporary) { atomic_fetch_add(&counts[44], 1); query_entry(76); }
  CAMLreturn(result);
}

CAMLprim value delivery_snapshot_exception(value enabled) { atomic_store(&snapshot_exception, Bool_val(enabled)); return Val_unit; }
/* Count-only noalloc observer: no roots, allocation, wait or runtime transition.
   The completion count follows the real reserve decision, not unrelated work. */
value __real_ml_duckdb_native_request_reserve_delivery(value);
value __wrap_ml_duckdb_native_request_reserve_delivery(value request) {
  value result = __real_ml_duckdb_native_request_reserve_delivery(request);
  if (Int_val(result) == 0) atomic_fetch_add(&counts[51], 1);
  atomic_fetch_add(&counts[50], 1);
  return result;
}
