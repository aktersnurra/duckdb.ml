#define _POSIX_C_SOURCE 200809L
#include <duckdb.h>
#include <caml/mlvalues.h>
#include <caml/callback.h>
#include <caml/fail.h>
#include <stdatomic.h>
#include <string.h>
#include <time.h>
#include <stdio.h>
#include <stdlib.h>

static _Atomic int executes, begins, commits, rollbacks, disconnects;
static _Atomic int installs, uninstalls, disposals, cancellations;
static _Atomic int request_failure;
static _Atomic int disconnect_gate, disconnect_entered, fail_rollback;
static _Atomic int execute_gate, execute_entered;
static void wait_gate(_Atomic int *gate) {
  struct timespec start, now, delay = {0, 1000000};
  clock_gettime(CLOCK_MONOTONIC, &start);
  while (atomic_load(gate)) {
    clock_gettime(CLOCK_MONOTONIC, &now);
    if (now.tv_sec - start.tv_sec >= 20) {
      fputs("adapter bridge native gate watchdog: process failure\n", stderr);
      abort();
    }
    nanosleep(&delay, NULL);
  }
}
duckdb_state __real_duckdb_execute_prepared(duckdb_prepared_statement, duckdb_result *);
duckdb_state __wrap_duckdb_execute_prepared(duckdb_prepared_statement p, duckdb_result *r) {
  atomic_fetch_add(&executes, 1);
  if (atomic_load(&execute_gate) == 1) {
    atomic_store(&execute_entered, 1); wait_gate(&execute_gate);
  }
  duckdb_state result = __real_duckdb_execute_prepared(p, r);
  if (atomic_load(&execute_gate) == 2) {
    atomic_store(&execute_entered, 2); wait_gate(&execute_gate);
  }
  return result;
}
duckdb_state __real_duckdb_query(duckdb_connection, const char *, duckdb_result *);
duckdb_state __wrap_duckdb_query(duckdb_connection c, const char *sql, duckdb_result *r) {
  if (!strcmp(sql, "BEGIN TRANSACTION")) atomic_fetch_add(&begins, 1);
  if (!strcmp(sql, "COMMIT")) atomic_fetch_add(&commits, 1);
  if (!strcmp(sql, "ROLLBACK")) {
    atomic_fetch_add(&rollbacks, 1);
    if (atomic_load(&fail_rollback)) sql = "invalid rollback injected";
  }
  return __real_duckdb_query(c, sql, r);
}
void __real_duckdb_disconnect(duckdb_connection *);
void __wrap_duckdb_disconnect(duckdb_connection *c) {
  atomic_fetch_add(&disconnects, 1);
  atomic_store(&disconnect_entered, 1);
  wait_gate(&disconnect_gate);
  __real_duckdb_disconnect(c);
}
CAMLprim value adapter_bridge_reset(value unit) {
  (void)unit;
  atomic_store(&executes, 0); atomic_store(&begins, 0);
  atomic_store(&commits, 0); atomic_store(&rollbacks, 0);
  atomic_store(&disconnects, 0); atomic_store(&disconnect_entered, 0);
  atomic_store(&fail_rollback, 0);
  atomic_store(&installs, 0); atomic_store(&uninstalls, 0);
  atomic_store(&disposals, 0); atomic_store(&cancellations, 0);
  return Val_unit;
}
CAMLprim value adapter_bridge_count(value which) {
  switch (Int_val(which)) {
    case 0: return Val_int(atomic_load(&executes));
    case 1: return Val_int(atomic_load(&begins));
    case 2: return Val_int(atomic_load(&commits));
    case 3: return Val_int(atomic_load(&rollbacks));
    case 4: return Val_int(atomic_load(&disconnects));
    case 5: return Val_int(atomic_load(&installs));
    case 6: return Val_int(atomic_load(&uninstalls));
    case 7: return Val_int(atomic_load(&disposals));
    default: return Val_int(atomic_load(&cancellations));
  }
}
CAMLprim value adapter_bridge_disconnect_gate(value enabled) {
  atomic_store(&disconnect_gate, Bool_val(enabled)); return Val_unit;
}
CAMLprim value adapter_bridge_disconnect_entered(value unit) {
  (void)unit; return Val_bool(atomic_load(&disconnect_entered));
}
CAMLprim value adapter_bridge_fail_rollback(value enabled) {
  atomic_store(&fail_rollback, Bool_val(enabled)); return Val_unit;
}

CAMLprim value adapter_bridge_execute_gate(value phase) {
  atomic_store(&execute_entered, 0);
  atomic_store(&execute_gate, Int_val(phase)); return Val_unit;
}
CAMLprim value adapter_bridge_execute_entered(value unit) {
  (void)unit; return Val_int(atomic_load(&execute_entered));
}

/* Invocation/order evidence only: these wrappers do not inspect native state. */
value __real_ml_duckdb_native_request_install(value, value);
value __wrap_ml_duckdb_native_request_install(value connection, value request) {
  if (atomic_load(&request_failure) == 2) return Val_int(1); /* no side effect */
  value result = __real_ml_duckdb_native_request_install(connection, request);
  if (Int_val(result) == 0) atomic_fetch_add(&installs, 1);
  return result;
}
value __real_ml_duckdb_native_request_uninstall(value);
value __wrap_ml_duckdb_native_request_uninstall(value request) {
  value result = __real_ml_duckdb_native_request_uninstall(request);
  if (Int_val(result) == 0) atomic_fetch_add(&uninstalls, 1);
  return result;
}
value __real_ml_duckdb_native_request_dispose(value);
value __wrap_ml_duckdb_native_request_dispose(value request) {
  value result = __real_ml_duckdb_native_request_dispose(request);
  if (Bool_val(result)) atomic_fetch_add(&disposals, 1);
  return result;
}
value __real_ml_duckdb_native_request_cancel(value);
value __wrap_ml_duckdb_native_request_cancel(value request) {
  value result = __real_ml_duckdb_native_request_cancel(request);
  atomic_fetch_add(&cancellations, 1);
  return result;
}

CAMLprim value adapter_bridge_request_failure(value mode) {
  atomic_store(&request_failure, Int_val(mode)); return Val_unit;
}
value __real_ml_duckdb_native_request_create(value);
value __wrap_ml_duckdb_native_request_create(value unit) {
  if (atomic_load(&request_failure) == 1)
    caml_raise_constant(*caml_named_value("resource_lifecycle_create_failure"));
  return __real_ml_duckdb_native_request_create(unit);
}
