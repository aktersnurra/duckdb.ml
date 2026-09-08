#define _POSIX_C_SOURCE 200809L
#define DUCKDB_API_NO_DEPRECATED
#include <duckdb.h>
#include <caml/mlvalues.h>
#include <stdatomic.h>
#include <time.h>
#include <string.h>
static _Atomic int armed, entered, proceed, waiting, fail_rollback;
CAMLprim value appender_fail_rollback(value u) { (void)u;atomic_store(&fail_rollback,1);return Val_unit; }
static void pause_at(int point) {
    if (atomic_load(&armed) != point) return;
    atomic_store(&entered, point);
    struct timespec interval = {0,1000000};
    while (!atomic_load(&proceed)) nanosleep(&interval,NULL);
}
CAMLprim value appender_arm(value point) {
    atomic_store(&entered,0); atomic_store(&proceed,0); atomic_store(&waiting,0);
    atomic_store(&armed,Int_val(point)); return Val_unit;
}
CAMLprim value appender_entered(value u) { (void)u;return Val_int(atomic_load(&entered)); }
CAMLprim value appender_release(value u) { (void)u;atomic_store(&proceed,1);return Val_unit; }
CAMLprim value appender_waiting(value u) { (void)u;return Val_bool(atomic_load(&waiting)); }
duckdb_state real_create(duckdb_connection,const char *,const char *,const char *,duckdb_appender *) __asm__("__real_duckdb_appender_create_ext");
duckdb_state wrapped_create(duckdb_connection,const char *,const char *,const char *,duckdb_appender *) __asm__("__wrap_duckdb_appender_create_ext");
duckdb_state wrapped_create(duckdb_connection c,const char *catalog,const char *schema,const char *table,duckdb_appender *a) {
    pause_at(1);return real_create(c,catalog,schema,table,a);
}
duckdb_state real_append(duckdb_appender,duckdb_value) __asm__("__real_duckdb_append_value");
duckdb_state wrapped_append(duckdb_appender,duckdb_value) __asm__("__wrap_duckdb_append_value");
duckdb_state wrapped_append(duckdb_appender a,duckdb_value v) { pause_at(2);return real_append(a,v); }
duckdb_state real_flush(duckdb_appender) __asm__("__real_duckdb_appender_flush");
duckdb_state wrapped_flush(duckdb_appender) __asm__("__wrap_duckdb_appender_flush");
duckdb_state wrapped_flush(duckdb_appender a) { pause_at(3);return real_flush(a); }
duckdb_state real_close(duckdb_appender) __asm__("__real_duckdb_appender_close");
duckdb_state wrapped_close(duckdb_appender) __asm__("__wrap_duckdb_appender_close");
duckdb_state wrapped_close(duckdb_appender a) { pause_at(4);return real_close(a); }
duckdb_state real_query(duckdb_connection,const char *,duckdb_result *) __asm__("__real_duckdb_query");
duckdb_state wrapped_query(duckdb_connection,const char *,duckdb_result *) __asm__("__wrap_duckdb_query");
duckdb_state wrapped_query(duckdb_connection c,const char *sql,duckdb_result *r) {
    if (strcmp(sql,"COMMIT")==0) pause_at(5);
    if (strcmp(sql,"ROLLBACK")==0 && atomic_exchange(&fail_rollback,0))
        return real_query(c,"invalid rollback fault",r);
    return real_query(c,sql,r);
}
value real_wait(value,value) __asm__("__real_caml_ml_condition_wait");
value wrapped_wait(value,value) __asm__("__wrap_caml_ml_condition_wait");
value wrapped_wait(value c,value m) { atomic_store(&waiting,1);return real_wait(c,m); }
