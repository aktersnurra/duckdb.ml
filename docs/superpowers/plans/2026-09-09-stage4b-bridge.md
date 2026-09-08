# Stage4b: safe bridge execution plan (not implementation)

> Follow writing-plans/executing-plans, interface-first TDD, one writer and
> independent review. No adapter package before the complete bridge gate.

**Base:** accepted Stage4a `2978138c`, Stage4 plan `1333a3de`, published
Stage3c/master `8bb77a2f`. The approved design and the global/Stage4b contracts in
[the Stage4 plan](2026-09-08-stage4-adapters.md) remain authoritative.
**Current deliverable:** non-production packaging fixture plus this plan.
**Not delivered:** a production bridge, final production signatures, adapters,
pooling, engine-lifetime synchronization or native cancellation responsiveness.

## 1. Evidence and first gate

Read `AGENTS.md`, `docs/superpowers/specs/duckdb-design.md`, Stage1–4a validation,
`stage4/packaging/README.md` and
[packaging validation](../../stage4b-packaging-validation.md) before execution.
Use only existing `stage1/run`, `_opam` and `.deps/duckdb`. No reinstall, sudo,
shared/global/editor/opam changes, alternate provider/backend/toolchain mode,
publication or bookmark movement. Stop/report the exact failing command and
state on infrastructure/provider failure. Use `jj`, no raw Git. Preserve the
six unrelated formatting files listed in the global plan; exclude `.pi/tasks`
bookkeeping from authored diffs. Keep generated fixtures/builds/logs ignored.

Three Stage4a prerequisites are separate:

1. **Packaging/type usability:** the new two-package fixture passes an installed
   consumer with private Resource inaccessible. It compiles an opaque request,
   synchronous callback facade and observable settlement. Independent review
   accepted this prerequisite and found B1 ready; the internal-versus-terminal
   cleanup clarification is incorporated below. This is a sequential simulation, not
   evidence of production contention, modes, native ownership or cleanup.
2. **Engine lifetime:** still open. `connection_ref` retains a C shell;
   `connection_clear` still disconnects its engine. An admitted request must own
   engine validity through all selected deliveries, cleanup and owner-close
   paths. No cast or public Resource/native conversion is an alternative.
3. **Actual core boundaries:** still open. Request latching/arming must cover
   each operation below, not only the outer worker callback. Stage4a's unsafe
   `between_calls` control does not enforce safe transaction settlement.

Reuse Stage4a cached source, disassembly, logs and hooks. The pinned engine
`d8cdaa33fda8df955cc76ef58a280f68f4cd43fa` clears interruption during prepare,
InitialCleanup, error processing and transaction preparation. The accepted
one-shot negative is intentional; repeat delivery until native completion is
required. `Duckdb_ffi.interrupt` is noalloc: it **cannot release the runtime**.
Its existing direct live-engine chain is nonblocking; any changed wrapper must
independently preserve that property. Do not redo upstream research.

## 2. Compiler-supported provisional interface shape

These declarations are the **exact Bridge declarations compiled twice** in
`stage4/packaging/core/{packaging_core,resource}.mli.in`: public wrapper and
private Resource. Surrounding abstract `connection` and named `error` belong to
the enclosing module. The production proposal places the same block in
`lib/duckdb/{duckdb,resource}.mli`; `duckdb.ml` already includes Resource.
This is evidence of module/type shape only, NOT that the real Resource supports
its ownership or runtime semantics. Names remain provisional until B1 compiler
controls and B2–B4 safety review. No new local/portable/unique mode is promised.

```ocaml
module Bridge : sig
  type request
  type settlement = Pending | Settled
  val create : unit -> request
  val cancel : request -> (unit, error) result
  val settlement : request -> settlement
  val run : request -> connection ->
    f:(connection -> ('a, error) result) -> ('a, error) result
end
```

The fixture's named error type is exactly:

```ocaml
type error = Closed | Busy | Cancelled
```

Production retains the full existing `Duckdb.error` and composites, adding the
named cancellation case only after compiling against the real interface; it
must not replace that error type with the three-case fixture. No proposed new
FFI/operation-phase `.mli` declaration has been compiled here: B2 must write,
compile and review it first. Do not infer any native representation from the
fixture. The private Resource proposal is the same Bridge block, not public
`native_connection`, ticket constructors or identity setters. Existing private
`with_admission`, `child_operation`, `with_child_snapshot` and
`poison_transaction` signatures need not become public.

### Proposed behavioral contract (to prove, not inferred from types)

- `create` is unbound to a connection, does no dispatch/native work, and starts
  no controller. Request identity is a fresh object, never a wrapping counter.
- `run` consumes its request once, even if cancelled or admission fails. An
  overlapping run on that request gets Busy; later run/cancel gets Closed.
  Cancellation before run suppresses callback, SQL and filesystem work. Pending
  includes never-run requests; it is not a queue or an awaiting worker.
- `cancel` acknowledges the persistent request latch; repeated pre-settlement
  requests succeed. It neither joins nor claims rollback. `settlement` is a
  nonblocking observation of Pending/Settled, not an outcome or user-settable
  completion. `run` returns/raises only after owned settlement. Adapters retain
  their own exactly-once completion containing the actual outcome/backtraces.
- `run` exclusively reserves the underlying owner for the whole synchronous
  callback and settlement. Its connection facade authorizes existing safe
  functions and explicit scoped transactions, not raw transaction SQL. Original
  owner aliases get Busy; every facade/child/transaction alias is revoked on
  exit. No live child can be imported from another request. Owned values may
  escape; a returned handle is only a revoked alias.
- Facade close must not disconnect the pooled owner. Proposed behavior: Busy
  while the lease is active, Closed once revoked; owner close is allowed only
  after settlement. Scope/parent close revokes/drains rather than stealing the
  lease. This is a behavioral test obligation, not implemented by the fixture.
- Run under the existing no-outward-effect barrier. Callbacks are synchronous,
  off-scheduler; no async core callbacks or borrowed/domain transfer. Do not
  make an Async/Eio call inside them, even if an owned-capture control compiles.
- Expected cancellation is a named result. Unexpected callback/worker failures
  keep exception identity and captured backtrace. Preserve existing
  Rollback_failed, Rollback_exception, Cleanup_exception and Exn.Finally
  combinations; do not flatten into strings. Cancellation wins over otherwise
  successful settlement if latched before terminal transition. Non-success
  primary/cleanup diagnostics are not erased by that classification: the
  adapter's private outcome must retain them alongside cancellation. B1/B4
  tests must check backtraces, not merely constructor names.

## 3. Ownership and synchronization to implement

### One owner, distinct leases

Do not duplicate Resource admission in a new scheduler abstraction. Refactor
Resource's connection into a shared owner plus optional request facade identity.
The owner contains native connection, gate, children and transaction lease;
facades reference that same owner. Add a **request lease distinct from the
transaction lease** so `with_transaction facade` can legitimately acquire its
inner transaction without releasing the outer request lease. Each transaction
and child remembers the request identity that admitted it. Every admission,
metadata operation, close and force-close must resolve/check that identity.
Do not let `transaction_connection` recreate an unscoped owner capability.
Reject initial request admission with busy/transaction/result ownership, and
with Live_children for otherwise idle prepared children. Never silently adopt
someone else's prepared/result/appender tree.

Request state authority uses named states: Fresh, Admitted, Running,
Quiescing, Settling, Finished. Fresh is the bridge counterpart of the adapter's
queued/dispatched states, not a bridge admission queue. Adapter dispatch checks
and Bridge.run's final admission check are both required. Native-call phase is
separate: idle, interruptible user/control work, internal cleanup, closed. Do not
use Running to mean both engine execution and all cleanup.

Use one short independent interrupt-state mutex for current request identity,
lease identity, cancellation latch, delivery reservations and disarm. Neither
SQL, whole callbacks, destruction, scheduler effects nor condition/join waits
hold it. Define lock order before coding: owner admission may install/remove a
lease under its own gate, but never wait for a controller holding that gate;
controller uses only interrupt state then native delivery guard. No reverse
native-to-ML lock acquisition. Wait for tickets outside both gates. Test lock
order on all exception/discard paths.

### Bounded independent control

Initial controller design: at most **one owned system-thread controller per
admitted connection-bearing bridge request**, zero for Fresh/queued/dispatched
requests, zero after join. The admission invariant makes this bounded by live
leased connections (and thus by an adapter's configured connection count), not
by arbitrary queue length. Do not use Async/Eio's shared database offload pool
for these controllers. No extra control queue or background scheduler. The
controller is started after exclusive admission and before initial native work;
thread-start failure revokes/releases admission and retains the exception.
Worker and controller hold strong owner/request roots until quiescence.

Each controller periodically checks the latch and current native-call phase,
reserves a ticket, and attempts the real interrupt only if identity, lease and
eligibility still match **after any pause**. A short bounded retry delay avoids
busy-spinning; there is no promised interrupt count or latency. A ticket is
permission to attempt, not permission to use a previously loaded raw pointer.
Controller thread exits/join completes before ML-level rollback/request cleanup/
owner release. Internal native cleanup instead establishes native-delivery
quiescence before destruction as described below; the still-live controller can
only attempt and skip ineligible delivery. For another user native call within
the same request, quiesce/disarm the prior call, check the persistent latch, then
arm that call; the one owned controller need not be recreated per call. A request cancelled while
idle does no native delivery and no further user call. Control progress must
still be demonstrated with every database worker occupied.

This per-lease bound is not a process-wide bound on callers creating unlimited
connections. Pool sizing/admission is still adapter-specific. Do not expose a
generic scheduler functor, executor, pool or control-worker API in the core.

### Native completion and lifetime are B2's hard gate

ML disarm after `F.execute` returns is too late: `ml_duckdb_execute` calls
`clear_work` (result/prepared/extracted/input destruction) **before returning**.
Similarly prepare/fetch/appender creation contain internal destruction. A test
wrapper flag before execute is not post-InitialCleanup acknowledgement.

The proposed native implementation gives each connection owner a small native
phase/delivery guard, shared by every operation and close path. Delivery checks
current native phase and live engine under this guard, never a cached pointer.
For the noalloc interrupt entry use a **nonblocking try-acquire**: contention
skips an attempt, retry happens in ML. Under the guard only a phase/identity
check and the already-audited direct interrupt may run. Never allocate, wait,
sleep, callback, destroy or enter/leave a blocking section there. Ordinary
worker transitions use the same guard with the runtime already released;
mark noninterruptible before internal destruction, without holding the guard
through destruction or runtime reacquisition. Then no new native delivery can
start; completed guarded delivery is already quiescent. ML reserved-but-paused
tickets subsequently fail eligibility and retire before owner settlement.

The native phase prevents delivery during `F.execute`'s internal cleanup even
while ML still regards the foreign call as Running. Native phase is NOT the
request latch: phase rearming after engine resets must never clear cancellation.
The proposed native request-state allocation is stable C-owned storage retained
through delivery retirement, separate from the engine connection shell. It
contains the native-visible latch and a non-reused lease identity; never read a
movable OCaml identity/value with the runtime released. ML request identity and
native lease state are installed together under interrupt-state synchronization.
Cancellation publishes the native latch before acknowledgement when bound;
unbound cancellation is copied during lease installation under that same lock.
Do not clear either latch on call rearm. Do not recycle/free native identity
storage until every selected delivery has retired, preventing address-reuse ABA.
The C/ML representation and ownership of this allocation require B2's compiled
FFI prototype and native lifetime tests; they are not established by packaging.
Each internal transition from prepare/metadata work to another native user call
must consult the native-visible persistent cancellation state before entry;
otherwise one FFI call could continue after its ML entry check. Internal cleanup
must remain available when the latch is set. B2 must compile a private FFI state
shape and test atomics/visibility with actual wrappers before adopting this
mechanism. If nonblocking delivery plus all internal transitions cannot be
proved, **stop for review**; do not fall back to one-shot interrupt, broad
Running-through-cleanup delivery or a noalloc call that releases the runtime.

Every `connection_clear`/disconnect path first marks native closing and excludes
delivery under that same guard. Reference retention alone is insufficient.
Request roots prohibit finalization of active owner slots; the native closing
check remains necessary for `finish_*`, child unref, native finalizers and unsafe
fallbacks. A finalizer must never wait on an ML controller that needs its runtime
lock. Audit/review the root and native-guard invariant rather than acquiring an
ML mutex from a finalizer. Normal explicit close waits for ML tickets/controller
join before engine destruction; native guard ensures no delivery overlaps the
engine transition itself. Native guards never wait for reacquisition of the
runtime while held. Unsafe simultaneous FFI use stays outside the safe API.

## 4. Source-to-boundary map (actual current core)

All filenames in this table are current source, not hypothetical adapter calls.
Every row requires a latch/phase test or an explicit proved noninterruptible
classification. Pure scalar access is not a reason to arm engine interruption.

| Source seam | Required boundary and settlement action |
| --- | --- |
| `resource.ml`: `execute`, `execute_transaction`, `with_admission`, `child_operation` | Check facade/transaction/request identity, owner availability and latch under admission; no reentrant owner use. Public close is cleanup, not user SQL. `raw_execute` must distinguish user/BEGIN/COMMIT versus rollback cleanup; its current `control : bool` alone is insufficient. |
| `resource.ml`: `raw_execute`; `resource_stubs.c`: `ml_duckdb_execute` | Check before extraction, prepare and execute (including internal resets), and on return even after native success. Native phase ends before `clear_work`; ML `F.clear_work` fallback must see cleanup-safe state. Control SQL remains private. |
| `resource.ml`: `with_transaction`, `revoke_and_drain`, `rollback`, `discard`, `release` | Outer request lease spans BEGIN, callback, child revocation/drain, COMMIT or rollback. Check latch immediately before BEGIN and **again immediately before COMMIT**, after callback and all child cleanup. Poisoning/latch survives ignored errors and caught exceptions. Disarm/detach all possible deliveries, await foreign completion and join controller before rollback and cleanup. Never release request lease just because transaction `release` ran. Failed/exceptional rollback discards. |
| `resource.ml`: `with_child_snapshot` | Same pre-BEGIN, post-work and pre-COMMIT checks, including temporary parameter-schema validation and materialization. Failure path's direct `destroy_connection` must retire request state too, not only close children. |
| `query.ml`: `prepare_on`, `validate_parameter_schema`, `reset`, `bind`, `execute_prepared` | Both initial prepare and fresh schema-prepare need individual phase/latch boundaries. Bind/reset can release runtime and reset engine state; keep bindings unusable on failure. Check before real execute after validation, before result publication/reservation, and clean a produced-but-cancelled result. Existing private snapshot COMMIT is covered separately. |
| `query.ml`: `fold_internal`, `fold_rows`, result/prepared close; `prepared_stubs.c`: prepare/fetch/clear helpers | Check at each chunk fetch and between callback batches, including Stop/empty/exhausted success before request settlement. No per-cell offload. Preserve local borrowed callback/effect barrier; native fetch's old-chunk destruction is cleanup phase before rearming fetch. Quiesce before result/chunk/prepared destruction; exceptional closes still consume admitted results. |
| `appender.ml`: `open_appender`, `operation`, `append_rows`, `flush_appender`, `close_appender`, `destroy`, scoped close | Check create/metadata phases, each batch and explicit/automatic flush, then latch/poison even if caller drops error. A normal close that flushes buffered rows is user work until flush finishes; split its flush from clear/destroy phase. Cancellation cleanup always clears before destroy, never flushes discarded rows. `with_appender` owns its transaction; transaction variant uses existing token. |
| `appender_stubs.c`: metadata query, append loop, `close_native`, `delete_owner` | Metadata prepare/execute/fetch and their cleanup need phase visibility; cancellation between internal rows/batches prevents next mutation/automatic flush. Copied cell memory remains owned. `clear_appender_input` is storage free; `finish_appender_close` can still invoke engine close/clear/destroy. |
| `parquet.ml`: `fold_rows`, `export`, `publish`, `remove` | Check before each next file, before temp reservation, COPY preparation/bind/execute, and immediately before link/publication. `export` publishes **inside** `with_transaction` callback, so publication precedes COMMIT today. Keep that fact explicit; don't silently reorder semantics. Latch after publish still suppresses COMMIT but cannot unpublish the final output. Path resolution/temp reservation are synchronous filesystem work on worker, not scheduler. |
| `local_file_stubs.c`: publish/remove and finish | Link/unlink normally unlock, but interrupting DuckDB cannot cancel filesystem calls. Check latch before publication entry/decision and after return; preserve committed/published effects if cancellation races after entry. Cleanup only owned temp; never unlink final output on cancellation. Finish frees copied strings/storage, not file cleanup. |
| `resource.ml`: `close_connection`, `force_close_connection`, `destroy_connection`, database close/force-close, `force_close_child`, `destroy_children` | Manual Busy/Live_children vs scoped revoke/drain stays distinct. All paths participate in request revocation and delivery retirement; parent database revoke-all-before-wait is retained. Keep strong native roots, block new admission, then join/disarm before destruction. Scope failure and transaction/snapshot discard are not exempt. |
| `resource_stubs.c`: connection/database clear, delete/unref, finalizers; `query_native.h`; `prepared_stubs.c`: delete/finalize; `appender_stubs.c`: delete/finalize | Shell lifetime, live engine validity and finalizer order are different. Protect engine close against delivery under native guard and root active owner slots. Native parent refs do not themselves preserve a connected engine. Audit every path to disconnect, not just public `close_connection`. |

### Call/commit/publication linearization

A latch check followed by an unlocked call is not enough to claim no work after
cancellation. Native-call admission/arming and latch publication must have an
explicit linearization under request/native synchronization. If cancellation
wins before call admission, suppress that call. If the call was admitted first,
treat it as in flight: cancellation may race engine entry/reset and repeated
delivery must survive; its effects might already be durable. Test both sides
with real entry gates, not elapsed time. COMMIT and link/publication each need
an explicit decision/entry gate with the same distinction. After terminal
settlement the outcome is fixed; late cancellation cannot affect the next
request. Do not claim cancellation proves no committed write or output file.

### Held-runtime cleanup audit and fallback gate

Normal execute clears work before reacquiring; normal disconnect/database close,
prepared close/result close, appender close and link/unlink release the runtime.
But `clear_work`, `finish_*`, native finalizers and parent-shell unrefs can still
run destructors while holding it after exceptional entry. `finish_local_file_work`
is only storage free. Existing pending-action/inner `Sys.with_async_exns`
boundaries and single-Break retry rules remain; cancellation must not use Break.

For ordinary bridge cancellation require native interrupted return followed by
noninterruptible, unlocked destruction and rollback. Exercise *actual held
native cleanup* with Async and Eio heartbeat observers; ML worker gates alone
are insufficient. Assert finish paths have no remaining engine work on ordinary
cancellation. If any ordinary cancellation reaches a potentially blocking locked
fallback, change that specific normal cleanup path before accepting the bridge.
Do not remove necessary signal/finalizer backstops or claim universal finalizer
responsiveness. Unusual signal/OOM/foreign-runtime limits remain explicit.

## 5. Executable tasks and red/green gates

### B1 — first production task: real Resource request lease and revocation

**Precondition:** independent approval of this plan and packaging evidence.
**Purpose:** implement the compiler-checked shape against real owner admission
without yet calling native interrupt. Cancellation in this task is latched,
cooperative at ML boundaries only; long native work may finish normally. B1 is
an unpublished intermediate slice, **not a usable/accepted cancellation bridge**.
Never install it as an accepted adapter dependency. B2 is required before any
running-interrupt safety/responsiveness claim. No adapter code in B1.

**Exact change set for B1:**

- `lib/duckdb/resource.mli`, `resource.ml`: Bridge block, named cancellation
  case, shared owner/facade representation, request lease distinct from tx,
  request-state mutex and checks/revocation. Existing admission stays here.
- `lib/duckdb/duckdb.mli`: matching Bridge declarations and error case with
  intermediate limitations. `duckdb.ml` needs **no edit** (`include Resource`).
- `lib/duckdb/query.ml`, `appender.ml`, `parquet.ml`: only existing seam calls
  needed for facade ownership and cooperative latch checks in the map above;
  no API rewrite, scheduler calls or new public callbacks. Before new private
  helper implementation, write its `resource.mli` declaration and compile a
  same-package positive control; freeze no uncompiled helper in this plan.
- `test/test_adapter_bridge.mli`, `.ml`: `val run : unit -> unit`, main once;
  uses real Duckdb only for safe operations, FFI only for resource counters.
- `test/adapter_bridge_hooks.c`: test-only linker wrappers described below;
  no exported production test API.
- `test/check_adapter_bridge_interfaces.sh`,
  `test/adapter_bridge_compile/{positive.ml,positive.mli,private_resource.ml.fail,forge_request.ml.fail,forge_pointer.ml.fail,domain.ml.fail}`.
- `test/dune`: bounded executable/runtest and compile controls only. Use
  `base threads duckdb duckdb-ffi evidence_support` for runtime test (reuse
  Stage4 support); wrapper link flags below. No `lib/duckdb/dune`, root
  dune-project, opam or preserved smoke-script changes.
- `docs/stage4b-validation.md`: new incremental log, explicitly B1 incomplete.

**TDD sequence:**

1. Write new `.mli`, positive consumer and `test_adapter_bridge.ml` cases
   before Resource implementation. First tests use `Duckdb.Bridge.create` so
   the initial command below must reject missing Bridge; then add real `.mli`
   declarations and record implementation/interface mismatch. Do not count
   unrelated Dune errors as these reds.
2. Add synchronized tests: owned return; copied facade/request aliases revoked
   on success/error/exception; cancellation before run gives SQL count zero;
   Busy for simultaneous run/nested owner use; Busy for facade close while live;
   live prepared/result/appender admission exclusion; original owner usable
   again only after settlement. Two `Evidence_support.with_worker` system
   threads handshake with an atomic callback gate; no sleeps as admission
   oracle. Release all gates before mandatory joins, including assertion exits.
3. Add latch tests inside a real transaction: execute INSERT, cancel at a
   handshake boundary, deliberately ignore next-call Cancelled and return Ok;
   COMMIT count must be zero, ROLLBACK one, observer query sees zero rows.
   Include callback exception caught locally before Ok, dropped result error,
   and query child snapshot path. Cancelled appender cleanup must discard not
   flush. A cancellation between Parquet files must never open the next file.
4. Implement shared Resource owner/facade and latch checks minimally. Thread
   creation/controllers/native interrupt are not part of B1. Preserve scope
   barrier and exception/backtrace composites while updating transaction paths.
   Add a source-named effect-denial case proving the outer handler sees zero
   deliveries and rollback still happens. Facade close must not recurse into
   its own lease drain; original parent scope waits from a distinct thread.
5. Native wrappers in `adapter_bridge_hooks.c`: count `duckdb_execute_prepared`,
   classify/count BEGIN/COMMIT/ROLLBACK in `duckdb_query`, count/gate
   `duckdb_disconnect`. Reuse Stage4a atomic monotonic watchdog style. All gates
   belong to already-unlocked foreign work; interrupt wrapper is count-only.
   B1 ML call-boundary gate lives in the callback. Link only this test with
   `--wrap=duckdb_execute_prepared`, `--wrap=duckdb_query`,
   `--wrap=duckdb_disconnect`; do not modify production for public test hooks.
6. Positive interface controls compile first. Negatives assert highlighted
   source/value and exact reason: private Resource unbound, unit not request,
   nativeint not safe connection, real connection not portable for
   Domain.Safe.spawn. Copy the source-named pattern, not preserved scripts.
   Do not assume the sequential fixture tested real connection transfer modes.
7. Mutation red: bypass only the real pre-COMMIT latch check **and** keep a
   swallowed-error case with no earlier poisoning as the oracle. Require a
   committed-row/count failure, restore and rerun green. Separately bypass
   facade active check to demonstrate alias-revocation red. If other defenses
   keep either mutation green, refine the case/record that control honestly;
   never weaken defenses just to obtain red.
8. Run focused commands then full baseline regression and preservation hashes.
   Independent review B1 for representation/admission/composites only. No
   running interruption or bridge completion claim; record B2 open explicitly.

```sh
# Initial interface red; same target becomes green after implementation:
stage1/run build test/test_adapter_bridge.exe
stage1/run exec --no-build -- ocamlc -version
stage1/run exec --no-build -- dune --version
# test/dune declares @adapter-bridge with 60-second timeout and compiler controls:
stage1/run build @test/adapter-bridge
for iteration in 1 2 3 4 5; do
  timeout 60 stage1/run exec --no-build test/test_adapter_bridge.exe
done
clang -std=c11 -Wall -Wextra -Werror -fsyntax-only \
  -I.deps/duckdb -I_opam/lib/ocaml test/adapter_bridge_hooks.c
stage1/run build @all
stage1/run runtest --force
sha256sum --check .local/stage4b/preserved-six.sha256
```

If the real facade/transaction/child relationship cannot preserve all existing
admission and dynamic-revocation tests with this signature, stop and review a
new **compiled** interface; do not expose Resource or a raw handle workaround.

### B2 — native lifetime/phase guard and actual running interruption

Only after B1 review. Extend `lib/ffi/duckdb_ffi.mli/.ml`, `resource_stubs.c`,
`query_native.h`, `prepared_stubs.c`, `appender_stubs.c` at the mapped boundaries;
Resource owns the controller/latch integration. No scheduler dependency.
Write private FFI interface declarations and test C/ML externals first, then
compiler mismatch red. Native operation classification/latch visibility must
cover internal calls in a single FFI entry; the current raw `interrupt` alone
is insufficient. Include bind/reset in `lib/ffi/typed_stubs.c`: these calls release the
runtime, and temporal binding destroys temporary duckdb_value objects internally.
`reset` calls `duckdb_clear_bindings`; do not conflate that with the engine's
query-start interrupted-flag resets. Classify/check these boundaries explicitly. Retain `local_file_stubs.c` behavior unless publication-entry
linearization specifically requires a native gate; no final-output deletion.

Extend `test/adapter_bridge_hooks.c` with the Stage4a pre/post execute and
pre-disconnect gates; count-only interrupt wrapper. For internal cleanup gate
wrap `duckdb_destroy_result`, `duckdb_destroy_prepare`, `duckdb_destroy_extracted`
and appender clear/destroy; gates release runtime by virtue of the real worker
call, never from the noalloc interrupt chain. Hold a delivery reservation in ML
between selection and native try-delivery using a **test-link-only private
hook**, not a public API; declare its small interface first and restrict it to
the test-linked unit. Production cannot wait on a test controller hook. If
link wrapping cannot reach the real post-selection seam without an unsafe ML
callback, stop to review the minimal private test linkage before proceeding.

Real-safe-bridge tests must reproduce Stage4a suppressed Queued/Dispatched,
one-shot/reset negative as a separate unsafe control, latched pre-entry/reset,
real running native interrupted return, transaction interruption, between-call
suppression, selected-ticket/retirement, stale A versus reused B, close gate,
terminal repeated cancel and native error. Do not substitute the simulated
fixture or test-owned unsafe slot for the production request in positive races.

Native shell references are not the oracle: require zero disconnect/reuse while
selected delivery exists, zero late native interrupt after disarm, native delivery
exclusion/quiescence before each internal destructor, and complete ticket retirement
and controller join before terminal ML request cleanup, rollback, owner release or
disconnect. Require a fresh lease identity on reuse. A live controller may skip
ineligible delivery during internal cleanup; that is not terminal retirement. Initial
interrupted connections are discard-only, even if SELECT 1 would succeed.
Native phase gate must prove no interrupt during F.execute internal cleanup.
Remove post-pause eligibility or native cleanup disarm in independent mutations;
each must fail its named race before accepting restored green.

### B3 — complete per-operation latch and publication coverage

Extend the existing Query/Appender/Parquet paths and same bridge tests/hooks;
add source-named test modules with `.mli` if size warrants, not another framework.
Finish every row of §4, including internal metadata/bind/reset/fetch, automatic
appender flush, snapshot pre-COMMIT, COPY, temp reservation and link. Cancellation
latched during each kind must suppress next admitted user work even when errors
are ignored or exceptions caught. Long batches need native per-row/batch latch
checks as appropriate; no per-cell scheduler work.

Hold COMMIT/COPY/link at **before decision/entry and after real operation** gates.
Use a separate observer connection/file read to record durable effects. Before
COMMIT decision: zero COMMIT and rollback; after COMMIT entry: committed writes
may exist despite cancellation. Before publication decision: no final file;
after real link: final file remains, only temp removed, even if later rollback
succeeds. Current export link-before-COMMIT means a final file may survive
pre-COMMIT cancellation. Verify Destination_exists and unlink failure retain
correct primary/cleanup outcomes. Never silently turn error/exception into Ok.

Inject rollback result failure and exception after a primary cancellation/error/
exception; verify composites and original backtraces, no release as reusable,
complete discard or reported close failure. Exercise all manual/scoped close,
parent revoke, result/appender force-close, snapshot discard and native-finalizer
fallback reachability. GC may diagnose fallback, never substitute for ordinary
settlement; live/fallback counts return to baseline without GC on normal paths.

### B4 — full bridge acceptance (mandatory before Stage4c)

Add `test/install_adapter_bridge_smoke.sh` (do not edit preserved install smoke)
and installed positive/negative consumer templates. Use separate disposable
source-relative build trees and prefixes under `.local/stage4b`, existing local
DuckDB, no dependency reinstall, no shared package overwrite. Install FFI then
safe package independently; consumer sees only prefix + pinned dependencies,
never source `_build`, private `.cmi` paths or unsafe conversion. Check installed
core META stays `base duckdb-ffi threads`, no Async/Eio dependency or scheduler
startup. Run public owned request/transaction and source-specific private
Resource/forged request/pointer/domain/borrowed-escape negatives.

Add test-only `test/test_adapter_bridge_async.mli/.ml` and
`test/test_adapter_bridge_eio.mli/.ml` targets, reusing the Stage4a scheduler
routing cases. These are **tests, not adapter packages**. Prove scheduler
heartbeat while actual execute, rollback, result/prepared/appender destruction,
disconnect, database close, publication and unlink are held in native code on
ordinary cancellation. With every database offload slot occupied, controller
progress and native interrupted completion still occur; no Async shared-pool
configuration change. Preserve abandoned Async completion and protected Eio
settlement/error/backtrace behavior. No async callback enters a core scope.

Final acceptance checklist (all required):

- [ ] Every Stage4a race rerun through real safe Bridge, five repetitions,
      including reset loss control and independent progress under occupied slots.
- [ ] Alias/request/transaction/child revocation, concurrent/nested admission,
      live prepared/result/appender exclusion and close-versus-delivery tested.
- [ ] Latch survives successful native return, dropped/caught cancellation and
      native failures; no later user call or COMMIT/publication when cancel wins.
- [ ] Native delivery excluded/quiescent before each internal destructor;
      all tickets retired and controllers joined before terminal ML request
      cleanup, rollback, discard, owner release or disconnect. Internal cleanup
      may retain a controller that can only skip ineligible delivery; no timeout
      authorizes recycling.
- [ ] Rollback/cleanup failure retains all outcomes/backtraces and discards;
      committed/published before/after race facts independently observed.
- [ ] Installed consumer works, Resource remains private, forge/mode negatives
      reject intended source; production dependency graph remains scheduler-free.
- [ ] Ordinary cancellation never reaches blocking held-runtime fallback;
      actual native-cleanup heartbeats and independent control progress pass.
- [ ] Full build/forced Stage1–4 regression, C warnings-as-errors and authored-C
      ASan/UBSan pass within their limits; no claim whole-process LSan passes.
- [ ] Independent specification and implementation review accept the complete
      bridge and its exact final public/private signatures, not merely B1.

Run B1 commands after each production slice, plus:

```sh
stage1/run runtest stage4 --force
bash test/install_adapter_bridge_smoke.sh
# New test/dune aliases must explicitly depend on all executables/hooks:
stage1/run build @test/adapter-bridge-responsiveness
ASAN_OPTIONS=detect_leaks=0:halt_on_error=1 UBSAN_OPTIONS=halt_on_error=1 \
  timeout 120 stage1/run exec --profile stage3a-sanitize \
  --build-dir "$PWD/.local/stage4b/build-sanitize" test/test_adapter_bridge.exe
```

Record exact command/exit/source pins, counters and heartbeat handshakes in
`docs/stage4b-validation.md`. A test timeout is failure, never a bounded-cleanup
claim. Unsuppressed whole-process LSan remains failing; authored-C sanitizers do
not instrument DuckDB/runtime/Base. OOM, arbitrary/repeated signals,
asynchronous-exception acquisition/bookkeeping gaps, foreign callbacks that
never return, invalid unsafe FFI use and crash/hostile-filesystem limits remain.

**Stop/review:** native guard nonblocking proof, finalizer/engine validity,
internal cleanup visibility, facade admission/modes, ordinary-cleanup runtime
release, or independent control progress failing blocks bridge acceptance.
Escalate safety/scope changes instead of switching modes or weakening guarantees.
Only after B4 acceptance return to the Stage4c Async plan, then Stage4d/e/f.
