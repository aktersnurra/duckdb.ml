/* _POSIX_C_SOURCE is the POSIX feature-test protocol; __wrap_/__real_ are
   GNU ld --wrap ABI names, not authored safe-API identifiers. Validated with
   cc -std=c11 -Wall -Wextra -Werror -fsyntax-only and the linked native test. */
#define _POSIX_C_SOURCE 200809L
#include <stdatomic.h>
#include <stdbool.h>
#include <time.h>
#include <stdlib.h>
#include <stdio.h>
#include <assert.h>
#include <stdint.h>
#include <string.h>
#include <duckdb.h>
#include <caml/mlvalues.h>
#include <caml/memory.h>
#include <caml/threads.h>
#include <caml/callback.h>
#include <caml/fail.h>

/* Finite executable-only observers. No pointers leave C; monotone connection
   serials avoid allocator address reuse. Gates only wait outside the runtime
   lock, at actual native entry, never inside a finish/noalloc/guard path. */
static atomic_int connects, disconnects, closes, executions, interrupts, locked_entries, native_errors;
static atomic_int fail_connect, fail_slot_close, fail_db_close, entered, close_entered;
static atomic_int result_destroys, prepared_destroys, appender_destroys, chunk_destroys, rollbacks, selected_disconnects, foreign_returns, replacement_returns, between_entries;
static atomic_bool held, close_held, hold_result_destroy, hold_prepared_destroy, hold_appender_destroy, hold_chunk_destroy, hold_rollback, hold_disconnect, hold_foreign_return, hold_replacement_return, hold_between;
static atomic_bool select_result, select_chunk, select_disconnect;
static _Atomic(uintptr_t) selected_result, selected_chunk;
static atomic_int open_entered, connect_entered, opens;
static atomic_bool open_held, connect_held;
static atomic_int held_entries[21];
static void gate(atomic_bool *holding, atomic_int *entries, int kind);
static _Thread_local bool released;
static _Thread_local unsigned disconnect_serial, database_serial;
CAMLprim value eio_foundation_reset(value fail_at) {
  for (int i = 0; i < 21; ++i) atomic_store(&held_entries[i], 0);
  atomic_store(&opens, 0); atomic_store(&open_entered, 0); atomic_store(&connect_entered, 0);
  atomic_store(&open_held, false); atomic_store(&connect_held, false);
  atomic_store(&connects, 0); atomic_store(&disconnects, 0);
  atomic_store(&closes, 0); atomic_store(&executions, 0);
  atomic_store(&interrupts, 0); atomic_store(&locked_entries, 0); atomic_store(&native_errors, 0);
  atomic_store(&fail_connect, Int_val(fail_at));
  atomic_store(&fail_slot_close, 0); atomic_store(&fail_db_close, 0);
  atomic_store(&entered, 0); atomic_store(&held, false);
  atomic_store(&close_entered, 0); atomic_store(&close_held, false);
  atomic_store(&result_destroys, 0); atomic_store(&prepared_destroys, 0); atomic_store(&appender_destroys, 0);
  atomic_store(&chunk_destroys, 0); atomic_store(&rollbacks, 0); atomic_store(&selected_disconnects, 0);
  atomic_store(&foreign_returns, 0); atomic_store(&replacement_returns, 0); atomic_store(&between_entries, 0);
  atomic_store(&hold_result_destroy, false); atomic_store(&hold_prepared_destroy, false); atomic_store(&hold_appender_destroy, false);
  atomic_store(&hold_chunk_destroy, false); atomic_store(&hold_rollback, false); atomic_store(&hold_disconnect, false);
  atomic_store(&hold_foreign_return, false); atomic_store(&hold_replacement_return, false); atomic_store(&hold_between, false);
  atomic_store(&select_result, false); atomic_store(&select_chunk, false); atomic_store(&select_disconnect, false);
  atomic_store(&selected_result, 0); atomic_store(&selected_chunk, 0);
  return Val_unit;
}
/* Separate from total destructor counts: published only by a selected,
   enabled gate AFTER runtime-release verification. */
CAMLprim value eio_foundation_held_entry(value kind) {
  int k = Int_val(kind);
  assert(k >= 0 && k < 21);
  return Val_int(atomic_load(&held_entries[k]));
}
CAMLprim value eio_foundation_counter(value which) {
  switch (Int_val(which)) {
    case 0: return Val_int(atomic_load(&connects));
    case 1: return Val_int(atomic_load(&disconnects));
    case 2: return Val_int(atomic_load(&closes));
    case 3: return Val_int(atomic_load(&executions));
    case 4: return Val_int(atomic_load(&interrupts));
    case 5: return Val_int(atomic_load(&entered));
    case 7: return Val_int(atomic_load(&native_errors));
    case 8: return Val_int(atomic_load(&close_entered));
    case 9: return Val_int(atomic_load(&result_destroys));
    case 10: return Val_int(atomic_load(&prepared_destroys));
    case 11: return Val_int(atomic_load(&appender_destroys));
    case 12: return Val_int(atomic_load(&open_entered));
    case 13: return Val_int(atomic_load(&connect_entered));
    case 14: return Val_int(atomic_load(&opens));
    case 15: return Val_int(atomic_load(&chunk_destroys));
    case 16: return Val_int(atomic_load(&rollbacks));
    case 17: return Val_int(atomic_load(&selected_disconnects));
    case 18: return Val_int(atomic_load(&foreign_returns));
    case 19: return Val_int(atomic_load(&replacement_returns));
    case 20: return Val_int(atomic_load(&between_entries));
    default: return Val_int(atomic_load(&locked_entries));
  }
}
CAMLprim value eio_foundation_hold_init(value kind, value enable) {
  atomic_store(Int_val(kind) == 12 ? &open_held : &connect_held, Bool_val(enable));
  return Val_unit;
}
CAMLprim value eio_foundation_hold(value enable) {
  atomic_store(&held, Bool_val(enable)); return Val_unit;
}
CAMLprim value eio_foundation_hold_database(value enable) {
  atomic_store(&close_held, Bool_val(enable)); return Val_unit;
}
CAMLprim value eio_foundation_fail_close(value slots, value database) {
  atomic_store(&fail_slot_close, Int_val(slots));
  atomic_store(&fail_db_close, Int_val(database)); return Val_unit;
}
CAMLprim value eio_foundation_hold_cleanup(value kind, value enable) {
  int selected = Int_val(kind);
  atomic_bool *gate = selected == 9 ? &hold_result_destroy : selected == 10 ? &hold_prepared_destroy :
                      selected == 11 ? &hold_appender_destroy : selected == 15 ? &hold_chunk_destroy :
                      selected == 16 ? &hold_rollback : selected == 17 ? &hold_disconnect :
                      selected == 18 ? &hold_foreign_return : selected == 19 ? &hold_replacement_return : &hold_between;
  if (selected == 9) atomic_store(&select_result, Bool_val(enable));
  if (selected == 15) atomic_store(&select_chunk, Bool_val(enable));
  if (selected == 17) atomic_store(&select_disconnect, Bool_val(enable));
  atomic_store(gate, Bool_val(enable)); return Val_unit;
}
CAMLprim value eio_foundation_hold_between(value enable) {
  atomic_store(&hold_between, Bool_val(enable)); return Val_unit;
}
CAMLprim value eio_foundation_wait_between(value unit) {
  CAMLparam1(unit);
  caml_enter_blocking_section();
  gate(&hold_between, &between_entries, 20);
  caml_leave_blocking_section();
  CAMLreturn(Val_unit);
}
extern void real_caml_enter_blocking_section(void) __asm__("__real_caml_enter_blocking_section");
void wrap_caml_enter_blocking_section(void) __asm__("__wrap_caml_enter_blocking_section");
void wrap_caml_enter_blocking_section(void) {
  real_caml_enter_blocking_section(); released = true;
}
extern void real_caml_leave_blocking_section(void) __asm__("__real_caml_leave_blocking_section");
void wrap_caml_leave_blocking_section(void) __asm__("__wrap_caml_leave_blocking_section");
void wrap_caml_leave_blocking_section(void) {
  released = false; real_caml_leave_blocking_section();
}
extern duckdb_state __real_duckdb_open_ext(const char *, duckdb_database *, duckdb_config, char **);
duckdb_state __wrap_duckdb_open_ext(const char *path, duckdb_database *db, duckdb_config config, char **error) {
  atomic_fetch_add(&opens, 1); gate(&open_held, &open_entered, 12);
  return __real_duckdb_open_ext(path, db, config, error);
}
extern duckdb_state __real_duckdb_connect(duckdb_database, duckdb_connection *);
duckdb_state __wrap_duckdb_connect(duckdb_database db, duckdb_connection *c) {
  int n = atomic_fetch_add(&connects, 1);
  gate(&connect_held, &connect_entered, 13);
  if (n == atomic_load(&fail_connect)) return DuckDBError;
  duckdb_state result = __real_duckdb_connect(db, c);
  if (result == DuckDBSuccess && n > 0) gate(&hold_replacement_return, &replacement_returns, 19);
  return result;
}
extern void __real_duckdb_disconnect(duckdb_connection *);
void __wrap_duckdb_disconnect(duckdb_connection *c) {
  atomic_fetch_add(&disconnects, 1); ++disconnect_serial;
  if (atomic_load(&select_disconnect)) {
    atomic_fetch_add(&selected_disconnects, 1); gate(&hold_disconnect, NULL, 17);
  }
  __real_duckdb_disconnect(c);
}
static void gate(atomic_bool *holding, atomic_int *entries, int kind) {
  if (!released) atomic_fetch_add(&locked_entries, 1);
  if (atomic_load(holding)) {
    if (released) {
      if (entries) atomic_fetch_add(entries, 1);
      atomic_fetch_add(&held_entries[kind], 1);
      struct timespec start, now, delay = {0, 1000000};
      clock_gettime(CLOCK_MONOTONIC, &start);
      while (atomic_load(holding)) {
        clock_gettime(CLOCK_MONOTONIC, &now);
        if (now.tv_sec - start.tv_sec > 15) {
          fputs("foundation gate watchdog (not a passing oracle)\n", stderr); abort();
        }
        nanosleep(&delay, NULL);
      }
    }
  }
}
extern void __real_duckdb_close(duckdb_database *);
void __wrap_duckdb_close(duckdb_database *db) {
  atomic_fetch_add(&closes, 1); ++database_serial;
  gate(&close_held, &close_entered, 8); __real_duckdb_close(db);
}
extern duckdb_state __real_duckdb_execute_prepared(duckdb_prepared_statement, duckdb_result *);
duckdb_state __wrap_duckdb_execute_prepared(duckdb_prepared_statement p, duckdb_result *r) {
  atomic_fetch_add(&executions, 1); gate(&held, &entered, 5);
  duckdb_state result = __real_duckdb_execute_prepared(p, r);
  if (atomic_load(&select_result)) atomic_store(&selected_result, (uintptr_t)r);
  if (result == DuckDBSuccess) gate(&hold_foreign_return, &foreign_returns, 18);
  if (result != DuckDBSuccess) atomic_fetch_add(&native_errors, 1);
  return result;
}
extern void __real_duckdb_interrupt(duckdb_connection);
void __wrap_duckdb_interrupt(duckdb_connection c) {
  atomic_fetch_add(&interrupts, 1); __real_duckdb_interrupt(c);
}
extern void __real_duckdb_destroy_result(duckdb_result *);
void __wrap_duckdb_destroy_result(duckdb_result *r) {
  atomic_fetch_add(&result_destroys, 1);
  uintptr_t selected = atomic_load(&selected_result);
  if (selected && (uintptr_t)r == selected) gate(&hold_result_destroy, NULL, 9);
  __real_duckdb_destroy_result(r);
}
extern void __real_duckdb_destroy_data_chunk(duckdb_data_chunk *);
void __wrap_duckdb_destroy_data_chunk(duckdb_data_chunk *chunk) {
  atomic_fetch_add(&chunk_destroys, 1);
  uintptr_t selected = atomic_load(&selected_chunk);
  if (selected && (uintptr_t)*chunk == selected) gate(&hold_chunk_destroy, NULL, 15);
  __real_duckdb_destroy_data_chunk(chunk);
}
extern duckdb_data_chunk __real_duckdb_fetch_chunk(duckdb_result);
duckdb_data_chunk __wrap_duckdb_fetch_chunk(duckdb_result result) {
  duckdb_data_chunk chunk = __real_duckdb_fetch_chunk(result);
  if (atomic_load(&select_chunk) && chunk) atomic_store(&selected_chunk, (uintptr_t)chunk);
  return chunk;
}
extern duckdb_state __real_duckdb_query(duckdb_connection, const char *, duckdb_result *);
duckdb_state __wrap_duckdb_query(duckdb_connection c, const char *sql, duckdb_result *r) {
  if (strcmp(sql, "ROLLBACK") == 0) { atomic_fetch_add(&rollbacks, 1); gate(&hold_rollback, NULL, 16); }
  return __real_duckdb_query(c, sql, r);
}
extern void __real_duckdb_destroy_prepare(duckdb_prepared_statement *p);
void __wrap_duckdb_destroy_prepare(duckdb_prepared_statement *p) {
  atomic_fetch_add(&prepared_destroys, 1); gate(&hold_prepared_destroy, NULL, 10);
  __real_duckdb_destroy_prepare(p);
}
extern duckdb_state __real_duckdb_appender_destroy(duckdb_appender *);
duckdb_state __wrap_duckdb_appender_destroy(duckdb_appender *a) {
  atomic_fetch_add(&appender_destroys, 1); gate(&hold_appender_destroy, NULL, 11);
  return __real_duckdb_appender_destroy(a);
}
/* Raise only at ordinary allocating ABI, after the actual destructor returned
   and reacquired the runtime. Core finalization/guard discipline is untouched. */
extern value __real_ml_duckdb_close_connection(value);
value __wrap_ml_duckdb_close_connection(value owner) {
  CAMLparam1(owner); CAMLlocal1(result);
  unsigned before = disconnect_serial;
  result = __real_ml_duckdb_close_connection(owner);
  if (disconnect_serial != before && atomic_load(&fail_slot_close) > 0) {
    atomic_fetch_sub(&fail_slot_close, 1);
    caml_raise_with_arg(*caml_named_value("eio_foundation_close"), Val_int(1));
  }
  CAMLreturn(result);
}
extern value __real_ml_duckdb_close_database(value);
value __wrap_ml_duckdb_close_database(value owner) {
  CAMLparam1(owner); CAMLlocal1(result);
  unsigned before = database_serial;
  result = __real_ml_duckdb_close_database(owner);
  if (database_serial != before && atomic_load(&fail_db_close) > 0) {
    atomic_fetch_sub(&fail_db_close, 1);
    caml_raise_with_arg(*caml_named_value("eio_foundation_close"), Val_int(2));
  }
  CAMLreturn(result);
}
