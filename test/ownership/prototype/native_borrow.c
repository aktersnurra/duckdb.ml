#define DUCKDB_API_NO_DEPRECATED
#include "native_borrow.h"
#include <duckdb.h>
#include <assert.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

struct stage2_owner {
    duckdb_database db;
    duckdb_connection connection;
    duckdb_result result;
    bool has_result;
    duckdb_data_chunk chunk;
    const int64_t *data;
    const uint64_t *validity;
    size_t length;
    char *sql;
    int status;
    unsigned close_trace;
    char message[512];
};
static _Atomic int live;
static void acquired(void) { atomic_fetch_add(&live, 1); }
static void released(void) { atomic_fetch_sub(&live, 1); }
int stage2_live_resources(void) { return atomic_load(&live); }
static void error(stage2_owner *o, const char *message) {
    o->status = 2;
    snprintf(o->message, sizeof(o->message), "%s", message ? message : "native failure");
}
stage2_owner *stage2_create(void) {
    stage2_owner *o = calloc(1, sizeof(*o));
    if (o) acquired();
    return o;
}
bool stage2_set_sql(stage2_owner *o, const char *sql, size_t length) {
    assert(o && !o->sql && !o->db && !o->has_result);
    if (length == SIZE_MAX || !(o->sql = malloc(length + 1))) {
        error(o, "SQL allocation failed"); return false;
    }
    acquired();
    memcpy(o->sql, sql, length);
    o->sql[length] = '\0';
    return true;
}
static void clear_sql(stage2_owner *o) {
    if (o->sql) { free(o->sql); o->sql = NULL; released(); }
}
void stage2_prepare(stage2_owner *o) {
    assert(o && o->sql && !o->db);
    if (duckdb_open(NULL, &o->db) != DuckDBSuccess) {
        if (o->db) acquired();
        error(o, "open failed"); clear_sql(o); return;
    }
    acquired();
    if (duckdb_connect(o->db, &o->connection) != DuckDBSuccess) {
        if (o->connection) acquired();
        error(o, "connect failed"); clear_sql(o); return;
    }
    acquired();
    /* Result belongs to owner even when query fails. */
    o->has_result = true; acquired();
    duckdb_state state = duckdb_query(o->connection, o->sql, &o->result);
    clear_sql(o);
    if (state != DuckDBSuccess) { error(o, duckdb_result_error(&o->result)); return; }
    if (duckdb_column_count(&o->result) != 1 ||
        duckdb_column_type(&o->result, 0) != DUCKDB_TYPE_BIGINT) o->status = 3;
}
static void clear_chunk(stage2_owner *o) {
    /* Drop all derived pointers before invalidating the chunk. */
    o->data = NULL; o->validity = NULL; o->length = 0;
    if (o->chunk) { duckdb_destroy_data_chunk(&o->chunk); released(); }
}
int stage2_next(stage2_owner *o) {
    assert(o && o->has_result);
    if (o->status != 0) return o->status;
    clear_chunk(o);
    for (;;) {
        o->chunk = duckdb_fetch_chunk(o->result);
        if (!o->chunk) {
            const char *message = duckdb_result_error(&o->result);
            if (message) error(o, message); else o->status = 1;
            return o->status;
        }
        acquired();
        o->length = (size_t)duckdb_data_chunk_get_size(o->chunk);
        if (o->length == 0) { clear_chunk(o); continue; }
        duckdb_vector vector = duckdb_data_chunk_get_vector(o->chunk, 0);
        o->data = duckdb_vector_get_data(vector);
        o->validity = duckdb_vector_get_validity(vector);
        assert(o->data);
        return 0;
    }
}
int stage2_status(const stage2_owner *o) { return o->status; }
const char *stage2_message(const stage2_owner *o) { return o->message; }
size_t stage2_length(const stage2_owner *o) { return o->length; }
bool stage2_valid(const stage2_owner *o, size_t i) {
    assert(o->chunk && i < o->length);
    return !o->validity || ((o->validity[i / 64] >> (i % 64)) & UINT64_C(1));
}
int64_t stage2_value(const stage2_owner *o, size_t i) {
    assert(stage2_valid(o, i));
    return o->data[i];
}
unsigned stage2_close_trace(const stage2_owner *o) { return o->close_trace; }
void stage2_close(stage2_owner *o) {
    if (!o) return;
    o->close_trace = o->chunk ? 1 : 0;
    clear_chunk(o);
    assert(!o->chunk && !o->data && !o->validity);
    if (o->has_result) {
        duckdb_destroy_result(&o->result); o->has_result = false; released();
        o->close_trace = o->close_trace * 10 + 2;
    }
    assert(!o->has_result);
    if (o->connection) {
        duckdb_disconnect(&o->connection); released();
        o->close_trace = o->close_trace * 10 + 3;
    }
    assert(!o->connection);
    if (o->db) {
        duckdb_close(&o->db); released();
        o->close_trace = o->close_trace * 10 + 4;
    }
    if (o->sql) o->close_trace = o->close_trace * 10 + 5;
    clear_sql(o);
    o->status = 1;
}
void stage2_delete(stage2_owner *o) {
    if (!o) return;
    stage2_close(o); free(o); released();
}
