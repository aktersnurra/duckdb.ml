#ifndef DUCKDB_ML_QUERY_NATIVE_H
#define DUCKDB_ML_QUERY_NATIVE_H
#define DUCKDB_API_NO_DEPRECATED
#include <duckdb.h>
#include <caml/mlvalues.h>
/* Private native seam. A child retains its parent's stable shell independently
   of OCaml finalization order. Safe-layer admission owns serialization. */
typedef struct connection_owner connection_owner;
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
