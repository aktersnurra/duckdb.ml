#define DUCKDB_API_NO_DEPRECATED
#include "query_native.h"
#include <caml/alloc.h>
#include <caml/custom.h>
#include <caml/fail.h>
#include <caml/memory.h>
#include <caml/mlvalues.h>
#include <caml/threads.h>
#include <caml/signals.h>
#include <assert.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <sched.h>

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
typedef enum {
    DUCKDB_ML_NATIVE_IDLE,
    DUCKDB_ML_NATIVE_NONINTERRUPTIBLE,
    DUCKDB_ML_NATIVE_USER,
    DUCKDB_ML_NATIVE_CLEANUP,
    DUCKDB_ML_NATIVE_CLOSING,
} duckdb_ml_native_phase;

typedef enum {
    DUCKDB_ML_REQUEST_FRESH,
    DUCKDB_ML_REQUEST_INSTALLED,
    DUCKDB_ML_REQUEST_DETACHED,
} duckdb_ml_request_state;

/* Exactly one custom slot owns this allocation. The sole selected attempt must
   root that slot through its entire lifetime; it does not own a second native
   reference. The bound owner reference is one-way, never an ownership cycle. */
typedef struct duckdb_ml_native_request {
    connection_owner *owner;
    duckdb_ml_request_state state;
    _Atomic bool reserved;
    _Atomic bool cancelled;
} duckdb_ml_native_request;

/* Required for the short noalloc paths on the supported target. */
static_assert(ATOMIC_BOOL_LOCK_FREE == 2 && ATOMIC_INT_LOCK_FREE == 2,
              "native request bool and reference atomics must be lock-free");

struct connection_owner {
    _Atomic unsigned references;
    database_owner *parent;
    duckdb_connection connection;
    _Atomic bool native_guard;
    duckdb_ml_native_request *active_request; /* guarded, non-owning */
    duckdb_ml_native_phase native_phase;
    bool native_closing;
    bool foreign_active;
    unsigned cleanup_depth;
    char *sql;
    duckdb_extracted_statements extracted;
    duckdb_prepared_statement prepared;
    duckdb_result result;
    int has_result, status;
    char message[512];
};
#define Database(v) (*((database_owner **)Data_custom_val(v)))
#define Connection(v) (*((connection_owner **)Data_custom_val(v)))
#define Native_request(v) (*((duckdb_ml_native_request **)Data_custom_val(v)))
static _Atomic int live, fallback;
static void acquired(void) { atomic_fetch_add(&live, 1); }
static void released(void) { atomic_fetch_sub(&live, 1); }
bool duckdb_ml_native_try_lock(connection_owner *owner) {
    bool expected = false;
    return atomic_compare_exchange_strong_explicit(
        &owner->native_guard, &expected, true,
        memory_order_acquire, memory_order_relaxed);
}
void duckdb_ml_native_unlock(connection_owner *owner) {
    atomic_store_explicit(&owner->native_guard, false, memory_order_release);
}
/* Safe Resource holds the entire live child tree through work and cleanup.
   Temporary children have scoped/CAML roots; closed children have NULL slots.
   Thus held-runtime finish/finalizers cannot share an owner with live foreign
   work. The sole ML controller takes this guard only with the runtime held,
   so it cannot contend with held-runtime fallback. Other owners have distinct
   guards. Unsupported unsafe concurrency fails closed, never frees on contention. */
static void native_lock(connection_owner *owner, duckdb_ml_runtime runtime) {
    while (!duckdb_ml_native_try_lock(owner)) {
        if (runtime == DUCKDB_ML_RUNTIME_HELD)
            caml_fatal_error("native fallback requires exclusive quiescent ownership");
        /* No guard is held and the runtime was already released by the caller. */
        sched_yield();
    }
}
static void native_phase_update(connection_owner *owner) {
    owner->native_phase = owner->native_closing ? DUCKDB_ML_NATIVE_CLOSING
        : owner->cleanup_depth ? DUCKDB_ML_NATIVE_CLEANUP
        : owner->foreign_active ? DUCKDB_ML_NATIVE_NONINTERRUPTIBLE
        : DUCKDB_ML_NATIVE_IDLE;
}
void duckdb_ml_native_work_begin(connection_owner *owner) {
    native_lock(owner, DUCKDB_ML_RUNTIME_RELEASED);
    if (owner->native_closing || owner->foreign_active || owner->cleanup_depth) {
        duckdb_ml_native_unlock(owner);
        caml_fatal_error("native work requires an open exclusive owner");
    }
    owner->foreign_active = true;
    native_phase_update(owner);
    duckdb_ml_native_unlock(owner);
}
void duckdb_ml_native_work_end(connection_owner *owner) {
    native_lock(owner, DUCKDB_ML_RUNTIME_RELEASED);
    if (!owner->foreign_active || owner->cleanup_depth) {
        duckdb_ml_native_unlock(owner);
        caml_fatal_error("native work completion requires balanced cleanup");
    }
    owner->foreign_active = false;
    native_phase_update(owner);
    duckdb_ml_native_unlock(owner);
}
static duckdb_ml_call_admission native_call_begin(connection_owner *owner, bool interruptible) {
    native_lock(owner, DUCKDB_ML_RUNTIME_RELEASED);
    if (!owner->foreign_active || owner->cleanup_depth || owner->native_closing) {
        duckdb_ml_native_unlock(owner);
        caml_fatal_error("native user admission requires exclusive open work");
    }
    duckdb_ml_native_request *request = owner->active_request;
    /* This acquire-load is admission's linearization against cancel's release
       store. After admission, cancellation may race engine entry/reset; the
       persistent controller retries until the subcall leaves USER. */
    if (request && atomic_load_explicit(&request->cancelled, memory_order_acquire)) {
        native_phase_update(owner);
        duckdb_ml_native_unlock(owner);
        return DUCKDB_ML_CALL_CANCELLED;
    }
    owner->native_phase = request && interruptible ? DUCKDB_ML_NATIVE_USER : DUCKDB_ML_NATIVE_NONINTERRUPTIBLE;
    duckdb_ml_native_unlock(owner);
    return DUCKDB_ML_CALL_ADMITTED;
}
duckdb_ml_call_admission duckdb_ml_native_user_call_begin(connection_owner *owner) {
    return native_call_begin(owner, true);
}
duckdb_ml_call_admission duckdb_ml_native_noninterruptible_call_begin(connection_owner *owner) {
    return native_call_begin(owner, false);
}
void duckdb_ml_native_user_call_end(connection_owner *owner) {
    native_lock(owner, DUCKDB_ML_RUNTIME_RELEASED);
    native_phase_update(owner);
    duckdb_ml_native_unlock(owner);
}
void duckdb_ml_native_cleanup_begin(connection_owner *owner, duckdb_ml_runtime runtime) {
    native_lock(owner, runtime);
    if (runtime == DUCKDB_ML_RUNTIME_HELD && owner->foreign_active) {
        duckdb_ml_native_unlock(owner);
        caml_fatal_error("native fallback cannot overlap foreign work");
    }
    ++owner->cleanup_depth;
    native_phase_update(owner);
    duckdb_ml_native_unlock(owner);
}
void duckdb_ml_native_cleanup_end(connection_owner *owner, duckdb_ml_runtime runtime) {
    native_lock(owner, runtime);
    if (!owner->cleanup_depth) {
        duckdb_ml_native_unlock(owner);
        caml_fatal_error("native cleanup completion requires matching entry");
    }
    --owner->cleanup_depth;
    native_phase_update(owner);
    duckdb_ml_native_unlock(owner);
}
static void native_close_begin(connection_owner *owner, duckdb_ml_runtime runtime) {
    native_lock(owner, runtime);
    if (owner->foreign_active || owner->cleanup_depth || owner->active_request) {
        duckdb_ml_native_unlock(owner);
        caml_fatal_error("native close requires completed work and detached request");
    }
    owner->native_closing = true;
    native_phase_update(owner);
    duckdb_ml_native_unlock(owner);
}
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
static void clear_work(connection_owner *owner, duckdb_ml_runtime runtime) {
    if (!owner) return;
    duckdb_ml_native_cleanup_begin(owner, runtime);
    if (owner->has_result) {
        duckdb_destroy_result(&owner->result); owner->has_result = 0; released();
    }
    if (owner->prepared) { duckdb_destroy_prepare(&owner->prepared); released(); }
    if (owner->extracted) { duckdb_destroy_extracted(&owner->extracted); released(); }
    if (owner->sql) { free(owner->sql); owner->sql = NULL; released(); }
    duckdb_ml_native_cleanup_end(owner, runtime);
}
static void connection_clear(connection_owner *owner, duckdb_ml_runtime runtime) {
    if (!owner) return;
    native_close_begin(owner, runtime);
    duckdb_ml_native_cleanup_begin(owner, runtime);
    clear_work(owner, runtime);
    if (owner->connection) { duckdb_disconnect(&owner->connection); released(); }
    duckdb_ml_native_cleanup_end(owner, runtime);
}
static void connection_delete(connection_owner *owner) {
    if (!owner || atomic_fetch_sub(&owner->references, 1) != 1) return;
    connection_clear(owner, DUCKDB_ML_RUNTIME_HELD); database_unref(owner->parent); free(owner); released();
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
/* Result order matches Native_request.uninstall_result in duckdb_ffi.ml. */
typedef enum {
    REQUEST_UNINSTALLED,
    REQUEST_UNINSTALL_CONTENDED,
    REQUEST_NATIVE_WORK_PENDING,
    REQUEST_DELIVERY_PENDING,
    REQUEST_NOT_INSTALLED,
} request_uninstall_result;

static request_uninstall_result native_request_uninstall(duckdb_ml_native_request *request) {
    if (!request || request->state != DUCKDB_ML_REQUEST_INSTALLED)
        return REQUEST_NOT_INSTALLED;
    connection_owner *owner = request->owner;
    if (!duckdb_ml_native_try_lock(owner)) return REQUEST_UNINSTALL_CONTENDED;
    request_uninstall_result result;
    if (owner->foreign_active || owner->cleanup_depth)
        result = REQUEST_NATIVE_WORK_PENDING;
    else if (atomic_load_explicit(&request->reserved, memory_order_acquire))
        result = REQUEST_DELIVERY_PENDING;
    else {
        /* Exclusive lifecycle use and the single binding establish identity. */
        if (owner->active_request != request) {
            duckdb_ml_native_unlock(owner);
            caml_fatal_error("native request owner identity invariant violated");
        }
        owner->active_request = NULL;
        request->owner = NULL;
        request->state = DUCKDB_ML_REQUEST_DETACHED;
        result = REQUEST_UNINSTALLED;
    }
    duckdb_ml_native_unlock(owner);
    /* Parent unref can destroy: never perform it under the guard. */
    if (result == REQUEST_UNINSTALLED) connection_delete(owner);
    return result;
}

static void finalize_native_request(value v) {
    duckdb_ml_native_request *request = Native_request(v);
    if (!request) return;
    /* Rooted workers/children cannot finalize; the whole dead owner tree has no
       foreign activity or same-owner guard user. Native owner retention handles
       either dead-slot order. No wait, spin or free-on-contention is permitted. */
    if (request->state == DUCKDB_ML_REQUEST_INSTALLED &&
        native_request_uninstall(request) != REQUEST_UNINSTALLED)
        caml_fatal_error("native request finalization requires quiescent exclusive ownership");
    Native_request(v) = NULL;
    atomic_fetch_add(&fallback, 1);
    free(request);
    released();
}
static struct custom_operations native_request_ops = {
    "duckdb.ffi.native_request", finalize_native_request,
    custom_compare_default, custom_hash_default, custom_serialize_default,
    custom_deserialize_default, custom_compare_ext_default, custom_fixed_length_default
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
    atomic_init(&owner->references, 1);
    atomic_init(&owner->native_guard, false);
    owner->native_phase = DUCKDB_ML_NATIVE_IDLE;
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
    duckdb_ml_native_work_begin(owner);
    owner->status = duckdb_connect(owner->parent->database, &owner->connection) == DuckDBSuccess ? 0 : 1;
    if (owner->connection) acquired();
    if (owner->status) message(owner->message, "DuckDB connection failed");
    duckdb_ml_native_work_end(owner);
    caml_leave_blocking_section();
    /* Reacquire only marks signals pending on this runtime. Deliver while still
       inside the caller's inner async boundary, not in its cleanup bookkeeping. */
    caml_process_pending_actions();
    CAMLreturn(Val_unit);
}
int duckdb_ml_allowed_statement(duckdb_statement_type type) {
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
    duckdb_ml_native_work_begin(owner);
    owner->status = 0;
    bool cleanup_started = false;
    if (is_control) {
        owner->has_result = 1; acquired();
        if (duckdb_query(owner->connection, owner->sql, &owner->result) != DuckDBSuccess) {
            owner->status = 1; message(owner->message, duckdb_result_error(&owner->result));
        }
    } else if (duckdb_ml_native_user_call_begin(owner) == DUCKDB_ML_CALL_CANCELLED) {
        owner->status = 3;
    } else {
        idx_t count = duckdb_extract_statements(owner->connection, owner->sql, &owner->extracted);
        duckdb_ml_native_user_call_end(owner);
        if (owner->extracted) acquired();
        const char *error = owner->extracted
            ? duckdb_extract_statements_error(owner->extracted)
            : "DuckDB could not allocate extracted statements";
        if (error && *error) { owner->status = 1; message(owner->message, error); }
        else if (count != 1) owner->status = 2;
        else if (duckdb_ml_native_user_call_begin(owner) == DUCKDB_ML_CALL_CANCELLED) owner->status = 3;
        else {
            duckdb_state state = duckdb_prepare_extracted_statement(owner->connection, owner->extracted, 0, &owner->prepared);
            duckdb_ml_native_user_call_end(owner);
            if (owner->prepared) acquired();
            if (state != DuckDBSuccess) {
                owner->status = 1;
                message(owner->message, owner->prepared ? duckdb_prepare_error(owner->prepared)
                                                       : "DuckDB could not allocate prepared statement");
            } else if (!duckdb_ml_allowed_statement(duckdb_prepared_statement_type(owner->prepared))) owner->status = 2;
            else if (duckdb_ml_native_user_call_begin(owner) == DUCKDB_ML_CALL_CANCELLED) owner->status = 3;
            else {
                owner->has_result = 1; acquired();
                duckdb_state executed = duckdb_execute_prepared(owner->prepared, &owner->result);
                /* Final subcall completion enters cleanup directly. Publish
                   exclusion before error inspection and every destructor. */
                duckdb_ml_native_cleanup_begin(owner, DUCKDB_ML_RUNTIME_RELEASED);
                cleanup_started = true;
                if (executed != DuckDBSuccess) {
                    owner->status = 1; message(owner->message, duckdb_result_error(&owner->result));
                }
            }
        }
    }
    if (!cleanup_started) duckdb_ml_native_cleanup_begin(owner, DUCKDB_ML_RUNTIME_RELEASED);
    clear_work(owner, DUCKDB_ML_RUNTIME_RELEASED);
    duckdb_ml_native_cleanup_end(owner, DUCKDB_ML_RUNTIME_RELEASED);
    duckdb_ml_native_work_end(owner);
    caml_leave_blocking_section();
    /* Reacquire only marks signals pending on this runtime. Deliver while still
       inside the caller's inner async boundary, not in its cleanup bookkeeping. */
    caml_process_pending_actions();
    CAMLreturn(Val_unit);
}
/* Constructor order matches the private control_statement ADT. Unlike the
   legacy unsafe bool entry, only rollback bypasses native latch admission. */
CAMLprim value ml_duckdb_execute_control(value v, value statement) {
    CAMLparam2(v, statement);
    connection_owner *owner = Connection(v);
    int control = Int_val(statement);
    const char *sql = control == 0 ? "BEGIN TRANSACTION" : control == 1 ? "COMMIT" : "ROLLBACK";
    caml_enter_blocking_section();
    duckdb_ml_native_work_begin(owner);
    owner->status = 0;
    if (control != 2 && duckdb_ml_native_user_call_begin(owner) == DUCKDB_ML_CALL_CANCELLED) {
        owner->status = 3;
        duckdb_ml_native_cleanup_begin(owner, DUCKDB_ML_RUNTIME_RELEASED);
    } else {
        owner->has_result = 1; acquired();
        duckdb_state result = duckdb_query(owner->connection, sql, &owner->result);
        duckdb_ml_native_cleanup_begin(owner, DUCKDB_ML_RUNTIME_RELEASED);
        if (result != DuckDBSuccess) {
            owner->status = 1; message(owner->message, duckdb_result_error(&owner->result));
        }
    }
    clear_work(owner, DUCKDB_ML_RUNTIME_RELEASED);
    duckdb_ml_native_cleanup_end(owner, DUCKDB_ML_RUNTIME_RELEASED);
    duckdb_ml_native_work_end(owner);
    caml_leave_blocking_section();
    caml_process_pending_actions();
    CAMLreturn(Val_unit);
}
/* A reservation decision is noninterruptible, not detached permission: private
   Parquet holds Resource admission across this entry and immediate temp_file. */
CAMLprim value ml_duckdb_admit_local_file(value v) {
    CAMLparam1(v);
    connection_owner *owner = Connection(v);
    caml_enter_blocking_section();
    duckdb_ml_native_work_begin(owner);
    duckdb_ml_call_admission result = duckdb_ml_native_noninterruptible_call_begin(owner);
    duckdb_ml_native_work_end(owner);
    caml_leave_blocking_section();
    caml_process_pending_actions();
    CAMLreturn(Val_int(result == DUCKDB_ML_CALL_ADMITTED ? 0 : 1));
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
    caml_enter_blocking_section(); connection_clear(owner, DUCKDB_ML_RUNTIME_RELEASED); caml_leave_blocking_section();
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
CAMLprim value ml_duckdb_clear_work(value v) { clear_work(Connection(v), DUCKDB_ML_RUNTIME_HELD); return Val_unit; }
CAMLprim value ml_duckdb_database_status(value v) { return Val_int(Database(v)->status); }
CAMLprim value ml_duckdb_connection_status(value v) { return Val_int(Connection(v)->status); }
CAMLprim value ml_duckdb_database_message(value v) {
    CAMLparam1(v); CAMLreturn(caml_copy_string(Database(v)->message));
}
CAMLprim value ml_duckdb_connection_message(value v) {
    CAMLparam1(v); CAMLreturn(caml_copy_string(Connection(v)->message));
}
CAMLprim value ml_duckdb_interrupt(value v) { duckdb_interrupt(Connection(v)->connection); return Val_unit; }

CAMLprim value ml_duckdb_native_request_create(value unit) {
    CAMLparam1(unit); CAMLlocal1(v);
    v = caml_alloc_custom(&native_request_ops, sizeof(duckdb_ml_native_request *), 0, 1);
    Native_request(v) = NULL;
    duckdb_ml_native_request *request = calloc(1, sizeof(*request));
    if (!request) caml_raise_out_of_memory();
    request->state = DUCKDB_ML_REQUEST_FRESH;
    atomic_init(&request->reserved, false);
    atomic_init(&request->cancelled, false);
    Native_request(v) = request;
    acquired();
    CAMLreturn(v);
}

CAMLprim value ml_duckdb_native_request_cancel(value v) {
    duckdb_ml_native_request *request = Native_request(v);
    if (request) atomic_store_explicit(&request->cancelled, true, memory_order_release);
    return Val_unit;
}

/* Constant constructor order matches the corresponding ML result ADTs. */
typedef enum {
    REQUEST_INSTALLED, REQUEST_INSTALL_CONTENDED, REQUEST_CONNECTION_CLOSED,
    REQUEST_CONNECTION_LEASED, REQUEST_USED, REQUEST_CONNECTION_ACTIVE,
} request_install_result;
typedef enum {
    REQUEST_RESERVED, REQUEST_INELIGIBLE, REQUEST_RESERVATION_PENDING,
} request_reserve_result;
typedef enum {
    REQUEST_DELIVERED, REQUEST_SKIPPED, REQUEST_NOT_RESERVED,
} request_interrupt_result;

CAMLprim value ml_duckdb_native_request_install(value connection, value v) {
    duckdb_ml_native_request *request = Native_request(v);
    if (!request || request->state != DUCKDB_ML_REQUEST_FRESH) return Val_int(REQUEST_USED);
    connection_owner *owner = Connection(connection);
    if (!owner) return Val_int(REQUEST_CONNECTION_CLOSED);
    if (!duckdb_ml_native_try_lock(owner)) return Val_int(REQUEST_INSTALL_CONTENDED);
    request_install_result result;
    if (owner->native_closing) result = REQUEST_CONNECTION_CLOSED;
    else if (owner->foreign_active || owner->cleanup_depth) result = REQUEST_CONNECTION_ACTIVE;
    else if (!owner->connection) result = REQUEST_CONNECTION_CLOSED;
    else if (owner->active_request) result = REQUEST_CONNECTION_LEASED;
    else {
        atomic_fetch_add_explicit(&owner->references, 1, memory_order_relaxed);
        request->owner = owner;
        request->state = DUCKDB_ML_REQUEST_INSTALLED;
        owner->active_request = request;
        result = REQUEST_INSTALLED;
    }
    duckdb_ml_native_unlock(owner);
    return Val_int(result);
}

static bool native_request_eligible(connection_owner *owner, duckdb_ml_native_request *request) {
    /* Permission is rechecked after selection; no cached engine pointer is a
       ticket. Only interruptible admitted subcalls write USER; cleanup never does. */
    return owner->active_request == request
        && atomic_load_explicit(&request->cancelled, memory_order_acquire)
        && owner->native_phase == DUCKDB_ML_NATIVE_USER
        && !owner->native_closing && owner->connection;
}

CAMLprim value ml_duckdb_native_request_reserve_delivery(value v) {
    duckdb_ml_native_request *request = Native_request(v);
    if (!request || !request->owner) return Val_int(REQUEST_INELIGIBLE);
    connection_owner *owner = request->owner;
    if (!duckdb_ml_native_try_lock(owner)) return Val_int(REQUEST_INELIGIBLE);
    request_reserve_result result = REQUEST_INELIGIBLE;
    if (atomic_load_explicit(&request->reserved, memory_order_acquire))
        result = REQUEST_RESERVATION_PENDING;
    else if (native_request_eligible(owner, request)) {
        atomic_store_explicit(&request->reserved, true, memory_order_release);
        result = REQUEST_RESERVED;
    }
    duckdb_ml_native_unlock(owner);
    return Val_int(result);
}

CAMLprim value ml_duckdb_native_request_try_interrupt(value v) {
    duckdb_ml_native_request *request = Native_request(v);
    if (!request || !atomic_load_explicit(&request->reserved, memory_order_acquire))
        return Val_int(REQUEST_NOT_RESERVED);
    connection_owner *owner = request->owner;
    if (!owner || !duckdb_ml_native_try_lock(owner)) return Val_int(REQUEST_SKIPPED);
    request_interrupt_result result = REQUEST_SKIPPED;
    if (native_request_eligible(owner, request)) {
        duckdb_interrupt(owner->connection);
        result = REQUEST_DELIVERED;
    }
    duckdb_ml_native_unlock(owner);
    return Val_int(result);
}

/* Normal allocating ABI for private test linkage. Production neither waits nor
   releases the runtime; eligibility is checked by the actual noalloc entry. */
CAMLprim value ml_duckdb_native_request_deliver(value v) {
    CAMLparam1(v);
    CAMLreturn(ml_duckdb_native_request_try_interrupt(v));
}

CAMLprim value ml_duckdb_native_request_retire_delivery(value v) {
    duckdb_ml_native_request *request = Native_request(v);
    /* Only the sole selecting controller may retire. No CAS loop or ref-drop. */
    if (request) atomic_store_explicit(&request->reserved, false, memory_order_release);
    return Val_unit;
}

CAMLprim value ml_duckdb_native_request_uninstall(value v) {
    return Val_int(native_request_uninstall(Native_request(v)));
}

CAMLprim value ml_duckdb_native_request_dispose(value v) {
    duckdb_ml_native_request *request = Native_request(v);
    if (!request) return Val_true;
    if (request->state == DUCKDB_ML_REQUEST_INSTALLED) return Val_false;
    /* Clearing the custom slot makes every copied ML alias a tombstone. */
    Native_request(v) = NULL;
    free(request);
    released();
    return Val_true;
}

CAMLprim value ml_duckdb_live_resources(value unit) { (void)unit; return Val_int(atomic_load(&live)); }
CAMLprim value ml_duckdb_fallback_reclaims(value unit) { (void)unit; return Val_int(atomic_load(&fallback)); }

connection_owner *duckdb_ml_connection_ref(value v) {
    connection_owner *owner = Connection(v);
    atomic_fetch_add(&owner->references, 1); return owner;
}
void duckdb_ml_connection_unref(connection_owner *owner) { connection_delete(owner); }
duckdb_connection duckdb_ml_connection_handle(connection_owner *owner) { return owner->connection; }
void duckdb_ml_acquired(void) { acquired(); }
void duckdb_ml_released(void) { released(); }
void duckdb_ml_fallback(void) { atomic_fetch_add(&fallback, 1); }
