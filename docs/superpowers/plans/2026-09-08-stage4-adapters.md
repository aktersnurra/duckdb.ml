# Stage 4 adapters implementation plan

> For the implementing worker: use writing-plans/executing-plans, interface-first TDD, and one writer. Each accepted slice requires independent specification and implementation review, arranged by the parent. Do not launch workers from this plan. This run is planning only: no commit or publication.

**Goal:** Implement separately installable Async and Eio adapters with bounded admission, exclusive connection leases, correctly routed cancellation and deterministic resource settlement before reuse.

**Architecture:** Keep the synchronous core scheduler-free. Establish the missing lifetime/operation-identity interruption contract before exposing adapters; implement scheduler-specific admission and completion routing separately. Initially run complete synchronous transactions and owned-result computations in each runtime's system-thread facility, rather than suspending a core scope or transferring a borrowed view.

**Tech stack:** pinned OxCaml `5.2.0minus39` (`5.2.0+ox`), Dune `3.22.2+ox` (binary `3.22.2`), Base/Async `v0.18~preview.130.106+341`, Eio/Eio_main `1.3+ox`, public DuckDB C API `v1.5.5`, Base/threads, existing handwritten FFI.

**Status:** Plan, not adapter completion. Stage3c `8bb77a2f` is the accepted parent. Stage4a prerequisite evidence is the first runnable milestone; no new public ownership signature is frozen here. Recovered from the original planning artifact on the user-authorized same-protocol resume and persisted at `docs/superpowers/plans/2026-09-08-stage4-adapters.md`. Independent plan review and focused rereview passed. The review's noalloc-fixture finding is corrected by the ML interrupt-ticket gate below. Stage4a evidence implementation is authorized; public bridge and adapter acceptance remain gated. Planning produced no production implementation or publication.

## Global constraints

- Read `AGENTS.md`, `docs/superpowers/specs/duckdb-design.md`, and `docs/stage1-validation.md` through `docs/stage3c-validation.md`; keep their bounded guarantees and explicit limitations.
- Full OxCaml, not upstream OCaml compatibility. Existing `stage1/run` and `.deps/duckdb` only. Never reinstall dependencies, switch execution/provider modes, use sudo, modify global/shared/editor/opam state, or work around a provider/infrastructure failure; stop and report it.
- Use `jj`, never raw Git. Published branch is **master**, not main; no publication or commit in this task.
- Preserve these unrelated paths byte-for-byte: `stage1/ffi/check_unboxed.sh`, `test/check_interfaces.sh`, `test/check_query_modes.sh`, `test/install_smoke.sh`, `test/test_native_setup.py`, `tools/setup_duckdb.py`. Preserve generated `.pi/tasks` state. Baseline is `.local/stage4/before-plan.diff`.
- Explicit `.mli` first, Base by default, named ADT errors/results for expected failures. Use Core only where Async/system APIs require it. No unsafe casts in authored safe code. Native representation/lifetime operations stay in `duckdb-ffi`.
- Do not add a scheduler functor or generic pool framework. A shared **core resource interruption invariant**, if required by both adapters, is not a generic scheduler abstraction.
- Handles move between system threads; they are not portable/domain-safe. No `Domain.Safe.spawn` or domain-manager transfer of handles. No static uniqueness/linear destruction claim based on phantom states.
- Borrowed chunks remain local, synchronous, non-escaping, with no owner-transition capability. Preserve the effect barrier, not just locality annotations. No Async/Eio calls from a borrowed callback.
- Development warnings-as-errors only; do not impose the development warning set on installed consumers or vendored code. No additional test dependency install.
- Unsuppressed whole-process LSan is a **failure**, not a pass. Authored-C ASan/UBSan with `detect_leaks=0` does not fix it or instrument the prebuilt engine/runtime/Base. Ambient OCaml LSP is incompatible/unavailable; the pinned compiler is authoritative.
- OOM, arbitrary/repeated signals, asynchronous-exception setup/bookkeeping gaps, foreign callbacks that never return, and crash/hostile-filesystem limits remain. Ordinary adapter cancellation must not rely on those unsupported signal paths.

## 1. Evidence read before designing

Paths below are relative to the repository unless absolute. Installed sources are inspectable evidence, not files to modify or copy into the binding.

| Evidence | Consequence |
| --- | --- |
| `lib/duckdb/duckdb.mli`; `resource.mli/.ml` (`with_admission`, child admission, `scope`, `with_transaction`, `with_child_snapshot`); `lib/duckdb/dune` | Resource is private. The public synchronous interface has no interrupt capability, manual transaction begin/commit, reusable fetch-one API, or scheduler suspension permission. A separately installed adapter cannot obtain `Resource.native_connection`; exposing Resource or casting the safe connection is not a solution. |
| `resource.ml:272–319` | One lease spans BEGIN, callback, child revocation/drain, COMMIT/ROLLBACK. Original-connection reentrancy/nesting is Busy. The callback returns a synchronous result. Returning `Ok deferred` would settle the transaction before that deferred completes; wrapping an Eio callback encounters the no-escape barrier. |
| `query.mli/.ml`, `borrowed_chunk.mli`, `duckdb.mli` | Execute materializes before returning; a result reserves the connection until consumed/closed. `fold_chunks`/`fold_rows` consume it on admitted exits; the whole fold is synchronous. Decode owned values on the worker. There is no existing safe streaming cursor or yield-between-chunks interface to assume. |
| `appender.mli/.ml`, `parquet.mli/.ml` | Appenders require a transaction snapshot, reserve the connection, poison the transaction on failed work, and clear before destruction. Parquet export owns its transaction and temporary-file/publication lifecycle; Parquet read currently takes a connection, not a transaction. Do not silently nest either connection-owned convenience inside an explicit transaction. |
| `lib/ffi/duckdb_ffi.mli`; `resource_stubs.c:17–79,230–261`; `query_native.h` | `interrupt : connection -> unit` is explicitly unsafe without independent lifetime/identity synchronization. The current C primitive directly dereferences `Connection(v)->connection`, holds the runtime lock, and contains no NULL/closed check, identity check, interrupt lock or disconnect synchronization. Native child references retain a shell, not permission to use a disconnected engine connection. |
| `prepared_stubs.c`, `appender_stubs.c`, `local_file_stubs.c`; `Resource.raw_execute`, `Query.native_close_result`, `Appender.destroy` | Normal long calls release the runtime lock. Some `finish_*`, finalizer, and exceptional cleanup paths can block while holding it. Merely placing those calls on a worker does not prove scheduler responsiveness. Audit reachable normal and cancellation paths, including `clear_work`, before adapter acceptance. |
| `.local/stage3b-schema/client_context.cpp:689–693,1189–1198`, previously attributed to DuckDB `d8cdaa33fda8df955cc76ef58a280f68f4cd43fa` | `InitialCleanup` clears interruption; `Interrupt` sets it. One interrupt issued just before query initialization can be lost. An operation-identity lock solves stale delivery, **not** this startup/reset problem. The entire C API → Connection → ClientContext chain and atomic-field definition still need the Stage4a source gate. |
| `_opam/lib/async_unix/in_thread.mli` and `.ml:73–144` | `In_thread.run` uses the shared Async thread pool; no arbitrary Async calls are allowed inside its callback. On exception it sends the captured exception/backtrace to the submitting monitor and does **not** fill the result Ivar. Joining the raw deferred after a worker exception can wait forever. Helper-thread affinity exists but is unnecessary for currently movable handles. |
| `_opam/lib/async_kernel/monitor.mli` | A monitor is exception routing, not cancellation. Synchronous dispatch exceptions and asynchronous worker exceptions need deliberate capture. No change to `In_thread.When_finished.default` or scheduler-wide pool configuration is authorized. |
| `_opam/lib/eio/unix/eio_unix.mli:53–62`, `thread_pool.mli`, `thread_pool.ml:115–134` | The Eio pool creates another system thread when all are busy, without a capacity limit. Submission checks an already-cancelled context, but running system-thread functions do not respond to cancellation. The wrapper returns the worker result without a final cancellation check. Adapter-level bounded admission and an independent request waiter/controller are required. |
| `_opam/lib/eio/core/eio__core.mli`, `promise.ml:35–66`, `cancel.ml`; `_opam/lib/eio_linux/sched.ml:450–454`, `eio_posix/sched.ml:369–373` | Promise waiting can be cancelled independently of the producer; cancellation contexts belong to their domain. `Cancel.protect` protects cleanup and does not check its parent on return. Cancellation hooks must not switch fibers. Keep all Eio context manipulation in scheduler fibers, not database system threads. |
| `stage1/async_probe.ml`, `eio_probe.ml`, `schedulers.t`; `test/async_handoff.ml`, `eio_handoff.ml` | Existing handshake probes and core-handle handoffs prove pinned compatibility, not cancellation safety. Retain actual worker-start/heartbeat acknowledgements and failure release/join. |
| `test/query_hooks.c`, `appender_hooks.c`, concurrency and signal suites, `test/install_smoke.sh` | Existing linker-wrap handshakes, explicit worker-exception transport, live/fallback counters, compiler controls, and separate installed-package consumers are the test patterns. Do not use elapsed time as proof of worker startup. Do not edit the preserved smoke script; add a separate adapter smoke script. |

### Fresh planning probes (not Stage4 implementation evidence)

Ignored sources: `.local/stage4/probes/{async_routing,eio_routing,chunk_async,chunk_eio,owned_async,owned_eio}.ml`, four matching ownership-control `.mli` files, `dune`, `dune-project`. Logs: `.local/stage4/logs/`.

1. **Async:** worker raises `Worker_failure` after a finally records cleanup. `Monitor.try_with` receives that exception; the raw `In_thread.run` deferred is still undetermined. The same executable offloads a complete `Duckdb.with_database` → `with_connection` → `with_transaction` computation and returns owned `42`.
2. **Eio:** scheduler waits for a system worker's running flag, cancels the worker fiber's context, verifies the blocked call has neither returned nor raised cancellation, then releases the worker. The raw call returns `42`; a subsequent explicit `Eio.Fiber.check ()` raises `Cancelled Requested`. A complete synchronous DuckDB transaction offloads and returns `42`.
3. **Two negative compiler probes:** capture the local chunk in `Async.In_thread.run` or `Eio_unix.run_in_systhread`. Both reject the highlighted `chunk` as local where global is required. Paired controls compute the owned integer length before creating the offload closure and compile. These positive controls establish only the capture-mode distinction: they are not executed and do not authorize scheduler calls from a live borrowed callback or worker. Runtime positives must finish the borrowed fold on the worker and transfer its owned output afterward. The initial paired-control build hit development warning 32 for the unused exported test function; adding its explicit `.mli` fixed it. This is recorded, not counted as the intended negative evidence.
4. Fresh reruns of the four existing scheduler/handoff executables all exit 0. No full Stage1–3 test rerun or sanitizer rerun is claimed for this documentation-only task.

Exact commands from repository root:

```sh
# Existing runner always establishes the project-local environment first.
probe_dune() {
  command=$1; shift
  stage1/run exec --no-build -- /usr/bin/env \
    OCAMLPATH="$PWD/_build/install/default/lib:$PWD/_opam/lib" \
    LIBRARY_PATH="$PWD/.deps/duckdb" LD_LIBRARY_PATH="$PWD/.deps/duckdb" \
    "$PWD/_opam/bin/dune" "$command" --root "$PWD/.local/stage4/probes" "$@"
}
# Initial build before negative targets were added:
probe_dune build
# Reproduce positives with the final probe tree (do not build intentional failures):
probe_dune build async_routing.exe eio_routing.exe owned_async.exe owned_eio.exe
probe_dune exec --no-build ./async_routing.exe
probe_dune exec --no-build ./eio_routing.exe
# These two builds must exit nonzero with local/global errors at chunk:
probe_dune build chunk_async.exe
probe_dune build chunk_eio.exe
# Exact timeout-wrapped runtime invocation used (repeat with eio_routing):
stage1/run exec --no-build -- /usr/bin/env \
  OCAMLPATH="$PWD/_build/install/default/lib:$PWD/_opam/lib" \
  LIBRARY_PATH="$PWD/.deps/duckdb" LD_LIBRARY_PATH="$PWD/.deps/duckdb" \
  timeout 30 "$PWD/_opam/bin/dune" exec --no-build \
  --root "$PWD/.local/stage4/probes" ./async_routing.exe
for executable in stage1/async_probe stage1/eio_probe test/async_handoff test/eio_handoff; do
  timeout 30 stage1/run exec --no-build "$executable.exe"
done
```

Observed outputs:

```text
async: monitor=Worker_failure raw-deferred=pending cleanup=done transaction=42
eio: running-worker=not-cancelled raw-return=42 explicit-check=Cancelled transaction=42
async: worker=42 heartbeat=ok
eio: worker=42 heartbeat=ok
duckdb: Async handoff=ok
duckdb: Eio handoff=ok
Error: The value "chunk" is "local" to the parent region
       but is expected to be "global"
```

These are not tests of real running DuckDB interruption, bounded pooling, stale-interrupt exclusion, or adapter shutdown. Those remain required below.

## 2. Correctness contract for all Stage4 slices

### 2.1 Admission and leases

- Validate pool connection count > 0 and maximum queued requests >= 0. Use finite limits; when the waiting queue is full, reject with a named `Queue_full` error without spawning an offload or retaining a queue node. Zero waiting slots means immediate lease or rejection. Initial discipline is FIFO among surviving queued requests, not a fairness/latency promise.
- Keep adapter-owned waiting work in the adapter queue; do not eagerly submit every request to Async's or Eio's thread pool. At most the configured number of connection-bearing operations may be dispatched/running/settling. Bound maintenance and interruption work separately; never hide an unbounded second queue or one waiting system thread per borrower.
- A dispatched-but-not-started worker remains cancellable without executing SQL. It must recheck the request identity and latched cancellation before entering work. Dequeuing alone is not the execution linearization point.
- Lease one connection to the **whole request**, including all typed parameter binding, materialization, fetch/decode, child cleanup, transaction settlement and any owned file cleanup. A complete transaction is one worker computation in the initial adapter API. Do not reacquire a pool connection per statement.
- Initial transaction callbacks are synchronous core callbacks executed off-scheduler. No deferred/Eio callback is promised. Nested use on the same connection is rejected; do not emulate nested transactions with arbitrary BEGIN/COMMIT or accidental second pool checkout. Explicit savepoints are outside this slice.
- Do not expose the pool's raw connection/prepared/result/appender owners to scheduler code. A scoped transaction token may use the already-demonstrated dynamic revocation model, but its final adapter signature must compile before publication. No local views cross a scheduling boundary; only owned values leave the worker.
- Parquet connection-only conveniences are separate request operations. Do not claim Parquet-in-explicit-adapter-transaction support from the current signatures. Transaction-owned appender work uses `with_appender_transaction`; connection-owned appender requests may use `with_appender` for their complete lifecycle.

### 2.2 Request state, identity and interruption

Use named internal states with one documented transition authority, not unrelated mutable booleans. The following is a behavioral state diagram, **not a promised public type**:

```text
Queued -> Dispatched -> Running -> Settling -> Finished
   |           |           |
   +-----------+-----------+-- cancellation latch (one request identity)
Queued/Dispatched cancellation before execution -> Finished without work
Running cancellation -> interrupt attempt(s) -> foreign completion -> Settling
Settling -> clean reusable connection OR completely closed/discarded connection
```

- Assign a fresh request identity and lease generation to every admission. An interrupt delivery checks both against the connection's current interruptible operation. Object identity or non-reused generation must prevent ABA, including after connection replacement. No unchecked wrapping integer identity.
- Cancellation is a **latch**, not proof that a native interrupt hit a query. It is checked before initial work, before further user work/next file/batch, and before commit/publication decisions. A callback catching an error must not erase it or enable transaction commit.
- Distinguish native work completion, interrupt-controller quiescence, resource/transaction settlement, pool release and caller delivery. They are not interchangeable completion signals.
- An independent, short interrupt-state lock must not be held by the database work, a complete callback, a condition wait, or a scheduler wait. Do not acquire the work/admission lock in order to interrupt a query blocked behind that same lock.
- Serialize **identity check plus native interrupt** against disarm/reuse/destruction, not just the check. If delivery reserves an in-flight ticket and drops the lock, retirement must await that ticket before reuse. If the primitive itself is called under the lock, Stage4a must show that path cannot wait on the execution mutex or perform a blocking destructor. Never hold an OCaml mutex while calling an effectful scheduler operation.
- A queued/delayed cancellation for A must never affect B, whether A has completed, B reused the connection, the connection was replaced, or shutdown closed it. Synchronize every close path, including scoped/failure discard and native-shell release, with interrupt retirement.
- Solve the start/reset gap established by `InitialCleanup`. The bridge experiment must prove a latched request survives cancellation before native entry and internal prepare/execute resets. A single unsynchronized `duckdb_interrupt` is rejected. The mechanism (per-native-call arming/checks or a bounded, identity-checked repeated interrupt driver) is selected only after Stage4a evidence. If a repeated driver is chosen, stop and drain it before rollback/destruction and before any new request.
- No POSIX signal or `Sys.Break` injection is the adapter cancellation implementation. No worker thread termination. Never time out and recycle a still-running connection.

### 2.3 Settlement and delivery

| Outcome | Required action before release/delivery |
| --- | --- |
| Queued cancellation | Remove/invalidate exactly that queue entry; no DuckDB or filesystem work; free capacity; settle once. |
| Success | Disarm/drain interruption, destroy results/chunks/children, settle transaction, then permit reuse and deliver owned output. |
| Ordinary core result error | Preserve `Duckdb.error`; settle all resources and transaction. Reuse only if positively known clean. |
| Running cancellation | Stop subsequent user work; request interruption; await foreign completion; retire all possible interrupt deliveries; roll back where applicable; destroy children. Start conservatively by discarding interrupted connections unless a reviewed test proves a narrower clean-reuse classification. |
| Completion races cancellation | The request's terminal transition determines the winner. Cancellation latched before terminal settlement wins the user-facing cancellation classification; a terminal result already fixed is not retroactively changed. Neither ordering proves writes/files were absent. |
| Worker/callback exception | Retain original exception/backtrace; perform settlement; return or discard connection on actual evidence. Unexpected failure never turns into success/ordinary string error or an unobserved background exception. |
| Rollback/cleanup failure | Preserve both primary and cleanup outcomes (existing composites where applicable). Discard; do not health-check with SELECT 1 and call it clean. Failed close remains a reported failure, not “closed successfully.” |

A transaction must not continue to COMMIT merely because a callback swallowed cancellation or a native error. Pre-COMMIT latching is fundamental Stage4 correctness. A request cancelled at/after COMMIT may already have written data. COPY/publication may already have created the output; never delete a final output on the assumption cancellation means rollback. Only owned temporary files are cleanup targets.

### 2.4 Scheduler-specific routing

**Async:** API operations return deferred results with an explicit request cancellation handle/interface. Cancellation acknowledgement and settled completion are different concepts; document whether cancel returns acknowledgement or completion, and make completion observable exactly once. Deferred abandonment is not cancellation. Catch worker exceptions *inside* the offload into a private outcome with backtrace so its completion channel always resolves; route exceptional outcomes to the captured caller monitor only after resource settlement. The adapter-owned completion must settle exactly once even when the raw deferred from an uncaught worker exception would stay pending: return the captured worker outcome through `In_thread.run`, then settle adapter accounting/completion on the scheduler before monitor delivery. Preserve both primary and cleanup exceptions in that outcome. Capture synchronous dispatch failure too. Do not call Async Ivar/Monitor/scheduler functions from the worker unless the exact API is documented thread-safe. Keep essential completion/accounting alive even if the caller monitor fails or drops its deferred. Test this separately from `Monitor.try_with` happy paths.

**Eio:** expected database/pool errors remain results; cancellation is `Eio.Cancel.Cancelled`, not flattened into a database error. The caller waits cancellably on request completion while a pool-owned producer performs `run_in_systhread` independently. On cancellation, latch/interrupt the request and use `Cancel.protect` to await worker completion and required cleanup before propagating the original cancellation. A cancelled caller must not cancel or abandon the only worker completion path. Observe caller-context cancellation even if a completed promise would return immediately; respect the terminal race rule and Eio's explicit checking semantics. Preserve cleanup failures alongside cancellation via documented composite exception/reporting rather than silently dropping them. Keep Eio context operations on their owning scheduler domain. Prefer public Promise/Switch/Cancel primitives; do not assume a private suspension API is necessary.

### 2.5 Responsiveness and shutdown

- Offload open/connect, SQL preparation/binding where native/file work can occur, execute, fetch/decode, append and automatic/explicit flush, close/discard/destruction, rollback/commit, database close, Parquet path resolution where it touches the filesystem, temporary-file reservation, COPY, publication and unlink. Whole-request offload is the initial safe implementation; no scheduling per cell.
- Runtime-lock release is independent of system-thread offload. Test normal and cancellation cleanup with a scheduler heartbeat while the actual native operation is held in flight. Held-runtime-lock exceptional fallbacks remain a stated signal-path limitation; if **ordinary adapter cancellation** reaches such a blocking path, fix it before accepting that slice.
- Initial shutdown policy: idempotently stop admission, settle queued requests with named shutdown outcomes, request cancellation of active requests, protect and await all foreign completions/interrupt retirement/settlement, then close connections and database in order. No hidden drain-versus-abort policy switch. Concurrent shutdown callers observe the same settled outcome. Reentrant shutdown from a worker callback must not wait for its own lease; reject that usage explicitly.
- A caller cancelling shutdown must not abandon closure; retain a pool-owned shutdown completion and protect the necessary drain. Partial pool initialization closes already-created connections before database close. Replacement failure is reported without unbounded retries; shutdown racing replacement never publishes a new idle connection.
- Interrupt/control progress must not depend on getting another slot in the same fully occupied database worker quota, or on a shared Async pool thread that all long requests occupy. Prove the chosen control path under saturation without changing scheduler-wide configuration.
- A foreign operation/callback that never finishes has no bounded shutdown guarantee. A timeout is a test failure bound or caller observation, never permission to disconnect an executing query.

## 3. Incremental slices and review gates

### Stage4a — prerequisite evidence, no public adapters (first runnable milestone)

**Deliverable:** a small tracked test/prototype area that reproduces pinned scheduler routing, mode restrictions, actual native interruption and retirement ordering. Its reviewed report decides the minimal bridge mechanism and the next interface-first slice. Tests may deliberately use unsafe FFI with explicit lifetime ownership; that does not become a public adapter API.

**Files to create at implementation time:**

- `stage4/dune`: independent Async/Eio evidence executables and bounded runtest rules; no new public package yet.
- `stage4/evidence_support.mli`, `.ml`: bounded atomic/system-thread handshake helpers and explicit worker outcome/backtrace transport; no scheduler dependency.
- `stage4/test_async_evidence.mli`, `.ml`: Async routing, full synchronous transaction handoff, owned-result and heartbeat evidence.
- `stage4/test_eio_evidence.mli`, `.ml`: raw Eio non-cancellation, cancellable waiter/protected producer experiment, full synchronous transaction handoff, effect-barrier and heartbeat evidence.
- `stage4/test_interrupt_evidence.mli`, `.ml`: directly owned unsafe FFI database/connection; independent-lock request identity experiment and native completion/retirement races. Not an installed module.
- `stage4/interrupt_hooks.c`: test-only atomic gates/counters around `duckdb_execute_prepared` and `duckdb_disconnect`; a nonblocking, count-only wrapper around `duckdb_interrupt`; optionally `duckdb_query` to distinguish BEGIN/COMMIT/ROLLBACK in the explicit-transaction experiment. The interrupt-delivery pause belongs in ML/system-thread test code, not the native wrapper. No production stub mutation and no runtime patch.
- `stage4/check_modes.sh`; `stage4/compile/{async_chunk,eio_chunk,domain}.ml.fail`; `stage4/compile/{owned_async,owned_eio,positive}.ml` and explicit interfaces for exported positive controls.
- `docs/stage4a-validation.md`: exact pins/source hashes, red/green outputs, native transition counts, source-to-design decision and remaining limits.

**Existing files to read, not change for this milestone:** all evidence in section 1, `test/check_query_modes.sh`, `test/query_hooks.c`, `test/test_query_concurrency.ml`, `stage1/dune`, `lib/ffi/duckdb_ffi.mli`, `.ml`, `resource_stubs.c`. No modifications to `lib/`, package opam files or `dune-project` until the evidence is reviewed.

**Probe interfaces (write these before implementations):**

```ocaml
(* stage4/evidence_support.mli *)
val await : label:string -> (unit -> bool) -> unit
val with_worker : (unit -> 'a) -> f:((unit -> 'a) -> 'b) -> 'b
```

`await` is a system-thread-only helper with a monotonic deadline and a named failure message; never call it on a scheduler thread. `with_worker` passes an idempotent join thunk to `f`, always joins on exit, and transports the worker's original exception/backtrace. Every scenario creates its release gate before starting a worker and wraps the body passed as `f` in a finally that releases that gate **before `with_worker` performs its mandatory join**. An outer finally running only after `with_worker` returns is too late and can deadlock the join. Worker-start failure must also release any already-created gates. Supervisor-approved Stage4a clarification: the monotonic deadline detects handshake/completion failure, but every successfully started worker is still mandatorily joined after the body releases all gates. `Thread.join` itself has no timeout; this potentially unbounded wait is explicit in the helper interface. The executable timeout bounds process failure only, never graceful cleanup or safe reuse. Preserve the original and join/cleanup failures. A controlled failing-handshake test must prove release and join before failure propagation.

```ocaml
(* Each test_*_evidence.mli *)
val run : unit -> unit
```

Each executable calls `run` exactly once; its own scheduler-specific `run` owns the scheduler. Empty stub implementations are only transient red-test scaffolding and must not survive the slice. Do not introduce hypothetical public pool/token interfaces in these files.

**Task A1 — promote demonstrated scheduler and type evidence**

- [ ] Write the `.mli` files and tests first. Recreate the two ignored routing probes as explicit test cases; preserve assertions about the raw deferred remaining undetermined and raw Eio work returning before explicit cancellation check.
- [ ] Record missing-implementation/target red with `stage1/run build stage4/test_async_evidence.exe stage4/test_eio_evidence.exe`.
- [ ] Implement the small support module and the scheduler tests. Include an ordinary result error, a worker exception, and dispatch failure as separate outcomes. No monitor wrapper that can finish before its child cleanup is allowed to masquerade as join evidence.
- [ ] Add a positive Async exception-transport control alongside the raw-deferred negative: catch the worker exception/backtrace into an owned outcome inside `In_thread.run`; after worker cleanup, assert the adapter-owned completion is determined exactly once before the caller monitor sees the exception. Inject a cleanup exception too and assert both primary and cleanup outcomes remain observable. Never join the deliberately pending raw-deferred negative.
- [ ] Add an Eio producer/waiter experiment: pool-lifetime protected producer fiber runs `run_in_systhread`, resolves a private completion promise on all worker outcomes; request waiter is cancelled after worker-start handshake, records its cancellation before worker release, then under `Cancel.protect` waits for completion. The scheduler-controlled release proves cancellation routing is independent of worker return. Cancel once more during protected settlement; cleanup must still finish before cancellation is reraised. Also fail cleanup and assert the original cancellation and cleanup failure are both preserved, not replaced by one another. Never register a cancellation hook that performs an Eio effect.
- [ ] Run whole synchronous transaction callback handoffs with two SQL statements and an owned result. Trigger outer Eio yield from a core scope and assert `Effects_not_allowed`, non-delivery to the outer handler, rollback and cleanup; do not weaken the barrier. Test an escaped transaction token after return gives `Closed`.
- [ ] Add paired compile tests using the real `Duckdb` and scheduler interfaces. Negative example:

```ocaml
let escape result =
  Duckdb.fold_chunks result ~init:() ~f:(fun chunk () ->
    let _work = Async.In_thread.run (fun () -> Duckdb.chunk_length chunk) in
    Ok (Duckdb.Stop ()))
```

For Eio replace only the offload expression with `Eio_unix.run_in_systhread`. Compile-only positive controls compute `let length = Duckdb.chunk_length chunk` before the global closure and capture `length`; do not execute these scheduler calls inside borrowed scopes. Separate runtime positives return owned strings/rows from a completed worker fold after resource destruction. Domain negative uses an actual safe connection and `Domain.Safe.spawn`, not an unrelated function whose mode already fails. Compile errors must name the intended value/modes, not merely exit nonzero. Use the existing source-named standalone compiler-control pattern and do not edit preserved scripts.

**Task A2 — prove the missing interrupt mechanism, without freezing a safe signature**

- [ ] Complete the pinned engine source audit: public `duckdb_interrupt` implementation, `Connection::Interrupt`, ClientContext interrupted-field declaration, query initialization/reset, and execution cancellation checks. First use existing pinned cached sources/archives. If a necessary immutable source is unavailable under the allowed environment, stop and report the missing evidence rather than substituting current HEAD, another library, or an unsupported lock-safety assertion. Record immutable source IDs/hashes in the validation document.
- [ ] Write the hook interface first in `test_interrupt_evidence.ml` as the following explicitly test-only primitives, mapping to C atomics (not callback-bearing native state):

```ocaml
external arm : int -> unit = "stage4_arm" [@@noalloc]
external entered : unit -> int = "stage4_entered" [@@noalloc]
external release : unit -> unit = "stage4_release" [@@noalloc]
external interrupt_count : unit -> int = "stage4_interrupt_count" [@@noalloc]
external disconnect_count : unit -> int = "stage4_disconnect_count" [@@noalloc]
```

`arm 0` disarms. Native gate points: 1 before real execute, 2 after real execute/before return, 4 before real disconnect. Count native calls independently of scenario completion. These wrappers run with the existing runtime lock released; read no movable OCaml data there. There is no native gate point 3: after reserving an in-flight interrupt ticket under the test's independent synchronization, pause the delivery system thread in ML using a bounded handshake, before calling the unchanged `Duckdb_ffi.interrupt`. Retirement must wait for that ticket; release it in protected cleanup on every delivery outcome. Release the ML pause before joining the delivery thread on test failure. Revalidate operation identity and delivery eligibility under synchronization after the pause, not only before it. The `duckdb_interrupt` wrapper only increments its counter and calls the real function; it must not wait, allocate, raise or release/reacquire the runtime. `Duckdb_ffi.interrupt` is `[@@noalloc]` (`lib/ffi/duckdb_ffi.ml:17`), and the pinned compiler manual `manual/src/cmds/intf-c.etex:2424–2435` forbids domain-lock release under that calling convention. The ML gate tests ticket retirement, not a hypothetical unlocked native interrupt.

- [ ] Use a tiny non-installed request record owned by the test, with a fresh identity, cancellation latch, independent interrupt mutex and states Dispatched/Running/Settling/Finished. The worker owns the FFI connection from creation through final close; other code receives no permission to disconnect it. The cancellation test retains that owner until the worker and all interrupt deliveries have joined. Exercise `Duckdb_ffi.execute`, not a different production query implementation.
- [ ] Establish real running interruption using a genuinely long query such as `SELECT sum(sin(i::DOUBLE)) FROM range(10000000000) t(i)`. A pre-call wrapper flag is **not** evidence that DuckDB has passed `InitialCleanup`. Latch cancellation after entry and retry identity-checked interruption until engine completion; the success oracle is a native interrupted error plus foreign completion, not elapsed duration. Bound failure externally. Record number of calls and prove the latch remains set if the first interrupt arrives before engine start.
- [ ] Add an exact start-gap control: gate before real execution, call interrupt once while the engine has not entered, release, and use a finite query. Record whether it completes normally (expected from inspected reset code). Then require the latched experiment to suppress still-dispatched work entirely or interrupt the eventual running query. Never call the raw one-shot control “cancellation-safe.”
- [ ] Make the pre-entry versus engine-start/reset distinction a named **handshake-tested acceptance gate**: (a) cancel a still-dispatched request behind its worker-entry gate and assert no native execution; (b) deliver one interrupt behind the pre-engine gate, then release it and record the finite-query reset control; (c) keep cancellation latched across that same transition and require an actual engine interrupted outcome plus foreign completion. Assert the ordering from gate/call counters, not sleeps. A failure of (c) blocks the bridge even if all stale-identity tests pass. A pre-call flag is never relabelled as a post-initialization acknowledgement.
- [ ] Add two deterministic retirement races: (i) reserve A's in-flight interrupt ticket, pause the delivery thread at the ML gate before the native call, and let A reach completion; assert disconnect/reuse cannot happen until the delivery retires its ticket and is joined. After releasing the gate, recheck eligibility: if A is already settling, skip native delivery and retire the ticket rather than interrupting cleanup. (ii) Delay A's cancellation notification until B has acquired the same connection with a fresh identity; assert zero native interrupt calls attributable to A and successful B. A stale check done only before waiting at the ML delivery gate is deliberately insufficient.
- [ ] Add queued and dispatched cancellation controls with an execution counter equal to zero, repeated cancellation, cancellation after terminal completion, shutdown-style close waiting for A, and native error followed by known-clean control work. All resource counters return to baseline and fallback counter remains unchanged without requesting GC. Capture worker exceptions through join, even on test failure.
- [ ] Test cancellation during an explicit transaction and between successive native calls: no next user statement or COMMIT after the cancellation latch is observed; disable and join interruption before rollback/close. If the current core provides no hook to enforce this, record that as the bridge prerequisite, not a passing adapter test. The small test-owned experiment may demonstrate the needed ordering but must not bypass the safe API in production.

**Task A3 — decision/report and independent gate**

- [ ] Run the commands below and record actual exit codes; compile-test rejections and one-shot-interrupt controls are negative evidence, not failed green tests.
- [ ] Record private-module packaging, native lifetime retention and cross-thread synchronization as separate prerequisites to a bridge signature. Reuse the installed-consumer/private-Resource rejection evidence from `docs/stage3c-validation.md` and inspect `lib/duckdb/dune` plus already-installed metadata. If the proposed bridge needs a packaging exposure not established by that evidence, stop the signature gate and specify a minimal non-production packaging experiment for separate review; do not install a new bridge or assume private-module access in this milestone. The runtime races must demonstrate engine-handle validity through interrupt retirement, not merely retention of a native shell.
- [ ] Write a source-to-mechanism decision: which reset boundaries require latching; which operation phases may receive interrupts; how delivery is serialized with close; why the control path progresses under saturated workers; which cleanup paths can hold the runtime lock. Identify the minimal Resource/FFI changes required.
- [ ] Gate on independent review of the evidence, not only the diagram. If the nonblocking interrupt chain, mode compatibility, routing, or interrupt retirement experiment fails, stop before any public adapter/bridge signature. Narrow the next prototype based on observed failures; do not change toolchain or silently weaken cancellation/reuse requirements.

**Stage4a execution evidence:** [`docs/stage4a-validation.md`](../../stage4a-validation.md) records the tracked scheduler/mode/native tests, missing-implementation and post-pause mutation reds, final focused/full regression and authored-C sanitizer greens, immutable source/disassembly audit, and remaining packaging/lifetime/core-boundary signature gates. Independent specification/quality review and fresh parent build/full-regression verification passed; Stage4a evidence is accepted. These results do not accept Stage4b or expose a public bridge. The exact saved preservation check fails only for independently updated `.pi/tasks` bookkeeping; all six preserved formatting paths pass.

**Exact first-milestone command set (future tracked files):**

```sh
stage1/run build stage4/test_async_evidence.exe stage4/test_eio_evidence.exe \
  stage4/test_interrupt_evidence.exe
# stage4/dune declares all executable dependencies and timeout-wrapped rules:
stage1/run runtest stage4 --force
for executable in test_async_evidence test_eio_evidence test_interrupt_evidence; do
  timeout 60 stage1/run exec --no-build "stage4/$executable.exe"
done
# Each evidence suite repeats its handshake scenarios, not elapsed-time success windows.
for iteration in 1 2 3 4 5; do
  timeout 60 stage1/run exec --no-build stage4/test_interrupt_evidence.exe
done
clang -std=c11 -Wall -Wextra -Werror -fsyntax-only \
  -I.deps/duckdb -I_opam/lib/ocaml stage4/interrupt_hooks.c
stage1/run build @all
stage1/run runtest --force
sha256sum --check .local/stage4/preserved.sha256
```

`stage4/dune` follows the existing native wrapper pattern: link `--wrap=duckdb_execute_prepared`, `--wrap=duckdb_interrupt`, `--wrap=duckdb_disconnect` only into the interrupt evidence executable, with Base/threads/duckdb-ffi dependencies. Scheduler tests remain separate executables and libraries. Mode rules compile positive cases first with pinned `%{ocamlc}`, then assert the intended negative diagnostics. No package installation or dependency build is part of this prerequisite milestone.

### Stage4b — minimal safe adapter bridge, after Stage4a review

**Scope:** the first production change, scheduler-neutral only where Resource/FFI safety requires it. Before implementation, write a small follow-on execution plan with the **compiled** interface chosen from Stage4a, not an invented portable/local/unique signature in this document.

**Expected files/seams:** `lib/duckdb/resource.mli/.ml`, `duckdb.mli/.ml`; `lib/ffi/duckdb_ffi.mli/.ml`, `resource_stubs.c`, `query_native.h` if native retention is needed; `query.ml`, `appender.ml`, `parquet.ml` only at the specific native admission/settlement boundaries established by A2. Add `test/test_adapter_bridge.ml`, `test/adapter_bridge_hooks.c`, interface controls and `docs/stage4b-validation.md`; change `test/dune` only for these tests. A dedicated small core module is appropriate only if it encapsulates one actual bridge responsibility without duplicating Resource admission.

**Boundary decision:** separately installed adapters need a narrow supported safe bridge reachable through `Duckdb`, not private-module access or an FFI conversion in adapter code. The bridge must expose request-scoped cancellation/settlement capability, never a native pointer or arbitrary connection interrupt function. Keep constructors and identity mutation private. No promise of public begin/end transaction handles or asynchronous transaction callbacks.

**Acceptance tests before code:** closed/revoked capability, alias revocation, invalid concurrent admission, live result/appender, all stage4a races through the **real safe bridge**, late A versus B, disconnect versus selected interrupt, swallowed cancellation before COMMIT, reset/start gaps, rollback failure/discard, pre/post-COMMIT and pre/post-publication outcomes. Test source-named positive/negative mode controls and an external installed bridge consumer; private Resource must remain unavailable. Adapt existing single-signal tests only if a changed native transition requires regression coverage; do not broaden signal guarantees.

**Stop gate:** no adapter package is implemented until the production bridge proves ordinary cancellation is separate from signals, cleanup is interruption-quiescent, and the lease cannot be reused or disconnected early. Do not claim that retaining a native shell or SELECT 1 proves those properties. Independent bridge review is required.

### Stage4c — first runnable Async vertical slice

**Files:** create `lib/async/duckdb_async.mli/.ml`, `lib/async/dune`, `duckdb-async.opam`; add the package in `dune-project`. Create `test/async/dune`, `test/async/test_duckdb_async.ml`, test-only hook/support files colocated there, `examples/asynchronous.ml/.mli`, separate example target, `test/install_async_smoke.sh`, and `docs/stage4c-validation.md`. Split internal admission/request modules only if the implementation grows beyond one coherent module; keep explicit `.mli` boundaries.

**Package boundary:** public package/library `duckdb-async`, module `Duckdb_async`; depends on `duckdb` and pinned Async, not `duckdb-eio` or its runtime. Direct adapter code must not use unsafe `Duckdb_ffi` connection conversions. Do not add Async dependencies to the synchronous packages. No scheduler startup at module initialization.

**Interface-first deliverable:** validated pool limits, lifecycle/shutdown, one SQL execution request returning a deferred result with explicit cancellation, and complete synchronous transaction requests. Public error ADT distinguishes invalid limits, queue full, pool shutdown, cancellation and wrapped core errors. Freeze exact names/types only after bridge acceptance and paired compiling consumers. A private worker completion outcome retains exceptions/backtraces separately from expected errors; no exception-as-string fallback.

**Required tests in this slice:** capacity one plus finite queue, FIFO surviving queue requests, no offload on queue overflow, queued and dispatched cancellation without execution, running interruption, completion races, stale interrupt after reuse/replacement, cancellation repeated/after finish, callback/result/native/dispatch failures, monitor routing exactly once after cleanup, abandoned deferred/failed monitor without lost pool accounting, all slots occupied while cancellation progresses, complete transaction isolation with a competing borrower, nesting rejected, cancellation before COMMIT plus post-COMMIT write caveat, clean-or-discard and replacement failure, shutdown in every state and concurrent/repeated shutdown. Include normal execution and cancellation/destruction heartbeats, not just a SELECT heartbeat.

**Gate:** first public Async slice is not accepted as “a thread-pool wrapper” while cancellation/shutdown are incomplete. Example and installed consumer must run independently of the Eio adapter. Run `stage1/run runtest test/async --force`, full build/runtest, and `bash test/install_async_smoke.sh`; independently review the slice.

### Stage4d — Async typed query, ingestion and local Parquet requests

**Files:** extend `lib/async/duckdb_async.mli/.ml`, `test/async/test_duckdb_async.ml` or source-named query/ingestion/parquet test modules, `test/async/dune`, `examples/asynchronous.ml`, `test/install_async_smoke.sh`, `docs/stage4d-validation.md`.

**Scope:** expose owned typed query results/folds using existing Scalar/Row representations, complete transaction-owned batch ingestion including explicit/automatic flush, and dedicated local Parquet read/export. All native and filesystem work remains inside offload, including path-to-absolute resolution/temp-file reservation. Borrowed callbacks may be used internally on the worker only. Start with owned accumulation/synchronous folds; no streaming/backpressure cursor API without another compiled lifetime prototype.

**Tests:** multi-chunk/NULL/type-width roundtrips, worker callback error/exception/Stop, failure after previous batches, unclosed appender, concurrent metadata changes, flush and destruction interruption, corrupt/later-mismatched Parquet file, cancellation between files and before/after output publication, owned temporary cleanup and final-output preservation. Every operation kind receives cancellation/settlement and in-flight scheduler heartbeat coverage. Assert there is no per-cell offload by counting offload admissions in test instrumentation. Do not make allocation/throughput claims from those counts.

### Stage4e — first runnable Eio vertical slice

**Files:** create `lib/eio/duckdb_eio.mli/.ml`, `lib/eio/dune`, `duckdb-eio.opam`; add the package in `dune-project`. Create `test/eio/dune`, `test/eio/test_duckdb_eio.ml`, test-only hook/support files, `examples/eio.ml/.mli`, separate example target, `test/install_eio_smoke.sh`, `docs/stage4e-validation.md`.

**Package boundary:** public package/library `duckdb-eio`, module `Duckdb_eio`; depends on `duckdb` and the pinned Eio Unix blocking-thread stack, not Async. Keep `eio_main` in executables unless installed-library dependency evidence actually requires it. Direct style does not imply core scopes can yield. No scheduler startup at module initialization or cross-domain handle claim.

**Interface-first deliverable:** same bounded lifecycle/SQL/complete synchronous transaction capabilities as Stage4c, but result-valued expected failures and idiomatic Eio cancellation. Use the reviewed producer/waiter/protected settlement mechanism. Do not copy the Async monitor machinery or build a generic functor.

**Tests:** all core state-machine races from Stage4c repeated through Eio; already-cancelled caller, queued cancellation, running cancellation caught independently of worker return, cancellation immediately after foreign completion, cancellation during protected rollback/destruction, completion promise already resolved while parent is cancelled, worker/cleanup exceptions, parent switch failure, shutdown under parent cancellation, all slots saturated, and no leftover worker using a closed Eio thread pool. Assert complete transaction isolation and scheduler responsiveness. Test the actual default backend without changing backend/mode to pass; source inspection of both backends is not a runtime pass on both.

**Gate:** `stage1/run runtest test/eio --force`, full build/runtest, `bash test/install_eio_smoke.sh`, standalone Eio example, independent review. Do not label Eio cancellation complete based on `run_in_systhread` alone.

### Stage4f — Eio typed operations and four-package integration

**Files:** extend `lib/eio/duckdb_eio.mli/.ml`, Eio tests/example/install smoke for the Stage4d typed/ingestion/Parquet coverage; add `test/install_adapters_smoke.sh` to orchestrate isolated package checks; update `README.md`, `docs/native-dependency.md` only for implemented installation instructions and add `docs/stage4-validation.md`.

**Tests:** repeat the Stage4d operation matrix through Eio with cancellation-context routing. Use separate Async and Eio executable examples plus the existing synchronous example. Installed-consumer checks build FFI → core → one adapter at a time with the sibling adapter's source/package absent. Verify META/dune-package dependencies, no scheduler dependency in `duckdb`/`duckdb-ffi`, no private Resource exposure, no build-root paths/rpaths, relocated `.deps`-derived native library loading, and consumers outside the repository source tree. Follow the existing source-relative private-module install workaround without editing the preserved `test/install_smoke.sh`. These are Dune install/consumer checks, not an actual opam solver/install run; do not claim one or fix unrelated publication metadata/license decisions.

**Gate:** full suites, independent spec/quality review of each adapter and integration diff, explicit limitations. No “all adapters complete” statement before both packages' full correctness matrix, examples and installed consumers pass.

## 4. Validation matrix and heartbeat oracle

Every scheduler's test report must identify each row below by source-named test, observed native/worker counters, and terminal outcome. Do not turn this into a shared scheduler abstraction merely to share a table.

| Area | Required deterministic ordering/oracle |
| --- | --- |
| Admission | Gate running A; fill queue; overflow rejects without spawning work; cancel queued B; surviving C executes once; queue accounting returns to zero. |
| Dispatched cancellation | Worker entry gate closed after dispatch; cancel; open gate; SQL/flush/file counter stays zero. |
| Actual running query | Foreign entry observed; cancellation driver reaches live engine; interrupted outcome; foreign return precedes resource release. Entry flag alone is insufficient. |
| Interrupt startup/reset | Cancel before native init and between native calls; first interrupt may be reset, latch is not; no post-cancel user work or commit. |
| Delayed interrupt | Pause selected delivery A; A cannot release/close while ticket lives; after B starts, delayed A notifications cause zero engine interrupts. |
| Transaction lease | A inserts and waits between statements; B cannot execute on A's connection before A settles; observer sees commit/rollback as expected. |
| Cleanup/reuse | Hold fetch/flush/destroy/rollback; completion stays unsettled; no next borrower; uncertain/faulted connection discarded, never returned idle. |
| Exceptions | Worker exception transported; cleanup completes; Async monitor or Eio caller receives it exactly once; primary plus cleanup failure both retained. |
| Shutdown | Stop admission at one transition; settle all queued; interrupt/join active; children before connections before database; repeated/concurrent shutdown shares outcome. |
| Scheduling | Actual worker/native operation stays in flight until scheduler heartbeat acknowledgement; scheduler first waits for true entry, then acknowledges; completion cannot precede acknowledgement. |
| Failure oracle | Inject heartbeat failure/deferred startup; release all gates before joining; expected nonzero exit, never timeout. Held-lock negative control must fail the positive heartbeat claim. |
| Native lifetime | Zero live binding resources relative to scenario baseline and zero fallback reclaims without GC; inspect temporary engine allocations separately; sanitizers are complementary. |
| Installation/modes | Paired intended compile rejection and owned positive; separate installed sibling-free consumers; exact pinned compiler, no ambient LSP substitution. |

For held-lock negative controls, use a native watchdog/system mechanism that can release the native gate without requiring the blocked OCaml scheduler; otherwise the fixture only proves its own deadlock. For ordinary positive tests, time budgets only bound failure and never define the success window. Use hook points for execute, fetch, automatic/explicit flush, result/appender/connection/database destruction, COPY, temporary creation/publication/unlink. If an uninstrumented OCaml filesystem operation cannot be held reliably, add a narrow test seam or source-backed system-call wrapper rather than substituting a sleep before unrelated SQL.

Run authored-C ASan/UBSan on changed native code and bridge/adapters with the existing `stage3a-sanitize` pattern, a source-relative ignored build directory, and explicit `detect_leaks=0`. Report the pre-existing unsuppressed whole-process LSan failure separately; do not suppress it or call the process leak-free. No performance or static safety claim without corresponding compiled/run evidence.

## 5. What is Stage4 versus Stage5

**Stage4 cannot defer:** bounded waiting/offload, exclusive complete transactions, cancelled queued work not executing, latched running cancellation, independent locks, identity/late-interrupt exclusion, foreign completion and interrupt retirement before reuse/destruction, safe cleanup/discard, scheduler-specific exception/cancellation behavior, blocking-operation offload/runtime-lock evidence, shutdown, examples and independently installed optional packages.

**Stage5 may add:** longer randomized/model-based race campaigns using already installed tooling, more failure schedules, prolonged shutdown/cancellation soak tests, measured tuning of pool/queue sizes, scheduler-tail-latency and throughput measurements, owned-row versus borrowed-chunk elapsed/allocation/GC benchmarks, VM/deployment observations and expanded documentation. Stage5 does not retroactively supply missing basic cancellation correctness. No SIMD, zero-copy/zero-allocation claim, streaming API or generic scheduler architecture is implied.

## 6. Self-review and readiness

- **Coverage:** separate packages/install consumers/examples — 4c/4e/4f; bounded admission/leases — §2.1 and 4c/4e; queued/running/completion/stale cancellation — §2.2 and 4a/4b; clean-or-discard/foreign completion — §2.3; monitor versus Eio — §2.4 and fresh probes; borrowed restrictions — 4a controls and 4d/4f; execute/fetch/flush/destruction/file work — §2.5 and §4; shutdown — §2.5, 4c/4e; Stage5 boundary — §5. No fundamental safety obligation is assigned only to Stage5.
- **Type consistency:** only existing compiled resource/scheduler signatures and simple non-installed evidence-helper signatures are given. `connection`, `transaction`, `prepared`, `query_result`, `chunk`, `appender`, Scalar/Row, and Parquet path retain their source meanings. No public portable/unique/local adapter lease type is invented. The descriptive request state diagram is not advertised as a type-level proof.
- **Scope consistency:** 4a is a runnable evidence milestone, 4b a separately reviewed bridge, each scheduler gets its own executable vertical slice before typed coverage. The core remains scheduler-free. Full transactions run synchronously on a worker; no hidden Eio suspension or early Async deferred settlement. No other writer/agent or production/Dune package change was made during planning.
- **Open engineering gates, not renewed product questions:** precise bridge capability signature; exact interrupt/reset/retirement mechanism and source chain; production Eio producer lifetime under shutdown; ordinary-cancellation runtime-lock cleanup reachability; final exception composite representation. Each has an explicit evidence/review gate before its consumers are implemented. Approved routine decisions suffice; no additional user interview is required to start Stage4a.
- **Ready:** Stage4a evidence implementation after independent plan review. **Not ready:** freeze public adapter signatures, declare cancellation safety, publish adapters, or skip the bridge evidence because handoffs already compile.

## 7. Pinned source provenance

- Compiler `5.2.0+ox`, package `oxcaml-compiler.5.2.0minus39`, inherited immutable revision `2515546fea38e21e8143cc41db663bd56efc8d06`; Dune binary `3.22.2`, package `3.22.2+ox`.
- Base, Async, Async_unix, Async_kernel all `v0.18~preview.130.106+341`, verified installed package directories. Installed opam source revisions: Async `5c1c47bb66487f536ff4c3927ffdb0448636bb48`, Async_unix `f2246763dc308b12dc2ac84820117b1ef07e4879`, Async_kernel `69bd328f770d136faaf377622f84ae48d14a043c`.
- Eio/Eio_main `1.3+ox`, fork `7de26f5331f1e7aac1c086a5ebe849dd940b5c3e` from the existing lock/source evidence. Inspected installed Eio Unix pool, Promise, Cancel, public core interfaces, both backend systhread dispatch sites; no runtime-backend-switch test performed.
- DuckDB `v1.5.5`; cached ClientContext source provenance is the prior validated immutable engine revision `d8cdaa33fda8df955cc76ef58a280f68f4cd43fa`. No network download or source/build replacement occurred. This planning run did not independently complete the full interrupt C++ call-chain audit; Stage4a explicitly requires it.
- Header SHA256 `48e716b9ce96ca8fead9cb35693fdc0343ac0fc1f6e7db5561fa0f44b674153d`; library `fc23f12e376c47be520f75221288281906e7942e8fd6f6ce4849198ba60d0405`, freshly unchanged.
- Inspected-source SHA256: Async `in_thread.mli` `c45c0cb3d4a582eb2705faaaab0dafefe1b85c026569078a37f04f459a3cb333`; `in_thread.ml` `de650876763647dd4d8d34e0ca4284a37b478e126927198b06d4b861117c226b`; Eio `unix/thread_pool.ml` `422c6428d87486e1436e57e93e5b1485a6cb55855038b9e87ff9d2f05224a742`; `core/eio__core.mli` `9b407a62e791125942a4a59ae48a0b1e92b0074bd129d654bf1912bc76bbbc32`; cached `client_context.cpp` `d5b4d9c1bc6af98bcad7612cb70d590214a29876e8674f1c5315894c12f55a5d`.

## Appendix A. Exact retained planning probe sources

These are the original ignored probes, unchanged on resume. They are evidence only, not production adapter implementations. Commands and observed outputs are in §1; positive ownership controls are compile-only. The initial runtime scripts intentionally have top-level entry points; Stage4a adds explicit test interfaces before tracked implementation.

### `.local/stage4/probes/dune-project`

```lisp
(lang dune 3.20)
(name stage4_planning_probes)
```

### `.local/stage4/probes/dune`

```lisp
(env (dev (flags (:standard -extension-universe beta))))
(executable (name async_routing) (modules async_routing) (libraries async duckdb))
(executable (name eio_routing) (modules eio_routing) (libraries base eio_main duckdb))
(executable (name chunk_async) (modules chunk_async) (libraries async duckdb))
(executable (name chunk_eio) (modules chunk_eio) (libraries eio_main duckdb))
(executable (name owned_async) (modules owned_async) (libraries async duckdb))
(executable (name owned_eio) (modules owned_eio) (libraries eio_main duckdb))
```

### `.local/stage4/probes/async_routing.ml`

```ocaml
open! Core
open! Async
exception Worker_failure
let ok = function Ok x -> x | Error _ -> failwith "DuckDB error"
let () =
  let raw = ref None in
  let cleaned = Stdlib.Atomic.make false in
  don't_wait_for (
    Monitor.try_with (fun () ->
      let d = In_thread.run (fun () ->
        Exn.protect ~f:(fun () -> raise Worker_failure)
          ~finally:(fun () -> Stdlib.Atomic.set cleaned true)) in
      raw := Some d;
      d)
    >>= fun outcome ->
    (match outcome with
     | Error exn -> assert (match Monitor.extract_exn exn with Worker_failure -> true | _ -> false)
     | Ok _ -> failwith "missing exception");
    assert (Stdlib.Atomic.get cleaned);
    assert (not (Deferred.is_determined (Option.value_exn !raw)));
    In_thread.run (fun () ->
      ok (Duckdb.with_database (ok (Duckdb.Config.create Memory)) ~f:(fun db ->
        Duckdb.with_connection db ~f:(fun c ->
          Duckdb.with_transaction c ~f:(fun tx ->
            Result.map (Duckdb.execute_transaction tx "select 42") ~f:(fun () -> 42))))))
    >>= fun value ->
    assert (Int.equal value 42);
    Stdlib.print_endline "async: monitor=Worker_failure raw-deferred=pending cleanup=done transaction=42";
    Shutdown.exit 0);
  never_returns (Scheduler.go ())
```

### `.local/stage4/probes/eio_routing.ml`

```ocaml
module System_thread = Thread
open! Base
exception Requested
let ok = function Ok x -> x | Error _ -> failwith "DuckDB error"
let () =
  Eio_main.run (fun env ->
    let clock = Eio.Stdenv.clock env in
    let running = Stdlib.Atomic.make false in
    let release = Stdlib.Atomic.make false in
    let returned = Stdlib.Atomic.make false in
    let cancelled = Stdlib.Atomic.make false in
    let context, publish_context = Eio.Promise.create () in
    let rec wait_worker remaining =
      if Stdlib.Atomic.get release then ()
      else if remaining = 0 then failwith "worker release timeout"
      else (System_thread.delay 0.001; wait_worker (remaining - 1)) in
    let rec wait_running remaining =
      if Stdlib.Atomic.get running then ()
      else if remaining = 0 then failwith "worker start timeout"
      else (Eio.Time.sleep clock 0.001; wait_running (remaining - 1)) in
    Eio.Fiber.both
      (fun () ->
        try Eio.Cancel.sub (fun cc ->
          Eio.Promise.resolve publish_context cc;
          let value = Eio_unix.run_in_systhread (fun () ->
            Stdlib.Atomic.set running true;
            wait_worker 5000;
            42) in
          assert (Int.equal value 42);
          Stdlib.Atomic.set returned true;
          Eio.Fiber.check ())
        with Eio.Cancel.Cancelled Requested -> Stdlib.Atomic.set cancelled true)
      (fun () ->
        Exn.protect ~finally:(fun () -> Stdlib.Atomic.set release true) ~f:(fun () ->
          let cc = Eio.Promise.await context in
          wait_running 5000;
          Eio.Cancel.cancel cc Requested;
          assert (not (Stdlib.Atomic.get returned));
          assert (not (Stdlib.Atomic.get cancelled))));
    assert (Stdlib.Atomic.get returned);
    assert (Stdlib.Atomic.get cancelled);
    let value = Eio_unix.run_in_systhread (fun () ->
      ok (Duckdb.with_database (ok (Duckdb.Config.create Memory)) ~f:(fun db ->
        Duckdb.with_connection db ~f:(fun c ->
          Duckdb.with_transaction c ~f:(fun tx ->
            Result.map (Duckdb.execute_transaction tx "select 42") ~f:(fun () -> 42)))))) in
    assert (Int.equal value 42);
    Stdlib.print_endline "eio: running-worker=not-cancelled raw-return=42 explicit-check=Cancelled transaction=42")
```

### `.local/stage4/probes/chunk_async.mli`

```ocaml
val escape : Duckdb.query_result -> (unit, Duckdb.error) result
```

### `.local/stage4/probes/chunk_async.ml`

```ocaml
let escape result =
  Duckdb.fold_chunks result ~init:() ~f:(fun chunk () ->
    let _work = Async.In_thread.run (fun () -> Duckdb.chunk_length chunk) in
    Ok (Duckdb.Stop ()))
```

### `.local/stage4/probes/chunk_eio.mli`

```ocaml
val escape : Duckdb.query_result -> (unit, Duckdb.error) result
```

### `.local/stage4/probes/chunk_eio.ml`

```ocaml
let escape result =
  Duckdb.fold_chunks result ~init:() ~f:(fun chunk () ->
    let _length = Eio_unix.run_in_systhread (fun () -> Duckdb.chunk_length chunk) in
    Ok (Duckdb.Stop ()))
```

### `.local/stage4/probes/owned_async.mli`

```ocaml
val escape : Duckdb.query_result -> (unit, Duckdb.error) result
```

### `.local/stage4/probes/owned_async.ml`

```ocaml
let escape result =
  Duckdb.fold_chunks result ~init:() ~f:(fun chunk () ->
    let length = Duckdb.chunk_length chunk in
    let _work = Async.In_thread.run (fun () -> length) in
    Ok (Duckdb.Stop ()))
```

### `.local/stage4/probes/owned_eio.mli`

```ocaml
val escape : Duckdb.query_result -> (unit, Duckdb.error) result
```

### `.local/stage4/probes/owned_eio.ml`

```ocaml
let escape result =
  Duckdb.fold_chunks result ~init:() ~f:(fun chunk () ->
    let length = Duckdb.chunk_length chunk in
    let _length = Eio_unix.run_in_systhread (fun () -> length) in
    Ok (Duckdb.Stop ()))
```

## Appendix B. Authorized resume verification

Fresh focused verification uses `bash .local/stage4/verify-resume.sh`: the four positive targets build, both routing/whole-transaction probes run, both borrowed-capture targets reject the intended local/global escape (exit 1), and all four existing scheduler/handoff executables pass. The script records the exact expanded command pattern and logs in `.local/stage4/logs/resume/`; it does not change the probe sources. Compiler/Dune versions and source/native hashes match §7. All seven saved preservation hashes pass. Appendix A is checked byte-for-byte against the retained probe source files.

The original run ended before canonical plan persistence. This resume recovers its plan and ignored probes rather than restarting investigation. The initial working diff matched both `.local/stage4/before-plan.diff` and `.local/stage4/before-authorized-resume.diff`; all six unrelated paths and generated task state passed the saved hash checks. Focused fresh probe reruns and final preservation results are recorded in the separate resumed planning report and `.local/stage4/logs/resume/`. No full production-suite or sanitizer rerun, new interrupt experiment, adapter completion or independent-review acceptance is claimed by this documentation slice.
