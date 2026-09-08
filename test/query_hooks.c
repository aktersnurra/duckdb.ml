#define _POSIX_C_SOURCE 200809L
#define DUCKDB_API_NO_DEPRECATED
#include <duckdb.h>
#include <caml/mlvalues.h>
#include <stdatomic.h>
#include <time.h>
static _Atomic int armed, entered, proceed, waiting, fail_bind, fail_fetch, fetch_error;
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
duckdb_data_chunk real_fetch(duckdb_result) __asm__("__real_duckdb_fetch_chunk");
duckdb_data_chunk wrapped_fetch(duckdb_result) __asm__("__wrap_duckdb_fetch_chunk");
duckdb_data_chunk wrapped_fetch(duckdb_result r) {
    pause_at(2);
    if (atomic_exchange(&fail_fetch, 0)) { atomic_store(&fetch_error, 1); return NULL; }
    return real_fetch(r);
}
const char *real_error(duckdb_result *) __asm__("__real_duckdb_result_error");
const char *wrapped_error(duckdb_result *) __asm__("__wrap_duckdb_result_error");
const char *wrapped_error(duckdb_result *r) {
    if (atomic_exchange(&fetch_error, 0)) return "injected fetch failure";
    return real_error(r);
}
duckdb_state real_bind(duckdb_prepared_statement, idx_t, int64_t) __asm__("__real_duckdb_bind_int64");
duckdb_state wrapped_bind(duckdb_prepared_statement, idx_t, int64_t) __asm__("__wrap_duckdb_bind_int64");
duckdb_state wrapped_bind(duckdb_prepared_statement p, idx_t i, int64_t x) {
    if (atomic_exchange(&fail_bind, 0)) return DuckDBError;
    return real_bind(p, i, x);
}
value real_wait(value, value) __asm__("__real_caml_ml_condition_wait");
value wrapped_wait(value, value) __asm__("__wrap_caml_ml_condition_wait");
value wrapped_wait(value c, value m) { atomic_store(&waiting, 1); return real_wait(c, m); }
CAMLprim value query_arm(value point) {
    atomic_store(&entered, 0); atomic_store(&proceed, 0); atomic_store(&waiting, 0);
    atomic_store(&armed, Int_val(point)); return Val_unit;
}
CAMLprim value query_entered(value unit) { (void)unit; return Val_int(atomic_load(&entered)); }
CAMLprim value query_release(value unit) { (void)unit; atomic_store(&proceed, 1); return Val_unit; }
CAMLprim value query_waiting(value unit) { (void)unit; return Val_bool(atomic_load(&waiting)); }
CAMLprim value query_fail_bind(value unit) { (void)unit; atomic_store(&fail_bind, 1); return Val_unit; }
CAMLprim value query_fail_fetch(value unit) { (void)unit; atomic_store(&fail_fetch, 1); return Val_unit; }
idx_t real_extract(duckdb_connection, const char *, duckdb_extracted_statements *) __asm__("__real_duckdb_extract_statements");
idx_t wrapped_extract(duckdb_connection, const char *, duckdb_extracted_statements *) __asm__("__wrap_duckdb_extract_statements");
idx_t wrapped_extract(duckdb_connection c, const char *sql, duckdb_extracted_statements *out) {
    pause_at(3); return real_extract(c, sql, out);
}
duckdb_state real_bind_text(duckdb_prepared_statement, idx_t, const char *, idx_t) __asm__("__real_duckdb_bind_varchar_length");
duckdb_state wrapped_bind_text(duckdb_prepared_statement, idx_t, const char *, idx_t) __asm__("__wrap_duckdb_bind_varchar_length");
duckdb_state wrapped_bind_text(duckdb_prepared_statement p, idx_t i, const char *text, idx_t length) {
    pause_at(4); return real_bind_text(p, i, text, length);
}
