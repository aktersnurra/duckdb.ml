#include "native_borrow.h"
#include <duckdb.h>
#include <assert.h>
#include <stdio.h>
#include <string.h>
static stage2_owner *query(const char *sql) {
    stage2_owner *o = stage2_create(); assert(o);
    assert(stage2_set_sql(o, sql, strlen(sql)));
    stage2_prepare(o); return o;
}
static void close_check(stage2_owner *o, unsigned trace) {
    stage2_close(o);
    assert(stage2_close_trace(o) == trace);
    assert(stage2_length(o) == 0);
    assert(stage2_live_resources() == 1); /* Only the owner shell remains. */
    stage2_close(o);
    assert(stage2_close_trace(o) == 0);
    stage2_delete(o);
    assert(stage2_live_resources() == 0);
}
int main(void) {
    assert(strcmp(duckdb_library_version(), "v1.5.5") == 0);
    for (int cycle = 0; cycle < 30; ++cycle) {
        stage2_owner *o = query("select case when i%65=0 then NULL else i end::bigint from range(5000) t(i)");
        assert(stage2_status(o) == 0);
        size_t rows = 0, chunks = 0;
        while (stage2_next(o) == 0) {
            ++chunks;
            for (size_t i = 0; i < stage2_length(o); ++i, ++rows) {
                assert(stage2_valid(o, i) == (rows % 65 != 0));
                if (stage2_valid(o, i)) assert(stage2_value(o, i) == (int64_t)rows);
            }
        }
        assert(rows == 5000 && chunks > 1 && stage2_status(o) == 1);
        assert(stage2_next(o) == 1); /* Exhaustion is stable. */
        close_check(o, 234);
        o = query("select v from (values ('-9223372036854775808'::bigint), (NULL::bigint), ('9223372036854775807'::bigint)) t(v)");
        assert(stage2_next(o) == 0 && stage2_length(o) == 3);
        assert(stage2_valid(o, 0) && stage2_value(o, 0) == INT64_MIN);
        assert(!stage2_valid(o, 1));
        assert(stage2_valid(o, 2) && stage2_value(o, 2) == INT64_MAX);
        close_check(o, 1234); /* Early exit: chunk must precede every parent. */
        o = query("select 1::bigint where false");
        assert(stage2_next(o) == 1); close_check(o, 234);
        o = query("not valid sql");
        assert(stage2_status(o) == 2 && strlen(stage2_message(o)) > 0);
        close_check(o, 234);
        o = query("select 1"); assert(stage2_status(o) == 3); close_check(o, 234);
        o = stage2_create(); assert(o);
        assert(stage2_set_sql(o, "select 1", 8)); close_check(o, 5);
    }
    puts("native-borrow: DuckDB v1.5.5, 30 nullable/multichunk/empty/extrema/error/order/idempotence cycles, ASan/UBSan/LSan=ok");
    return 0;
}
