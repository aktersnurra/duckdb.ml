(** Scheduler-only Async requests. No scheduler starts at module initialization.
    An N-connection pool reserves N+1 shared Async system threads until explicit
    shutdown. Reservation failure opens no database; no global pool settings are
    changed. Keep Async and its thread pool alive until shutdown settles.

    Only successful uncancelled SQL-only requests reuse their connection. Every
    transaction (including success), error, exception and cancellation retires
    and replaces its connection before completion. No raw pool owner is exposed.

    All operations except pure Limits construction require the scheduler thread.
    execute/transaction/completion/cancel/shutdown reject calls from any adapter
    transaction callback with Reentrant_call before accessing Async. *)
type error =
  | Invalid_connections of int
  | Invalid_queue_capacity of int
  | Queue_full
  | Pool_shutdown
  | Cancelled
  | Reentrant_call
  | Core of Duckdb.error
  | Offload_unavailable of Core.Error.t

type exception_info =
  { exception_ : exn
  ; backtrace : Stdlib.Printexc.raw_backtrace
  }

type failure =
  | Expected of error
  | Raised of exception_info
  | During_cleanup of { primary : failure; cleanup : failure }
  | During_cancellation of failure

exception Request_failed of failure

module Limits : sig
  type t

  (** Connections must be positive; queue capacity nonnegative. Zero queue
      capacity permits only immediate dispatch. All int bounds are validated
      without computing connections+1. *)
  val create : connections:int -> queue_capacity:int -> (t, error) result
end

type t
type 'a request
type cancel_ack = Requested | Already_finished

(** Completes after all connections exist, or after attempted partial cleanup.
    Abandoning this Deferred does not cancel creation: retain the result and
    explicitly shut down the pool. No lexical/finalizer destruction promise. *)
val create : Limits.t -> Duckdb.Config.t -> (t, failure) result Async.Deferred.t

(** Immediate bounded FIFO admission; Queue_full retains no node or offload.
    Native SQL execution and its cleanup run entirely off-scheduler. *)
val execute : t -> string -> (unit request, error) result

(** One lease/offload spans BEGIN, the whole synchronous callback, child cleanup
    and COMMIT/ROLLBACK. Do not invoke Async or suspend in the callback. Return
    owned usable values only. An escaped token is dynamically revoked (Closed).
    Returning a Deferred directly is a type error; [Ok existing_deferred] can
    compile but is not awaited and does not extend the transaction lifetime. *)
val transaction : t -> f:(Duckdb.transaction -> ('a, Duckdb.error) result) -> ('a request, error) result

(** The same request-owned Deferred on every call. Settles once after Bridge
    return/controller retirement and pool accounting/required maintenance, before
    any exceptional notification to the submitting monitor. Dropping a Deferred
    or failing that monitor does not abandon the producer. Exceptional composite
    failures retain their constituents and raw traces, not serialized messages. *)
val completion : 'a request -> (('a, failure) result Async.Deferred.t, error) result

(** Acknowledges a persistent request latch, not delivery or cleanup. Pending
    repeats are Requested; terminal calls are Already_finished and cannot affect
    subsequent work. Queued/unentered work is suppressed. Cancellation winning
    before adapter terminal settlement changes classification but cannot undo
    already-admitted COMMIT/COPY or other durable effects. *)
val cancel : 'a request -> (cancel_ack, error) result

(** Idempotently stop admission, settle waiting work as Pool_shutdown, cancel and
    drain active work, close connections then database, and release helpers.
    Every call shares the same settled Deferred. Only the first explicit caller's
    monitor receives exceptional shutdown notification. Abandonment does not
    abandon closure. Failed close is reported, not retried or called reclaimed.
    Nonreturning work prevents shutdown; there is no timeout/recycle or bounded
    join guarantee. OOM/asynchronous bookkeeping, arbitrary signals, unsafe
    concurrency and finalizer/whole-process leak guarantees are outside scope. *)
val shutdown : t -> ((unit, failure) result Async.Deferred.t, error) result
