#include "native_probe.h"
#include "duckdb.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>

int main(void) {
    assert(strcmp(duckdb_library_version(), "v1.5.5") == 0);
    for (int i = 0; i < 100; ++i) {
        void *r = stage1_query("SELECT i::BIGINT FROM range(5000) t(i)");
        assert(stage1_status(r) == 0 && stage1_count(r) == 5000);
        for (int j = 0; j < 5000; ++j) assert(stage1_value(r, j) == j);
        stage1_destroy(r);
        r = stage1_query("invalid SQL");
        assert(stage1_status(r) == 3 && strlen(stage1_error(r)) > 0);
        stage1_destroy(r);
        r = stage1_query("SELECT NULL::BIGINT");
        assert(stage1_status(r) == 4);
        stage1_destroy(r);
        r = stage1_query("SELECT 'unsupported'");
        assert(stage1_status(r) == 4);
        stage1_destroy(r);
        r = stage1_query_at("/proc/duckdb-stage1-missing/database", "SELECT 42::BIGINT");
        assert(stage1_status(r) == 1 && strlen(stage1_error(r)) > 0);
        stage1_destroy(r);
        assert(stage1_live_results() == 0);
    }
    puts("native: DuckDB v1.5.5, 100 query/error/open-failure cycles, ASan/UBSan/LSan=ok");
    return 0;
}
