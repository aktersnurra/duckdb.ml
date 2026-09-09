/* _POSIX_C_SOURCE and __wrap_/__real_ retain the narrow POSIX/GNU ABI
   exception. Test-executable-only observers, no production lifecycle hooks. */
#define _POSIX_C_SOURCE 200809L
#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <time.h>
#include <errno.h>
#include <unistd.h>
#include <duckdb.h>
#include <caml/mlvalues.h>
#include <caml/memory.h>
#include <caml/threads.h>

/* Selection strings are copied with the runtime held and only replaced after
   request settlement. No managed heap or freed native owner is inspected while
   released. Prepared/result identities are captured before destruction. */
static char first_path[4096], second_path[4096], final_path[4096];
static atomic_int selected_kind, counts[13];
static atomic_bool holding, unlink_failure;
static _Atomic(uintptr_t) first_prepared, second_prepared, copy_prepared, first_result, copy_result;
static _Thread_local bool released, operation_worker, first_fetch;
static void wait_at(int kind, bool matches) {
  if (!matches || !released || atomic_load(&selected_kind) != kind || !atomic_load(&holding)) return;
  atomic_fetch_add(&counts[0], 1);
  struct timespec start, now, delay = {0, 1000000};
  clock_gettime(CLOCK_MONOTONIC, &start);
  while (atomic_load(&holding)) {
    clock_gettime(CLOCK_MONOTONIC, &now);
    if (now.tv_sec - start.tv_sec > 15) { fputs("Parquet gate watchdog (not evidence)\n", stderr); abort(); }
    nanosleep(&delay, NULL);
  }
}
CAMLprim value eio_parquet_select(value kind, value first, value second, value destination) {
  snprintf(first_path, sizeof first_path, "%s", String_val(first));
  snprintf(second_path, sizeof second_path, "%s", String_val(second));
  snprintf(final_path, sizeof final_path, "%s", String_val(destination));
  for (int i = 0; i < 13; ++i) if (i != 10) atomic_store(&counts[i], 0);
  atomic_store(&first_prepared, 0); atomic_store(&second_prepared, 0); atomic_store(&copy_prepared, 0);
  atomic_store(&first_result, 0); atomic_store(&copy_result, 0);
  atomic_store(&selected_kind, Int_val(kind)); atomic_store(&holding, true); return Val_unit;
}
CAMLprim value eio_parquet_release(value unit) { (void)unit; atomic_store(&holding, false); return Val_unit; }
CAMLprim value eio_parquet_counter(value index) { int i = Int_val(index); return Val_int(i >= 0 && i < 13 ? atomic_load(&counts[i]) : -1); }
CAMLprim value eio_parquet_worker_entry(value unit) { (void)unit; operation_worker = true; return Val_unit; }
CAMLprim value eio_parquet_fail_unlink(value enabled) { atomic_store(&unlink_failure, Bool_val(enabled)); return Val_unit; }
extern void __real_caml_enter_blocking_section(void);
void __wrap_caml_enter_blocking_section(void) { __real_caml_enter_blocking_section(); released = true; }
extern void __real_caml_leave_blocking_section(void);
void __wrap_caml_leave_blocking_section(void) { released = false; __real_caml_leave_blocking_section(); }
extern value __real_caml_sys_getcwd(value);
value __wrap_caml_sys_getcwd(value unit) {
  atomic_fetch_add(&counts[operation_worker ? 11 : 12], 1);
  return __real_caml_sys_getcwd(unit);
}
static _Thread_local duckdb_extracted_statements selected_extracted;
static _Thread_local bool extracted_first, extracted_second, extracted_copy;
extern idx_t __real_duckdb_extract_statements(duckdb_connection, const char *, duckdb_extracted_statements *);
idx_t __wrap_duckdb_extract_statements(duckdb_connection c, const char *sql, duckdb_extracted_statements *e) {
  extracted_first = first_path[0] && strstr(sql, "read_parquet(") && strstr(sql, first_path);
  extracted_second = second_path[0] && strstr(sql, "read_parquet(") && strstr(sql, second_path);
  extracted_copy = strncmp(sql, "COPY (", 6) == 0;
  idx_t count = __real_duckdb_extract_statements(c, sql, e);
  selected_extracted = *e;
  return count;
}
extern duckdb_state __real_duckdb_prepare_extracted_statement(duckdb_connection, duckdb_extracted_statements, idx_t, duckdb_prepared_statement *);
duckdb_state __wrap_duckdb_prepare_extracted_statement(duckdb_connection c, duckdb_extracted_statements e, idx_t index, duckdb_prepared_statement *p) {
  bool first = e == selected_extracted && extracted_first;
  bool second = e == selected_extracted && extracted_second;
  if (second) atomic_fetch_add(&counts[1], 1);
  duckdb_state state = __real_duckdb_prepare_extracted_statement(c, e, index, p);
  if (state == DuckDBSuccess) {
    /* The core prepares a second, short-lived parameter-schema validator.
       Keep the original statement, never its validator's destruction. */
    uintptr_t empty = 0;
    if (first) atomic_compare_exchange_strong(&first_prepared, &empty, (uintptr_t)*p);
    empty = 0;
    if (second) atomic_compare_exchange_strong(&second_prepared, &empty, (uintptr_t)*p);
    empty = 0;
    if (e == selected_extracted && extracted_copy) atomic_compare_exchange_strong(&copy_prepared, &empty, (uintptr_t)*p);
  }
  return state;
}
extern duckdb_state __real_duckdb_execute_prepared(duckdb_prepared_statement, duckdb_result *);
duckdb_state __wrap_duckdb_execute_prepared(duckdb_prepared_statement p, duckdb_result *r) {
  bool first = (uintptr_t)p == atomic_load(&first_prepared);
  bool copy = (uintptr_t)p == atomic_load(&copy_prepared);
  if ((uintptr_t)p == atomic_load(&second_prepared)) atomic_fetch_add(&counts[2], 1);
  wait_at(9, first); wait_at(3, copy);
  duckdb_state state = __real_duckdb_execute_prepared(p, r);
  if (first) atomic_store(&first_result, (uintptr_t)r->internal_data);
  if (copy) { atomic_store(&copy_result, (uintptr_t)r->internal_data); atomic_fetch_add(&counts[6], 1); }
  wait_at(4, copy); return state;
}
extern duckdb_data_chunk __real_duckdb_fetch_chunk(duckdb_result);
duckdb_data_chunk __wrap_duckdb_fetch_chunk(duckdb_result r) {
  first_fetch = (uintptr_t)r.internal_data == atomic_load(&first_result);
  wait_at(10, first_fetch);
  return __real_duckdb_fetch_chunk(r);
}
extern void __real_duckdb_destroy_data_chunk(duckdb_data_chunk *);
void __wrap_duckdb_destroy_data_chunk(duckdb_data_chunk *c) {
  bool selected = first_fetch && *c;
  __real_duckdb_destroy_data_chunk(c);
  if (selected) atomic_fetch_add(&counts[5], 1);
}
extern void __real_duckdb_destroy_result(duckdb_result *);
void __wrap_duckdb_destroy_result(duckdb_result *r) {
  bool first = r->internal_data && (uintptr_t)r->internal_data == atomic_load(&first_result);
  bool copy = r->internal_data && (uintptr_t)r->internal_data == atomic_load(&copy_result);
  __real_duckdb_destroy_result(r);
  if (first) { atomic_fetch_add(&counts[3], 1); atomic_store(&first_result, 0); first_fetch = false; }
  if (copy) atomic_store(&copy_result, 0);
  wait_at(11, first); wait_at(8, copy);
}
extern void __real_duckdb_destroy_prepare(duckdb_prepared_statement *);
void __wrap_duckdb_destroy_prepare(duckdb_prepared_statement *p) {
  bool first = *p && (uintptr_t)*p == atomic_load(&first_prepared);
  bool second = *p && (uintptr_t)*p == atomic_load(&second_prepared);
  bool copy = *p && (uintptr_t)*p == atomic_load(&copy_prepared);
  __real_duckdb_destroy_prepare(p);
  if (first) { atomic_fetch_add(&counts[4], 1); atomic_store(&first_prepared, 0); }
  if (second) atomic_store(&second_prepared, 0);
  if (copy) atomic_store(&copy_prepared, 0);
  wait_at(1, first);
}
extern void __real_duckdb_disconnect(duckdb_connection *);
void __wrap_duckdb_disconnect(duckdb_connection *c) { __real_duckdb_disconnect(c); atomic_fetch_add(&counts[10], 1); }
/* This normal ABI external is held BEFORE the actual admission decision.
   It is not the noalloc/finish chain and holds no native request mutex. */
extern value __real_ml_duckdb_admit_local_file(value);
value __wrap_ml_duckdb_admit_local_file(value connection) {
  CAMLparam1(connection);
  caml_enter_blocking_section(); wait_at(2, final_path[0] != 0); caml_leave_blocking_section();
  value result = __real_ml_duckdb_admit_local_file(connection); CAMLreturn(result);
}
extern int __real_link(const char *, const char *);
int __wrap_link(const char *source, const char *destination) {
  bool selected = final_path[0] && strcmp(destination, final_path) == 0;
  wait_at(5, selected);
  int result = __real_link(source, destination);
  if (selected && result == 0) { atomic_fetch_add(&counts[7], 1); wait_at(6, true); }
  return result;
}
extern int __real_unlink(const char *);
int __wrap_unlink(const char *path) {
  /* Exact fixture directory plus the core's reserved basename: unrelated
     unlinks cannot acknowledge the held cleanup gate. */
  const char *slash = strrchr(final_path, '/');
  bool owned = slash && strncmp(path, final_path, (size_t)(slash - final_path + 1)) == 0 &&
    strncmp(path + (slash - final_path + 1), ".duckdb-parquet-", 16) == 0;
  wait_at(7, owned);
  if (owned && atomic_load(&unlink_failure)) { errno = EACCES; return -1; }
  int result = __real_unlink(path);
  if (owned && result == 0) atomic_fetch_add(&counts[8], 1);
  return result;
}
