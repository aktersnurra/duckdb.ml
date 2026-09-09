#ifndef DUCKDB_ML_QUERY_NATIVE_H
#define DUCKDB_ML_QUERY_NATIVE_H
#define DUCKDB_API_NO_DEPRECATED
#include <duckdb.h>
#include <caml/mlvalues.h>
/* Private native seam. A child retains its parent's stable shell independently
   of OCaml finalization order. Safe-layer admission owns serialization. */
typedef struct connection_owner connection_owner;
/* Every transition releases the guard before work/destruction. Unlocked callers
   may retry between attempts; held-runtime fallback must never wait. */
typedef enum { DUCKDB_ML_RUNTIME_HELD, DUCKDB_ML_RUNTIME_RELEASED } duckdb_ml_runtime;
bool duckdb_ml_native_try_lock(connection_owner *owner);
void duckdb_ml_native_unlock(connection_owner *owner);
void duckdb_ml_native_work_begin(connection_owner *owner);
void duckdb_ml_native_work_end(connection_owner *owner);
/* Raw execute and Query: the guarded latch load is each native subcall's
   admission decision. No guard is retained into the engine. Scalar binding and
   reset admit against the same latch without enabling delivery. */
typedef enum { DUCKDB_ML_CALL_ADMITTED, DUCKDB_ML_CALL_CANCELLED } duckdb_ml_call_admission;
duckdb_ml_call_admission duckdb_ml_native_user_call_begin(connection_owner *owner);
duckdb_ml_call_admission duckdb_ml_native_noninterruptible_call_begin(connection_owner *owner);
void duckdb_ml_native_user_call_end(connection_owner *owner);
void duckdb_ml_native_cleanup_begin(connection_owner *owner, duckdb_ml_runtime runtime);
void duckdb_ml_native_cleanup_end(connection_owner *owner, duckdb_ml_runtime runtime);
connection_owner *duckdb_ml_connection_ref(value v);
void duckdb_ml_connection_unref(connection_owner *owner);
duckdb_connection duckdb_ml_connection_handle(connection_owner *owner);
void duckdb_ml_acquired(void);
void duckdb_ml_released(void);
void duckdb_ml_fallback(void);
int duckdb_ml_allowed_statement(duckdb_statement_type type);
typedef struct prepared_owner {
    connection_owner *parent;
    duckdb_prepared_statement prepared;
    duckdb_extracted_statements extracted;
    duckdb_result result;
    duckdb_data_chunk chunk;
    char *input;
    int has_result, status;
    char message[512];
} prepared_owner;
prepared_owner *duckdb_ml_prepared(value v);
#endif
