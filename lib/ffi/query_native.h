#ifndef DUCKDB_ML_QUERY_NATIVE_H
#define DUCKDB_ML_QUERY_NATIVE_H
#define DUCKDB_API_NO_DEPRECATED
#include <duckdb.h>
#include <caml/mlvalues.h>
#include <caml/custom.h>
/* Private native seam. A child retains its parent's stable shell independently
   of OCaml finalization order. Safe-layer admission owns serialization. */
typedef struct connection_owner connection_owner;
#define DUCKDB_ML_MESSAGE_SIZE 512
/* Owner status ABI, decoded on the ML side by Duckdb_ffi.Status. */
typedef enum {
    DUCKDB_ML_STATUS_OK = 0,
    DUCKDB_ML_STATUS_ERROR = 1,
    DUCKDB_ML_STATUS_UNSUPPORTED = 2,
    DUCKDB_ML_STATUS_CANCELLED = 3,
} duckdb_ml_status;
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
/* Process-wide schema epoch. It advances before and after every CREATE/ALTER/
   DROP execution, and when a transaction that ran one settles, so a reader
   that sees no change across a window knows no schema change became visible
   in it. [enter] reports whether [leave] must advance it again. */
bool duckdb_ml_changes_schema(duckdb_prepared_statement prepared);
bool duckdb_ml_schema_enter(connection_owner *owner, duckdb_prepared_statement prepared);
void duckdb_ml_schema_leave(bool changing);
/* Per-chunk cache of each column's vector. The array is allocated at a
   result's first fetch with each column's [type] and element [width] (0 when
   the type is not fixed-width), which never change for a result; [data] and
   [validity] are refreshed at every fetch and are valid only while
   [chunk] lives. The array outlives each chunk (it is freed with the result),
   so its pointers dangle between chunks: readers must refuse when [chunk] is
   NULL or a row is not below [chunk_rows], which is 0 whenever no chunk is
   cached. [validity] is NULL when every row is valid. */
typedef struct { void *data; uint64_t *validity; duckdb_type type; uint8_t width; } duckdb_ml_vector;
/* Bytes per element of a fixed-width engine type the views read; 0 otherwise. */
static inline uint8_t duckdb_ml_type_width(duckdb_type t) {
    switch (t) {
    case DUCKDB_TYPE_BOOLEAN: case DUCKDB_TYPE_TINYINT: return 1;
    case DUCKDB_TYPE_SMALLINT: return 2;
    case DUCKDB_TYPE_INTEGER: case DUCKDB_TYPE_DATE: case DUCKDB_TYPE_FLOAT: return 4;
    case DUCKDB_TYPE_BIGINT: case DUCKDB_TYPE_DOUBLE: case DUCKDB_TYPE_TIMESTAMP:
    case DUCKDB_TYPE_TIMESTAMP_S: case DUCKDB_TYPE_TIMESTAMP_MS: case DUCKDB_TYPE_TIMESTAMP_NS:
    case DUCKDB_TYPE_TIMESTAMP_TZ: return 8;
    default: return 0;
    }
}
typedef struct prepared_owner {
    connection_owner *parent;
    duckdb_prepared_statement prepared;
    duckdb_extracted_statements extracted;
    duckdb_result result;
    duckdb_data_chunk chunk;
    char *input;
    int has_result, status;
    char message[DUCKDB_ML_MESSAGE_SIZE];
    duckdb_ml_vector *vectors;
    idx_t vector_count;
    idx_t chunk_rows; /* rows of [chunk] behind the cache; 0 without one */
} prepared_owner;
/* The owner behind a prepared custom block; inline so per-value view reads
   do not pay a cross-file call. */
#define DUCKDB_ML_PREPARED_SLOT(v) (*((prepared_owner **)Data_custom_val(v)))
static inline prepared_owner *duckdb_ml_prepared(value v) { return DUCKDB_ML_PREPARED_SLOT(v); }
#endif
