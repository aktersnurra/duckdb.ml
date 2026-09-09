# Stage4c Async vertical slice implementation plan

> For the single implementing writer: use interface-first TDD and executing-plans;
> the parent arranges independent review. No production implementation before
> independent design review. No commit, bookmark movement or publication authority.

**Goal:** A separately installable `duckdb-async` / `Duckdb_async` with bounded
SQL requests, explicit cancellation, complete synchronous transactions and shutdown.

**Architecture:** Public manual Duckdb owners, hidden behind a private synchronous
capsule, with explicitly owned lifetimes. Reserve **N request helper threads plus
one maintenance helper** from Async, all-or-nothing, before opening DuckDB. Submit
at most one job to each reserved helper; never use general-pool fallback. Bridge
alone owns native cancellation, controllers, reset/latch and engine retirement.

**Tech stack:** existing `stage1/run`, OxCaml 5.2.0+ox / 5.2.0minus39
(revision `2515546fea38e21e8143cc41db663bd56efc8d06`), Dune 3.22.2,
Base/Async v0.18~preview.130.106+341, DuckDB v1.5.5
(`d8cdaa33fda8df955cc76ef58a280f68f4cd43fa`). No dependency installation.

**Status:** Stage4c accepted after independent design and implementation reviews
and fresh parent build/full-regression verification; see
`docs/stage4c-validation.md`. The detailed task lists below retain the original
design-stage execution plan; the validation record records final evidence and
source-backed applicability decisions. Accepted/published Stage4b is master `82460786`; historical
“unpublished” and missing-Bridge text in older reports is not current API status.
At the design checkpoint, only this plan was a tracked authored change.
Design runtime/compiler probes, commands, hashes and checkpoint decisions remain in
`.local/stage4c/design/`; concrete report: `handoff.md` there.

## 1. Authority, exclusions and source decisions

Read the approved [specification](../specs/duckdb-design.md), the **entire**
[Stage4 plan](2026-09-08-stage4-adapters.md), completed
[Stage4b plan](2026-09-09-stage4b-bridge.md), Stage1–4b validation reports and
`.local/stage4b/finish-bridge/acceptance-review-recovered.json`.
The global Stage4 lifecycle/validation matrix applies unchanged except the
explicit engineering choices below, approved through the supervisor checkpoints.

- New production paths, after review: `lib/async/duckdb_async.{mli,ml}`,
  `lib/async/worker_owner.{mli,ml}`, `lib/async/dune`, `duckdb-async.opam`.
  Modify `dune-project` only to add that optional package.
- Tests: `test/async/dune`, `test/async/test_duckdb_async.{mli,ml}`,
  `test/async/test_support.{mli,ml}`, `test/async/async_hooks.c`,
  `test/async/check_interfaces.sh`, source-named `test/async/compile/` controls,
  `test/install_async_smoke.sh` and `test/installed_async/` templates.
  Add `examples/asynchronous.{mli,ml}` and its separate example stanza.
  Record executed gates in `docs/stage4c-validation.md`.
- `Worker_owner` is private, not a public pool framework. It separates synchronous
  resource authority from scheduler code; no getter returns a Duckdb owner.
  Keep queue/request logic in `Duckdb_async` unless actual size warrants review
  of another small private module. No scheduler functor, raw FFI conversion,
  `Obj` cast, fake portable/unique owner or core/private access.
- Core/FFI and accepted tests stay byte-for-byte unchanged absent a demonstrated
  defect and separate parent approval. Preserve the six paths in
  `.local/stage4b/preserved-six.sha256`, old Dune stanzas and generated `.pi/tasks`.
- No Eio adapter, typed query/ingestion/Parquet convenience expansion, remote
  storage, streaming cursor, performance claim, metadata/license invention or
  Stage5 deferral of basic cancellation/shutdown correctness.
- New development code uses explicit interfaces first, Base by default, Core
  only for Async/system types. Warnings-as-errors are development-only.

### Minimal alternatives and the selected mechanism

| Alternative | Evidence and decision |
| --- | --- |
| Persistent `with_database` / `with_connection` worker loops | Feasible only with an explicit synchronous command/completion transport and permanent workers. No scheduler wait is allowed inside these core scopes. Unnecessary: real public `open_database`, `connect`, `close_connection`, `close_database` already exist and owners may move between system threads. Do not invent a scoped continuation bridge. |
| General `In_thread.run` per queued borrower | Reject: invisible unbounded work queue, no admission bound. `thread_pool.ml:592–609` can retain unstarted work even after thread creation failure. |
| One reserved maintenance helper, general request jobs | **Rejected at checkpoint:** reserving the last usable thread can strand every general request, even with no external work. A one-thread Async pool is a concrete counterexample. |
| N request helpers plus one maintenance helper | Selected/approved. `Helper_thread.create_now` reserves an actual available/createable thread or returns Error; each request is routed directly to its own reserved helper. No request needs spare general-pool headroom. Reject creation before native acquisition if all reservations cannot be obtained. |
| Probe an uncertain connection with SELECT 1 | Reject as a cleanliness proof. Public Bridge does not expose an owner-health or discard-status getter; a transaction callback may swallow a failed rollback/discard. |
| Extend Bridge with a health getter | Not needed for this slice. Approved conservative policy: only successful, uncancelled adapter-owned SQL work can reuse; **every transaction callback**, even successful, and every error/cancellation/exception retires/replaces its connection. |

The chosen reservation cost is prominent public behavior: an N-connection pool
reserves N+1 shared Async system threads until shutdown, including while idle.
Idle helpers execute no blocked callback or core scope. Creation can fail despite
valid limits if other applications/pools hold those threads. This does not
reserve CPU cores or grant domain safety. It changes no Async configuration. The application must keep Async and its shared
thread pool running until shutdown completes; terminating the scheduler/thread
pool itself is not request cancellation. Ordinary private-helper submissions
reject before enqueue only on invalid/finished helper or finished pool in the
inspected source. Allocation/asynchronous failure after enqueue remains within
existing unsupported bookkeeping gaps, not permission to recycle its capsule.
Bridge may additionally start at most N independent system-thread controllers.

Pinned sources inspected: `_opam/lib/async_unix/in_thread.{mli,ml}` (helper
reservation/release and worker exception behavior),
`_opam/lib/async_unix/thread_pool/thread_pool.ml:561–728` (actual reservation,
direct helper queue, reject-before-enqueue and idempotent finish),
`_opam/lib/async_kernel/monitor.mli`, and
`_opam/lib/ocaml/threads/thread.mli:212–236` (real Thread.TLS).
Current `lib/duckdb/duckdb.mli:103–143` and `resource.ml:291–413` establish
manual ownership, close settlement and synchronous scope barriers; no private
function from those sources becomes an adapter dependency.

## 2. Compiled candidate public interface

The following exact declarations compiled as standalone `probes/candidate.mli`
and with `public_consumer.{mli,ml}` against the actual public Duckdb and pinned
Async. This is interface/consumer evidence, **not a linked adapter implementation**.
Production must repeat this gate against its own implementation and installed
consumer before freezing the package.

```ocaml
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
  val create : connections:int -> queue_capacity:int -> (t, error) result
end

type t
type 'a request
type cancel_ack = Requested | Already_finished
val create : Limits.t -> Duckdb.Config.t -> (t, failure) result Async.Deferred.t
val execute : t -> string -> (unit request, error) result
val transaction : t -> f:(Duckdb.transaction -> ('a, Duckdb.error) result) -> ('a request, error) result
val completion : 'a request -> (('a, failure) result Async.Deferred.t, error) result
val cancel : 'a request -> (cancel_ack, error) result
val shutdown : t -> ((unit, failure) result Async.Deferred.t, error) result
```

### Public semantics, not stronger type promises

- Limits require connections > 0 and queue_capacity >= 0. All OCaml ints are
  finite; avoid `connections + 1` overflow by reserving maintenance first then
  decrementing a request-helper count. Reserve before allocating N-element
  resource arrays. A huge valid limit normally fails reservation, not silently
  truncates. Q=0 admits only an immediately available slot.
- `create` is **scheduler-only**; it starts no scheduler. Limits construction is
  pure. Creation resolves after full initialization or complete attempted cleanup
  of partial initialization, not after merely opening the database. The pool
  stays private until initialization succeeds. Dropping create's Deferred is not
  cancellation; callers must retain its result and explicitly shut down a created
  pool. This manual lifecycle is not a lexical/finalizer destruction promise.
- `execute` submits exactly core SQL execution, discarding results. It performs
  no native/filesystem work on the scheduler. `transaction` leases once for
  BEGIN, complete synchronous callback, binding/materialization/fetch/child
  cleanup and COMMIT/ROLLBACK. Existing token API is available on that worker;
  this does not add typed adapter conveniences.
- Both return immediate admission results: overflow/shutdown/reentrancy retain
  no queue node, create no Bridge/controller/offload and capture no monitor.
  Accepted requests have fresh object identity, no wrapping generation counter.
- `completion` returns the same adapter-owned Deferred on every permitted call.
  It resolves once only after Bridge settlement and pool accounting/maintenance
  for that lease. The outer result permits synchronous reentrancy rejection.
  Deferred abandonment alone does not cancel, abandon accounting, or close a pool.
- `cancel` acknowledges a latch, not interruption delivery, rollback, cleanup,
  or completion. Repeated pending calls return Requested; terminal calls return
  Already_finished and cannot change outcome. Queue cancellation completes with
  Expected Cancelled. Running native interruption may return a native diagnostic;
  During_cancellation retains it. No message-string cancellation classification.
- `shutdown` outer Error Reentrant_call is immediate and does not initiate stop.
  Otherwise it returns the **same** pool-owned settled shutdown Deferred each
  time, even after completion. The first explicit shutdown caller's monitor receives
  exceptional shutdown notification; later callers share the result, not duplicate
  sends. If internal replacement failure initiated stop first, its request already
  retains that failure; the first explicit shutdown call attaches the sole shutdown
  observer, also when the outcome is already determined. Notification is scheduled
  after the shared completion, never part of resource/accounting authority.
- `execute`, `transaction`, `completion`, `cancel`, `shutdown` reject use from
  **any adapter transaction callback**, including against a different pool,
  before touching Async. Use one adapter-module `Thread.TLS` boolean, set around
  the synchronous user callback and cleared in `Exn.protect` on every exit.
  It is not a thread-ID registry; reused helper threads have no stale identity.
  Other arbitrary non-Async threads remain outside the scheduler-only contract.
  `create` has a scheduler-only precondition, not a promised result-valued guard.
- No callback suspension is supported. The compiler rejects returning a Deferred
  directly in place of a synchronous result, but **accepts `Ok existing_deferred`**
  because `'a` is polymorphic. It does not await that Deferred. Likewise an escaped
  transaction token can compile but is dynamically revoked (`Closed`). Only owned
  usable data should be transferred; no static effect purity/destruction claim.
  Borrowed chunk capture by offload is separately rejected as local/global.
  The runtime core barrier rejects outward effects, not every ordinary Async
  function call: callers must not invoke Async in the callback.
- Nested adapter admission is Reentrant_call, not a second checkout. The core's
  existing original-connection nesting is Busy; no raw owner is exposed to allow
  accidental same-owner nesting. No savepoints/nested-transaction API.

## 3. Lifetime graph and transition authority

```text
pool-owned scheduler producer + pool t
  -> N+1 reserved helper capabilities
  -> opaque Worker_owner.database (manual live database)
  -> N slot descriptors
       -> opaque Worker_owner.slot (manual connection)
       -> at most one admitted request/completion producer
            -> fresh Bridge.request
            -> worker closure -> synchronous Bridge facade -> transaction/children
                                  -> Bridge controller/native request roots
```

Only Worker_owner's synchronous functions can see database/connection handles.
Scheduler code may retain opaque capsules but cannot execute Duckdb operations on
an extracted owner. The capsule has no pointer/owner getter and is a private Dune
module. Its operations are invoked only in an `In_thread.run ~thread` closure.
Opening/connecting/closing occur on maintenance; requests run on their slot helper.
Manual owner validity spans those separate jobs. It does **not** depend on a live
`with_database` callback or an Async effect crossing a core scope. Bridge and
transaction scopes open and close entirely inside the request computation.

Worker closures, active producer callbacks and slot descriptors retain capsules
until joined settlement/close. User pool abandonment is not finalizer-driven
shutdown. Once shutdown starts, a pool-owned producer roots closure to completion
independently of shutdown callers. Database close is attempted only after all
slot close attempts and after all admitted workers/Bridge controllers settle.
Native shell retention is not the argument for live engine validity; exclusive
slot ownership plus Bridge's accepted lease/retirement guarantee is.

### One authority per state, with explicit cross-thread gate

Scheduler-only pool states: **Initializing -> Accepting -> Stopping -> Stopped**.
Initialization failure goes directly to protected cleanup then Stopped, never
publishes an Accepting pool. Explicit shutdown or first maintenance failure owns
the sole Accepting -> Stopping transition. Subsequent failures append outcomes
to the same bounded drain, never start another shutdown or replacement loop.

Scheduler-only slot states: **Idle -> Leased -> Maintenance -> Idle**, or
**Idle/Leased/Maintenance -> Closing -> Closed/Close_failed** under stop.
A Leased slot remains charged while dispatched, executing, returning or awaiting
maintenance. Worker return alone is not Idle. Replacement closes old before
connecting new; shutdown never publishes a completed replacement as Idle.

Scheduler-only request states: **Queued -> Dispatched -> Settling -> Finished**.
Queued cancel/shutdown removes its actual node then moves to Finished. The
scheduler does not pretend it instantaneously observes a worker start. Each
Dispatched request additionally has a short mutex-protected execution gate:
**Awaiting_entry -> Executing -> Returned** plus a persistent cancellation latch.
The worker owns entry/return transitions; scheduler cancel owns latching under
that same gate. After entry the worker calls Bridge.run, which independently
checks the native/request latch before user work. No SQL/callback/Async call or
join holds this mutex. Gate return is published with a captured outcome.

This separates actual Running from scheduler accounting without racing mutable
scheduler records on worker threads. Mutex order: never hold the execution gate
while calling Bridge.cancel, taking another pool/request lock, scheduling, or
waiting. No scheduler mutation from workers. Bridge retains its own accepted
owner/request/native lock order unchanged.

### Bounds and FIFO proof

1. Admission selects an Idle slot only if the surviving queue is empty; otherwise
   append at tail if length < Q, else reject before allocating retained work.
   Removing a cancelled node frees capacity immediately. Use explicit removable
   nodes (e.g. Base.Doubly_linked), not permanent cancelled tombstones.
2. Dispatch takes the oldest surviving node and one Idle slot. Charge before
   submitting. A slot gets at most one outstanding request-helper job; next job
   is submitted only after its previous completion/accounting. The Q queue is
   never submitted to Async. No thread per waiting borrower.
3. Maintenance descriptors are the existing N slots needing retirement/close;
   at most N, with **one** job submitted to the maintenance helper. Initialization
   and final database close each have a single producer/control descriptor.
   Do not enqueue one extra deferred closure for each repeated shutdown/cancel.
4. At most N connection-bearing leases exist across dispatched/running/settling.
   Same-slot maintenance starts only after its request worker has returned and
   Bridge has settled; these are sequential uses of one charged slot, not an
   additional live connection. Close-before-connect keeps live connections <=N.
5. Reserved helper threads: exactly N+1 on success (at most that many in partial
   acquisition), no adapter-created transient Async threads. Concurrent executing
   request computations <=N; maintenance <=1; Bridge controllers <=N, zero for
   waiting or unentered requests. No hidden queue of controller jobs.
6. Occupied request helpers cannot starve maintenance; each has an actual distinct
   reserved thread. Interrupt progress uses Bridge's independent controller.
   All-or-nothing actual reservation eliminates the rejected last-general-thread
   counterexample. This is progress independence, not a latency/deadline guarantee.
7. `finished_with` is called explicitly once per held helper after its final job
   and pool accounting; clear the owned helper collection afterward. Partial
   reservation failure releases the successful prefix before any native open.
   Never rely on the helper finalizer or submit after releasing it.

## 4. Cancellation, settlement and diagnostic policy

The adapter terminal point is the scheduler's single **Finished** transition,
after Bridge has returned/raised and slot disposition/accounting is fixed.
Cancellation latched before that transition wins classification, including after
Bridge's own terminal return; cancellation afterward is Already_finished. If
Bridge.cancel reports Closed in that interval, do not treat it as successful
native delivery or erase the adapter latch. Its fresh request cannot affect B.

| Request point | Action and evidence required |
| --- | --- |
| Queued | Unlink node, clear retained callback/SQL, fill Expected Cancelled. No Bridge/native/filesystem/offload work. Shutdown instead fills Expected Pool_shutdown. |
| Dispatched, not entered | Latch gate and Bridge request. **Do not free slot/capsule or release helper**: the already queued helper closure may still run. It must acknowledge return without SQL; only then settle/account. Shutdown follows exactly this protocol. |
| Executing | Latch and call Bridge.cancel outside adapter mutex. Bridge handles reset gaps, native eligibility, selected tickets, actual delivery and join. No adapter interrupt loop, signals or worker termination. |
| Returned / Settling | Latch may still change classification, not returned diagnostics or durable effects. Conservative cancellation forces retirement even if successful SQL would otherwise reuse. If maintenance has already produced a fresh idle candidate, classify before publishing it. |
| Finished | No new latch, interruption, queue mutation or outcome change. |

Reusable proof is deliberately narrow: normal uncancelled `execute` success,
no arbitrary callback, no retained child and complete Bridge return, with no
maintenance failure. All other requests retire; successful transaction output
is delivered only after old close/replacement accounting. Bridge actual Delivered
already discards internally; adapter idempotent close handles that case. This
extra conservative retirement is **not** a change to Bridge's more permissive
no-actual-delivery/ordinary-rollback reuse semantics.

On stop, retire but do not replace. If close fails, record Close_failed, never
retry indefinitely or advertise it as clean. Attempt remaining independent
closes and then database close, preserving their diagnostics (including a parent
Live_children failure), not overriding them with success. A failed close is a
reported failure, not proof of reclamation. Ordinary supported close completes;
arbitrary external corruption/OOM/asynchronous-bookkeeping faults remain limits.

### Failure algebra and exceptional monitor transport

- Core Error e becomes Expected (Core e); normal core Cancelled with a latched
  adapter cancellation becomes Expected Cancelled. Preserve core Rollback_failed,
  Rollback_exception, Cleanup_exception and Base.Exn.Finally constituents; do not
  serialize/stringify them or catch them as an ordinary Native_error.
- Capture exceptions and raw backtraces **inside** every offload, before crossing
  In_thread. Capture synchronous submission exceptions outside `In_thread.run`
  too. Existing core composite exceptions carry their retained constituents;
  an adapter-created cleanup composite additionally retains each capture's trace.
- Primary failure plus cleanup/replacement failure becomes During_cleanup. If
  primary succeeded but cleanup failed, completion is that failure, not success.
  Multiple independent cleanup failures form a deterministic acquisition/slot-order
  tree using During_cleanup; bound this tree by resources/requests, not retries.
- Cancellation + otherwise-success => Expected Cancelled. Cancellation + independent
  non-success => During_cancellation primary (including cleanup tree). Do not
  duplicate an already pure Cancelled into a redundant wrapper. Suppressed queued
  shutdown is Pool_shutdown; active shutdown cancellation follows the same latch
  rule and does not erase primary/cleanup errors.
- An exception-containing failure notifies the **submitting** monitor once,
  after completion/accounting. Pure expected failures do not notify monitors.
  A sole Raised sends its original exception with its original `This backtrace`;
  a composite containing exceptions sends Request_failed full_tree with the first
  retained exceptional trace. The same full tree is always observable in completion.
  Do not send each constituent separately. Record the chosen order in tests.
- Request failures remain in request completions. Pool shutdown aggregates
  lifecycle/maintenance/close failures, not an unbounded history of all SQL
  errors. A maintenance failure belongs both to its affected request completion
  (with its primary) and the pool's single drain outcome. Do not repeatedly notify
  the same request monitor because repeated shutdown reads that outcome.

The essential producer runs in a **pool-owned detached monitor**, not the caller's
`Monitor.try_with` scope. Capture caller Monitor.current at admission before
entering the producer context. Submit and register completion continuations in
`Scheduler.within_v ~monitor:pool_monitor`; catch synchronous failures directly,
not by hoping a monitor produces a raw result. The pool monitor's handler must
not invoke user callbacks as part of accounting. All expected failures and injected
ordinary worker/dispatch/maintenance exceptions follow the explicit outcome path.
Unexpected internal monitor failure triggers the same one-stop/drain path and is
retained; it is not swallowed or treated as a resolved raw In_thread deferred.

Never join the raw deferred of an *uncaught* worker exception: pinned In_thread
sends the exception but leaves its result Ivar empty. Our worker always returns
its captured outcome under the supported ordinary-exception contract. No worker
uses Ivar/Monitor/Scheduler APIs or calls Thread_safe.block_on_async. Scheduler
sets slot state, frees admission, fixes terminal outcome and fills completion
before sending any exceptional notification. A failed/detached observer cannot
abandon that sequence. Do not run arbitrary user continuation inline in accounting.

## 5. Initialization, replacement and shutdown sequence

**Initialization:** validate Limits before create; reserve maintenance + N request
helpers synchronously with create_now (no native resources yet). Catch both Error
and ordinary exceptions, release each successful reservation exactly once, retain
release exceptions with the original if any. After reservation, offload open and
sequential connects on maintenance. Maintain an acquisition ledger immediately
on each successful return. On first open/connect failure, close every acquired
connection, then database, capture every close outcome, then finish helpers.
Publish t only after all connections exist. No retry/partially initialized pool.

**Replacement:** after Bridge return, the slot remains charged in Maintenance;
serialized maintenance closes old and, only while still needed, connects once.
Scheduler is final authority to publish the result. If Stopping won while a
connect was in flight, close the returned candidate, never expose Idle. Connect
failure records the original and makes the pool Stopping once. Cancellation of
the associated request does not cancel the sole maintenance producer. A pending
replacement never requires an idle request slot or new shared thread.

**Shutdown:**

1. Check callback TLS before any Async access. First permitted call fixes Stopping,
   retains shutdown monitor/outcome producer, and rejects all further admission.
2. Remove/settle all queued requests as Pool_shutdown without work; request
   cancellation of every dispatched/running request. Keep dispatched capsules and
   helpers rooted until the queued helper closures actually return.
3. Drain each captured worker outcome; Bridge returns only after native completion,
   selected retirement/controller join, core transaction/child settlement and any
   core discard. No timeout/recycle. Ordinary rollback admitted before cancellation
   can retain its sole ineligible controller until terminal settlement as accepted.
4. Serialize every slot close (idle slots included), allowing progress while
   other slots still run; never close the *same* slot while its worker is active.
   Settle affected request accounting/completions before their monitor sends.
5. After all slot work/close attempts, close database on maintenance. Capture all
   failures without skipping independent remaining cleanup. Resolve one shutdown
   result only after all helper jobs return and explicit finished_with calls.
   Repeated/concurrent calls receive that same result. Caller abandonment is irrelevant.

A nonreturning callback/foreign/filesystem call can prevent shutdown completion;
there is no bounded join promise. This caveat is not an excuse for adapter-created
headroom deadlock, unbounded hidden queues or abandoned completion channels.
Cancellation can follow already-admitted COMMIT/COPY/link; do not infer absent
writes/files, undo committed changes or unlink final output. Only owned temporary
resources belong to cleanup. No SQL policy broadening or remote convenience.

## 6. Prototype evidence and what it does not establish

Reproduce from repository root:

```sh
stage1/run build lib/duckdb/duckdb.cma
bash .local/stage4c/design/compile.sh
bash .local/stage4c/design/probe-dune.sh build probe.exe
timeout 40 bash .local/stage4c/design/probe-dune.sh exec --no-build ./probe.exe
python3 .local/stage4c/design/mutations.py
sha256sum --check .local/stage4b/preserved-six.sha256
```

- `02-interface-red.log`: absent implementations after explicit probe interfaces,
  intended Dune missing-modules rejection. `03-interfaces.log`: standalone actual
  public interfaces plus paired consumer compile before bodies.
- `06-modes.log`: five rejections at exact source/value/type/mode: borrowed chunk
  capture, Deferred-as-callback-result, pool domain transfer, forged request and
  opaque capsule-as-connection. Owned controls compile; Ok(existing Deferred)
  intentionally compiles as a **limitation**, not async-transaction permission.
- `05-probe-run.log`, `10-restored-green.log`, `12-tls-run.log`: actual manual
  capsule created on maintenance, moved to request helper for Bridge SQL and
  complete transaction, token revoked, outward effect denied, then maintenance
  closes/replaces and finally closes database. No raw owner leaves capsule.
  Real reuse of successful SQL and replacement after a transaction both run.
- Actual capacity exhaustion after 50 reservations on this unchanged Async pool;
  a subsequent attempted acquisition rejects, zero native resources. Injected
  create failures at positions 0/1/2 prove partial-release bookkeeping. Releasing
  permits successful new reservations. Post-finished_with submission rejects
  synchronously before its worker flag. **Exact one-thread configuration is a
  source proof, not a runtime test or configuration change.**
- Held request helper plus actual reserved maintenance execution proves routing
  independence. This is an ML entry/release gate, **not** a native-heartbeat or
  adapter-wide cancellation test. Actual native heartbeats remain implementation
  gates below; accepted Stage4b evidence is not relabelled new adapter evidence.
- Caught worker exception/backtrace survives a failed, abandoned caller monitor;
  completion/accounting precede one send. Injected synchronous dispatch fails
  before submission, not actual OS failure. TLS guard compiles and demonstrates
  active set, exception clear, reused-helper clear and scheduler-thread clear.
- `08-mutation-red.log`: independently removing only partial-reservation release
  builds, then fails `partial reservations released exactly once`, exit 1, no
  timeout. Backup and restoration hashes retained; restored build/run pass.
- Live binding resources and fallback counts end at zero without GC. A small
  test-only count-only `duckdb_open_ext` linker wrapper additionally asserts zero
  native open calls on reservation failure and exactly one in the paired successful
  capsule lifecycle; strict C11 warnings-as-errors passes. No production C change,
  new sanitizer or installed-adapter claim; candidate API has no implementation yet.

The prototype is intentionally not a miniature production pool. It proves the
new public lifetime/thread routing and candidate modes; the complete state-machine
races, resource fault injection, exactly-once composites and package installation
remain mandatory implementation gates, **not unresolved design choices**.

## 7. Interface-first implementation tasks and red/green gates

Each task snapshots diff/source hashes first and appends exact commands, exits,
source diagnostics/counters to `docs/stage4c-validation.md`. Keep the phase's
ignored handoff concrete. Parent review may reject a task independently; a
partially implemented package is never described as accepted Stage4c.

### C1 — Owner capsule, reservations and lifecycle skeleton

Files: new library/package metadata, Worker_owner interfaces/bodies, public
Duckdb_async interface, test support and initial test interfaces/Dune targets.

- [ ] Copy the compiled declarations, with the semantics above as public docs;
      compile standalone paired consumer before implementation. Worker_owner
      consumes only Duckdb's public Config/Bridge/manual lifecycle/transaction.
      Its prototype `.mli` supplies exact capsule signatures; keep test-only
      `transaction_revocation`/`effect_barrier` out of production.
- [ ] Write tests `invalid_limits`, `reserve_partial_failure`,
      `reserve_real_capacity_failure`, `initialize_connect_failure`,
      `shutdown_idle`, `initialize_close_composite` before bodies.
      Core assertion for every reservation failure: native_open=0,
      released_helpers=successful_reservations, live/fallback unchanged.
      Invalid 0/-1 connections and -1 queue reject; 1/0 accepts; max_int validation
      does not overflow bookkeeping. Fault at each connect index closes prior
      slots before database; close fault preserves initial failure too.
- [ ] Run `stage1/run build test/async/test_duckdb_async.exe`; require missing
      declarations/implementation before code, not a Dune typo. Implement finite
      reservation ledger and serialized maintenance acquisition/cleanup. Explicitly
      release helpers on all supported initialization exits; no GC dependency.
- [ ] Run the same build and `stage1/run runtest test/async --force`; partial-init
      and idle shutdown must be green, resource/call-order counts named. A test
      linker wrapper can fault real open/connect before/after entry; counter-only
      FFI use in tests is permitted, no adapter FFI owner conversion.

### C2 — Admission, dispatch and completion transport

Files: `duckdb_async.ml`, test/support/interface controls; retain C1 interfaces.

- [ ] Tests first: `fifo_survivors`, `overflow_no_offload`, `zero_queue`,
      `queued_cancel`, `dispatched_cancel`, `dispatch_exception`,
      `callback_guard`, `worker_exception_monitor`, `abandoned_completion`.
      Hold A, queue B/C, reject D: offloads=1, queue=2, retained overflow nodes=0.
      Cancel B; release A; C executes once and FIFO surviving order holds.
- [ ] Add a test-link-only worker-entry gate before adapter/Bridge admission,
      cancel after dispatch but before opening gate: SQL/COPY/file counters=0,
      completion pending and slot not closed until worker-return acknowledgement.
      Keep controls distinct from an already-running native-entry gate.
- [ ] Implement the scheduler and execution-gate states in §3, removable queue,
      capture-inside offload plus capture-outside dispatch, detached pool producer,
      final terminal/accounting/completion-before-monitor sequence. Inject callback
      and cleanup exceptions separately; assert original identities/source traces
      and whole failure tree, not string equality. Pure expected errors send zero.
- [ ] Test TLS guards for all five protected operations from same/different-pool
      callbacks; require Reentrant_call before touching Async. After callback error
      or exception, a new request on that helper must not see a stale marker.
- [ ] Compile source-named public positives/negatives, including the intentionally
      accepted Deferred-value limitation. Independent mutations remove queue bound,
      dispatch gate check, prefix helper release and pre-monitor accounting one
      at a time; each must build and fail its named assertion without timeout.
      Restore exact bytes in finally and rerun focused green after each.

### C3 — Complete native cancellation, disposition and transactions

Files: adapter logic; `test/async/async_hooks.c` and source-named tests.

- [ ] Add real tests from rows N1–N8 below before adjusting production. Use
      accepted test-link patterns from `test/native_delivery/delivery_hooks.c`
      and `test/adapter_bridge_responsiveness_hooks.c`, not production setters
      or duplicated production C. Declare new test `.mli`/externals first.
- [ ] Running cancellation must show actual interrupted native result + foreign
      return, Bridge settled and join before close/replacement, not just wrapper
      entry or a timer. Preserve first-interrupt/reset control separately.
- [ ] Enforce approved disposition: successful SQL reuse; all transactions/error/
      cancellation/exception close+replace exactly once. Swallowed transaction
      rollback failure cannot return an uncertain owner Idle. Replacement failure
      enters Stopping once, preserves affected request primary and replacement/
      close errors, settles queue and drains others. No retry or health query.
- [ ] Keep entire synchronous transaction inside one helper/Bridge call. Hold
      A between two writes while competing B waits (N=1); B cannot execute on A's
      lease. Observer sees commit/rollback facts. Pre-COMMIT cancellation blocks
      commit even if callback ignores error; post-COMMIT may show a durable row.
- [ ] Run focused suite and five race repetitions. Independent mutation of early
      release must fail held-close/selected-retirement assertion, and stale-A
      misrouting must fail the named zero-B-interrupt assertion. Never remove
      extra independent defenses merely to manufacture a red; report redundancy.

### C4 — Full shutdown and failure settlement matrix

Files: adapter lifecycle and shutdown tests; no API mode changes without checkpoint.

- [ ] Tests first: every S row below, including dispatched helper closure still
      queued, active native work, ordinary rollback already admitted, held close,
      in-flight replacement and failed caller monitors. Concurrent callers must
      receive the same settled shutdown outcome and no duplicated helper release.
- [ ] Implement §5 drain. Stop admission once; resolve queued named shutdown
      errors; cancel active and keep all roots through return. Shutdown cannot
      wait on its own callback, cancel the sole producer, or release helpers before
      their last completion callback has performed accounting.
- [ ] Fail queued/dispatch/worker/callback/result/native/rollback/cleanup/close
      points independently, then pair primary+cleanup+cancel. Retain both expected
      errors and actual exceptions/backtraces. Multiple close failures still
      attempt all independent remaining owners and report database close outcome.
- [ ] Every test failure path sets all release gates **before** joining admitted
      work; watchdogs detect process failure, never authorize reuse. Injected
      heartbeat/assertion failure must exit at its named assertion, not timeout.
- [ ] Independent mutations publish replacement after stop, fill completion early,
      or release helpers before last job: require named red and byte restoration.
      Run all shutdown rows plus full Stage1–4 regression before review.

### C5 — Responsiveness, example and installed optional package

Files: async hooks/tests, standalone example/Dune stanza, new install script and
installed consumer templates, final validation document. No preserved smoke edits.

- [ ] Implement N9 native heartbeat matrix below. Each gate is in actual unlocked
      native work and observes runtime-lock state; never artificially unlock a
      noalloc entry or reinterpret ML-worker waiting as native responsiveness.
      Reuse the accepted locked-engine observer/negative-control design.
- [ ] Example creates a finite pool, issues SQL plus two-statement synchronous
      transaction returning owned data, obtains explicit request completion,
      and always awaits shutdown even following result/exception failure.
      Prints a named completion banner. No Eio or scheduler startup at library load.
- [ ] New smoke hash-copies current `lib`, root package metadata and dune-project
      into `.local/stage4c/installed/producer`. Exclude sibling Eio source/package
      before build. Invoke pinned Dune **from producer cwd**, `-p duckdb-ffi`,
      `-p duckdb`, `-p duckdb-async` with single-component relative build dirs;
      install FFI then safe then Async into the private prefix. Do not combine
      `-p` and `--root`; do not use external/nested private_dirs build layouts.
- [ ] Hide entire producer before independent consumer build, using only prefix
      and pinned dependencies in OCAMLPATH. Audit actual compiler -I arguments,
      META/dune-package and native loader (prefix/_opam only; no producer/source
      _build/.private include paths, rpath or sibling Eio dependency).
      Run SQL, transaction, cancel, repeat completion/shutdown public consumers
      and the asynchronous example without Eio. Reject private Resource,
      Worker_owner, forged request/pointer, domain and borrowed source controls.
      Require no adapter scheduler/controller startup at module initialization.
- [ ] Run all final commands below and independently review complete Stage4c.
      Installed Dune smoke is **not** an opam solver/install claim. Missing
      publication/license metadata remains explicitly unresolved, not invented.

## 8. Required causal test matrix (all in Stage4c)

Use named test selectors in `test_duckdb_async.exe -- CASE`; every row appears
in the validation report with exact command, native/worker/queue/helper/resource
counters and failure outcome. SQL-only convenience scope does not waive cleanup
of typed child work used by a transaction callback.

| ID / selectors | Causal ordering and mandatory oracle |
| --- | --- |
| A / admission selectors in C1/C2 | N=1/Q=2 held A, surviving FIFO, immediate overflow no node/offload, Q=0; queued cancel repeated/terminal; pending dispatch retains capsule until acknowledged, zero SQL/filesystem. |
| N1 `running_reset`, `all_slots_cancel` | True native execute gate, persistent cancellation across pre-engine/reset and actual interrupted errors. N=2 request helpers occupied, maintenance heartbeat + independent Bridge delivery both progress, no global pool change. Count distinct connections/controllers. |
| N2 `cancel_at_return`, `cancel_at_terminal` | Hold foreign return, then core settlement and scheduler terminal separately. Cancel before Finished wins diagnostic wrapper; after Finished unchanged/Already_finished. Repeat cancel at each point. |
| N3 `selected_retirement`, `stale_reuse`, `stale_replacement` | Hold A selected delivery; no detach/close/reuse before retirement/join. After successful SQL A reuse, hold B natively and send delayed A.cancel: zero B interruption. Repeat after A cancellation/transaction replacement with new capsule/identity. |
| N4 `transaction_exclusion`, `nested_rejected`, `token_revoked` | Two statements under one lease, competing borrower cannot interleave; adapter nesting reentrant vs existing core Busy; escaped tx dynamically Closed, borrowed mode controls unchanged. |
| N5 `pre_commit_cancel`, `post_commit_cancel` | Real before-decision vs after-real-COMMIT gates, swallowed cancellation cannot commit before admission; observer rows document post-entry durable caveat. SQL COPY/file work cancelled before dispatch must never enter filesystem. No final-output deletion. |
| N6 `ordinary_error`, `rollback_failed`, `callback_raised`, `cleanup_raised` | Native/result/callback/worker/dispatch failure classes preserved, original raw backtraces plus composite cleanup; uncertain owners retire, zero successful-reuse claims from SELECT 1. Swallowed inner failure + Ok still retires transaction connection. |
| N7 `replacement_failed`, `replacement_stop` | Close old before new connect; injected connect fails once, one stop/drain, queue shutdown, original/close/connect outcomes observable. Hold connect while stop wins; candidate closes, never Idle, no retry. |
| N8 `monitor_once`, `abandoned_failed_monitor` | Actual Bridge exception with held rollback/destruction, failed/detached caller before worker release. Completion and accounting first, one exceptional send, pure errors zero sends, full primary+cleanup+cancel tree retained. Caller does not own producer. |
| N9 `heartbeat_*` | Actual open/connect, execute, fetch, result/chunk/prepared/appender clear/destroy, rollback, disconnect and database close. Cover normal and ordinary cancellation paths reachable through SQL/transaction. Scheduler observes true entry, acknowledges while held, completion after acknowledgement; runtime/finish-depth observer requires zero ordinary locked-engine destruction. File work exposed by raw SQL/transaction receives real COPY/file-work heartbeat where reachable; dedicated Parquet adapter API is not added. |
| S1 `shutdown_queued`, `shutdown_dispatched`, `shutdown_running` | One stop-admission transition, queued Pool_shutdown with zero work, dispatched closure returns before same-slot close, active foreign return/controller join before close; no new admission after stop. |
| S2 `shutdown_settling`, `shutdown_replacing`, `shutdown_closing` | Hold cleanup/replace/close; shutdown pending, no Idle publication/no parent close while child active; maintenance independent of occupied request slots. |
| S3 `shutdown_concurrent`, `shutdown_repeated`, `shutdown_abandoned` | Physical shared completion/result, one close per owner/helper release, caller monitor failure/drop cannot abandon closure. Reentrant shutdown fails immediately before Async API. |
| S4 `init_partial`, `multi_close_failure`, `shutdown_exception` | Acquired-prefix cleanup, initial+cleanup tree, remaining independent attempts after failure, named reported close failure not “closed”; no unbounded retry, all captured producers terminate when native calls return. |
| F `failure_release_join`, `held_lock_negative` | Controlled failed handshake/assertion releases every gate before mandatory joins; named red, not watchdog or timeout. Native independent releaser handles broken held-runtime negative without needing blocked scheduler. |
| I `installed_*`, `example` | FFI -> core -> Async, sibling absent, producers hidden, exact include/native paths; public run and intended type/privacy rejections, no startup at module init. |

Final commands (future production gates, **not claimed executed in this design**):

```sh
stage1/run build @all
stage1/run runtest test/async --force
stage1/run runtest --force
stage1/run runtest stage4 --force
for iteration in 1 2 3 4 5; do
  timeout 120 stage1/run exec --no-build test/async/test_duckdb_async.exe
done
bash test/install_async_smoke.sh
stage1/run exec examples/asynchronous.exe
clang -std=c11 -Wall -Wextra -Werror -fsyntax-only \
  -Ilib/ffi -I.deps/duckdb -I_opam/lib/ocaml test/async/async_hooks.c
ASAN_OPTIONS=detect_leaks=0:halt_on_error=1 UBSAN_OPTIONS=halt_on_error=1 \
  timeout 120 stage1/run exec --profile stage3a-sanitize \
  --build-dir "$PWD/.local/stage4c/build-sanitize" test/async/test_duckdb_async.exe
sha256sum --check .local/stage4b/preserved-six.sha256
```

No timeout is a passing cleanup bound. Authored-C sanitizer instrumentation
excludes prebuilt DuckDB/runtime/Base; `detect_leaks=0` does not fix the known
unsuppressed whole-process LSan failure. OOM/asynchronous acquisition/bookkeeping
gaps, arbitrary/repeated signals, nonreturning work, invalid unsafe concurrency,
finalizer responsiveness and process/hostile-filesystem limits remain explicit.

## 9. Design gate checklist

- [x] Real public manual lifetime and Bridge API read, no invented scope/owner seam.
- [x] Supervisor checkpoint approves candidate signatures, conservative disposition;
      second checkpoint approves N+1 reservation headroom correction.
- [x] Standalone interfaces/paired consumer and source-specific mode controls compile.
- [x] Public capsule cross-thread lifetime, helper capacity/reclamation/progress,
      exception transport and TLS cleanup mechanisms compile/run; honest limits.
- [x] Concrete admission/settlement/shutdown authority, failure algebra, helper release
      and all required Stage4c race/example/install gates mapped to tasks.
- [x] Independent design review.
- [x] Production C1–C5, independent implementation review and parent full validation.

Stage4c is accepted within the limits in `docs/stage4c-validation.md`.
Stage4d typed conveniences, Stage4e/f Eio and Stage5 soak/performance remain later
work. Acceptance does not authorize publication.
