#ifndef DUCKDB_STAGE1_NATIVE_PROBE_H
#define DUCKDB_STAGE1_NATIVE_PROBE_H
#include <stdint.h>
/* Native-owned response. No DuckDB handles or vector pointers escape this helper. */
void *stage1_query(const char *sql);
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
