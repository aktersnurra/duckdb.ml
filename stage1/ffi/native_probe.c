#define _POSIX_C_SOURCE 200809L
#define DUCKDB_API_NO_DEPRECATED
#include "native_probe.h"
#include "duckdb.h"
#include <assert.h>
#include <errno.h>
#include <limits.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>

struct response {
    int status;
    int count;
    int64_t *values;
    char error[512];
};
static atomic_int live = 0;
static atomic_int active = 0;

void *stage1_query_at(const char *path, const char *sql) {
    struct response *out = calloc(1, sizeof(*out));
    if (!out) return NULL;
    atomic_fetch_add(&live, 1);
    duckdb_database db = NULL;
    duckdb_connection connection = NULL;
    duckdb_config config = NULL;
    duckdb_result result = {0};
    duckdb_data_chunk chunk = NULL;
    char *open_error = NULL;
    int queried = 0;
    if (duckdb_create_config(&config) != DuckDBSuccess ||
        duckdb_set_config(config, "threads", "1") != DuckDBSuccess) {
        out->status = 1;
        snprintf(out->error, sizeof(out->error), "configuration failed");
        goto cleanup;
    }
    if (duckdb_open_ext(path, &db, config, &open_error) != DuckDBSuccess) {
        out->status = 1;
        snprintf(out->error, sizeof(out->error), "%s", open_error ? open_error : "open failed");
        goto cleanup;
    }
    if (duckdb_connect(db, &connection) != DuckDBSuccess) {
        out->status = 2;
        goto cleanup;
    }
    queried = 1;
    if (duckdb_query(connection, sql, &result) != DuckDBSuccess) {
        out->status = 3;
        goto query_error;
    }
    if (duckdb_column_count(&result) != 1 || duckdb_column_type(&result, 0) != DUCKDB_TYPE_BIGINT) {
        out->status = 4;
        goto cleanup;
    }
    while ((chunk = duckdb_fetch_chunk(result)) != NULL) {
        idx_t size = duckdb_data_chunk_get_size(chunk);
        if (size > (idx_t)(INT_MAX - out->count)) {
            out->status = 5;
            goto cleanup;
        }
        if (size != 0) {
            int64_t *values = realloc(out->values, ((size_t)out->count + size) * sizeof(*values));
            if (!values) { out->status = 5; goto cleanup; }
            out->values = values;
            duckdb_vector vector = duckdb_data_chunk_get_vector(chunk, 0);
            const int64_t *data = duckdb_vector_get_data(vector);
            uint64_t *validity = duckdb_vector_get_validity(vector);
            for (idx_t i = 0; i < size; ++i) {
                if (validity && !duckdb_validity_row_is_valid(validity, i)) {
                    out->status = 4;
                    goto cleanup;
                }
                out->values[out->count++] = data[i];
            }
        }
        duckdb_destroy_data_chunk(&chunk);
    }
    if (duckdb_result_error(&result) != NULL) {
        out->status = 3;
        goto query_error;
    }
    goto cleanup;
query_error: {
    const char *message = duckdb_result_error(&result);
    snprintf(out->error, sizeof(out->error), "%s", message ? message : "query failed");
}
cleanup:
    if (chunk) duckdb_destroy_data_chunk(&chunk);
    /* Required even when duckdb_query fails: it owns the error string. */
    if (queried) duckdb_destroy_result(&result);
    if (connection) duckdb_disconnect(&connection);
    if (db) duckdb_close(&db);
    if (config) duckdb_destroy_config(&config);
    if (open_error) duckdb_free(open_error);
    return out;
}

void *stage1_query(const char *sql) { return stage1_query_at(NULL, sql); }
int stage1_status(void *p) { return p ? ((struct response *)p)->status : 5; }
const char *stage1_error(void *p) { return p ? ((struct response *)p)->error : "allocation failed"; }
int stage1_count(void *p) { return p ? ((struct response *)p)->count : 0; }
int64_t stage1_value(void *p, int index) {
    struct response *r = p;
    assert(r && r->status == 0 && index >= 0 && index < r->count);
    return r->values[index];
}
void stage1_destroy(void *p) {
    if (p) {
        struct response *r = p;
        free(r->values);
        free(r);
        atomic_fetch_sub(&live, 1);
    }
}
void stage1_slow(void) {
    struct timespec remaining = { .tv_sec = 0, .tv_nsec = 200000000 };
    atomic_store(&active, 1);
    while (nanosleep(&remaining, &remaining) != 0 && errno == EINTR) {}
    atomic_store(&active, 0);
}
int stage1_active(void) { return atomic_load(&active); }
int stage1_live_results(void) { return atomic_load(&live); }
