#define DUCKDB_API_NO_DEPRECATED
#include <duckdb.h>
#include <caml/mlvalues.h>
#include <stdatomic.h>
/* Counts engine prepares so tests can observe skipped revalidation. */
static _Atomic long prepares;
duckdb_state real_prepare(duckdb_connection, duckdb_extracted_statements, idx_t, duckdb_prepared_statement *)
    __asm__("__real_duckdb_prepare_extracted_statement");
duckdb_state wrapped_prepare(duckdb_connection, duckdb_extracted_statements, idx_t, duckdb_prepared_statement *)
    __asm__("__wrap_duckdb_prepare_extracted_statement");
duckdb_state wrapped_prepare(duckdb_connection c, duckdb_extracted_statements e, idx_t i, duckdb_prepared_statement *p) {
    atomic_fetch_add(&prepares, 1);
    return real_prepare(c, e, i, p);
}
value epoch_test_prepares(value unit) { (void)unit; return Val_long(atomic_load(&prepares)); }
