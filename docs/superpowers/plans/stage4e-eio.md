# Stage4e Eio concrete execution plan

Authority: approved `duckdb-design.md`, Stage4e of
`2026-09-08-stage4-adapters.md`, and the bounded FOUNDATION continuation.
This is an Eio-only SQL / synchronous whole-transaction slice, not Stage4f.

## FOUNDATION — independently reviewed and parent-accepted

1. **Capture before publication.** `Duckdb_eio.capture` records core results or
   exception/raw-backtrace pairs inside each native offload. `offload` also
   captures dispatch failure. The public `.mli` defines phase-tagged failures,
   result-valued `Lifecycle_errors`, exceptional `Lifecycle_failure`, and
   `Cancelled_with_failures`. A lone callback exception reraises its original
   trace. Ordinary native interruption retains idiomatic Eio cancellation;
   additional cleanup/raised constituents are never dropped.
2. **Bounded admission and one lease.** Admission increments `owned` before
   creating a producer; `owned <= connections + queue_capacity` is enforced
   without integer addition overflow. Each admitted request owns one Bridge
   latch and completion. Its scheduler-local state is Admitted, Waiting (with
   a private cancellable sub-context), Running, or Settled. Only semaphore
   waiting is cancellable; cancellation removes that waiter without acquiring
   a native owner, then the protected producer releases admission exactly once.
   If permit handoff wins removal, the producer records the permit and checks
   cancellation before leasing; settlement releases that permit without SQL.
   At most `connections` offloads hold a connection lease, including its
   retirement and replacement.
   An accepting, successful, uncancelled SQL outcome alone may return Idle;
   all transactions and other outcomes retire. There is no health-check query.
3. **One already-registered drain.** `create` arms an ordinary-context daemon
   before returning. Explicit shutdown/replacement failure resolves `stopping`
   once; parent cancellation wakes the same daemon directly. The daemon enters
   protection only AFTER this trigger, stops admission, removes queued waiters
   and latches running Bridge requests, joins every admitted settlement and
   acquires every permit, then closes idle slots and the database
   sequentially before resolving the shared shutdown result. No shutdown fiber
   is forked on an already-cancelled switch. Close failure does not prevent
   attempting independent remaining closes. Retirement close failure also stops
   admission and is retained by shared shutdown.
4. **Producer settlement.** A producer captures its outcome, settles native
   owners, captures replacement/close faults, releases only an acquired permit,
   removes its owned request, and publishes completion. Shutdown removes queued
   waiters promptly; they publish `Pool_shutdown` without taking a native owner.
   A cancelled queued caller removes its semaphore wait; a dispatched caller
   latches its Bridge. Both wait protected for producer settlement, not vice
   versa. The daemon joins queued settlement as well as native retirement.
5. **Pinned lifetime proof.** Eio revision
   `7de26f5331f1e7aac1c086a5ebe849dd940b5c3e`:
   `lib_eio/core/switch.ml:94-111` joins fibers before release hooks;
   `lib_eio/core/fiber.ml:13-44` skips forks when the switch is cancelled;
   `lib_eio_linux/sched.ml:423-427` enters a fork child before resuming its
   parent. `lib_eio/unix/thread_pool.ml:69-85,107-113` returns workers to the
   free pool before enqueueing completion and terminates the thread pool when
   its scheduler scope exits. The protected-caller native tests below establish
   that the daemon really cancels before joins; this is not inferred from the
   word "daemon". No public core/native owner escapes the private worker capsule.

### Covering checked evidence

`test/eio/foundation_eio.ml`, paired explicit interface and executable-only
`foundation_hooks.c` run real Eio operations on the default **linux** backend:

- `reuse_and_exception`: native SQL reuse counters, unconditional successful
  transaction retirement, original callback trace prefix/source frame, real
  subsequent native SQL and final exact owner inventory.
- `replacement_failure`: actual failed native connect; queued SQL suppression;
  exactly one drain; database-close gate proves concurrent shutdown callers
  wait while lifecycle is already Stopping; repeated shared failure settles.
- `core_and_close`, `raised_and_close`, `independent_close`, `partial_creation`,
  `automatic_close`: actual destructor calls followed by ordinary-ABI raised
  failures; every primary/cleanup constituent retained, all independent owners
  attempted, and unobserved automatic cleanup failure reaches switch owner.
- `parent_failure`, `parent_cancellation`: running native query held at actual
  entry, queued work, both callers protected. An independently live outer fiber
  releases the gate only after observing a real Bridge/native interrupt (or
  releases on a bounded test failure). Assert real engine interruption, zero
  queued execution, producer completion and exact owner inventory at switch exit.
- `cancellation_cleanup`, `ordinary_cancellation`: native interruption and
  original Eio cancellation; actual Bridge failure-cleanup close exception
  retains the core primary/cleanup composite and trace rather than flattening it.

Checked commands through unchanged `stage1/run`:

```sh
stage1/run build @all
stage1/run runtest test/eio --force
cc -std=c11 -Wall -Wextra -Werror -fsyntax-only -I.deps/duckdb -I_opam/lib/ocaml test/eio/foundation_hooks.c
for i in $(seq 1 20); do echo "RUN $i"; timeout 60 stage1/run exec test/eio/foundation_eio.exe || exit; done > .local/stage4e/foundation-runs.log
```

All pass: 20 repetitions, 220 foundation test-group passes; prior
`adapter_eio` basic SQL/transaction/callback/already-cancelled consumer also
passes. Native fault wrappers use real destructors then raise with the runtime
reacquired, at allocating ABI only; native gates never wait in noalloc or
runtime-locked paths. GNU `--wrap` identifiers and POSIX feature-test macro are
intentional tool protocols, independently compiled with strict authored-C flags.

## CANCELLATION — historical checks; review found missing causal rows

`test/eio/cancellation_eio.ml` is compiled into the native foundation harness
so it uses the same real DuckDB entry/interrupt counters (not final exception
classification alone), on the default **linux** Eio backend. Four deterministic
cases were originally claimed to cover the bounded cancellation/admission slice
(the review invalidated the queued-state and race claims; see corrections below):

- a held native A plus a cancelled admitted queue producer proves no queued SQL
  reaches the native entry counter and does not interrupt unrelated A;
- dependent FIFO statements, finite overflow, and `queue_capacity = 0` prove
  FIFO admission and that rejected requests have no native execution;
- a real held/running cancellation observes `duckdb_interrupt`, preserves the
  original `Requested` identity, waits terminal cleanup, then proves B executes
  and receives no stale A interrupt; an already-cancelled caller starts no SQL;
- whole transactions retire their slots, and a transaction callback's adapter
  reentry is rejected before native scheduler effects.

The original foreign-return/terminal claim was not established: held native
entry is not a terminal boundary, and pre-admission cancellation is not an
already-resolved completion. It is retained as historical false-oracle context;
its corrected coverage is recorded below.
Native counters are executable-only observers; no owner is exposed to ML.
Historical commands (passing them did not establish the missing states):

```sh
stage1/run build @all
stage1/run runtest test/eio --force
cc -std=c11 -Wall -Wextra -Werror -fsyntax-only -I.deps/duckdb -I_opam/lib/ocaml test/eio/foundation_hooks.c
for i in $(seq 1 10); do timeout 90 stage1/run exec test/eio/foundation_eio.exe; done
```

All pass. The harness prints `cancellation backend=linux`; each repetition
passes the four cancellation groups plus the eleven foundation groups. This is
not a cleanup, saturation, installed-package, sanitizer, or final-review claim.

## BEHAVIOR correction — findings 1–3 implemented and checked

Actual review authority: `.local/stage4e/review-recovered.json`; this is not
Stage4e acceptance. Source-named corrected evidence:

- `Cancellation_eio.queue_and_admission`: N=1/Q=1; A held at native entry;
  independent `Queue_full` proves B admitted BEFORE cancellation. B settles
  while A remains unresolved; native open/connect/close/SQL/interrupt inventory
  is unchanged. C then occupies freed Q (another independent overflow), and
  A/C/subsequent SQL finish once on the same connection.
- `Cancellation_eio.queued_shutdown`: overflow proves B admitted; shutdown
  removes B with `Pool_shutdown` while A is still held and shutdown unresolved.
  Existing FIFO/Q=0/overflow, running cancellation, parent-switch, saturation,
  retirement/replacement and cleanup-failure tests still pass.
- `Foundation_eio.already_cancelled_creator`, `cancelled_creator_open`,
  `cancelled_creator_connect`, `cancelled_creator_cleanup`,
  `creator_cancelled_during_cleanup`: caller `Cancel.sub` is distinct from a
  live enclosing switch. Zero acquisition on pre-cancel; true held native
  open/connect or partial-init close entry, runtime-release/pending-completion
  checks and heartbeat; no pool publication; acquired owners closed before
  returning cancellation, including all injected cleanup/partial-init failures.
- `Cancellation_eio.transaction_isolation_and_reentry`: create, execute,
  transaction and shutdown all return `Reentrant_call` in the actual synchronous
  worker callback before scheduler effects or extra native open/connect/SQL/
  interrupt/close work. This does NOT close finding 5's transaction-isolation,
  escaped-token or callback-effect-barrier matrix.

`create` now checks the caller sub-context before protection (through public
`Cancel.sub`) and after protected initialization, independently of the supplied
switch. It checks again after the daemon-registration scheduling boundary; if
cancelled there it joins the single registered drain rather than closing twice
or publishing the pool. Captured cancellation/backtrace and cleanup algebra are
preserved. Public signatures are unchanged; `.mli` documents the corrections.

Focused red/green logs, exact commands and repetition evidence are under
`.local/stage4e/behavior/`; numbered disposition and report pointer are in
`.local/stage4e/finding-disposition.md`. Findings 4–7 remain for NATIVE_MATRIX,
RACES_MODES and FINAL. Prior passing/false-oracle history is not erased.

## Historical remaining bounded assignments — superseded by correction batch

- **CLEANUP:** remaining child-resource native heartbeat/saturation/race matrix,
  abandoned/cancelled shutdown variants, partial-init/replacement race expansion,
  new mutation controls and authored-C sanitizer coverage.
- **INTEGRATION:** example, isolated installed-package consumer/privacy checks,
  full forced regression, consolidated validation/manifests and final review.

No core/FFI/Async changes, dependency/provider changes, backend selection,
publication, streaming API, native-work timeout/recycle policy, or global changes
are authorized by this plan. Nonreturning native/user work can prevent shutdown.

## Three-oracle correction reconciliation — independently closed and accepted

The historical `.local/stage4e/closure-review-recovered.json`
closed production findings 1–3 and package finding 6 but rejected three causal
oracle claims in the previous correction batch. Passing historical `final-*`
logs did not establish selected-result held entry, delayed A cancellation with
B active, or dispatch source-frame/independent zero-work observations.

The bounded correction now supplies:

1. `Foundation_eio.held_child_cleanup`, `held_rollback`, `held_disconnect`:
   distinct selected-held acknowledgments, published only after runtime release
   and enabled owner matching (not BEGIN/total destructor counts); pending
   completion through heartbeat/cancellation; release-before-join. All six
   disabled cleanup-gate controls fail the intended held-entry assertion.
2. Generated `Gates.delayed_a_cancellation_active_b`, both reuse/replacement:
   A's actual private completion settles and releases its permit before its
   caller is held; B acknowledges actual native entry and remains pending;
   only then A is cancelled and its cancellation delivered/awaited. B remains
   held with zero independent native interrupts, then succeeds after release.
   Capacity and final inventory hold. Disabled-B and early-B-completion controls
   reject absent active B. Old `running_cancellation_then_reuse` and
   `foreign_return_then_reuse` cases are honestly named later-usability tests.
3. `Gates.dispatch_fault`: the caller's original raw backtrace contains the
   named `Test_support.dispatch_fault_source_frame` and its source path after
   real adapter delivery. Independent operation-worker and native SQL counters
   remain zero for the faulted request; legitimate retirement/replacement is
   separate. Subsequent execution/drain succeed. Lost-frame and work-before-fault
   mutants fail those exact assertions, not shim-attempt counts or watchdogs.

The generator still permits exactly one completion seam and one dispatch seam;
its dispatch insertion also observes operation-worker entry inside the native
worker closure. Current production input/output hashes are retained. No atomic
accounting yield, production hook, core copy or API change was introduced.
`transaction_between_statements`, `replacement_shutdown_wins` and the original
post-await-check deletion mutant remain separate evidence, not substitutes for
the three new oracles.

The paired mode controls compile an owned transaction result and reject borrowed
callback escape/domain handoff and private/opaque forgeries, both in-tree and
from the isolated installed consumer. They do not claim static purity or a
restriction on arbitrary owned values. Finding 6 is corrected by removing the
library package's unconditional `eio_main` dependency; tests/examples still use
`eio_main`. Finding 7's explicit `cancellation_eio.mli` was already fixed; the
validation/disposition claims are now reconciled with the corrected oracles
and independently reviewed.

The historical pinned campaign remains in `.local/stage4e/final-*.log` without
being promoted to causal evidence. This bounded correction ran focused meaningful
controls with exact restoration, current forced Eio tests, strict C, both pristine
and generated Eio sanitizer targets, and three focused repetitions. Exact
commands, exits, limitations and hashes are in
`.local/stage4e/THREE-ORACLES-fix.md`. That correction did not repeat the
accepted Async/Bridge, install or full-regression campaigns.

Reviewer `9dd07218-51c7-47cf-af04-46f1a3f09e7f` subsequently closed findings 4–5
and the remaining claims in 7 with no new issues; earlier closed findings remain
closed. Parent then passed all eight checks in
`.local/stage4e/parent-evidence-index.json`, including `stage1/run build @all`,
one full forced regression, the Eio example, strict C and preservation/hash
checks across 342 non-task source files. See `docs/stage4e-validation.md` for
acceptance evidence and diagnostic limitations. Stage4e is complete and accepted;
Stage4f is not included, and no commit/bookmark/publication is authorized.
