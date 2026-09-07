#define DUCKDB_API_NO_DEPRECATED
#include <duckdb.h>
#include <caml/alloc.h>
#include <caml/custom.h>
#include <caml/fail.h>
#include <caml/memory.h>
#include <caml/mlvalues.h>
#include <caml/threads.h>
#include <caml/signals.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>

/* Slots own stable native shells before any raising runtime transition. Native
   parent references are independent of OCaml finalizer order. Safe ML serializes
   access; atomics here only cover finalization/counters, not an unsafe API lock. */
typedef struct database_owner {
    _Atomic unsigned references;
    duckdb_database database;
    duckdb_config config;
    char *path, *open_error;
    int status;
    char message[512];
} database_owner;
typedef struct connection_owner {
    database_owner *parent;
    duckdb_connection connection;
    char *sql;
    duckdb_extracted_statements extracted;
    duckdb_prepared_statement prepared;
    duckdb_result result;
    int has_result, status;
    char message[512];
} connection_owner;
#define Database(v) (*((database_owner **)Data_custom_val(v)))
#define Connection(v) (*((connection_owner **)Data_custom_val(v)))
static _Atomic int live, fallback;
static void acquired(void) { atomic_fetch_add(&live, 1); }
static void released(void) { atomic_fetch_sub(&live, 1); }
static void message(char *out, const char *in) {
    snprintf(out, 512, "%s", in ? in : "DuckDB operation failed");
}
static void database_clear(database_owner *owner) {
    if (!owner) return;
    if (owner->database) { duckdb_close(&owner->database); released(); }
    if (owner->config) { duckdb_destroy_config(&owner->config); released(); }
    if (owner->path) { free(owner->path); owner->path = NULL; released(); }
    if (owner->open_error) { duckdb_free(owner->open_error); owner->open_error = NULL; }
}
static void database_unref(database_owner *owner) {
    if (owner && atomic_fetch_sub(&owner->references, 1) == 1) {
        database_clear(owner); free(owner); released();
    }
}
static void clear_work(connection_owner *owner) {
    if (!owner) return;
    if (owner->has_result) {
        duckdb_destroy_result(&owner->result); owner->has_result = 0; released();
    }
    if (owner->prepared) { duckdb_destroy_prepare(&owner->prepared); released(); }
    if (owner->extracted) { duckdb_destroy_extracted(&owner->extracted); released(); }
    if (owner->sql) { free(owner->sql); owner->sql = NULL; released(); }
}
static void connection_clear(connection_owner *owner) {
    if (!owner) return;
    clear_work(owner);
    if (owner->connection) { duckdb_disconnect(&owner->connection); released(); }
}
static void connection_delete(connection_owner *owner) {
    if (!owner) return;
    connection_clear(owner); database_unref(owner->parent); free(owner); released();
}
static void finalize_database(value v) {
    if (Database(v)) { atomic_fetch_add(&fallback, 1); database_unref(Database(v)); Database(v) = NULL; }
}
static void finalize_connection(value v) {
    if (Connection(v)) { atomic_fetch_add(&fallback, 1); connection_delete(Connection(v)); Connection(v) = NULL; }
}
static struct custom_operations database_ops = {
    "duckdb.ffi.database", finalize_database, custom_compare_default, custom_hash_default,
    custom_serialize_default, custom_deserialize_default, custom_compare_ext_default,
    custom_fixed_length_default
};
static struct custom_operations connection_ops = {
    "duckdb.ffi.connection", finalize_connection, custom_compare_default, custom_hash_default,
    custom_serialize_default, custom_deserialize_default, custom_compare_ext_default,
    custom_fixed_length_default
};
CAMLprim value ml_duckdb_database_owner(value unit) {
    CAMLparam1(unit); CAMLlocal1(v);
    v = caml_alloc_custom(&database_ops, sizeof(database_owner *), 0, 1);
    Database(v) = NULL;
    database_owner *owner = calloc(1, sizeof(*owner));
    if (!owner) caml_raise_out_of_memory();
    atomic_init(&owner->references, 1); Database(v) = owner; acquired();
    CAMLreturn(v);
}
CAMLprim value ml_duckdb_connection_owner(value parent) {
    CAMLparam1(parent); CAMLlocal1(v);
    v = caml_alloc_custom(&connection_ops, sizeof(connection_owner *), 0, 1);
    Connection(v) = NULL;
    connection_owner *owner = calloc(1, sizeof(*owner));
    if (!owner) caml_raise_out_of_memory();
    owner->parent = Database(parent);
    atomic_fetch_add(&owner->parent->references, 1);
    Connection(v) = owner; acquired();
    CAMLreturn(v);
}
CAMLprim value ml_duckdb_open(value v, value path, value threads, value memory, value readonly) {
    CAMLparam5(v, path, threads, memory, readonly);
    database_owner *owner = Database(v);
    if (strcmp(duckdb_library_version(), "v1.5.5") != 0) {
        owner->status = 1; message(owner->message, "duckdb-ffi requires DuckDB v1.5.5");
        CAMLreturn(Val_unit);
    }
    size_t length = caml_string_length(path);
    owner->path = malloc(length + 1);
    if (!owner->path) caml_raise_out_of_memory();
    acquired(); memcpy(owner->path, String_val(path), length); owner->path[length] = 0;
    long thread_count = Long_val(threads), memory_bytes = Long_val(memory);
    int read_only = Bool_val(readonly);
    caml_enter_blocking_section();
    owner->status = 1;
    duckdb_state state = duckdb_create_config(&owner->config);
    if (owner->config) acquired();
    char number[64];
    if (state == DuckDBSuccess) {
        snprintf(number, sizeof(number), "%ld", thread_count);
        state = duckdb_set_config(owner->config, "threads", number);
    }
    if (state == DuckDBSuccess && memory_bytes > 0) {
        snprintf(number, sizeof(number), "%ldB", memory_bytes);
        state = duckdb_set_config(owner->config, "memory_limit", number);
    }
    if (state == DuckDBSuccess)
        state = duckdb_set_config(owner->config, "access_mode", read_only ? "READ_ONLY" : "READ_WRITE");
    if (state == DuckDBSuccess)
        state = duckdb_open_ext(length ? owner->path : NULL, &owner->database,
                                owner->config, &owner->open_error);
    if (owner->database) acquired();
    if (state == DuckDBSuccess) owner->status = 0;
    else message(owner->message, owner->open_error);
    if (owner->config) { duckdb_destroy_config(&owner->config); released(); }
    free(owner->path); owner->path = NULL; released();
    if (owner->open_error) { duckdb_free(owner->open_error); owner->open_error = NULL; }
    caml_leave_blocking_section();
    /* Reacquire only marks signals pending on this runtime. Deliver while still
       inside the caller's inner async boundary, not in its cleanup bookkeeping. */
    caml_process_pending_actions();
    CAMLreturn(Val_unit);
}
CAMLprim value ml_duckdb_connect(value v) {
    CAMLparam1(v);
    connection_owner *owner = Connection(v);
    caml_enter_blocking_section();
    owner->status = duckdb_connect(owner->parent->database, &owner->connection) == DuckDBSuccess ? 0 : 1;
    if (owner->connection) acquired();
    if (owner->status) message(owner->message, "DuckDB connection failed");
    caml_leave_blocking_section();
    /* Reacquire only marks signals pending on this runtime. Deliver while still
       inside the caller's inner async boundary, not in its cleanup bookkeeping. */
    caml_process_pending_actions();
    CAMLreturn(Val_unit);
}
static int allowed_statement(duckdb_statement_type type) {
    /* A conservative allowlist: unknown future engine statements cannot bypass
       the transaction lease. PREPARE/EXECUTE/CALL/PRAGMA may hide control SQL. */
    switch (type) {
    case DUCKDB_STATEMENT_TYPE_SELECT: case DUCKDB_STATEMENT_TYPE_INSERT:
    case DUCKDB_STATEMENT_TYPE_UPDATE: case DUCKDB_STATEMENT_TYPE_DELETE:
    case DUCKDB_STATEMENT_TYPE_CREATE: case DUCKDB_STATEMENT_TYPE_ALTER:
    case DUCKDB_STATEMENT_TYPE_DROP: case DUCKDB_STATEMENT_TYPE_COPY:
    case DUCKDB_STATEMENT_TYPE_ANALYZE:
    case DUCKDB_STATEMENT_TYPE_MERGE_INTO: return 1;
    default: return 0;
    }
}
CAMLprim value ml_duckdb_execute(value v, value sql, value control) {
    CAMLparam3(v, sql, control);
    connection_owner *owner = Connection(v);
    size_t length = caml_string_length(sql);
    owner->sql = malloc(length + 1);
    if (!owner->sql) caml_raise_out_of_memory();
    acquired(); memcpy(owner->sql, String_val(sql), length); owner->sql[length] = 0;
    int is_control = Bool_val(control);
    caml_enter_blocking_section();
    owner->status = 0;
    if (is_control) {
        owner->has_result = 1; acquired();
        if (duckdb_query(owner->connection, owner->sql, &owner->result) != DuckDBSuccess) {
            owner->status = 1; message(owner->message, duckdb_result_error(&owner->result));
        }
    } else {
        idx_t count = duckdb_extract_statements(owner->connection, owner->sql, &owner->extracted);
        if (owner->extracted) acquired();
        const char *error = owner->extracted
            ? duckdb_extract_statements_error(owner->extracted)
            : "DuckDB could not allocate extracted statements";
        if (error && *error) { owner->status = 1; message(owner->message, error); }
        else if (count != 1) owner->status = 2;
        else {
            duckdb_state state = duckdb_prepare_extracted_statement(owner->connection, owner->extracted, 0, &owner->prepared);
            if (owner->prepared) acquired();
            if (state != DuckDBSuccess) {
                owner->status = 1;
                message(owner->message, owner->prepared ? duckdb_prepare_error(owner->prepared)
                                                       : "DuckDB could not allocate prepared statement");
            } else if (!allowed_statement(duckdb_prepared_statement_type(owner->prepared))) owner->status = 2;
            else {
                owner->has_result = 1; acquired();
                if (duckdb_execute_prepared(owner->prepared, &owner->result) != DuckDBSuccess) {
                    owner->status = 1; message(owner->message, duckdb_result_error(&owner->result));
                }
            }
        }
    }
    clear_work(owner);
    caml_leave_blocking_section();
    /* Reacquire only marks signals pending on this runtime. Deliver while still
       inside the caller's inner async boundary, not in its cleanup bookkeeping. */
    caml_process_pending_actions();
    CAMLreturn(Val_unit);
}
/* Close never frees the stable shell while unlocked. If enter raises, its slot
   still owns all resources; if reacquire raises, the cleared shell is still owned.
   The locked completion below is idempotent and only called after safe draining. */
CAMLprim value ml_duckdb_close_database(value v) {
    CAMLparam1(v); database_owner *owner = Database(v);
    caml_enter_blocking_section(); database_clear(owner); caml_leave_blocking_section();
    /* Reacquire only marks signals pending on this runtime. Deliver while still
       inside the caller's inner async boundary, not in its cleanup bookkeeping. */
    caml_process_pending_actions();
    CAMLreturn(Val_unit);
}
CAMLprim value ml_duckdb_close_connection(value v) {
    CAMLparam1(v); connection_owner *owner = Connection(v);
    caml_enter_blocking_section(); connection_clear(owner); caml_leave_blocking_section();
    /* Reacquire only marks signals pending on this runtime. Deliver while still
       inside the caller's inner async boundary, not in its cleanup bookkeeping. */
    caml_process_pending_actions();
    CAMLreturn(Val_unit);
}
CAMLprim value ml_duckdb_finish_database_close(value v) {
    database_unref(Database(v)); Database(v) = NULL; return Val_unit;
}
CAMLprim value ml_duckdb_finish_connection_close(value v) {
    connection_delete(Connection(v)); Connection(v) = NULL; return Val_unit;
}
CAMLprim value ml_duckdb_clear_work(value v) { clear_work(Connection(v)); return Val_unit; }
CAMLprim value ml_duckdb_database_status(value v) { return Val_int(Database(v)->status); }
CAMLprim value ml_duckdb_connection_status(value v) { return Val_int(Connection(v)->status); }
CAMLprim value ml_duckdb_database_message(value v) {
    CAMLparam1(v); CAMLreturn(caml_copy_string(Database(v)->message));
}
CAMLprim value ml_duckdb_connection_message(value v) {
    CAMLparam1(v); CAMLreturn(caml_copy_string(Connection(v)->message));
}
CAMLprim value ml_duckdb_interrupt(value v) { duckdb_interrupt(Connection(v)->connection); return Val_unit; }
CAMLprim value ml_duckdb_live_resources(value unit) { (void)unit; return Val_int(atomic_load(&live)); }
CAMLprim value ml_duckdb_fallback_reclaims(value unit) { (void)unit; return Val_int(atomic_load(&fallback)); }
