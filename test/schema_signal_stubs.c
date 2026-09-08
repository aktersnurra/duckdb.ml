#define DUCKDB_API_NO_DEPRECATED
#include <duckdb.h>
#include <string.h>
#include "signal_stubs.c"
static int fail_control;
duckdb_state real_query(duckdb_connection, const char *, duckdb_result *) __asm__("__real_duckdb_query");
duckdb_state wrapped_query(duckdb_connection, const char *, duckdb_result *) __asm__("__wrap_duckdb_query");
duckdb_state wrapped_query(duckdb_connection c, const char *sql, duckdb_result *out) {
    if ((fail_control == 1 && strcmp(sql, "COMMIT") == 0) ||
        (fail_control == 2 && strcmp(sql, "ROLLBACK") == 0) ||
        (fail_control == 3 && strcmp(sql, "BEGIN TRANSACTION") == 0)) {
        fail_control = 0;
        return real_query(c, "SELECT error('injected snapshot control failure')", out);
    }
    return real_query(c, sql, out);
}
CAMLprim value schema_fail_control(value mode) { fail_control = Int_val(mode); return Val_unit; }
