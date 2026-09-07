#ifndef DUCKDB_STAGE1_NATIVE_PROBE_H
#define DUCKDB_STAGE1_NATIVE_PROBE_H
#include <stdint.h>
#include <stddef.h>
/* SQL-copy instrumentation for the private exception-path probes. */
char *stage1_alloc_sql(size_t size);
void stage1_free_sql(char *sql);
int stage1_live_sql_copies(void);
/* Native-owned response. No DuckDB handles or vector pointers escape this helper. */
void *stage1_query(const char *sql);
/* Caller owns a NULL-initialized native slot before starting the query. */
void stage1_query_into(const char *sql, void **slot);
void stage1_destroy_slot(void **slot);
void *stage1_query_at(const char *path, const char *sql);
int stage1_status(void *response);
const char *stage1_error(void *response);
int stage1_count(void *response);
int64_t stage1_value(void *response, int index);
void stage1_destroy(void *response);
void stage1_slow(void);
int stage1_active(void);
int stage1_live_results(void);
#endif
