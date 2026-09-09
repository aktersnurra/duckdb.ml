/* Same test wrappers as the safe Bridge executable; no production source copy. */
#include "../adapter_bridge_hooks.c"
#include "query_native.h"
#include <assert.h>
static connection_owner *fixture_owner;
connection_owner *__real_duckdb_ml_connection_ref(value);
connection_owner *__wrap_duckdb_ml_connection_ref(value connection) {
  assert(!fixture_owner);
  fixture_owner = __real_duckdb_ml_connection_ref(connection);
  return __real_duckdb_ml_connection_ref(connection);
}
CAMLprim value lifecycle_release_fixture(value unit) {
  (void)unit;
  connection_owner *owner = fixture_owner;
  fixture_owner = NULL;
  duckdb_ml_connection_unref(owner);
  return Val_unit;
}
/* Unsafe fixture only: Native_request's private ML record stores its custom slot
   first. Extract/root it before the guard; no safe handle conversion is involved. */
#include <caml/memory.h>
CAMLprim value lifecycle_contended_install(value connection, value request) {
  CAMLparam2(connection, request);
  CAMLlocal1(slot);
  slot = Field(request, 0);
  assert(fixture_owner);
  if (!duckdb_ml_native_try_lock(fixture_owner)) abort();
  value result = __real_ml_duckdb_native_request_install(connection, slot);
  duckdb_ml_native_unlock(fixture_owner);
  CAMLreturn(result);
}

static _Atomic int boundary_gate, boundary_entered;
static void boundary(int id) {
  if (atomic_load(&boundary_gate) != id) return;
  /* Every tested destructor/engine call must run outside the real guard. */
  if (!duckdb_ml_native_try_lock(fixture_owner)) abort();
  duckdb_ml_native_unlock(fixture_owner);
  atomic_store(&boundary_entered, id);
  wait_gate(&boundary_gate);
}
CAMLprim value lifecycle_boundary_gate(value id) {
  atomic_store(&boundary_entered, 0);
  atomic_store(&boundary_gate, Int_val(id)); return Val_unit;
}
CAMLprim value lifecycle_boundary_entered(value unit) {
  (void)unit; return Val_int(atomic_load(&boundary_entered));
}
#define STATE_WRAPPER(name, id, parameters, arguments) \
  duckdb_state __real_##name parameters; \
  duckdb_state __wrap_##name parameters { boundary(id); return __real_##name arguments; }
STATE_WRAPPER(duckdb_bind_int64, 1, (duckdb_prepared_statement p, idx_t i, int64_t n), (p, i, n))
STATE_WRAPPER(duckdb_clear_bindings, 2, (duckdb_prepared_statement p), (p))
STATE_WRAPPER(duckdb_appender_flush, 7, (duckdb_appender p), (p))
STATE_WRAPPER(duckdb_appender_close, 8, (duckdb_appender p), (p))
STATE_WRAPPER(duckdb_appender_clear, 9, (duckdb_appender p), (p))
STATE_WRAPPER(duckdb_appender_destroy, 10, (duckdb_appender *p), (p))
#define VOID_WRAPPER(name, id, parameters, arguments) \
  void __real_##name parameters; \
  void __wrap_##name parameters { boundary(id); __real_##name arguments; }
VOID_WRAPPER(duckdb_destroy_result, 3, (duckdb_result *r), (r))
VOID_WRAPPER(duckdb_destroy_prepare, 4, (duckdb_prepared_statement *p), (p))
VOID_WRAPPER(duckdb_destroy_data_chunk, 5, (duckdb_data_chunk *c), (c))
duckdb_data_chunk __real_duckdb_fetch_chunk(duckdb_result);
duckdb_data_chunk __wrap_duckdb_fetch_chunk(duckdb_result r) {
  boundary(6); return __real_duckdb_fetch_chunk(r);
}
