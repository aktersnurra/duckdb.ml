# Stage4b — accepted bridge validation (unpublished)

## Current status (updated 2026-09-13)

B1, the native lifecycle and Resource close-safety slices, the sole-controller
raw boundary/drain oracle, Query, Appender, and control/publication increments
have passed their bounded independent reviews (with the earlier parent checks
recorded below). Control/publication's recovered review is
`.local/stage4b/finish-bridge/control-publication-review-recovered.json`.
The owner's recoverable ordinary rollback/controller refinement remains
controlling: ordinary rollback may keep the same delivery-ineligible controller;
cancellation-driven terminal cleanup retires selected attempts and joins first.

**B1–B4 are accepted within the documented supported contract.** Independent
whole-bridge specification/implementation review found no issues. The parent
then reran all 52 acceptance commands successfully: installed isolation/privacy/
modes, real Async/Eio native-cleanup heartbeats, occupied test-owned database-slot
independent control, five complete race repetitions, full forced Stage1–4
regressions, compiler/C checks and authored-C sanitizers. Exact final review and
parent evidence are recorded at the end. No adapter package, scheduler dependency
in core, remote publication, static foreign-lifetime, universal finalizer
responsiveness or whole-process leak-free claim is made.
Historical B1-only, USER-disabled and pending-bounded-review wording below records
earlier slices, not the current behavior. The final B4 matrix at the end identifies
runtime evidence separately from noninterruptible source classification and all
remaining limitations.

## Historical B1 delivery record

**B1 implementation checks pass; B1 remains pending independent acceptance. B2
is open. This unpublished intermediate slice is NOT an accepted cancellation
bridge and must not be installed as an accepted adapter dependency.** Native
work may finish normally. There is no native interrupt delivery, controller,
engine-delivery guard, scheduler dependency, adapter, pool or responsiveness
claim in this slice. Stage4b as a whole is incomplete.

Base: accepted packaging/plan `3db90c1d`, over accepted Stage4a `2978138c`.
Published `master` remains `8bb77a2f`. No commit, bookmark movement, publication,
raw Git, staging, dependency reinstall or shared/global/editor/opam change.
The six unrelated formatting files are hash-preserved; generated `.pi/tasks`
state is excluded. `duckdb.ml`, production FFI/native code, package metadata and
library Dune definitions are unchanged. Resource remains private.

Plan: [B1 contract](superpowers/plans/2026-09-09-stage4b-bridge.md).
Exact logs and ignored interface controls: `.local/stage4b/b1/`.
Baseline: `.local/stage4b/before-b1.diff`. Focused authored diff from `3db90c1d`:
`.local/stage4b-b1-review.diff`.

## Implementation and bounded contract

Public/private `.mli` declarations precede implementation: abstract
`Bridge.request`, `create`, `cancel`, `settlement` (`Pending | Settled`) and
synchronous `run`; the existing complete error ADT gains `Cancelled`. The public
interface explicitly warns that B1 is intermediate. Private `checkpoint` and
cleanup-aware child admission declarations were compiled with same-package
positive consumers before implementation (`03-helper-interface.log`). No native
pointer, request constructor, public Resource, scheduler callback or cast was
introduced.

A connection now references one shared owner plus an optional request identity.
The owner retains its native connection, gate, children/result and transaction
lease, plus a **distinct request lease**. Transaction connections and children
retain the admitting facade, rather than recovering an unscoped owner. Original
owner aliases are Busy for the request; a live facade close is Busy and a revoked
facade close is Closed, never a disconnect. Otherwise idle prepared children
reject initial admission with Live_children; results, appenders and transactions
reject with Busy. Children cannot be imported into a request.

Fresh object identities and named Fresh/Admitted/Running/Quiescing/Settling/
Finished states are private. A short independent request mutex protects the latch
and state; the lock order is owner gate then request mutex. Cancellation and
observation take only the latter. No SQL, callback, destructor, condition wait or
join holds it. B1 has no delivery ticket or native phase representation: those
are B2's uncompiled/open gates. A request is consumed on every first run,
including admission failure and pre-cancellation. Concurrent reuse is Busy;
terminal run/cancel is Closed. Cancellation acknowledges a latch, not rollback
or completion. Terminal success classification, owner-lease release and Finished
publication share synchronization. Non-success errors/exceptions are not erased
by cancellation; future adapters must retain their own cancellation/outcome pair.

The lease spans callback, transaction settlement and request child destruction.
Request exit revokes before draining admitted work; scoped parent close waits
for the request rather than taking its lease. Failed transaction rollback owns
busy destruction before releasing its transaction lease, preventing a competing
parent closer from also destroying the owner. Snapshot discard runs within its
existing admitted child operation; the enclosing request retains ownership until
its own final release. No shell-retention claim substitutes for B2 engine safety.

ML checks cover user execute, admission, BEGIN, post-BEGIN, the **real pre-COMMIT
boundary after callback/child drain**, snapshots, prepare/schema refresh,
reset/bind/execute/result publication, each fetch and callback batch/Stop,
appender operations/close, next Parquet file, temporary reservation and
publication. A BEGIN suppressed before entry does not provoke a spurious native
ROLLBACK; attempted native BEGIN failures retain existing rollback composites.
Cleanup has a separate latch bypass but never an identity/admission bypass.
Cancelled appender close discards; it does not flush. Rollback remains available
with cancellation latched. Parquet publication still occurs inside the
transaction callback, before COMMIT; only the owned temporary is removed.

These are **ML boundary checks, not native entry linearization**. A cancellation
racing an already-admitted foreign call, COMMIT or link can follow durable work.
There are no checks between internal C subcalls/rows, no repeated interruption,
and no native cleanup/delivery guard in B1. The outer callback is synchronous and
runs under the existing no-outward-effect barrier. Borrowed/local/domain
restrictions remain unchanged. Original exceptions are captured before the
pinned `Sys.with_async_exns` C callback return can replace their ML backtrace;
rollback and cleanup composites retain exception identities/backtraces.

## Real safe tests

`test/test_adapter_bridge.ml` uses Duckdb for all database operations; its only
Duckdb_ffi calls are live-resource/fallback counters. Main calls `run` once.
Test-only linker wrappers count prepared execute and BEGIN/COMMIT/ROLLBACK, and
count/gate disconnect. The supervisor additionally authorized pre-call and
post-return gates **inside the existing already-unlocked prepared-execute
wrapper**, with distinct IDs 1/2, for a real snapshot test. No new linker surface,
production hook, runtime transition or movable OCaml access was added. C gates
use atomics and monotonic watchdogs; timeout means process failure, not cleanup
permission or safe reuse.

Tests include:

- Owned return, nested owner/request exclusion, live facade close, success/error/
  exception alias revocation, revoked transaction/prepared/result/appender aliases,
  single-use requests and original-owner reuse after settlement.
- Two system workers with explicit callback handshakes test simultaneous run,
  owner execute/close and competing request admission. All gates release before
  mandatory joins, including assertion failure exits; exceptions travel through
  `Evidence_support` with their backtraces.
- Pre-entry repeated cancellation suppresses the callback and leaves SQL/control
  counts zero. Cancel/drop-error/catch-exception transaction variants INSERT then
  ignore the entire transaction result: COMMIT zero, ROLLBACK one, observer rows
  zero. Variant zero has **no earlier Cancelled operation or poisoning**, so it
  independently tests the pre-COMMIT latch.
- A real INSERT RETURNING snapshot pauses **after native result production**;
  cancellation is acknowledged before release. BEGIN/execute are each one,
  COMMIT zero, ROLLBACK one. The uncancelled paired control commits once. Observer
  count retains only the control's row; produced result/native resources are cleaned.
- Cancelled buffered appender cleanup leaves zero rows. A safe CHECK expression
  calling a nontransactional sequence proves **no flush occurred**, rather than
  merely proving rollback: the next sequence value is still 1. An ordinary
  appender control advances that same sequence.
- Cancel during chunk callbacks prevents another callback/fetch, both Continue
  and Stop. Cancel during the first Parquet file prevents preparing/executing a
  deliberately missing second file (one execute, Cancelled, not file error).
- Outer effect handler observes zero deliveries; transaction rollback is retained.
  Callback exceptions preserve identity and a source-named callback backtrace;
  Rollback_exception retains that frame. Error-with-cancellation remains the
  primary error; Rollback_failed and Exn.Finally keep both constituents. Existing
  full signal suites retain Cleanup_exception/Break and parent/child behavior.
- A distinct scope worker revokes a parent while the request callback is held.
  No disconnect occurs while Pending; after gate release the request reports
  Closed, settlement precedes actual gated native disconnect, then closure joins.
- Final binding live-resource and fallback counters are zero without GC. These
  do not enumerate all temporary engine/runtime allocations.

## Red/green and debugging record

Every project command uses the installed pinned `stage1/run` and `.deps/duckdb`.
Numbers below name log prefixes under `.local/stage4b/b1/`.

| Evidence | Result |
| --- | --- |
| `01-missing-bridge`, `stage1/run build test/test_adapter_bridge.exe` | Exit 1, exactly `Unbound module D.Bridge` in the new test, not Dune scaffolding failure |
| `02-interface-mismatch`, same build after `.mli` | Exit 1, actual Resource implementation lacks Bridge/checkpoint |
| `03-helper-interface` | Actual private `.mli` and same-package checkpoint/cleanup consumers compile |
| `04-first-implementation` | Test-only Base.Printexc deprecation errors; qualified Stdlib instead of disabling warnings |
| `05-runtime` | Nested request exposed missing owner request-lease exclusion; fixed admission |
| `06-runtime` | Source-named callback-backtrace assertion failed across Sys.with_async_exns; capture inside the boundary, not string replacement |
| `07`–`10` | Focused runtime and first full @all/forced baseline pass |
| `11-focused` | Compiler correctly rejects domain connection; guard expected different wording. Require actual highlighted characters 77–87 and contended/uncontended/portable reason |
| `12`/`13` | Parent-close test admission probe raced the request and made it Busy. Diagnostic transport showed handshake failures; fixed fixture to await callback admission before probing revocation. Gates released and workers joined, not treated as a pass |
| `14-focused` | Positive + four source-specific negatives and runtime pass |
| `15-commit-mutation-red` | Exit 2: remove only real pre-COMMIT latch, swallowed-error variant fails `pre-COMMIT latch: committed rows/count` |
| `16-state-mutation-control` | Exit 0: removing only the state branch remains protected by lease identity. Recorded honestly, not a revocation red |
| `18-facade-mutation-red` | Exit 2 at revoked facade close (test line 33): bypass only complete facade-access check; other checkpoint/child defenses remain unchanged |
| `17`/`19` | Restore authored source; green |
| `20`–`25` | Terminal/discard review, safe no-flush oracle, callback boundaries, compiler controls, native syntax and pins pass |
| `26-repeat-1` through `5` | Five focused runtime repetitions pass, no timeouts |
| `27-sanitize` | Authored-C ASan/UBSan passes with detect_leaks=0 |
| `28-final-all`, `29-final-regression`, `30-preserved` | Full build/forced Stage1–4 and six preservation hashes pass |
| `31-boundary-review` | Further source review separates pre-BEGIN suppression from attempted-BEGIN rollback and preserves snapshot/cleanup backtraces; focused tests pass |

Final post-review evidence (all under the same log directory):

- `32-commit-runtime`: expected exit **2**, committed-row/count mutation red.
- `33-state-runtime`: exit **0**, redundant state-only mutation remains protected.
- `34-facade-runtime`: expected exit **2**, revoked-close mutation red.
- `35-final-focused` and `36-final-repeat-*`: restored greens.
- `37-final-clang`: exit **0**, native syntax warnings-as-errors.
- `38-final-sanitize`, `39-final-all`, `40-final-regression`,
  `41-final-preserved`: exit **0**.
- `42-final-boundaries`: post-fetch/pre-publication and post-validation batch
  entry checks reviewed; focused tests pass.
- **Final authored source:** `43-final-focused`, `44-final-repeat-1` through `5`,
  `45-final-sanitize`, `46-final-all`, `47-final-regression`,
  `48-final-preserved`: all exit **0**, no timeout. The forced regression includes
  actual parent/child transaction draining, all existing signal regressions,
  Stage1/2 native diagnostics and Stage4 scheduler/interruption evidence.

The exact mutation runner is `.local/stage4b/b1/mutations.py` (run with `python3`),
with final Resource backup and build/runtime outputs beside it. It restores
source in a finally, checks intended statuses/diagnostics and never weakens
additional defenses to manufacture the state-only red. No deliberately weakened
production check remains.

## Reproduction and final gates

```sh
stage1/run build test/test_adapter_bridge.exe
stage1/run exec --no-build -- ocamlc -version
stage1/run exec --no-build -- dune --version
stage1/run build @test/adapter-bridge
for iteration in 1 2 3 4 5; do
  timeout 60 stage1/run exec --no-build test/test_adapter_bridge.exe
done
clang -std=c11 -Wall -Wextra -Werror -fsyntax-only \
  -I.deps/duckdb -I_opam/lib/ocaml test/adapter_bridge_hooks.c
ASAN_OPTIONS=detect_leaks=0:halt_on_error=1 UBSAN_OPTIONS=halt_on_error=1 \
  timeout 120 stage1/run exec --profile stage3a-sanitize \
  --build-dir "$PWD/.local/stage4b/b1/build-sanitize" test/test_adapter_bridge.exe
stage1/run build @all
stage1/run runtest --force
sha256sum --check .local/stage4b/preserved-six.sha256
```

Compiler **5.2.0+ox**, package `oxcaml-compiler.5.2.0minus39`, source
`2515546fea38e21e8143cc41db663bd56efc8d06`; Dune **3.22.2**; jj **0.42.0**;
Clang **22.1.6**. Fresh `24-versions.log` hashes match accepted evidence: header
`48e716b9ce96ca8fead9cb35693fdc0343ac0fc1f6e7db5561fa0f44b674153d`, library
`fc23f12e376c47be520f75221288281906e7942e8fd6f6ce4849198ba60d0405`, compiler archive
`93dbcf859e655d2a2b41dfa077c126fa5a15fd0205b1c57dbb5ff2cc9d595462`.

Ambient OCaml LSP remains **incompatible/unavailable**, not passed. Automated
unknown-extension/local-syntax/no-config diagnostics were checked against the
passing pinned compiler, not fixed by changing user configuration or valid
OxCaml source. Reserved identifiers required by POSIX/GNU linker wrappers are
not native compiler failures; explicit C warnings-as-errors passes.

**Unsuppressed whole-process LSan remains failing**, not rerun/fixed/suppressed.
Authored-C ASan/UBSan does not instrument prebuilt DuckDB, runtime or Base and
is not a leak-free-process claim. Existing OOM, arbitrary/repeated signals,
async-exception acquisition/bookkeeping gaps, foreign work that never returns,
unsafe FFI misuse and hostile-filesystem/process-crash limits remain. B2 must
prove native engine validity, persistent native latch/internal boundaries,
nonblocking noalloc delivery, disarm/retirement, cleanup and real responsiveness.
Adapters and complete cancellation-safe reuse remain unauthorized/open. Parent
and independent review own B1 acceptance; passing this suite is not bridge acceptance.

## B2 resume: compiler controls and lifetime stop gate

Logs: `.local/stage4b/b2-resume/`. The starting `jj diff --summary` and the
provisional FFI/compiler-test diff are saved as `summary.log` and `draft.log`.
Working change `rxsssmwz` remains over `3db90c1d`; no new change, bookmark movement
or publication. This resume changes only this evidence, the B2 compiler checker
and its Dune test rule (apart from generated task bookkeeping). Existing B1 and
production B2 draft sources were not changed.

### Commands and observed results

All commands below ran from `/home/aktersnurra/projects/duckdb.ml` using the
existing local switch and DuckDB. Each numbered log includes the exact command,
output and exit status.

| Log | Command | Result |
| --- | --- | --- |
| `01-all` | `stage1/run build @all` | Exit 0, including latest compiler-control edits |
| `02-positive-build` | `stage1/run build test/native_request_compile/positive.exe` | Exit 0 |
| `03-positive-run` | `stage1/run exec --no-build test/native_request_compile/positive.exe` | Exit 0; sequential create/install/count-zero/uninstall only |
| `04-interfaces` | `bash test/native_request_compile/check_interfaces.sh "$PWD/_opam/bin/ocamlc"` | Exit 0; positive compiles, disposable missing-interface control rejects `Duckdb_ffi.Native_request.create`, line 2, characters 10–42, `Unbound module "Duckdb_ffi.Native_request"` |
| `05-clang` | `clang -std=c11 -Wall -Wextra -Werror -fsyntax-only -I.deps/duckdb -I_opam/lib/ocaml lib/ffi/resource_stubs.c` | Exit 0 |
| `07-alias` | `stage1/run build @test/native_request_compile/runtest --force` | Exit 1; checker could not mutate its read-only copy of a Dune input |
| `08-all` | `stage1/run build @all` | Exit 0; does not execute the failing alias |
| `09-b1` | `stage1/run build @test/adapter-bridge --force` | Exit 0; positive/four intended compiler rejections and B1 runtime pass |
| `10-preserved` | `sha256sum --check .local/stage4b/preserved-six.sha256` | Exit 0; all six OK |
| `12-direct` | `bash test/native_request_compile/check_interfaces.sh "$PWD/_opam/bin/ocamlc"` | Exit 0 after disposable-copy permission fix; same intended rejection |
| `13-alias` | `stage1/run build @test/native_request_compile/runtest --force` | Exit 0; compiler controls and bounded lifecycle executable both run |
| `14-all` | `stage1/run build @all` | Exit 0 after checker fix |

Direct controls passed **before** adding the rule to the local `runtest` alias.
Dune then exposed a separate checker bug: source interface mode was `0644`,
`_build/default/lib/ffi/duckdb_ffi.mli` was `0444`, and `cp` retained that mode in
the disposable red directory. Python's `write_text` failed with PermissionError,
not the intended compiler rejection. The checker now runs `chmod u+w` only on
`$tmp/red/duckdb_ffi.mli` before mutation. Source/build inputs, shared settings,
compiler flags and diagnostic assertions are unchanged. Direct and Dune controls
both pass after this one-line fix. The alias declares the checker, both positive
sources, the real FFI interface and the lifecycle executable as dependencies.

`06-versions` records `stage1/run exec --no-build -- ocamlc -version` returning
**5.2.0+ox** and `_opam/bin/ocamllsp -version` returning **NO_VERSION_UTIL** (both
exit 0). The latter is not a useful LSP revision identifier. `11-pins` records
Dune **3.22.2**, Clang **22.1.6**, and the same DuckDB header/library SHA256 values
listed in the B1 evidence above. No compiler or native dependency was replaced.
An initial LSP diagnostic reported `Unbound module Duckdb_ffi` for the compiler
consumer; the authoritative pinned build and direct consumer compilation pass.
No clean LSP claim or confirmed server-cache restart is made.

### Source review: stop before enabling native delivery

The existing draft is not sufficient to integrate a real interruptible boundary:

- `connection_clear` calls `clear_work` and `duckdb_disconnect` without acquiring
  `native_guard`, publishing closing or detaching delivery eligibility. Every
  finalizer/delete/explicit-close route reaching that helper still lacks this
  exclusion. The install reference retains the C shell, **not a connected engine**.
  Turning on USER delivery before repairing these paths would leave disconnect
  and internal destruction outside the delivery synchronization protocol.
- Only IDLE is assigned today. USER/CLEANUP/CLOSING enum declarations are not
  operation transitions; `native_closing` is never published true. Consequently
  reserve/try-delivery cannot exercise a real eligible delivery in this draft.
  The lifecycle positive cannot establish nonblocking delivery, quiescence,
  engine validity, cancellation visibility at internal subcalls or race safety.
- The generated `uint64_t lease_id` is a wrapping counter and is not checked by
  delivery. Actual comparisons use the retained request address. The unused
  counter is not evidence of the plan's fresh/non-reused lease identity; reuse,
  installation authority and selected-ticket retirement still need review.
- Install adds owner/request references; only explicit uninstall releases them.
  Neither close nor finalization retires an installed request. The prototype has
  no Resource-owned strong-root/controller settlement discipline to ensure that
  uninstall happens, and no finalizer fallback proof. Uninstall checks ticket
  count but does not yet establish foreign-call completion or cleanup phase.

These are source findings, not a demonstrated safe-API race: the safe Resource
path does not use Native_request, and the draft never arms USER. No production
C/ML extension was made after identifying this stop gate. Review must establish
engine-close exclusion, completion/phase transitions, root ownership and request
identity/retirement **before** one real native boundary can be enabled. The old
direct `Duckdb_ffi.interrupt` remains outside the B2 safety protocol.

Not run for this bounded checker-only change: full forced Stage1–4 regression,
new native-race tests, sanitizer tests or independent B2 review. No controller,
Resource/Query/Appender/Parquet integration, boundary map completion, close safety,
adapter package or safe API was added. **B2 remains in progress, unaccepted.**

## B2 native-only lifecycle repair (2026-09-11; not B2 acceptance)

Parent approved a **narrower slice than the lifetime review recommendation**:
only `lib/ffi/duckdb_ffi.{mli,ml}`, `lib/ffi/resource_stubs.c`,
`test/native_request_compile/`, and this appended evidence. No Resource,
Query/Appender/Parquet integration, controller, real native boundary, USER
activation or close-path rewrite. B1 remains unchanged. **No safe interruption,
native lifetime completeness or B2 acceptance is claimed.** Review of this
bounded lifecycle remains required.

Working change remains `rxsssmwz` over `3db90c1d`; no new change, commit,
bookmark movement, publication, raw Git or staging. jj has no staging area.
No dependencies, shared switch/editor settings or execution mode were changed.
All logs, mutation backups and sanitizer output are ignored under
`.local/stage4b/native-lifecycle/`. `baseline.diff` was saved before edits;
`27-baseline-preservation.log` compares every non-allowlisted diff section with
that baseline (excluding generated `.pi/tasks` bookkeeping): B1, plan and all
six unrelated files are unchanged. The six SHA256 checks also pass.

### Compiled interface and bounded ownership contract

The interface now declares named install/uninstall/reserve/interrupt results,
`try_install`, request-only `try_uninstall`/delivery operations and deterministic
idempotent `dispose`. No arbitrary connection argument to delivery, operational
counter accessor, raw pointer or identity setter remains. Each successful
binding consumes the request identity permanently. Failed installation leaves
Fresh unchanged. Disposed aliases retain a cleared custom slot: cancellation
and retirement are no-ops; install reports Request_used, uninstall Not_installed,
reserve Ineligible, interrupt Not_reserved, and repeated dispose succeeds.
Installed disposal reports Still_installed.

An ML record retains the actual connection slot while bound. Installation
preallocates its option root before the noalloc native entry; publication has
no intervening allocation/runtime transition. Uninstall explicitly keeps this
root live through native reference release, then clears it. The custom slot is
the sole owner of request storage; a request holds one native owner-shell
reference, while `active_request` is non-owning. There is no installed-reference
cycle or wrapping identity counter. A detached identity is never reinstalled;
disposed aliases cannot reference subsequently reused native allocation storage.

The supported invariant is deliberately restricted: caller serializes the entire
request/owner tree, installs only on an idle connected owner, does no engine work
or explicit owner/parent close while bound in this slice, and detaches before
close. **Runtime-serialized externals are not domain-safe.** Concurrent unsafe
use, unrooted active workers/controllers and async-exception acquisition/root
bookkeeping gaps are not supported. There is no assertion that zero reservations
proves foreign completion: this slice admits no such foreign work.

Idle abandonment finalization attempts the guard once, detaches, releases the
guard, then drops the native owner reference and frees request storage. All
current guard users retain the runtime; none allocate, destroy, wait, callback
or transition runtime state while guarded. Under the supported serial/root
invariant, an unreachable idle request cannot contend with a live user of its
guard. Violation fails closed with a fatal invariant diagnostic, never a spin,
join or free-on-contention. If the dead connection slot finalizes first, the
one-way native reference preserves its shell; if the request goes first, the
connection slot still owns it. Existing fallback destruction may block with the
runtime held. This proof must be reviewed anew before worker/USER integration;
it is not a general native-lifetime or finalizer-responsiveness claim.

A future sole controller owns at most one reservation; only it may retire after
attempt/skip in a protected finally. Retirement is a single atomic store, not a
CAS retry/ref-drop loop. USER still has **no writer**. No Reserved, Delivered,
contention, Delivery_pending or Native_work_pending positive execution is claimed.
The all-operation consumer compiles their ADTs; runtime cases cover only reachable
idle lifecycle outcomes. C11 static assertions require bool and reference-count
integer atomics to be always lock-free on the compiled target; this is not proof
of the future complete delivery/cleanup protocol.

### Tests and real reds

`positive.ml` now tests all declared operations, Fresh/Installed/Detached/Disposed
aliases, same request on two connections, same-owner duplication, failed fresh
installation on a leased/empty/released owner, reinstallation rejection, a fresh
request reusing the owner, installed-dispose refusal, explicit native reclamation,
repeated disposal and exception/cancellation cleanup. Ordinary cases restore live
counts without forced GC and require zero fallback-counter increase.

Separate GC tests retain only the request's ML connection root, check the weak
connection remains live and no fallback occurs, detach/dispose and check that
root is released. Idle request-first abandonment clears the owner's pointer so a
fresh request can bind. Whole-tree abandonment and child-last native unref also
restore counters. Whole-tree GC does **not** control or claim a particular order
among dead custom-slot finalizers; the source invariant covers both orders.
These tests do not use a Bridge callback or demonstrate active-worker rooting.

The direct compiler checker compiles the real `.mli` and an exhaustive consumer
of every operation/constructor. Disposable negatives require exact source,
location and type/module reason: missing Native_request (`create`, line 2,
characters 16–48), connection-as-delivery-request (line 2, 42–52), and unit-as-request
(line 1, 44–46). Existing B1 safe privacy/pointer/domain negatives are also rerun.

| Logs under `native-lifecycle/` | Command / observation |
| --- | --- |
| `01-compiler`, `02-old-build` | Pinned compiler 5.2.0+ox; old-API regression executable builds. |
| `03-old-{cross-owner,reinstall,dispose,abandon}` | `stage1/run exec --no-build test/native_request_compile/positive.exe -- CASE`: each exit **2**, respectively same-request-two-owners, reinstall-after-detach, explicit-reclamation counter and idle-abandonment counter assertions. Pre-edit fixture is saved as `old-positive.ml`. |
| `04-interface` | First standalone interface compile fails warning 50 for ambiguous doc comments; corrected spacing. **Not** an intended red. |
| `05-interface`, `06-interface-controls` | Real `.mli`/positive consumer compile before implementation; disposable missing-interface and source-specific wrong-type controls reject as intended. |
| `07-mismatch`, `08-test-compile` | `stage1/run build lib/ffi/duckdb_ffi.cma` (and test build): exit **1**, actual Native_request implementation lacks new result types and try_install/try_uninstall/dispose. Intended interface/implementation red. |
| `09-clang` | Authored C syntax/warnings pass. |
| `10-first-green` | Compiler warning 69: root field written but never read. Added explicit `Sys.opaque_identity` root keep-alive through native unref; no warning suppression. Not an intended red. |
| `11-green`, `15-restored-green` | Forced native lifecycle alias passes. |
| `12-invalid-fallback-mutation` | Incorrect test mutation skipped NULL-slot handling and segfaulted (exit -11); **not counted** as a lifecycle red. Source restored in finally. |
| `13-fallback-mutation`, `14-mutations` | Corrected independent mutation reds all exit **2** at their named assertions; source restored in finally. |
| `26-exact-controls` | Forced native alias passes after tightening negative diagnostic locations/reasons. |

Reproducible mutation runner: `python3
.local/stage4b/native-lifecycle/mutations.py`. Each mutation first successfully
builds `test/native_request_compile/positive.exe`, then runs it with
`stage1/run exec --no-build test/native_request_compile/positive.exe`. Removing
request Fresh enforcement fails cross-owner rejection; permitting Detached fails
reinstall rejection; omitting owner-pointer detach fails fresh-owner reuse;
omitting disposal free/accounting fails deterministic zero counters; omitting
ML root publication fails weak-root retention; skipping installed finalization
fails idle-abandonment reclamation. `12-mutation-*-{build,run}.log` records exact
commands, exit codes and diagnostics. No deliberately weakened source remains.

### Fresh validation on restored authored source

`validate.sh` runs the following exact commands, logging command/output/status.
All exited **0** (`16`–`23` logs):

```sh
stage1/run exec --no-build -- ocamlc -version
stage1/run build @all
stage1/run build @test/native_request_compile/runtest --force
stage1/run build @test/adapter-bridge --force
bash test/native_request_compile/check_interfaces.sh "$PWD/_opam/bin/ocamlc"
clang -std=c11 -Wall -Wextra -Werror -fsyntax-only \
  -I.deps/duckdb -I_opam/lib/ocaml lib/ffi/resource_stubs.c
sha256sum --check .local/stage4b/preserved-six.sha256
env ASAN_OPTIONS=detect_leaks=0:halt_on_error=1 UBSAN_OPTIONS=halt_on_error=1 \
  timeout 120 stage1/run exec --profile stage3a-sanitize \
  --build-dir "$PWD/.local/stage4b/native-lifecycle/build-sanitize" \
  test/native_request_compile/positive.exe
```

Native output reports deterministic lifecycle/exception cleanup passed, then
separate ML-root/idle-GC fallback passed with USER disabled. B1 reports its
unchanged ML-cooperative-only success. ASan/UBSan reports no authored-C error;
prebuilt DuckDB, runtime and Base are not instrumented. This uses detect_leaks=0;
unsuppressed whole-process LSan remains unresolved and is not claimed passing.

`25-pins.log`: Dune 3.22.2, jj 0.42.0, Clang 22.1.6 targeting
x86_64-pc-linux-gnu. Compiler remains 5.2.0+ox (pinned source
`2515546fea38e21e8143cc41db663bd56efc8d06`). Fresh hashes match prior pins:
DuckDB header `48e716b9ce96ca8fead9cb35693fdc0343ac0fc1f6e7db5561fa0f44b674153d`,
library `fc23f12e376c47be520f75221288281906e7942e8fd6f6ce4849198ba60d0405`,
compiler archive `93dbcf859e655d2a2b41dfa077c126fa5a15fd0205b1c57dbb5ff2cc9d595462`.

An automatic editor diagnostic reported EOF syntax on the runtime test despite
`_opam/bin/ocamlc -stop-after parsing -c -o
.local/stage4b/native-lifecycle/positive.cmo test/native_request_compile/positive.ml`
and the actual pinned native build/run succeeding. No clean LSP claim or editor
configuration workaround. C's standard assertion now uses the C11 `static_assert`
macro from `<assert.h>`; warnings-as-errors syntax compilation passes.

**Omissions / next safety gate:** no full forced Stage1–4 regression or installed
consumer rerun in this slice; no real guard-contention test, selected delivery,
latch/internal-entry linearization, native cleanup/closing transition or engine
validity evidence. Resource admission/terminal/discard integration, controller
rooting/join, every destructor/close path and runtime-release responsiveness
remain open. Existing raw `interrupt` is still outside this protocol. Review the
compiled native-only lifecycle/root invariant first; separately authorize and
prove integration/close exclusion before any USER activation. Passing this
slice is not B2 or complete bridge acceptance.

### Independent review and parent verification

Independent reviewer `7f62fa47-bf1e-4fa1-be67-66902feda8bf` found **no issues**
and approved only this bounded, native-only lifecycle slice. Review covered the
actual sources, root/finalizer invariant, single-use identity, deterministic
disposal, compiler controls and recorded mutation evidence. It executed no
commands. Report: workflow `2ab901dd-052a-47ed-b2db-7a11fd3b3322`, artifact
`reviews/native-lifecycle-fix.md`.

The parent inspected the compiled interface, ML root handling and C lifecycle
implementation, then independently reran `stage1/run build @all`,
`stage1/run build @test/native_request_compile/runtest --force`,
`stage1/run build @test/adapter-bridge --force`, the exact Clang syntax command
above and the six preservation hashes. All exited **0**; exact output is in
`.local/stage4b/native-lifecycle/29-parent-validation.log`. The parent did not
rerun mutations or sanitizers; those remain the reviewed worker evidence.

The native-only lifecycle slice is accepted within its explicit idle/exclusive
unsafe-FFI contract. USER remains disabled. B1 is preserved; **B2 and the complete
bridge remain unaccepted**, pending the integration and safety gates above.

## B2 Resource integration / close-safety slice (2026-09-11; review pending)

**Implemented and checked only within this bounded, USER-disabled slice.** B1 is
preserved. There is still no controller, running interruption, native-lifetime
completeness or B2/bridge acceptance. Independent review was pending at the
implementation handoff and is recorded below. All new production edits are
confined to private Resource and the
approved FFI files; safe `Duckdb` declarations and Query/Appender/Parquet ML are
unchanged. No package, scheduler, raw-pointer API or ML phase/identity setter was
added. No commit/new change, bookmark movement, staging, publication, dependency
installation or shared configuration change was performed.

Logs, exact commands/statuses, mutation backups and validation scripts are under
`.local/stage4b/resource-lifecycle/`. The pre-slice snapshot is `f70f1419` in the
same working change `rxsssmwz` over `3db90c1d`, recorded by `before-ref.log` and
`before.diff`. Compare it with the parent's `timeout-state.diff` for the final
increment; timeout interrupted generation of the planned `focused.diff` and
`preservation.log`, so neither is evidence. Read-only recovery compared these
two snapshots and found only the 19 reported slice paths changed; other saved
diff sections were unchanged. `52-final-preserved.log` independently records the
six preservation hashes passing, not a whole-diff comparison. jj has no staging area.

### Approved interface refinement and Resource lifecycle

The supervisor approved the pre-edit lock/root/discard/transition checkpoint.
The first actual `.mli` added `Connection_active`; an exhaustive consumer compiled
before the implementation, whose missing constructor produced the intended red.
A second checkpoint rejected the existing `Some connection` root allocation under
the request mutex: allocation can trigger GC/finalizers even without a native
lock. The approved correction adds only opaque `Native_request.installation`,
`prepare_install` and `try_install_prepared`. The convenience `try_install` remains
for existing unsafe callers. Both new declarations and the exhaustive consumer
compiled before the intended missing-type/value implementation red.

An installation preallocates the request/connection roots outside synchronization;
preparing it neither binds nor consumes the request. Publication calls the same
single-use native installer and stores the preallocated root. Candidate aliases
cannot reinstall detached/disposed requests. They retain their own ML roots until
dropped, but do not acquire additional native references. `39-install-assembly.log`
shows the pinned `try_install_prepared` code calls only native install and
`caml_modify`, with no managed-allocation slow path or runtime release. This is
not a latency, universal allocation-free-runtime or static ownership claim.

Resource first acquires its existing exclusive request lease. Native allocation
and root preparation occur inside the protected scope, outside owner/request
locks. The allocated request is retained before installation preparation; a
failed preparation can therefore use ordinary cleanup. Binding and copying the
persistent ML cancellation latch share the request mutex. A bound `cancel`
publishes the native atomic latch before acknowledgement. This is publication
ordering, **not** native user-call admission/linearization or interrupt delivery.

Lock order remains **owner gate -> request mutex -> native try-guard**. Cancel and
settlement observation take only the request mutex. After foreign work drains,
terminal cleanup destroys children, extracts/clears native state under request
synchronization, then uninstalls/disposes outside ML locks before releasing the
owner lease. It never retires a controller reservation on someone else's behalf.
Pending detach is an explicit invariant failure retaining the request root, not
permission to free. With USER/controllers disabled and exclusive completed work,
that failure is unreachable through supported Resource operations.

`destroy_connection` also detaches before native close, independently of the
outer Bridge return. Thus failed transaction rollback and child-snapshot discard
cannot disconnect with an installed request. A later terminal detach is
idempotent. Existing transaction/result error and exception/backtrace composites,
ML cancellation classification and facade revocation remain intact. Scoped parent
close revokes/drains the request; it does not take its lease. Manual owner close
still returns Busy while the request owns it.

### Native transitions and finalizer argument

C-only helpers in `query_native.h` share the actual native try-guard. A guarded
`foreign_active` flag records released-runtime work; a separately balanced
`cleanup_depth` records nested destruction. Phase is IDLE, NONINTERRUPTIBLE,
CLEANUP or permanent CLOSING. **There is no USER writer.** Zero reservations is
not foreign completion: uninstall checks activity/cleanup and the independent
reservation flag. Installation rejects closing or active owners before reading
the engine pointer, which disconnect changes outside the guard.

Work begins only after runtime release and ends before reacquisition/pending
actions. Engine destructors run after cleanup publication and guard release.
Prepared result/chunk/statement cleanup, execute's own cleanup, appender metadata,
error-data/logical-type/value destruction, typed temporal destruction, bind/reset,
and close/finish/finalizer paths use the shared helpers. Appender close's optional
flush is noninterruptible foreign work **before** cleanup/clear/destroy, not a
flush hidden in cleanup eligibility. Nested helpers restore NONINTERRUPTIBLE while
outer foreign work remains active. Pure held-runtime metadata/scalar reads remain
noninterruptible; no controller can run concurrently through them in this slice.

Every route to `connection_clear`, including final shell unref, publishes closing
before destruction/disconnect; closing is never reset. No guard is held across
destruction, allocation, callback, sleep, runtime transition or wait. Released
workers may yield between unsuccessful guard attempts. Held-runtime fallbacks
try once, fail closed on contention/foreign overlap and never spin/join. No
noalloc entry releases the runtime or waits for a guard/controller.

Root argument for supported safe use: admitted owner -> Resource request -> native
request wrapper -> actual ML connection slot; worker/cleanup scopes retain the
owner and request. The owner retains registered child cleanup closures and native
children; temporary prepared owners retain scoped/CAML roots. Already closed
children have cleared slots. Consequently same-owner child/request finalizers
cannot overlap an active safe foreign call, including while another worker runs
GC. Other owner trees use different guards. Native request -> owner-shell is
one-way; `active_request` is non-owning. Native child/parent references handle
both dead-slot finalizer orders and child-last deletion. Final unref/destruction
is always after guard release. Database finalization cannot destroy the engine
under live child references; explicit database close still requires safe draining.

This is a source/root invariant plus compiled/runtime evidence, not a static
lifetime proof or support for arbitrary unsafe concurrent FFI use. Finalizers
remain fallback reclamation and can run potentially blocking destructors with the
runtime held. No deferred-reclamation architecture or finalizer responsiveness
claim was introduced. Re-review this argument before any controller/USER change.

### Deterministic tests and limitations of their oracles

- Safe Bridge tests exercise success, native/result error, callback exception,
  cancellation, admission rejection, parent revoke, transaction discard and real
  produced-result snapshot discard. Native install/uninstall/dispose invocation
  counts and live-resource counts settle without GC. Existing B1 tests and
  diagnostic/backtrace/composite checks remain enabled.
- Test-only create failure raises a registered exception **before** real native
  creation; install contention returns before side effects. Registration occurs
  outside production locks. Both prove settled/reusable owner, deterministic
  cleanup and paired uninjected success; create preserves its source-named
  non-tail caller backtrace. These are valid failure-state injections, not OOM
  coverage for every acquisition/bookkeeping instruction.
- A real admitted callback remains held while a distinct GC worker runs; no
  fallback/disconnect occurs, and settlement later reclaims without GC. Separate
  existing idle native-root/request-first/whole-tree/child-last fallback tests also
  pass. GC does not force a particular order among simultaneously dead slots.
- Unsafe lifecycle fixtures hold actual unlocked foreign or destructor wrappers:
  raw/prepared execute, bind/reset/fetch, result/chunk/prepared destruction,
  appender flush/close/clear/destroy. Uninstall reports Native_work_pending while
  held and succeeds after release; fresh install during unbound work reports
  Connection_active. The real disconnect gate observes Connection_closed before
  destruction completes. Destruction hooks also try/release the real guard,
  checking that production did not retain it into the destructor.
- The native contention **mechanism** test captures/retains an unsafe fixture owner
  using wrapped `duckdb_ml_connection_ref`. Its test primitive extracts/roots the
  private native-request slot before taking the real guard, invokes actual noalloc
  install, then releases immediately. No pause, wait, callback, allocation or
  runtime transition occurs under that guard. This is representation-dependent
  test-only linkage, not a safe pointer conversion, delivery test or controller.
  The fixture explicitly releases its extra native reference. No production C
  source is duplicated/included in the test build.
- All held gates release before mandatory joins, including assertion exits.
  Watchdogs are process failures, never cleanup/reuse permission. There are no
  elapsed-time admission or GC-based ordinary-settlement oracles.

Native cancellation counters are **invocation/order evidence**, not direct
inspection of the atomic latch. The supervisor explicitly deferred direct latch
inspection and the precise cancel-between-admission-and-binding race to real
native-boundary integration rather than add a production getter/setter or ML
callback. No positive Reserved/Delivered, selected-ticket retirement, stale
interrupt, internal entry linearization or safe interruption evidence is claimed.

### Reds, corrections and final commands

Each log contains its exact command, full output and exit status.

| Log | Evidence |
| --- | --- |
| `01`/`02` | Standalone revised interface/consumer passes; actual implementation fails for missing Connection_active |
| `04`/`06` | Safe pre-implementation red; `06` preserves the actual `Resource binds after admission` assertion rather than flattening it |
| `10`–`12` | Initial unused test external prevents build; not lifecycle reds. Removed it until its consumer existed |
| `14`/`15` | Intended native assertions: zero reservations is not foreign completion; closing must precede disconnect |
| `16` | C interface-first link red: actual native try-guard helpers not yet implemented |
| `24`/`25`, then `26`/`27` | Ambiguous doc-comment warning fixed with spacing; standalone preallocation interface passes, real implementation missing installation/prepare_install/try_install_prepared fails |
| `30`/`31` | Test expected an optimized-away tail caller frame; non-tail source control restores that frame. Used pinned Callback.Safe registration rather than suppressing its alert |
| `37`/`50` | Seven independent mutation builds pass then intended runtime assertions fail with exit 2; source restored in finally |
| `38` | Restored native + safe aliases pass after mutations |
| `47`/`47b` | Direct B1 checker initially invoked from wrong cwd, exits 1 on missing source paths. Stopped/reported; supervisor approved same checker from test/ with absolute pinned compiler. Corrected command passes; checker unchanged |

Mutation runner: `python3 .local/stage4b/resource-lifecycle/mutations.py`.
Independent removals cover permanent closing publication, foreign completion
check, prepared foreign-work transitions, standalone result cleanup transitions,
appender clear/destroy cleanup transitions, bound cancellation publication and
Resource disposal. The named assertion fails in each case; no weakened source
remains. These test lifecycle/closing mechanics, not USER races.

Final restored checks (`44`–`58`, and `38`) all pass, except the preserved,
corrected invocation error `47`. Reproduce with:

```sh
bash .local/stage4b/resource-lifecycle/validate.sh
```

That script runs `stage1/run build @all`, forced native lifecycle and B1 aliases,
direct native compiler controls, the B1 checker from its required test cwd,
strict `clang -std=c11 -Wall -Wextra -Werror -fsyntax-only` on all four touched C
stubs and both test hook files, `stage1/run runtest --force`, seven mutation reds
and restored greens, the six preservation hashes, and fresh pins. It also runs
these three executables with the existing sanitizer profile/build directory:

```sh
env ASAN_OPTIONS=detect_leaks=0:halt_on_error=1 UBSAN_OPTIONS=halt_on_error=1 \
  timeout 120 stage1/run exec --profile stage3a-sanitize \
  --build-dir "$PWD/.local/stage4b/resource-lifecycle/build-sanitize" EXECUTABLE
# EXECUTABLE: test/resource_lifecycle/test_native_close.exe
#             test/test_adapter_bridge.exe
#             test/native_request_compile/positive.exe
```

Full forced regression includes existing Stage1–4 compiler, signal, scope/drain,
transaction/snapshot, appender/Parquet and scheduler evidence. Generated/vendor
Ctypes macro warnings appeared in the first full build; authored-C strict checks
pass. Sanitizers pass for authored C; prebuilt DuckDB/runtime/Base remain
uninstrumented. `detect_leaks=0` is not whole-process leak validation; the known
unsuppressed whole-process LSan limitation is unchanged.

Fresh tools: compiler **5.2.0+ox**, Dune **3.22.2**, jj **0.45.1**, Clang
**22.1.8** targeting x86_64-pc-linux-gnu. The latter two are actual current values,
not historical prior-slice values; this worker changed no tools/configuration.
Compiler source remains pinned `2515546fea38e21e8143cc41db663bd56efc8d06` by the
unchanged archive hash `93dbcf859e655d2a2b41dfa077c126fa5a15fd0205b1c57dbb5ff2cc9d595462`.
DuckDB header/library hashes remain respectively
`48e716b9ce96ca8fead9cb35693fdc0343ac0fc1f6e7db5561fa0f44b674153d` and
`fc23f12e376c47be520f75221288281906e7942e8fd6f6ce4849198ba60d0405`.

Automatic editor diagnostics repeatedly used stale FFI interfaces/missing C
include paths or rejected required POSIX/GNU linker names. Pinned compiled
interfaces and strict Clang disprove those diagnostics (`editor-diagnostics.md`,
logs `18`, `28`, `29`, `33`, `34`, `48`). No clean LSP claim or shared/editor
configuration workaround. One broad inspection-only skill search timed out;
a bounded lookup found/read the required skills. No provider/execution-mode
fallback occurred.

**Residual gates:** controller roots/join and
selected delivery retirement; native latch/user-entry/reset/commit/publication
linearization; actual interrupted cleanup and responsiveness; full B2–B4 bridge
acceptance. Installed consumers were not rerun in this slice. Existing OOM and
asynchronous-exception acquisition/bookkeeping gaps, arbitrary/repeated signals,
unsafe FFI misuse, nonreturning foreign work and crash/hostile-filesystem limits
remain. Passing this bounded lifecycle slice does not authorize USER or adapters.

### Timeout recovery, independent review and parent checks

Workflow `3309fa8b-7e13-480c-8b4d-73f64624200f` failed when its worker exceeded
1800000ms after validation/documentation but before final artifact preparation.
The scheduled reviewer never started. The parent captured the dirty working
copy (`rxsssmwz`, `a24f693d`, over `3db90c1d`) as `timeout-state.diff` with summary
and reference logs. No source was discarded or execution mode changed.

Same-protocol workflow `da742cbc-c836-4445-a922-02125bfe45b7` resumed the worker
for a read-only handoff, then ran fresh reviewer
`340056cb-6506-4e2a-a7da-40767d316088`. Recovery confirmed current mutation targets
match all seven saved pre-mutation backups. The reviewer found no P0/P1
implementation defects within the supported controller-free contract and gave
**OK with notes** for this bounded slice. Its P2 finding was the nonexistent
artifact references above; the parent corrected them, without production edits.
Reports are managed artifacts `implementation/resource-lifecycle-recovered.md`
and `reviews/resource-lifecycle.md` under that recovery workflow.

The parent inspected Resource admission/detachment and native transitions, then
reran the full build and all three focused aliases:

```sh
stage1/run build @all
stage1/run build @test/native_request_compile/runtest \
  @test/resource_lifecycle/runtest @test/adapter-bridge --force
```

Strict C11 warnings-as-errors syntax checks on all four touched stubs and both
test hook files, plus the six preservation hashes, also passed. Exact commands
and output: `.local/stage4b/resource-lifecycle/59-parent-validation.log`, all
exit **0**. Full regression, mutations and sanitizers were inspected as worker
evidence, not independently rerun by the parent.

This accepts only the bounded Resource/native lifecycle increment. USER remains
disabled; native latch admission races, controller roots/join, selected delivery
retirement, interrupted-cleanup responsiveness and complete B2–B4 acceptance
remain open. No safe interruption or complete native-lifetime guarantee follows.

## First native-delivery checkpoint: recovery semantics block activation (2026-09-11)

**No production change or USER activation.** The mandatory supervisor checkpoint
approved a narrower evidence deliverable: a real safe-Bridge recovery regression
and disposable compiled proposal. The supervisor will seek owner approval for a
rollback-contract refinement; neither that refinement nor the proposed delivery
adapter is approved for production. B1 and the accepted USER-disabled native/
Resource lifecycle increments are preserved. **B2 remains unaccepted.**

### Contract conflict and proposed decision

`Resource.with_transaction` (`resource.ml:341-381`) rolls back an ordinary result/
native error or exception, releases the transaction lease, and restores the
original diagnostic. A Bridge callback can ignore/catch it and execute again on
the same facade. `with_child_snapshot` (`resource.ml:385-419`), called by
`Query.execute_prepared` (`query.ml:105-123`), likewise permits recovery after a
successful rollback. These are ML rollbacks before the enclosing Bridge ends,
not terminal request settlement.

The plan requires controller stop/join before ML rollback and at most one
controller creation per admitted request. Joining on these recoverable paths
leaves subsequent user calls without a controller. Restarting violates the bound;
revoking the request or silently disabling later delivery changes semantics.
Therefore activation stopped **before production edits**.

Proposed, **not approved**, refinement: recoverable ordinary rollback quiesces
native delivery but retains the same controller; cancellation/terminal rollback
permanently stops/joins first, since the persistent cancellation latch already
prohibits subsequent user work. The owner must arbitrate this plan change.
No fallback to one-shot interrupt, extra controllers or altered recovery behavior
was implemented.

The full pre-edit checkpoint/root/lock/boundary analysis is durable at
`.local/stage4b/first-delivery/design-checkpoint.md`. Its candidate boundary is
only `ml_duckdb_execute(control=false)`, with latch admission before extraction,
prepare and execute. Control SQL and all other kinds remain noninterruptible in
that candidate. It proposes a normal allocating-ABI private `deliver` adapter
for a test-link-only selected pause, delegating to the unchanged noalloc
try-interrupt entry after runtime reacquisition. This shim's necessity/safety and
the concurrent root/finalizer argument still require review. No such production
function or boundary exists yet.

### Real regression of existing behavior

New `test/bridge_recovery/test_bridge_recovery.{mli,ml}` runs four cases through
real safe `Duckdb.Bridge`: transaction result error, native error, caught callback
exception (including source-named backtrace), and native snapshot error. The
snapshot uses an INSERT violating NOT NULL: prepare succeeds and native execute
fails inside the actual private snapshot, rather than failing before BEGIN.

All cases assert rollback before returning to the callback, the same request
still Pending, original owner alias still Busy, one retained native installation,
and no detach/dispose/disconnect until Bridge settlement. Later raw execute and
a subsequent transaction/snapshot succeed on that same facade. A separate
observer sees only the two post-rollback writes. Each case restores live-resource
and fallback counts without GC. This establishes existing recovery semantics,
**not controller counts, selected-ticket races or safe native delivery**.

The new Dune `@test/bridge_recovery/runtest` alias is included by the ordinary
recursive forced regression. `recovery_hooks.c` reuses existing test-only native
invocation counters; no gate is armed, no failure is injected, and production C
is not copied. The regression is green against the unchanged production baseline:
there is no claim of a new runtime feature red or a manufactured race/mutation red.

### Disposable compiler controls

All proposal copies/objects remain ignored under
`.local/stage4b/first-delivery/proposal/`. `compile-proposal.py` copies the actual
FFI interface/body and adds proposed `Native_request.deliver` **only to those
copies**. The explicit interface/consumer compile first. The old copied body
then fails exactly for missing `deliver`; the copied normal-ABI slot adapter
compiles. A connection-as-request consumer rejects at line 2, characters 36-46;
a consumer against the unchanged copied interface rejects missing `deliver` at
line 1, characters 22-55. A system-thread closure retaining owner/request with
protected reservation retirement and join compiles but is **never executed**;
it is a type/root-capture shape, not an implemented controller loop.

`check-proposal-c.sh` checks C-private admission declarations and compile-only
normal-ABI adapter/selected-wrapper bodies with strict Clang. A wrong function
pointer type rejects at `admission_mismatch.c:2`. Objects retain unresolved real
runtime/delivery/wait symbols, printed with `nm -u`: **they are not linked or
executed**. There is no production C admission body or linked pause/race proof.
An initial OCaml fixture run failed warnings 40/42 on unqualified constructors;
qualification fixed it without disabling warnings. That incidental failure is
recorded, not counted as an intended red.

### Exact fresh evidence

Commands, cwd where relevant, output and exit statuses are in
`.local/stage4b/first-delivery/`. Every numbered validation command below exits 0,
except the explicitly recorded incidental fixture run `03` (exit 1). Expected
negative compiler subprocesses exit 2 for OCaml and 1 for Clang; their checkers
exit 0 only after matching named source/type diagnostics.

| Logs | Command/result |
| --- | --- |
| `01`, `02` | `stage1/run build test/bridge_recovery/test_bridge_recovery.exe`; `stage1/run build @test/bridge_recovery/runtest --force`: all four existing-semantics cases pass |
| `03`, `04` | `python3 .local/stage4b/first-delivery/compile-proposal.py`: incidental warnings failure then corrected positive shapes and three intended OCaml rejections |
| `05` | `bash .local/stage4b/first-delivery/check-proposal-c.sh`: C shapes and intended mismatch pass; no link/run |
| `06`, `07` | `stage1/run build @all`; forced native lifecycle, Resource lifecycle, B1 Bridge and new recovery aliases pass |
| `08`, `09` | Direct native checker with absolute pinned compiler; B1 checker from `test/` with the same compiler: intended controls pass |
| `10` | Strict Clang C11 `-Wall -Wextra -Werror -fsyntax-only` on the new hook, existing two hooks and four previously touched stubs passes; no production C changed in this run |
| `11` | `stage1/run runtest --force`: full Stage1–4 regression passes |
| `12-sanitize-*` | Recovery, B1 Bridge, Resource lifecycle and native lifecycle executables pass authored-C ASan/UBSan with the existing sanitizer profile/build directory |
| `13`–`19` | Six preservation hashes, tool versions, pinned dependency hashes and jj reference recorded |

Reproduce exact validation with
`bash .local/stage4b/first-delivery/validate.sh`. Sanitizer invocations use
`ASAN_OPTIONS=detect_leaks=0:halt_on_error=1 UBSAN_OPTIONS=halt_on_error=1`,
`timeout 120 stage1/run exec --profile stage3a-sanitize --build-dir
"$PWD/.local/stage4b/resource-lifecycle/build-sanitize" EXECUTABLE`.
Prebuilt DuckDB/runtime/Base are not instrumented. Whole-process LSan remains
unresolved; these are not whole-process leak-free claims. No installed-consumer,
new delivery mutation, controller-failure or scheduler-responsiveness test was
run for this non-activated proposal.

Fresh versions: compiler **5.2.0+ox**, Dune **3.22.2**, jj **0.45.1**, Clang
**22.1.8**, x86_64-pc-linux-gnu. Compiler source pin remains
`2515546fea38e21e8143cc41db663bd56efc8d06`; archive hash
`93dbcf859e655d2a2b41dfa077c126fa5a15fd0205b1c57dbb5ff2cc9d595462`.
DuckDB v1.5.5 header/library hashes remain
`48e716b9ce96ca8fead9cb35693fdc0343ac0fc1f6e7db5561fa0f44b674153d` and
`fc23f12e376c47be520f75221288281906e7942e8fd6f6ce4849198ba60d0405`.
Pinned compiler evidence is authoritative; no LSP-clean claim is needed.

`focused.diff`, `final-state.diff`, `final-summary.log` and `preservation.log`
were generated before documenting their existence and are refreshed after this
append by `python3 .local/stage4b/first-delivery/preserve.py`. They compare the
actual working diff with `before.diff`/working revision `0d5d9ecd`, require an
empty production `lib/` increment, and preserve every non-allowlisted diff
section (except generated `.pi/tasks/`) plus all six hashes. Working change
`rxsssmwz` remains over `3db90c1d`. jj has no staging area; no staging, commit,
new change, bookmark movement, publication, dependency/shared configuration or
execution-mode change occurred.

**Next gate:** owner decision on recoverable ML rollback and independent review
of this bounded proposal/regression. Only after that may a separately authorized
implementation establish controller start/failure/stop/join, active concurrent
roots, selected retirement, real reset-surviving interrupted return, internal
destructor exclusion, stale A/fresh B, discard-only interrupted ownership and
independent mutation oracles. Existing OOM/asynchronous-exception bookkeeping,
repeated signals, unsafe FFI misuse and nonreturning foreign-work limits remain.
Passing these checks is not first native-delivery implementation or B2 acceptance.

## First native boundary/controller — recovered implementation (2026-09-11)

**Implemented locally under `activation-approval.md`; independent review pending,
not B2 acceptance.** The owner approved the recoverable-ordinary-rollback
refinement now authoritative in the Stage4b plan. That supersedes earlier
pending-approval statements without rewriting their historical evidence. Safe
Duckdb declarations, Query/Appender/Parquet ML, packages and the evidence-only
recovery regression are unchanged. Only raw `execute(control=false)` admits
USER; control SQL and every other operation kind remain noninterruptible.

### ENOSPC recovery

Run `275fb029-8a96-4d66-b60f-561ced629add` stopped on an ENOSPC persistence failure,
not a reported compiler/test failure. The parent backed up actual lib/test/docs,
current diff and hashes under `first-delivery/enospc-recovery/` and
`/tmp/duckdb-enospc-recovery-2ilrimx1`. With explicit user permission, the parent
cleared **only** the audited project-local `_opam/.opam-switch/build` cache:
no installed symlink depended on it and no process was using it. Installed
packages, source, shared switches and configuration were untouched. The parent's
`cache-audit.json` and `toolchain-after-cleanup.log` record unchanged installed
ocamlc/ocamlopt/dune/ocamllsp hashes and passing version commands. No alternate
execution mode was used; this resumed worker deleted no cache.

Recovery began at `rxsssmwz` / `790ccc4a` over `3db90c1d`, with 45 GB free on
/home. `activation-recovered/00-source-integrity.log` verifies **all 117** backed-up
source hashes and all four installed tool hashes against actual files. The last
C per-subcall admission/cleanup edit is complete, not truncated; no mutation had
been started. A fresh pinned build (`01-build.log`) passed before continuation.
The preserved original activation logs end at the controller-green/native-
selection-red sequence; none is inferred to establish later native behavior.

All following paths are under `.local/stage4b/first-delivery/` unless specified.
New logs use `activation-recovered/`; earlier `activation/` and proposal evidence
are preserved, as is `before-activation.diff` (identical to `activation/start.diff`).

### Implemented synchronization and lifetime contract

- Actual FFI `.mli` gains `Native_request.deliver : t -> interrupt_result`, a
  **normal allocating ABI** adapter immediately delegating to the existing
  noalloc try-interrupt. The implementation does not pause, allocate managed
  data or release runtime. The approved test-linked wrapper CAML-roots its
  argument, releases runtime for a selected pause, reacquires, then invokes the
  real adapter. It never reads movable values while unlocked. No public safe
  pointer/identity/phase setter or duplicate production C build was introduced.
- `query_native.h` declares C-only user admission/end helpers. Each extraction,
  prepare-extracted and execute-prepared call checks the persistent native latch
  under the guard. The acquire-load is the admission decision against cancel's
  release-store; cancellation after admission may race engine entry/reset.
  Suppressed admission reports status 3 / Cancelled, while actual native errors
  keep their messages. Rearming never clears the request latch.
- Extraction/prepare completion returns to NONINTERRUPTIBLE before metadata or
  another call. Final execution completion enters CLEANUP before result-error
  inspection and destructors. Nested cleanup remains excluded, and normal work
  finishes before runtime reacquisition. No guard spans allocation, destruction,
  callback, wait, sleep or runtime transition. Delivery takes one try-acquire and
  rechecks identity, latch, USER phase, closing and live engine **after** a pause.
- Resource starts at most one owned system thread after successful binding and
  before the callback; none for Fresh or pre-binding cancellation. Start failure
  retains its exception/backtrace and deterministically detaches. The sole
  controller owns reservation retirement in a protected finally. A 1 ms retry
  delay is not a latency guarantee. Unexpected controller exceptions latch
  cancellation and are retained for terminal reporting.
- Owner gate -> request mutex -> native try-guard remains the lock order.
  Controller never takes owner gate; stop/join and native destruction occur
  outside ML locks. Worker/controller retain owner -> request -> native wrapper
  -> actual ML connection slot, plus registered child cleanup roots. Owner/native
  request identity and storage remain bound until foreign completion, selected
  retirement and join. Held-runtime controller entries serialize with held-
  runtime finalizers; released workers may contend only on short guarded state
  transitions. Active same-owner request/child finalizers remain unreachable.
  This is a supported-root invariant, not static lifetime or domain safety.
- Ordinary cleanup admission observes the latch under the request mutex. If
  cancellation already won, join precedes ML cleanup; otherwise ordinary
  transaction/snapshot rollback may finish noninterruptibly with the same live
  controller. A subsequent latch suppresses later user calls. Failed rollback,
  terminal cleanup, discard and detach always join. Cancelled scoped/manual child
  cleanup also joins before destruction. Transaction rollback first drains
  admitted foreign work, including the callback-exception path, **then** stops
  the controller; stopping before drain could lose repeated delivery.
- A real Delivered permanently marks the request's owner discard-only. Terminal
  cleanup destroys children, detaches/disposes and disconnects it before lease
  release. Cancelled requests with no actual delivery may reuse a clean owner.
  Cancellation does not establish that a write did not commit.

`26-native-assembly.log` records actual `objdump -dr` on the built C object:
try-interrupt performs one try-lock, post-selection checks and direct
`duckdb_interrupt`, then unlocks. The guard is one `lock cmpxchg`, not a waiting
loop. The adapter only establishes C roots and delegates. This supports the
specific authored no-wait/no-runtime-transition chain, not real-time latency or
whole-engine static claims.

### Real safe-Bridge gates and red/green evidence

`test/native_delivery/` contains 21 cases, using only safe Duckdb database
operations and existing FFI resource counters. Test-only wrappers gate actual
unlocked extraction/prepare/execute, result/prepared/extracted destructors,
rollback and disconnect. Two normal-ABI entry wrappers also root/release before
native request creation or raw execute, testing binding and native-admission
races without a production setter. No noalloc entry pauses. All gates release
before mandatory joins on failure; watchdog expiry is process failure.

Evidence includes real native **interrupted diagnostic** after repeated delivery
across execute's reset, interrupted explicit transaction rollback, and later
native interruption after recoverable ordinary rollback using the same sole
controller. Actual disconnect is held until selected retirement, join and detach
are observed. Active controller/worker GC stress leaves fallback counts unchanged.

Cancellation before native admission suppresses extraction; cancellation after
extraction/prepare suppresses the next subcall. Cancellation between exclusive
admission and native binding suppresses the callback/work and starts no controller;
that last case tests safe behavior, not direct inspection of the copied C latch.
Idle cancellation suppresses the next user call. Selected pause then native
completion proves skipped post-pause delivery, no join completion/detach/close or
fresh-request reuse before retirement, and no stale A delivery to fresh B.

Each internal destructor is held while a selected attempt resumes and skips.
This is real safe-Bridge cleanup exclusion, not a test-owned native slot fixture.
Transaction and snapshot rollback tests cover cancellation before admission and
while an already-admitted ordinary rollback is held: no delivery in rollback,
no later user work, required terminal join, primary diagnostics retained. Scoped
and manual cancelled child cleanup test join-before-destructor separately.
Every case restores binding live/fallback counters without GC for reclamation.

| Logs | Observation |
| --- | --- |
| `activation/01`–`03` | Real consumer rejects missing deliver, revised interface/consumer passes, real implementation rejects missing deliver before body implementation |
| `activation/06`, `08`, `09` | Missing controller assertion red, controller green, missing USER selection handshake red (gates released and joins completed; not an accepted timeout) |
| recovered `02`, `03`, `04` | Initial native cases, expanded cases and existing focused suites pass |
| `05-*-red`, `06` | Cancelled scoped/manual child cleanup reached a destructor before join; both named reds, then private Resource fixes and green |
| `07` | First mutation runner stopped because Multiple_failures hid the named assertion, despite exit 2; sources restored. Test reporting now recursively prints constituent exceptions rather than weakening the oracle |
| `09`–`10` | Five intended independent mutation reds and restored green |
| `27`, `28`, `29` | Result-error foreign-drain control was already green; callback-exception variant exposed premature controller stop, named red. Removed pre-drain join from rollback, retained post-drain decision; green |
| `30-mutation-*`, `31` | Final source: all five mutation builds exit 0, each named runtime red exits 2, restored 21-case suite exits 0 |

Final mutations independently remove post-pause eligibility, cleanup phase
publication, persistent admission checking, ordinary-rollback controller retention
and cancellation-before-rollback joining. Each fails its named safe-Bridge oracle.
`mutations.py` restores in finally; both targets match `.pre-mutation` backups.
The one-shot/reset negative remains the separately identified Stage4 unsafe
control in full regression, not a replacement for the safe positives.

### Final fresh commands and exact limits

`activation-recovered/validate.sh` contains the exact commands; run with
`VALIDATION_PREFIX=final-` to reproduce the final log names. **All `final-11`
through `final-25` commands exit 0**, including:

```sh
stage1/run build @all
stage1/run build @test/native_delivery/runtest @test/native_request_compile/runtest \
  @test/resource_lifecycle/runtest @test/adapter-bridge @test/bridge_recovery/runtest --force
bash test/native_request_compile/check_interfaces.sh "$PWD/_opam/bin/ocamlc"
(cd test && bash check_adapter_bridge_interfaces.sh "$PWD/../_opam/bin/ocamlc")
clang -std=c11 -Wall -Wextra -Werror -fsyntax-only -Ilib/ffi -I.deps/duckdb \
  -I_opam/lib/ocaml lib/ffi/resource_stubs.c lib/ffi/prepared_stubs.c \
  lib/ffi/typed_stubs.c lib/ffi/appender_stubs.c test/native_delivery/delivery_hooks.c \
  test/bridge_recovery/recovery_hooks.c test/adapter_bridge_hooks.c \
  test/resource_lifecycle/lifecycle_hooks.c
stage1/run runtest --force
# Five separate repetitions:
timeout 120 stage1/run exec --no-build test/native_delivery/test_native_delivery.exe
sha256sum --check .local/stage4b/preserved-six.sha256
```

Five authored-C ASan/UBSan executions (`final-18-sanitize-*`) pass using the
existing `stage3a-sanitize` profile and
`.local/stage4b/resource-lifecycle/build-sanitize`, with
`ASAN_OPTIONS=detect_leaks=0:halt_on_error=1 UBSAN_OPTIONS=halt_on_error=1` and a
120-second process timeout each: new native delivery, recovery regression, B1
Bridge, Resource lifecycle and native lifecycle. Prebuilt DuckDB/runtime/Base are
not instrumented. Unsuppressed whole-process LSan remains unresolved. Legacy
ML-only/USER-disabled test banners describe their earlier evidence scope, not a
current native-state probe; those preserved tests are not new delivery evidence.

Actual tools: compiler **5.2.0+ox**, Dune **3.22.2**, jj **0.45.1**, Clang
**22.1.8** (x86_64-pc-linux-gnu). Compiler source remains
`2515546fea38e21e8143cc41db663bd56efc8d06`; archive SHA256
`93dbcf859e655d2a2b41dfa077c126fa5a15fd0205b1c57dbb5ff2cc9d595462`.
DuckDB header/library SHA256 remain
`48e716b9ce96ca8fead9cb35693fdc0343ac0fc1f6e7db5561fa0f44b674153d` and
`fc23f12e376c47be520f75221288281906e7942e8fd6f6ce4849198ba60d0405`.
Automatic editor complaints about required POSIX/GNU linker names are not
compiler evidence; strict Clang and the pinned OxCaml checks pass. No editor or
shared configuration change was made.

`activation-recovered/{focused.diff,final-state.diff,final-summary.log,
final-ref.log,preservation.log}` were generated before this documentation and
are refreshed afterward by `preserve.py`. Comparison against
`before-activation.diff` / `f25ab0c9` preserves all non-allowlisted sections
(excluding generated `.pi/tasks/`), the six hashes, recovery regression and plan.
`before-activation.diff` SHA256 is
`85512f99647754bd6db6296b7601d3805be5ca43458d76b2e8202cb11f16042f`.
No jj commit/new change, bookmark movement, publication, raw Git, package install,
shared configuration or additional cache deletion occurred.

**Remaining gates:** independent review of this bounded implementation; full
Query/Appender/Parquet/commit/publication native admission coverage; adapter
scheduler/native-cleanup heartbeats and occupied-pool responsiveness; installed
consumers and complete B2–B4 acceptance. No universal finalizer responsiveness,
static lifetime, bounded join or whole-process leak claim. Existing OOM and
asynchronous-exception acquisition/bookkeeping gaps, arbitrary/repeated signals,
unsafe FFI misuse, nonreturning foreign work and crash/filesystem limits remain.

### P2 follow-up: observe the request worker's foreign-drain wait

**Test-oracle fix only; reviewed and parent-verified below; B2 remains unaccepted.**
The independent first-boundary review identified that controller selection in
`rollback-drains-foreign` did not prove the request worker had entered rollback's
foreign drain. The historical `activation-recovered/28-drain-exception-red.log`
caught early controller stop on one schedule, but is **not** deterministic
regression protection by itself. This follow-up replaces that ordering oracle;
it does not change the production rollback/controller contract or activation.

The test executable alone now links `--wrap=caml_ml_condition_wait`. Immediately
before raising `Drain_failure`, the request worker arms its next condition-wait
observation. The hook requires both its thread-local installed-request marker
and its thread-local arm: controller, observer and foreign-child threads cannot
publish this observation. The real foreign child remains held at native gate 5.
At this source seam the worker's next condition wait is the transaction drain.
The wrapper publishes a one-shot atomic observation and immediately delegates
to the real wait; it adds no wait, sleep, callback, runtime transition or native
guard acquisition. It does not inspect safe-handle representations. The worker
clears its arm in `finally` before joining its child, and successful uninstall
also clears it; reset clears the observation only between joined test cases.

The observer now awaits **actual request-worker drain entry OR premature join**,
then asserts `drain_wait_entered && join_entries = 0`. Only after this assertion
and the selected-controller handshake may it release gate 5. Independent
controller selection can no longer release the child before rollback starts.
Existing failure cleanup releases all gates before mandatory joins. No deliberate
weakness, production hook or duplicate C implementation is retained.

All new evidence is under `.local/stage4b/first-delivery/drain-oracle/`.
`baseline.diff`, `baseline-focused.diff`, `baseline-hashes.json` and copied
baseline files were saved before edits at `rxsssmwz` / `5d5dd9cb` over `3db90c1d`.
`final-focused.diff` is the incremental baseline-to-current diff (not the whole
pre-existing dirty change); `final-state.diff` and `final-status.log` retain the
whole working-copy context. These artifacts and the logs below were generated
before being cited and are refreshed after this append.

| New logs | Command/result |
| --- | --- |
| `01-interface` | `stage1/run build test/native_delivery/.test_native_delivery.eobjs/byte/dune__exe__Test_native_delivery.cmi`, exit 0; existing explicit `.mli` unchanged |
| `02-missing-hook-red` | `stage1/run build test/native_delivery/test_native_delivery.exe`, exit 1 after ML external declarations, intended undefined references to `delivery_arm_drain_wait` / `delivery_drain_wait_entered` |
| `03-hook-green`, `06-restored-green`, `07-forced-alias` | `stage1/run build @test/native_delivery/runtest --force`, each exit 0, all 21 cases |
| `04-early-stop-build` | Exact transient early-join mutation builds, exit 0 |
| `05-early-stop-red-1` through `-5` | Five separate focused executions, each exit 2 with `Failure "rollback drains foreign before stopping controller"`; not timeout/watchdog failures |
| `08-repeat-1` through `-5` | Five separate restored full 21-case executions, each exit 0 |
| `09-strict-clang`, `10-all`, `11-focused-sanitize` | Strict authored-C checks, `@all`, and all 21 native-delivery cases under authored-C ASan/UBSan, each exit 0 |
| `12-preserved-six`, `13`–`18` | Six hashes pass; compiler/Dune/jj/Clang versions, dependency hashes and jj reference recorded |

`python3 .local/stage4b/first-delivery/drain-oracle/mutate-early-stop.py`
reintroduces the early-controller-stop behavior by changing exactly the rollback
body's `complete_cleanup (fun () -> revoke_and_drain ();` to
`complete_cleanup (fun () -> admit_cleanup c; revoke_and_drain ();`.
It backs up `lib/duckdb/resource.ml`, requires the named assertion in each of
five reds, restores bytes in `finally`, then forces the restored alias green.
`early-stop-mutation.txt`, `mutation-transcript.log` and
`mutation-restoration.log` record the replacement, exits and restoration hash.
Each mutated runtime command is exactly:

```sh
timeout 40 stage1/run exec --no-build test/native_delivery/test_native_delivery.exe -- rollback-drains-foreign
```

The fresh green validation script is
`bash .local/stage4b/first-delivery/drain-oracle/validate.sh`; its transcript and
individual logs record exact arguments/exits. In addition to the alias above:

```sh
# Five executions, separately logged:
timeout 120 stage1/run exec --no-build test/native_delivery/test_native_delivery.exe
clang -std=c11 -Wall -Wextra -Werror -fsyntax-only -Ilib/ffi -I.deps/duckdb \
  -I_opam/lib/ocaml lib/ffi/resource_stubs.c lib/ffi/prepared_stubs.c \
  lib/ffi/typed_stubs.c lib/ffi/appender_stubs.c test/native_delivery/delivery_hooks.c
stage1/run build @all
ASAN_OPTIONS=detect_leaks=0:halt_on_error=1 UBSAN_OPTIONS=halt_on_error=1 \
  timeout 120 stage1/run exec --profile stage3a-sanitize \
  --build-dir "$PWD/.local/stage4b/resource-lifecycle/build-sanitize" \
  test/native_delivery/test_native_delivery.exe
sha256sum --check .local/stage4b/preserved-six.sha256
python3 .local/stage4b/first-delivery/drain-oracle/preserve.py
```

The pinned existing `stage1/run` / `_opam` worked with the owner's relocated opam
root; no fallback, dependency or configuration changes were needed. Fresh versions
remain OxCaml `5.2.0+ox`, Dune `3.22.2`, jj `0.45.1`, Clang `22.1.8`; the compiler
archive and DuckDB header/library hashes match those recorded above.
`preservation.log` and `production-final.sha256` verify all **27 production
files** equal the pre-fix baseline, every other non-allowlisted tracked file is
preserved (excluding `.pi/tasks` bookkeeping), and all six preservation hashes
pass. Authored changes are only the three native-delivery test files and this
documentation append. No `.mli` change, staging, commit/new change, bookmark,
publication, raw Git, sudo or shared configuration operation occurred.

**Scope of new proof:** only the forced native-delivery alias, five normal suite
repetitions, five early-stop mutation reds, strict Clang, `@all` and one focused
21-case sanitizer execution were rerun here. Full `runtest --force`, other
focused aliases/compiler controls, other sanitizer executables and installed
consumers were **not** rerun for this test fix; earlier full-regression logs are
historical evidence, not new proof. Sanitizers still exclude prebuilt
DuckDB/runtime/Base and use `detect_leaks=0`. Independent review and subsequent
parent checks are recorded below; remaining B2–B4/adapter/native-boundary gates
and previously stated safety limits remain unchanged.

### First-boundary acceptance: reviews and parent verification

The implementation workflow stopped with `Request was aborted` after saving its
report and final artifacts; its scheduled reviewer did not run. The parent
captured `activation-recovered/abort-state.diff` and verified it equals the
worker's `final-state.diff` byte-for-byte. The report survived. No cause linking
the abort to the owner's opam relocation was established; the queued relocation
notice was not delivered to the terminated worker. Recovery remained within the
native subagent protocol, with no source edits for report recovery.

Independent reviewer `601f38c8-629a-4df8-a2af-9333511c358b` found no P0/P1
production defect within the supported one-boundary/system-thread contract.
It identified P2: selection alone did not prove rollback had entered its foreign
drain. The test-only follow-up above corrected that oracle. Fresh reviewer
`680b075a-c178-45c5-9e03-3801cfb46dd2` confirmed P2 resolved, no fix-local
race/deadlock or new issue, and restored production code. Both reviews were
read-only source/evidence reviews, not independent test reruns. Their managed
reports are `reviews/first-boundary-independent.md` (run `601f38c8...`) and
`reviews/drain-oracle-fix.md` (workflow `82770bac-104d-4948-932c-96acb61cb78f`).

The parent inspected controller/cleanup/native-admission code and the revised
drain handshake, then independently ran:

```sh
stage1/run build @all
stage1/run build @test/native_delivery/runtest \
  @test/native_request_compile/runtest @test/resource_lifecycle/runtest \
  @test/adapter-bridge @test/bridge_recovery/runtest --force
clang -std=c11 -Wall -Wextra -Werror -fsyntax-only \
  -I.deps/duckdb -I_opam/lib/ocaml test/native_delivery/delivery_hooks.c
sha256sum --check .local/stage4b/first-delivery/drain-oracle/production-final.sha256
sha256sum --check .local/stage4b/preserved-six.sha256
```

All exited **0**. Exact output is in
`.local/stage4b/first-delivery/drain-oracle/20-parent-final.log`. The 27 production
hashes confirm the test fix left production unchanged. Full regression, repeated
runs, mutation reds and sanitizer results remain the reviewed worker evidence;
the parent did not independently repeat those commands.

**Accepted only:** controller ownership/retirement and the guarded raw-execute
user boundary, within the stated supported contract. **Not accepted:** complete
B2, all operation boundaries, commit/publication admission, adapters, installed
consumer gates, scheduler/native-cleanup heartbeat or whole-process leak freedom.
Existing limitations and the remaining B2–B4 gates still apply.

## Query native-delivery increment (2026-09-12; reviewed and parent-verified)

**Implemented and checked only for the approved Query slice. Not full B2/B3/B4
or adapter acceptance.** Raw execute's accepted controller/lifecycle protocol is
preserved. Query extraction, prepare-extracted, prepared execution and chunk fetch
now individually admit USER; bind/reset admit the persistent latch without USER.
Control BEGIN/COMMIT/ROLLBACK native-entry linearization, Appender delivery,
dedicated Parquet filesystem/publication coverage, installed consumers and
scheduler/native-cleanup heartbeats remain later gates. Query internals used by
Parquet benefit incidentally; this is not complete Parquet cancellation coverage.

All new commands, full outputs/statuses, backups and focused artifacts are under
`.local/stage4b/query-delivery/`. The mandatory supervisor checkpoint approved
this classification, private interface and lifetime argument **before production
edits**. A later explicit approval covers the shared backtrace fix below; another
confirms the existing POSIX/GNU linker names are audited editor false positives,
not permission to disable warnings. No package, scheduler, safe public signature,
raw pointer, identity setter, async callback or production test setter was added.

### Exact boundary and ownership contract

- `prepared_stubs.c`: each extraction, prepare-extracted, execute-prepared and
  fetch uses the existing guarded persistent-latch admission mechanism. Cancellation
  winning the acquire-load decision suppresses that individual call (status 3).
  A call admitted first is in flight: repeated delivery may race native entry and
  engine interrupted-flag resets. No rearming clears the latch. Each USER call
  explicitly ends before diagnostic/kind metadata. Preparation then publishes
  CLEANUP before extracted/input destruction; fetch destroys the old chunk in
  CLEANUP **before** admitting the next fetch. Execution/fetch retain produced
  results/chunks until safe cleanup; success plus a later latch never exposes a
  cancelled chunk or returns a successful result from the operation.
- `typed_stubs.c`: the new C-only `noninterruptible_call_begin` shares the same
  guarded latch decision without enabling engine interruption. All bind entry
  points and clear-bindings/reset use it. Temporal-value creation is separately
  admitted from its subsequent bind-value; if that second admission loses, the
  created value is still destroyed under CLEANUP. Input copies and temporary
  values are C-owned while unlocked. Failed/suppressed bind does not restore its
  ML usable-binding bit; reset clears all bits before entry. Tests exercise each
  binding family with representative scalar types (TIMESTAMP_S for the shared
  temporal path); remaining scalar/temporal branches are source-audited plus
  existing roundtrip/signal regressions, not separate deterministic race claims.
- Held-runtime parameter/schema metadata and scalar/borrowed reads remain
  synchronous noninterruptible **batches**, not independently native-linearized
  cells/calls. Query checks before/after parameter extraction/schema validation
  and before publishing owned schema output where applicable. Cancellation after
  batch admission may race that already-admitted batch. Callback batches and
  Continue/Stop/empty/exhausted returns use existing ML checkpoints; no per-cell
  offload or USER arming is introduced. Result publication retains the existing
  post-native/post-snapshot checks. A native COMMIT-entry race is still unimplemented.
- Native status ABI remains `int`: 0 success, 1 native diagnostic, 2 unsupported,
  3 suppressed cancellation. Query maps 3 to the named `Cancelled`; real engine
  failures retain `Native_error` and their diagnostic. Production never matches
  message strings to classify cancellation. Tests inspect the actual interrupted
  diagnostic only as an oracle for real engine completion.
- Query's directly owned prepared/result cleanup calls private `admit_cleanup`
  **after foreign completion**, including failed prepare, fresh schema temporaries,
  failed execution and fold cleanup. Cancellation-driven destruction therefore
  follows selected retirement and controller join. Ordinary cleanup admitted
  first remains native-ineligible with the same sole controller; no restart.
  Existing Resource terminal/drain/discard and recoverable rollback logic is
  unchanged. Any actual Delivered still makes the owner discard-only.
- Native workers CAML-root prepared slots; registered child cleanup closures root
  live prepared owners, and fresh schema temporaries retain scoped/CAML roots.
  Worker/controller roots retain request -> native request -> actual ML connection
  slot. Native prepared refs retain the shell, not independent permission to use
  a disconnected engine. Existing exclusive admission and root/drain protocol
  supplies engine validity. Old chunks are destroyed only after borrowed callbacks
  have returned under the existing local/effect barrier. Native phase/cleanup
  transitions release their guard before destruction, allocation, wait, callback
  or runtime transition. Normal destructors remain unlocked; finish/finalizer
  backstops remain held-runtime and outside universal responsiveness claims.

### Private interface-first evidence and shared backtrace correction

`Resource.mli` exposes the **already existing** `admit_cleanup`; a same-package
consumer compiles against actual copied private interfaces before Query uses it.
The disposable missing-declaration control rejects exactly
`query_cleanup.ml:1:25-47`, `Unbound value Resource.admit_cleanup` (`01-interface`).
This is not a missing-production-body red. `query_native.h` declares the named
noninterruptible admission helper; a function-pointer consumer passes strict
C11 compilation before its body (`02-c-interface`). Actual authored stubs then
fail linkage for missing `duckdb_ml_native_noninterruptible_call_begin` before
that body is implemented (`11-admission-body-red`). The new test module has its
explicit `.mli`; missing test-linked externals produce `03-missing-hooks-red`.

A new caught Query callback test exposed a **pre-existing shared wrapper gap**:
`Resource.protected_operation` crossed `Sys.with_async_exns` directly, replacing
an already captured callback backtrace with the runtime primitive frame. Logs
`21-final-query` and `22-backtrace-diagnosis` retain the named assertion and actual
lost trace. The supervisor explicitly approved capturing exception/backtrace
inside that existing boundary and re-raising outside, keeping outer
`Exn.protect`/`finish_operation` in place. Normal results/errors, pending-action
behavior and cleanup composites retain their existing paths. `23-backtrace-green`
proves callback identity, source frame, cancellation poison and cleanup.
**Review blast radius:** this small `Resource.ml` change serves shared admission,
not just Query. Full signal/exception/shared-admission regression was rerun after
it; this is no additional native activation or admission redesign.

### Deterministic actual safe Query evidence

`test/native_delivery/query_delivery.{mli,ml}` adds **34 cases** to the existing
executable (55 total with the preserved 21 cases). Tests use actual safe Bridge
and Query operations; FFI access is only existing resource/fallback counters.
Link-only wrappers add normal-ABI pre-entry gates, actual engine entry/return and
value/chunk destruction observations. Normal-ABI wrappers CAML-root arguments
before releasing the runtime; no noalloc entry waits. Query mode filters held
gates by the installed-request-worker TLS marker, excluding observers/controllers.
The old foreign-child drain test leaves this mode disabled; its reviewed
request-worker condition-wait oracle is unchanged. All failure paths release
gates before mandatory joins. Watchdog/timeout is failure, never cleanup permission.

Cases cover pre-prepare suppression; after extraction/prepare for initial and
schema-refresh preparation; post-FFI-prepare success; native prepare error with
concurrent cancellation; reset and null/integer/float/string/temporal bind
before/after entry; temporal create-to-bind suppression with guaranteed destruction;
prepared execute admission and native-result return; real repeated interruption
across prepared execution's reset after clear-bindings; first fetch admission and
produced/empty fetch returns; old-chunk cleanup before next-fetch admission;
Continue/Stop borrowed callbacks; caught callback exception identity/backtrace and
persistent poisoning; next-call suppression even when operation errors are ignored.

Prepared/schema/chunk cleanup races wait for **actual worker join entry OR native
destructor entry**, not independent controller selection, and require join first.
They additionally check no detach/disconnect/reuse while selected, then retirement
and join before held destruction. Internal extracted cleanup holds the real
unlocked destructor while a selected attempt resumes and skips, before ML join.
Old-chunk cleanup is necessarily entered noninterruptibly from completed prior
fetch/returned callback; native phase balancing there is source-audited and the
next-call latch is dynamically tested, not a fabricated eligible delivery window.
Each case restores live/fallback counts without GC reclamation. Those counters
cover binding-owned resources, not every engine/runtime allocation.

The old `snapshot-rollback-before` test assumed Query was USER-disabled and
initially failed its global interrupt-count-zero assertion (`16-focused`). Query
return gate 6 now legitimately admits delivery **before rollback**. The test now
holds selected delivery, releases native return, observes real join entry, and
retires selection before the rollback gate. This preserves its no-delivery,
noninterruptible rollback and reusable-owner oracle without altering production
rollback. The ordinary-rollback-after case and separate recovery regressions remain.

### Reds, independent mutations and final verification

`05-prepare-red`, `06-bind-red`, `07-temporal-red`, `08-execute-red`, `09-fetch-red`
are actual preimplementation safe-path assertion failures, all exit 2, not
scaffolding/timeout failures. `13-query-green` passes the first 24 cases;
`14-expanded-query` passes 32. The later backtrace red/green is described above.

`python3 .local/stage4b/query-delivery/mutations.py` runs **seven independent**
mutations on final production source: ignore Query preparation admission; ignore
binding admission; ignore only the temporal second admission; remove direct
prepared cleanup joining; the same isolated cleanup removal against fresh schema;
remove direct result/chunk cleanup joining; and restore the old shared backtrace
wrapper. Each mutation builds successfully, then exits 2 at its named assertion.
No unrelated defense is removed to manufacture red. Source is restored in finally,
with per-target restoration hashes/backups. `24-final-mutations` lists every result;
`18-*-red` contains full output and `19-restored-query` is green. These cleanup
mutations test new ML retirement-before-destruction exclusions; they do not claim
independent sensitivity to every redundant native phase transition.

Final `validate.sh` / `final-validation-transcript.log` records exact commands and
statuses. **All `25`–`38` validation commands exit 0**, on restored final source:

```sh
stage1/run build @all
stage1/run build @test/native_delivery/query-delivery @test/native_delivery/runtest \
  @test/native_request_compile/runtest @test/resource_lifecycle/runtest \
  @test/adapter-bridge @test/bridge_recovery/runtest --force
bash test/native_delivery/check_query_interfaces.sh "$PWD/_opam/bin/ocamlc"
bash test/native_request_compile/check_interfaces.sh "$PWD/_opam/bin/ocamlc"
(cd test && bash check_adapter_bridge_interfaces.sh "$PWD/../_opam/bin/ocamlc")
(cd test && bash check_query_modes.sh "$PWD/../_opam/bin/ocamlc")
(cd test && bash check_interfaces.sh "$PWD/../_opam/bin/ocamlc")
clang -std=c11 -Wall -Wextra -Werror -fsyntax-only -Ilib/ffi -I.deps/duckdb \
  -I_opam/lib/ocaml lib/ffi/resource_stubs.c lib/ffi/prepared_stubs.c \
  lib/ffi/typed_stubs.c test/native_delivery/delivery_hooks.c
stage1/run runtest --force
# Five separately logged complete 55-case executions:
timeout 120 stage1/run exec --no-build test/native_delivery/test_native_delivery.exe
sha256sum --check .local/stage4b/preserved-six.sha256
```

Authored-C ASan/UBSan passes for the complete delivery executable and recovery
executable, using the existing `stage3a-sanitize` profile/build directory
`.local/stage4b/resource-lifecycle/build-sanitize`, `timeout 120`,
`ASAN_OPTIONS=detect_leaks=0:halt_on_error=1 UBSAN_OPTIONS=halt_on_error=1`.
Prebuilt DuckDB/runtime/Base are uninstrumented. Unsuppressed whole-process LSan
remains unresolved; this is neither whole-process leak freedom nor static lifetime
or universal finalizer responsiveness. Installed-consumer and scheduler-native
cleanup heartbeats were not newly run or claimed.

Fresh pins (`38-pins`): OxCaml **5.2.0+ox**, Dune **3.22.2**, jj **0.45.1**, Clang
**22.1.8**, x86_64-pc-linux-gnu. DuckDB header/library SHA256 match previous pins
`48e716b9ce96ca8fead9cb35693fdc0343ac0fc1f6e7db5561fa0f44b674153d` /
`fc23f12e376c47be520f75221288281906e7942e8fd6f6ce4849198ba60d0405`.
The authoritative local runner/switch worked after the owner's opam relocation;
no migration/reinstall/configuration edit or alternate execution mode was used.
Normal signed jj snapshots also worked; signing was never bypassed.

`focused.diff`, `final-state.diff`, `final-ref.log`, `changed-files.json`,
`final-source.sha256` and `preservation.log` were generated before this append and
are refreshed afterward by `preserve.py`. Baseline `before.diff` equals the
worker's pre-edit snapshot byte-for-byte. Every non-allowlisted baseline source
hash and jj diff section is preserved (except generated `.pi/tasks` bookkeeping),
including all six preservation hashes. Working change remains `rxsssmwz` over
`3db90c1d`; jj has no staging area. No raw Git, staging, commit/new change, bookmark,
publication, sudo, dependency/shared/editor configuration or cache deletion occurred.

**Remaining scope:** do not infer full B2/B3/B4, complete Parquet/control/Appender
cancellation, adapter readiness, no durable writes on cancellation, or static
safety from these checks. Existing OOM/asynchronous-exception bookkeeping gaps,
arbitrary/repeated signals, unsupported unsafe concurrency, nonreturning foreign
work and process/filesystem failure limits remain.

### Query review and parent verification

Independent reviewer `9f9d51d5-f2c7-4862-b075-26ce9e1724f7` found **no issues**
and approved this bounded Query increment, including shared `protected_operation`
backtrace transport and the adjusted snapshot oracle. It reviewed actual sources,
focused diff and recorded evidence, without editing or independently rerunning
tests. Report: `reviews/query-native-delivery.md` in workflow
`05fe6b22-fb74-42f5-9f9e-b66e4331baf0`.

The parent inspected Query cleanup, typed temporal admission and the shared
exception wrapper. `43-parent-validation.log` records fresh successful `@all`,
all six focused aliases listed above, and strict C checks on Resource/prepared/
typed stubs and native-delivery hooks. The subsequent worker-manifest check
exited **1**: only `test/native_delivery/check_query_interfaces.sh` differed.
Comparison against reviewed revision `5802b65576c3` showed shell formatting only
(redirection spacing and replacing a semicolon with a newline), with no behavior
change. The parent did not revert that formatting or overwrite the original
manifest; the exact difference is `44-checker-format-diff.log`.

The current checker then passed direct positive/source-specific negative controls.
A separate `parent-source.sha256` records the current source files (not this
changing evidence document). Its check and the six preserved-file checks all
exit **0**, recorded in `45-parent-final-checks.log`. The original failed hash
check remains recorded rather than being relabelled a pass. No production code
was changed by the parent during acceptance.

This accepts only the bounded Query increment. Full forced regression, five
55-case repetitions, seven restored mutation reds and sanitizers are reviewed
worker evidence; the parent reran the build/focused/compiler/C/hash checks above,
not those larger suites. Appender/control/publication, installed-consumer and
scheduler-native-cleanup gates remain open; **full B2 is still unaccepted**.

## Finish-wave Appender increment (2026-09-12; independent review pending)

**Implemented and validated for this bounded phase only; ready for independent
phase review, not accepted B2/B3/B4 or a completed bridge.** Control/commit and
dedicated Parquet/publication coverage are next. Installed consumers and actual
scheduler/native-cleanup heartbeats remain full-bridge gates, not claims here.
No adapter, public safe signature, scheduler dependency, raw pointer conversion,
public phase/identity setter or unsafe cast was added.

Evidence root: `.local/stage4b/finish-bridge/appender/`. All numbered logs contain
exact command/output/exit. `before.diff`, `before-ref.log`, `baseline/` and
`baseline-hashes.json` were saved before edits. The phase began at
`rxsssmwzkuvk` / `aa76d86cf8cc`, over `3db90c1d7940`; no earlier phase in this
finish wave. `checkpoint.md` records the pre-edit supervisor approval and later
editor adjudication. Production edits are **only** `lib/duckdb/appender.ml` and
`lib/ffi/appender_stubs.c`. Resource/controller, Query, shared C headers/helpers,
all safe `.mli` files and package/build configuration are preserved.

### Boundary classification and lifetime argument

- Appender metadata now uses separately latch-admitted extraction and
  prepare-extracted instead of the combined `duckdb_prepare`. Extraction,
  preparation, execute-prepared and each fetch (including exhaustion) admit USER
  individually. Every USER ends before diagnostics/scalar work/destruction.
  The constant metadata SQL still runs in the appender's explicit transaction
  snapshot. Each metadata binding admits the latch without enabling delivery.
- Appender creation, schema extraction, begin-row, temporary value creation and
  append-value are **noninterruptible** latch admissions. Each next native
  mutation consults the persistent latch, including the second admission after
  value creation. Already-admitted scalar work may finish. Temporary DuckDB
  values are destroyed even if the subsequent append admission loses; copied
  cell/string/blob storage remains C-owned throughout released-runtime work.
  Held-runtime cached-schema array copies form a synchronous metadata batch;
  a post-copy ML checkpoint prevents publishing an appender cancelled during it.
- End-row can automatically flush through a real INSERT, so it admits USER;
  this does not imply each row is a query or add per-cell scheduler dispatch.
  Explicit flush and safe normal-close flush also admit USER. The first
  cancelled admission sets native status 3; the safe layer maps it to named
  `Cancelled`. Status 0 remains success and status 1 preserves the first native
  diagnostic. Production never classifies cancellation by matching messages.
  Later rows/batches/flushes cannot proceed after the latch wins admission,
  including when the caller drops an error or catches an exception.
- Safe normal close explicitly flushes first, then admits cleanup, then calls
  native close with **false**. Destruction is in a protected finally, including
  flush error/exception paths. Native clear precedes destroy unconditionally;
  buffered or partial rows are discarded rather than silently flushed by the
  engine destructor. Primary flush/poison errors remain primary; cleanup
  exceptions still compose through existing `Exn.protect`/Resource settlement.
  A final close checkpoint covers cancellation during already-admitted cleanup.
  The unsafe FFI close(true) path retains its ABI and now latch-admits its user
  close before cleanup; safe close never uses that path.
- Direct failed-create cleanup and every Appender-owned destructor call private
  `Resource.admit_cleanup` **after foreign completion**. Cancellation-driven ML
  destruction follows controller retirement/join. Ordinary cleanup admitted
  first can retain the same sole controller, but native delivery is ineligible.
  Native metadata/result/chunk/statement/extracted/error-data/value/type cleanup
  uses the existing cleanup guard protocol. Error-data/type and scalar-value
  destruction cannot admit USER; this is also source-audited, not a claim of
  separate interrupted-engine completion for scalar operations.
- Existing lock/root/finalizer invariants are unchanged: worker/CAML roots retain
  appender slots and copied storage; registered child closures retain live
  appenders; worker/controller retain request -> native request -> actual ML
  connection slot. Native child references retain the shell, not independent
  permission to use a disconnected engine. No native guard spans allocation,
  destruction, waits, callbacks or runtime transitions. Ordinary close clears
  the native appender before finish reacquires/destructs the remaining shell;
  finish has no engine appender left on ordinary cancellation. Exceptional
  signal/finalizer backstops remain potentially held-runtime, not universally
  responsive. No new lifetime/static-ownership guarantee is claimed.
- Recoverable ordinary rollback still retains the sole ineligible controller;
  cancellation-driven/terminal cleanup joins. Cancellation racing an admitted
  rollback permits completion but no later user work. Any actual Delivered
  remains discard-only. Cancellation does **not** undo already-admitted effects:
  flush can advance a nontransactional sequence even if transaction rows roll
  back; commit/publication durable-effect gates remain later work.

Pinned engine classification uses the existing immutable v1.5.5 source revision
`d8cdaa33fda8df955cc76ef58a280f68f4cd43fa`:
`.local/stage3c/appender.cpp:71–82,393–418,497–553,606–620,744–758`,
`.local/stage3c/appender-c.cpp:94–105`, and
`.local/stage3b-schema/client_context.cpp:1304–1309`.
EndRow -> FlushChunk -> Flush -> Appender::FlushInternal -> ClientContext::Append
runs a real query; Clear resets buffered/partial state before destructor Close.
Fresh source/header/library/compiler hashes are in `verified-45-pins.log` and
match prior accepted pins. No source download or dependency replacement occurred.

### Tests, reds and oracle corrections

`test/native_delivery/appender_delivery.{mli,ml}` extends the existing executable
by **45 cases, 100 total**, preserving the prior 55 and the drain/backtrace fixes.
All database race positives use actual safe Bridge operations. Only existing
binding/fallback counters use FFI directly; test-only linker wrappers provide
normal-ABI rooted entry gates or already-unlocked native gates. The existing
request-worker filter excludes observers/controllers from held gates. Every
failure releases all gates before mandatory joins; watchdog/timeout is failure,
never cleanup/reuse permission.

Coverage includes metadata/create/schema before and after admission, successful
native return and post-copy publication; absent table and actual create-on-view
native failures concurrent with cancellation; batch/row/cell/value boundaries;
second value admission with guaranteed destruction; two batches through the
explicit-transaction variant; dropped cancellation errors and caught callback
exception with **original identity and source-named backtrace**; explicit flush,
normal close and automatic flush; actual native interrupted completion in all
three flushing routes, with repeated delivery surviving the INSERT reset and
owner discard. Automatic-flush tests gate the pinned 204800th end-row, append
220000 input rows, and require no 204801st mutation. The uncancelled/returned
sequence oracle proves the engine really flushed, not merely reached a wrapper.

The nontransactional sequence no-flush test and paired normal-close control are
independent of transactional row counts. Clear-before-destroy mutation causes
that sequence test to fail even though rollback still removes rows. Selected
normal-close flush tests await **actual worker join OR destructor entry**, hold
selected delivery through that observation, and require retirement/join before
clear/destroy; no owner reuse/detach/disconnect is allowed while selected.
Metadata's internal result/chunk/statement/extracted destructors instead hold
real cleanup while a selected attempt resumes and skips before ML join.
Noninterruptible create has no selected ticket: its distinct cleanup test
captures join completion **at actual clear entry**. Ordinary cleanup and ordinary
rollback admitted before cancellation retain the sole controller while held,
then suppress later work and settle. Each case restores binding live/fallback
counts without GC; these counters do not enumerate all engine/runtime allocations.

| Evidence under the phase root | Observation |
| --- | --- |
| `01-interface`, `02-c-interface`, `03-test-interface` | Appender-named private Resource consumer, C function-pointer declarations and explicit test `.mli` compile before production. Missing private declaration rejects the exact Appender source/location. Existing helper bodies pre-exist; not missing-body reds. |
| `04-missing-hooks-red`, `05-hooks-build` | Expected undefined test-wrapper links before bodies, followed by successful link. |
| `06-metadata-red`, `07-batch-red`, `08-cell-red`, `10-flush-red` | Preimplementation safe-operation failures, each exit 2 at intended native admission assertions, not timeouts. |
| `11-first-green`, `16-expanded-green` | First 20 then 32 Appender cases pass. |
| `15-callback-red` | Appender-local outer `Sys.with_async_exns` replaced the preserved callback trace. Capture exception/backtrace inside that boundary; no Resource change. Source-named test passes in subsequent greens. |
| `19-close-return-red`, `20-metadata-publish-red` | Actual post-cleanup close latch and post-schema publication failures; corresponding ML checkpoints fix them. |
| `23-regression`, `24-concurrency-green` | Old concurrency point 4 awaited removed native close call and timed out. Retargeted only its hook to actual normal-close flush; all ten DDL/snapshot races pass, including original row/conflict/Busy/drain assertions. |
| `27-final-expanded`, `28-final-expanded` | New metadata-result cleanup gate initially caught BEGIN's result destruction before metadata. Arm after actual BEGIN inside transaction callback; corrected causal gate passes. Initial handshake failure is retained, not a red/pass claim. |
| `39-final-regression`, `46-signal-*` | Original close-leave signal now hit flush return (10 live, expected post-clear 9). Preserve exact old cleanup oracle with link-only `ml_duckdb_close_appender` target; add separate close-flush enter/leave tests. All four pass with counts 10/9/10/10 and zero final resources/fallback. |
| `final-39-final-regression` | Exposed test-only scheduling assumption in noninterruptible-create cleanup: correct join can finish and destructor enter before observer resumes. Capture join count at actual clear entry, not an assumption that every controller has selected work. USER selected-close tests stay distinct. |
| `30-final-mutations`, `47-restored-mutations`, `25-*-{build,red}` | Nine independent mutations build successfully and exit 2 at named assertions. Final mutation rerun includes corrected cleanup oracle. |

Mutation command: `python3 .local/stage4b/finish-bridge/appender/mutations.py`.
Independent controls bypass USER latch admission, scalar latch admission, only
the second temporary-value admission, direct cleanup joining against close and
create separately, clear-before-destroy, metadata publication checkpoint, final
close checkpoint, and the Appender-local callback backtrace repair. Source is
restored in finally. `mutation-restoration.log`, both `*.mutation-backup` files
and `preservation.log` verify final production equals restored backups exactly.
No deliberately weakened check remains.

### Final verification and limitations

After all corrections, **every `verified-*` command exited 0**. Reproduce with:

```sh
bash .local/stage4b/finish-bridge/appender/validate.sh
```

`verified-validation-transcript.log` includes exact command/status summaries;
individual full logs cover:

- `verified-31-final-all`: `stage1/run build @all`.
- `verified-32-final-focused`: forced Appender, Query and complete native-delivery
  aliases, native request/lifecycle, Resource close lifecycle, B1 Bridge and
  recovery aliases; no prior case removed.
- `verified-33`–`37`: direct private cleanup/native declarations, safe Bridge
  privacy/forgery/domain controls, Query borrowed/mode controls, safe interfaces
  and Appender owner-type controls using the pinned compiler.
- `verified-38-final-clang`: C11 `-Wall -Wextra -Werror -fsyntax-only` with
  `-Ilib/ffi -I.deps/duckdb -I_opam/lib/ocaml`, on resource/prepared/typed/appender
  stubs and native-delivery/appender/stage3c-signal hooks.
- `verified-39-final-regression`: full `stage1/run runtest --force`, including
  Stage1–4 and all old/new signal, drain, concurrency, rollback and mode suites.
- `verified-40-repeat-1` through `-5`: five complete 100-case executions, each
  `timeout 120 stage1/run exec --no-build test/native_delivery/test_native_delivery.exe`.
- `verified-41`–`43`: authored-C ASan/UBSan passes for the 100-case executable,
  recovery and Appender concurrency. Existing `stage3a-sanitize` profile and
  `.local/stage4b/resource-lifecycle/build-sanitize` are reused; each command has
  `timeout 120`, `ASAN_OPTIONS=detect_leaks=0:halt_on_error=1` and
  `UBSAN_OPTIONS=halt_on_error=1`.
- `verified-44-preserved-six`, `verified-45-pins`: all six hashes pass. Current
  tools: OxCaml **5.2.0+ox**, Dune **3.22.2**, jj **0.45.1**, Clang **22.1.8**,
  x86_64-pc-linux-gnu. Compiler source remains
  `2515546fea38e21e8143cc41db663bd56efc8d06`; archive/header/library hashes match
  prior pins. Project runner works with relocated global opam root; no migration,
  reinstall/configuration edit or cache deletion was needed. `/home` had 44 GB free.

`focused.diff`, `final-state.diff`, `final-ref.log`, `changed-files.json`,
`final-source.sha256` and `preservation.log` were generated before this append
and refreshed afterward by `preserve.py`. All nonallowlisted baseline source
hashes and jj diff sections remain unchanged (except generated `.pi/tasks`
bookkeeping); all six preserved paths pass. No commit/new change, bookmark
movement, publication, raw Git, sudo or shared/editor/configuration change.

Automatic editor reports included stale Dune__exe/Query_delivery CMI assumptions
after the interface-only build, and required POSIX/GNU linker identifiers. The
supervisor explicitly adjudicated that exact CMI report as stale/editor-only
after fresh authoritative builds/runtime evidence (`12`, `18`, `21`, then final
verified builds); strict Clang disproves the identifier reports. No LSP-clean
claim, cache reset, warning suppression or configuration workaround. A real
optional-argument test typing diagnostic was corrected and compiled normally.
Earlier regression failures and failed validation transcripts remain recorded;
only the final `verified-*` set is the full passing gate.

Sanitizers exclude prebuilt DuckDB/runtime/Base, and `detect_leaks=0` is **not**
whole-process leak freedom. Known unsuppressed whole-process LSan failure is not
fixed or relabelled. Existing OOM/asynchronous-exception acquisition/bookkeeping
gaps, arbitrary/repeated signals, unsafe FFI misuse, nonreturning foreign work,
finalizer responsiveness and process/filesystem failure limits remain. This
phase does not prove complete bridge, adapter, installed-consumer or scheduler
readiness, native COMMIT/publication linearization, or static lifetime safety.
**Independent phase review and parent acceptance remain required.**

## Finish-wave control/publication increment (independent phase review pending)

**Ready for independent bounded phase review only, not B2/B4/full bridge
acceptance.** The prior Appender reviewer passed with no findings. Its managed
Markdown artifact was zero bytes; the supervisor recovered the actual structured
review through the same native subagent protocol into
`.local/stage4b/finish-bridge/appender-review-recovered.json`. No alternate provider
or execution mode was used. This phase also persists `handoff.md` under its
ignored evidence root, in addition to its managed report.

Evidence root: **`.local/stage4b/finish-bridge/control-publication/`**. Fresh phase
snapshot `before.diff`, `before-ref.log`, `baseline-hashes.json` and `baseline/`
precede production edits. `checkpoint.md` records the exact supervisor-approved
named controls, exclusive file admission, rooting and deterministic gates.
Follow-up approvals cover shared Resource and Query backtrace preservation,
join-before-owned-temp-unlink, and exact signal inventory corrections. No safe
public signature, package definition, Appender production code, native guard or
controller ownership protocol changed. Old unsafe bool execute/publication ABIs
remain available; safe control/publication paths use named/admitted entries.

### TDD, failures, and corrections

| Evidence at phase root | Exact observation |
| --- | --- |
| `01-interface-mismatch-red`, `02-interface-mismatch-red`, `03-private-interfaces`, `07-interface-implemented` | First command found ambiguous docstring warnings, fixed before intended missing type/value implementation red. New actual FFI `.mli` and source-named positive/missing-declaration consumers compile before bodies. Three missing declarations reject intended control_publication source locations. |
| `04-baseline-tests-build`, `06-{begin-before,commit-before,snapshot-before,publication-before}-red` | Tests linked against original production, then all four actual safe race controls exit 2 at intended forbidden native-call/count assertions. No timeout counted as red. |
| `08`–`11` | Initial implementation and 108-case prior/new suite pass; strict authored C passes. |
| `16-expanded-control` | Test oracle expected one COPY extraction before execute but fresh parameter-schema validation correctly performs a second. Correct exact count to two; no production change. |
| `18`, `20-file-trace-red`, `22-cleanup-trace-control` | Actual unlink failure retained composite but shared complete_cleanup outer runtime boundary erased Parquet.remove source frame. Capture inside existing boundary, preserving exactly one Break retry/failure precedence; source-specific green. Shared cleanup blast radius, not Parquet-only. |
| `24-unlink-order-red` | Actual unlink entry observed controller not joined after cancellation during noninterruptible link. Add existing admit_cleanup to every owned-temp cleanup closure under the private transaction's exclusive cleanup proof; preserve ordinary rollback/unlink controller refinement. |
| `25-final-expansion-build`, `26-final-expansion` | Authored optional-argument test typing error; chained command accidentally ran old no-build executable after failed build. Neither result is new production validation. Make test rollback argument explicit; subsequent commands use build-success chaining. |
| `28-expanded-control` | Injected rollback exception is before real duckdb_query, so expected native rollback count is 0, not 1. Exact test oracle corrected without production change. |
| `30`, `32-snapshot-trace-red`, `34-query-trace-control` | Snapshot native-error plus rollback exception lost Resource.raw_control trace at Query.execute_prepared outer runtime boundary. Approved capture-inside repair keeps normal results/publication and unconditional result cleanup, including exceptions escaping boundary itself. Source-specific green. |
| `35-control-alias`, `37-control-alias` | Dune's copied interface is read-only: disposable compiler script must chmod its existing temporary copy before overwriting it. Corrected authored script; no shared/cache/config workaround. |
| `38-full-regression`, `39`–`42` | Old control-enter signal resource inventories counted now-absent transient SQL copy. Supervisor rejected reintroducing pointless allocation; update only exactly explained enter counts. Preserve exception/commit observer/final counts. Retarget Stage3c publication signal hook to actual admitted entry. Complete focused signal suites pass; final full regression below passes. |
| `45-first-mutation-transcript`, `45-commit-obligation-unused-red` | Initial mutation removed sole use of ref and failed warnings-as-errors before runtime. Correct mutation explicitly ignores ref; this compile failure is not a behavioral red. |
| `63-final-mutation-transcript`, all `45-*-{build,red}`, `46-restored-build`, `47-restored-green` | Eleven independent mutation builds exit 0; every named runtime red exits 2, never timeout. All five production targets restored byte-for-byte, complete 140-case suite green. |

`editor-diagnostics.md` records interface-staging stale CMI diagnostics and
supervisor-adjudicated POSIX/GNU linker/libc errno false positives. Fresh pinned
build/link and strict Clang resolved the exact concerns without configuration
or warning suppression. A transient Callback.register_exception alert was
corrected to Callback.Safe.register_exception. No blanket LSP-clean claim.

The **40 new cases plus preserved 100** use actual safe Bridge operations.
Test-only normal-ABI wrappers root arguments before temporary runtime release;
engine/file/destructor gates run already unlocked. The controller reserve-decision
observer is count-only/noalloc and never waits/releases runtime. Request-worker
TLS excludes independent observers; it is cleared at uninstall. File metadata
is not mistaken for DuckDB interruption. Every gate releases before mandatory
worker join on assertion/exception exits; watchdog means process failure, never
reuse permission. Resource live/fallback counters restore without GC in each case.

Mutation command:

```sh
python3 .local/stage4b/finish-bridge/control-publication/mutations.py
```

Controls independently bypass BEGIN and COMMIT native decisions, suppressed-BEGIN
and known-COMMIT rollback obligation bookkeeping, publication admission, publication
noninterruptible classification, reservation admission, unlink retirement, shared
complete_cleanup trace transport, Query snapshot trace transport, and cleanup
primary-error retention. `mutation-restoration.log` and five `*.mutation-backup`
files prove no deliberately weakened source remains.

### Final exact verification

Reproduce the full final green set with:

```sh
bash .local/stage4b/finish-bridge/control-publication/validate.sh
```

`final-validation-transcript.log` and all final per-command logs record **exit 0**
after the last mutation/source restoration and test-only noalloc observer addition:

- `final-48-all`: `stage1/run build @all`.
- `final-49-focused`: forced control/publication, Appender, Query, whole native
  delivery, native request/lifecycle, Resource lifecycle, B1 and recovery aliases.
- `final-50`–`53`: direct new/private/compiler declaration controls and safe
  privacy/forgery/domain/borrowed/owner controls on the pinned compiler.
- `final-54-strict-clang`: C11 `-Wall -Wextra -Werror -fsyntax-only`, existing
  local headers/compiler includes, all five engine/file authored stubs plus
  current native delivery, Stage3c signal, Appender/lifecycle/recovery/B1 hooks.
- `final-55-regression`: complete `stage1/run runtest --force`, including Stage1–4,
  all actual signal, scope/exception, schema, concurrency and lifetime suites.
- `final-56-repeat-1` through `-5`: five separate
  `timeout 120 stage1/run exec --no-build test/native_delivery/test_native_delivery.exe`,
  each exactly **140** passing cases.
- `final-57-sanitize-*`: actual 140-case native-delivery suite, recovery, B1,
  dedicated Parquet and all Query schema signal/fault tests. Existing
  `stage3a-sanitize` profile and
  `.local/stage4b/resource-lifecycle/build-sanitize`; each uses
  `ASAN_OPTIONS=detect_leaks=0:halt_on_error=1`, `UBSAN_OPTIONS=halt_on_error=1`,
  `timeout 120 stage1/run exec --profile stage3a-sanitize --build-dir ...`.
- `final-58-preserved-six`, `final-59-pins`: all six hashes pass. Tools remain
  OxCaml **5.2.0+ox** / compiler revision
  `2515546fea38e21e8143cc41db663bd56efc8d06`, Dune **3.22.2**, jj **0.45.1**,
  Clang **22.1.8**, x86_64-pc-linux-gnu. DuckDB **v1.5.5** immutable revision
  `d8cdaa33fda8df955cc76ef58a280f68f4cd43fa`; header/library/compiler archive and
  cached upstream source hashes match prior pins. `/home` has 43 GB free.

`preserve.py` generates and refreshes `focused.diff`, `final-state.diff`,
`final-ref.log`, `changed-files.json`, `final-source.sha256` and `preservation.log`.
It verifies all nonallowlisted baseline hashes and jj diff sections (except
`.pi/tasks` bookkeeping), the six protected paths and five mutation target backups.
Artifacts were generated before citation and refreshed after this documentation.
No commit/new change, bookmark movement, publication, raw Git, sudo, dependency
reinstall, cache removal or shared opam/editor/configuration change occurred.

Authored-C sanitizers exclude prebuilt DuckDB/runtime/Base; `detect_leaks=0` is
not whole-process leak freedom. Known unsuppressed whole-process LSan limitations
remain. No latency/bounded join, universal finalizer responsiveness, static lifetime,
invalid-unsafe-use, arbitrary/repeated-signal, OOM/bookkeeping-gap, nonreturning
foreign work, crash or hostile-filesystem guarantee is added.

This is the implemented/source-audited map within the supported synchronous, single-system-thread-worker safe contract. It is not complete B2/B4 acceptance, a static lifetime proof, or scheduler responsiveness evidence. Prior reviewed native lifecycle/raw/Query/Appender mechanisms are retained. Every row distinguishes actual new tests from preserved tests and source audit; not every scalar branch has its own race.

### Admission/settlement map

| Source boundary | Classification / settlement proof | Evidence |
| --- | --- | --- |
| Resource.with_admission, child_operation, facade_access, checkpoint | Owner gate verifies live facade/request identity, transaction identity, owner availability, result ownership and exclusive busy admission. User checkpoint rejects persistent cancellation; cleanup bypasses only latch. Request lease spans entire callback/settlement. | Preserved B1 alias/busy/revocation/parent/child tests; native-delivery old 100 cases; final-49/55. |
| Resource.raw_execute; resource_stubs.ml_duckdb_execute | Existing extraction, prepare and execute individually USER-admitted against native latch, native CLEANUP before destruction, post-return checkpoint. Old unsafe bool ABI retained but safe control callers no longer use it. | Prior raw reset/running/selected/destructor races preserved and rerun five times. |
| Resource.raw_begin / raw_commit; ml_duckdb_execute_control | Named fixed C SQL, individual USER admission through the existing guarded acquire-load vs cancel release-store. Only status 3 clears an unstarted BEGIN obligation. Only known successful COMMIT clears rollback obligation before post-return checkpoint. Native failures remain native errors, not cancelled-by-string. CLEANUP before diagnostics/result destruction; no guard across engine/destructor/runtime transition. | control-begin-before/after; control-commit-before/entry/after; independent row observer; control-begin/commit-result-cleanup hold real result destruction while selected controller resumes and skips. Admission/obligation mutations. |
| Resource.with_transaction revoke_and_drain, rollback, release, discard | Token revocation and foreign busy drain precede cleanup admission/controller join. BEGIN is checked before callback entry; COMMIT additionally follows callback/child drain completion. Ordinary rollback retains same delivery-ineligible controller. Cancellation-driven cleanup joins first; cancellation after ordinary cleanup admission allows only that noninterruptible completion. Failed rollback discards and detaches before disconnect. Request lease is distinct from transaction release. | Preserved rollback-before/after, rollback-drains-foreign actual condition-wait oracle, recovery tests. New six cancellation/native-error/callback-exception × rollback-native-error/rollback-exception composites retain primary identity/source trace and discard. |
| Resource.with_child_snapshot; Query.execute_prepared | Same named native decisions as explicit transactions; COMMIT follows parameter-schema validation and materialization. Success result reservation/publication still follows checkpoint. Snapshot error/exception discard routes through destroy_connection, not an unguarded disconnect. Query's existing outer runtime boundary now captures exception/raw trace inside; both captured and boundary-escaping exceptions still close native result under Exn.protect. | control-snapshot-before/entry/after with INSERT RETURNING and independent observer; four snapshot error/exception × rollback outcomes with selected retirement; Query old-body backtrace mutation; all Query and schema-signal regressions. |
| Query initial/fresh prepare, reset/bind, execution, fetch | Existing prepare/extract/execute/fetch USER calls; scalar bind/reset/temporal create+bind noninterruptible individually latch-admitted. Old chunk destruction is cleanup before new fetch admission. Produced-but-cancelled native result is closed before returning error. | Prior Query deterministic gates rerun; COPY prepare/bind/execute tests exercise real dedicated export, including second schema extraction. Remaining typed branches source-audited/shared native helpers plus round-trip tests. |
| Query parameter_count, parameter/schema/kind arrays, status, Borrowed_chunk columns/cells | Synchronous noninterruptible metadata/scalar batches under admitted operation or borrowed callback scope, with batch pre/post checkpoints and no engine-interrupt arming. Borrowed reads do not become independent scheduler/native calls. Ownership/effect barrier prevents destruction while borrowed callback is active. | Preserved metadata publication/Stop/Continue/empty/exhausted tests and source-named privacy/domain/borrowed compiler negatives; no per-cell latency or static foreign lifetime claim. |
| Appender create/metadata, rows/cells/end-row, explicit/automatic/normal-close flush | Reviewed metadata/subcalls and flush USER; scalar row mutation/noninterruptible create consult latch, copied cell/value storage retained. Normal close flush separated from cleanup; cancelled cleanup clear-before-destroy never flushes buffered rows. First failure poison persists even if dropped/caught. | Appender prior 45 cases preserved byte-for-byte, including real running flush/reset, automatic flush and sequence durable-effect negative/positive, selected cleanup and original callback trace. Rerun in final 140-case suite. |
| Parquet.fold_rows per-next-file; export source schema / COPY | Next-file loop and Query admissions reject cancellation; empty/Stop/callback paths retain Query checks. Source schema validates before temp reservation. COPY uses existing separately admitted prepare, bind, fresh schema validation and execute, then result/prepared scoped close. No lexical SQL classifier/remote expansion. | control-next-file uses real first Parquet file and unavailable next file; control-copy-prepare/bind/execute assert no next extraction/mutation/execute/publication and owned temp cleanup. Existing dedicated Parquet full fidelity/path/failure regressions and sanitizer. |
| Parquet temp reservation; F.admit_local_file | Existing with_admission(c, Some private tx) remains held across native NONINTERRUPTIBLE latch decision AND immediate Filename.temp_file operation/return. Native work is balanced before ML return. Success admits exactly that one in-flight reservation, not a reusable detached ticket. Temp is bound into cleanup scope before next checkpoint; cancellation losing decision may create that temp but cannot reach COPY. | control-temp-before/admitted/reserved gate before native decision, after actual decision, and after real caml_sys_open. Exact decision/open/COPY/unlink counts; independent reservation-admission mutation. Busy owner alias is exclusion evidence, not a separate proof of the private busy flag; actual combinator span is source-audited. |
| Parquet.publish; F.publish_local_file_admitted / local_file_stubs | with_admission retains live private tx/exclusive operation through copied rooted native work, NONINTERRUPTIBLE latch decision and actual no-replace link. Status -1 is suppressed, 0 success, positive errno retains filesystem primary diagnostic. Guard released before link, native work ends before error processing/runtime return. Post-success checkpoint classifies cancellation. Link remains inside transaction callback BEFORE COMMIT. | control-publication-before/entry/after/precommit: actual link counter and independent file reader; final file survives cancellation and rollback. Count-only noalloc reserve-decision observer proves controller actually polled while file held and found no eligible delivery. Missing-decision and wrongly-USER mutations independently fail. |
| Parquet.remove; remove_local_file / finish_local_file_work | Owned-temp-only unlink, never final destination. Cleanup calls admit_cleanup before remove on every owned-temp outcome. Export's tx is never exposed, internal Query scopes have drained, publication admission returned, and outer request/tx leases still exclude aliases. No locks held while joining/unlinking. Ordinary cleanup admitted first may finish noninterruptibly after cancellation. ENOENT retry semantics unchanged. File finish frees copied storage and drops recorded parent shell ref; safe rooted connection slot prevents last-ref engine destruction on ordinary publication finish. | Actual-unlink-entry captures completed controller join, not unrelated selection. Missing-admit_cleanup mutation fails; ordinary-unlink-after-cancel test retains one controller/ineligible until terminal settlement. Destination_exists/cancel/unlink and combined rollback result/exception cases retain bytes, primary/secondary diagnostics and source trace. |
| Config/Scalar/Row construction; Parquet.path | Pure validation/owned value construction except path's synchronous getcwd. These have no request/connection parameter, hence are not independently cancellable request operations. Export receives an already resolved path. Arbitrary user callback work is not forcibly stopped by Bridge.cancel. Adapters must route filesystem path construction appropriately; no scheduler API added here. | Existing validation/path tests and source audit, not request admission or scheduler evidence. |

### Every remaining close/force-close/fallback route

- **Manual connection/database close** (`resource.ml:close_connection`, `close_database`): Busy/Live_children remain distinct; live facade close never disconnects owner. No native destruction with a request lease. Ordinary explicit native close releases runtime; finish follows only after completed exclusive close. Preserved B1/Resource lifecycle tests exercise rejection and settlement/reuse.
- **Scoped connection and database force close** (`force_close_connection`, `force_close_database`): mark Closing, database revokes all children before waiting for any one, drain busy/transaction/request leases using Condition.wait outside native/request locks; no request lease stolen. `destroy_connection` joins current controller, destroys registered children, detaches/disposes native request, then native close. Preserved parent-close and selected-terminal races rerun.
- **Transaction discard and private snapshot discard**: failed/exceptional rollback invokes the same destroy_connection route; selected controller joined, foreign call finished, native request detached before engine close. New explicit/snapshot composite tests require Closed and observer rollback; old produced-result snapshot discard retained. Successful ordinary rollback does not discard/restart the controller; Delivered always makes final settlement discard-only.
- **Manual/scoped/forced child close**: `child_operation ~cleanup:true`, `force_close_child`, and `destroy_children` preserve live identity/exclusive drain versus scoped revocation distinctions. Revoked tx's waiting child scope leaves cleanup to settlement; admitted foreign child drains before controller stop. Registered cleanup closures root result/prepared/appender slots. Query native_close/native_close_result and Appender.destroy call admit_cleanup after foreign return; manual cancelled and scoped selected cleanup races remain enabled. Destruction is idempotent after slots are cleared.
- **Native connection/database close/unref/finalizers** (`resource_stubs.c:179–235,252–291,498–520`): every connection_clear goes through native_close_begin; foreign activity, cleanup depth or installed request prohibit disconnect. Permanent CLOSING is published under short guard, guard dropped before destruction. database parent ref and request/child shell refs address dead-slot order, not standalone live-engine permission. Safe worker/controller and registered child roots keep active native slots reachable. Final request uninstall checks identity/activity/reservation; parent unref happens after unlocking. Fallback tries once/fails closed; no finalizer spin/join/free-on-contention. Native lifecycle's explicit idle/whole-tree/child-last/finalizer mechanism tests remain rerun, not relabelled as new safe-delivery positives.
- **Prepared/result/chunk fallback** (`prepared_stubs.c:19–40,123–137`): all clear paths publish nested CLEANUP before chunk/result/statement/extracted destruction; ordinary close is unlocked, finish/delete/finalizer held-runtime backstop. Live/fresh schema slots are rooted by callbacks/scopes/CAML roots and owner cleanup registration. Parent unref after guard release. Ordinary cancellation has already performed unlocked destruction before finish; source proof and prior cleanup tests, with final ASan/UBSan evidence.
- **Appender fallback** (`appender_stubs.c:76–107,298–305`): normal flush is user work before clear/destroy. Held-runtime delete_owner passes flush=false and clears before destroy; no destructor flush of discarded buffered data. Copied input frees are storage-only. Appender phase's selected cleanup/clear-before-destroy/source audit remains authoritative and rerun, with no production Appender edits here.
- **File fallback** (`local_file_stubs.c:15–25,48–74`): work retains copied paths and optional parent ref before raising runtime transition. Work slot is CAML/scoped rooted while active; connection is rooted by exclusive admission/request. Finish only frees storage/ref, never unlinks final or temp; owned temp removal is explicit ML cleanup. Unusual orphaned work finalization may drop the final shell ref and invoke guarded held-runtime engine deletion only in an already-dead, quiescent tree. This is not universal finalizer responsiveness.

No new root cycle, movable ML access while unlocked, guard-held allocation/destruction/wait/runtime transition, controller restart or scheduler dependency was introduced. Zero binding/fallback counters on ordinary cases are not whole-engine allocation accounting. Complete_cleanup's capture-inside-runtime change has shared Resource cleanup blast radius; the one-Break retry and retry-failure precedence are unchanged. Query.execute_prepared's separate transport repair keeps unconditional result cleanup and Exn.protect composites.

### Signal inventory and commit exception limitation

Named fixed control SQL omits exactly the legacy transient SQL copy. At a plain control enter, database shell+engine and connection shell+engine = 4, previously 5 with SQL copy; control return remains 4. Snapshot BEGIN/ROLLBACK enter have the same four plus observer shell+engine and prepared shell+engine = 8, previously 9; returns remain 8. Snapshot COMMIT enter adds the produced result = 9, previously 10; return remains 9. Stage3c COMMIT is likewise 4 instead of 5 at entry, unchanged 4 at return. All other exact counts, one signal, final zero resources/fallback, visibility, discard/reuse and exception composite assertions remain unchanged. Raw query-enter still owns/covers copied-SQL cleanup (5). Publication's new parent shell ref is not a separately acquired binding resource; file work plus two copied strings remain three (total 7), unchanged. Stage3c publication signal hook targets the actual new admitted entry, not old unsafe ABI.

`control-commit-return-exception` injects an exception after actual native COMMIT returns success but before Resource bookkeeping, through normal test linkage. It is a mechanism test for that uncertainty window, not itself a POSIX runtime-transition signal. Real existing commit-leave and snapshot-commit-leave single-Break tests also pass: uncertain completion retains Rollback_exception(Break, native rollback error), discards, and independent observer sees committed effects. Normal-return obligation repair does not close arbitrary asynchronous-exception/OOM acquisition/bookkeeping gaps. No promise rollback undoes committed or linked effects.

### Open B4 evidence

Installed consumer isolation/metadata/privacy/modes, real Async/Eio native-cleanup heartbeats (including files/control/destructors) and occupied-worker independent progress, complete Stage4a-to-safe-Bridge acceptance repetition matrix, and independent full bridge/specification acceptance remain mandatory B4 work. Production boundary coverage is implemented/source-audited here within the stated contract and is ready for independent phase review, not full bridge acceptance. No adapter/package, remote work or publication is authorized by these results.

## B4 acceptance evidence — writer complete, whole-bridge review pending

Evidence root: `.local/stage4b/finish-bridge/acceptance/`. This phase adds only
test executables/support, an isolated installed smoke and templates, Dune test
registration and documentation. The sole production-file change is an approved
comment correction in `lib/duckdb/duckdb.mli`; every declaration and all production
implementation bodies remain unchanged. The public comment no longer incorrectly
claims ML-only cooperative B1 cancellation and explicitly retains pending
whole-bridge acceptance and supported-contract limitations.

### Interface-first and exact failures

- `09-missing-test-implementation-red.log`: authored alias stanza typo, **not**
  intended red. Corrected to Dune's alias stanza.
- `10-missing-test-implementation-red.log`: expected missing implementations for
  the new explicit test interfaces. `11-interfaces.log` caught one ambiguous
  docstring; `12-interfaces.log` compiles all actual test `.mli` files against
  the real public Duckdb signature. Additive counter/suppression interfaces
  compile in `20-counter-interface.log` and `24-suppression-interface.log`.
- `21-missing-counter-link-red.log`: both executables fail at the exact missing
  native test-counter symbol before its body is added.
- `14-scheduler-build.log`: the pinned Async Ivar API has no `peek_exn`; use
  `Option.value_exn (Ivar.peek ...)`. `15` links both executables.
- `16-async.log`: enclosing database close happens after the request settles;
  the original test incorrectly required Pending there. Corrected only that
  oracle to require terminal Closed for late cancellation; it still holds the
  actual database destructor and requires joined controller. `18`, `19` pass.
- `23`/`26`: expanded real-native heartbeats, two **distinct** connection delivery
  observations under the occupied two-slot quota, actual dispatched suppression,
  and exception routing pass. The extra quota-queued request must do zero native
  SQL; both occupied queries must return actual interrupted native errors.
- `29-mutation-transcript.log`, five `30-*-build.log` and ten scheduler-specific
  `30-*-red.log`: independent result, prepared, appender, connection and database
  mutations each omit only ordinary unlocked destruction, leaving real work for
  the existing held-runtime finish backstop. Every mutation builds successfully
  and both schedulers fail **"ordinary cleanup no locked engine calls"**, exits
  Async 1 / Eio 2. No watchdog/timeout/compile failure is counted as a red.
  The native observer records a locked fallback and does not hold its test gate
  in that broken case; it never artificially unlocks a held runtime.
  Three production files match the byte-for-byte `*.mutation-backup` copies;
  `mutation-restoration.log` and `31-restored-responsiveness.log` record restoration
  and full restored green. No production fix was needed.

### Installed package isolation and corrected invocation

`test/install_adapter_bridge_smoke.sh` leaves disposable evidence trees under
`.local/stage4b/installed/`, never installing into a shared switch or replacing a
dependency. The preserved `test/install_smoke.sh` is unchanged. Current producer
sources are copied and hashed against originals, FFI is built/installed first,
then `-p duckdb` builds safe core only against that installed FFI. Producer source
and both build trees are renamed before an external consumer is built. The
actual compiler include arguments exclude producer/source `_build` and private
CMIs. Installed `Duckdb__Resource`, request/pointer forgery, real-connection
Domain.Safe.spawn and borrowed chunk return all reject at intended source values
with exact diagnostic assertions. An owned Bridge transaction/fold runs twice.
Core META remains exactly **base duckdb-ffi threads**, FFI META empty; the consumer
observes one process task before and after Fresh creation (no scheduler/controller
startup). Loader uses pinned `.deps/duckdb/libduckdb.so`, no host rpath.

The pinned Dune's nested relative build path failed (`01`); parent-approved
absolute source-contained build reached known `Obj_dir.External.encode` private
Dirs installation failure (`02`). Parent approved the existing packaging fixture
source-copy layout, retaining the same pinned protocol. `-p` plus explicit
`--root` rejected duplicate root (`03`, `04`); run the pinned Dune from the copied
producer cwd with a single-component relative build dir and `-p`. An overly broad
source-root grep then matched the **authorized prefix**, also under .local (`06`);
exclude only that exact installed prefix in the metadata audit. `08` and `43`
pass all checks. Failed help invocations (`05`, `07`) are invocation diagnostics,
not green evidence. No dependency, editor/configuration, backend or toolchain
change occurred. `checkpoint.md` retains all live supervisor decisions.

### New native/scheduler evidence and ownership limits

Each separate executable has a test-only database quota of two guarding **every**
database offload (`Async.Throttle`, `Eio.Semaphore`); no core scheduler abstraction
or adapter package is introduced. Two actual safe Bridge/native execute calls
occupy both slots with a third database job queued. Cancellation calls the real
Bridge directly; distinct native delivery identities are observed before either
native gate is released, then both return interrupted diagnostics and join their
controllers. This is database-slot saturation, **not all Async global threads**;
no Async pool configuration is changed. Eio's default backend is unchanged.

Both schedulers acknowledge a heartbeat while actual native execute, ROLLBACK,
result/prepared/extracted/chunk destruction, appender clear/destroy, disconnect,
database close, link and unlink are held. Gates never perform a runtime release.
A separate TLS runtime-transition observer and finish-call depth count actual
nested engine destructors, including parent-shell last-unref paths and
config/value/type/error-data destruction. Ordinary cancellation gives zero locked
engine calls, four/eight observed finish calls per normal native scenario, zero
remaining binding resources and unchanged fallback counter without GC. This is
not whole-engine allocation accounting or universal finalizer responsiveness.

Actual Bridge callback failures retain a named `callback_failure_frame` raw
backtrace through rollback and scheduler transport. An abandoned/failed Async
caller cannot abandon the independent captured worker producer: owned completion
is filled exactly once before monitor delivery, including Exn.Finally primary +
rollback cleanup exception. Eio's waiter observes cancellation while actual
ordinary-admitted rollback is held, acknowledges/latches Bridge cancellation,
protects the independent producer completion against repeated cancellation, then
rethrows the same cancellation instance/reason with original worker/cleanup
outcome and source trace. No Async/Eio callback enters a core/borrowed scope.
Synchronous dispatch exceptions are captured outside each runtime submission as
well as worker exceptions inside it, so submission failure cannot leave only an
unfillable completion. Earlier raw Async-pending/Eio-raw-return routing controls
remain separately rerun in Stage4.

### Exact final command matrix and pins

`validate.sh` logs every expanded command/exit. `39-final-validation-transcript.log`
and `40`–`51` pass on restored executable code; the `final-*` rerun records the
comment/counter refinements. The final `complete-*` set, in
`64-complete-validation-transcript.log`, additionally includes the actual delayed
A cancellation while same-owner B is held natively: **17 cases per scheduler**.
All 52 final command logs pass, including 35 repetition logs and seven sanitizer
logs. `63-verified-mutations.log` reruns all five independent mutants against the
final tests; ten named runtime reds and restored `verified-31` green pass.
The same-owner reuse helper's interface compiles in `58`, implementation mismatch
is the intended `59` red, and `61`/`62` build/run both actual races green.
Earlier selected-terminal tests alone did not send delayed cancellation while B
was active; the new gate makes that causal distinction explicit. Commands are:

```sh
stage1/run build @all
stage1/run runtest --force
stage1/run runtest stage4 --force
bash -x test/install_adapter_bridge_smoke.sh
stage1/run build @test/adapter-bridge-responsiveness --force
# Four private-interface scripts and four safe/privacy/borrow/owner scripts
# enumerated exactly by validate.sh, each with $PWD/_opam/bin/ocamlc.
clang -std=c11 -Wall -Wextra -Werror -fsyntax-only \
  -Ilib/ffi -I.deps/duckdb -I_opam/lib/ocaml \
  $(find lib test stage4 stage1 stage2 -name '*.c' | sort)
# Each of native140, B1, Async17, Eio17, recovery, Resource lifecycle and unsafe
# Stage4a interrupt executable, five separately logged repetitions:
timeout 120 stage1/run exec --no-build test/native_delivery/test_native_delivery.exe
# Seven targets: B1, both new schedulers, native140, recovery, lifecycle, Parquet:
ASAN_OPTIONS=detect_leaks=0:halt_on_error=1 UBSAN_OPTIONS=halt_on_error=1 \
  timeout 120 stage1/run exec --profile stage3a-sanitize \
  --build-dir "$PWD/.local/stage4b/resource-lifecycle/build-sanitize" \
  test/test_adapter_bridge_async.exe
sha256sum --check .local/stage4b/preserved-six.sha256
```

Current pins: OxCaml `5.2.0+ox`, compiler source
`2515546fea38e21e8143cc41db663bd56efc8d06`, Dune `3.22.2`, jj `0.45.1`,
Clang `22.1.8`, DuckDB `v1.5.5` source
`d8cdaa33fda8df955cc76ef58a280f68f4cd43fa`. Fresh hashes in `51-pins.log`:
header `48e716b9ce96ca8fead9cb35693fdc0343ac0fc1f6e7db5561fa0f44b674153d`,
shared library `fc23f12e376c47be520f75221288281906e7942e8fd6f6ce4849198ba60d0405`,
compiler archive `93dbcf859e655d2a2b41dfa077c126fa5a15fd0205b1c57dbb5ff2cc9d595462`.
All source revision/hash limits and prebuilt runtime/Base/DuckDB sanitizer
exclusions remain. Known unsuppressed whole-process LSan does not pass; no new
leak suppression or whole-process leak-free claim is made.

Strict Clang/full links are authoritative. pi-lens required POSIX/GNU identifier
flags and source-disproved stale-CMI `R.interrupted_connections`, `R.executions`,
`R.suppressed_work` reports were explicitly adjudicated by parent; exact symbols
exist and current pinned affected builds pass. Real unused includes and Ivar API
mistake were fixed. `editor-diagnostics.md` records exact checks; no blanket LSP
cleanliness or alternative execution claim.

### Whole-bridge source-to-boundary and B4 gate matrix

**Writer evidence, not parent acceptance.** Source classifications below retain the independently reviewed implementation in `../control-publication/boundary-audit.md`; this phase changes no production executable code. Current source hashes/preservation and public declaration equality are separately verified. Each native boundary is either individually latch-admitted USER, explicitly noninterruptible cleanup/scalar/file work, or pure owned construction; none is inferred from an outer callback flag.

Evidence paths here are relative to `.local/stage4b/finish-bridge/acceptance/`. `48-repeat-{1..5}-test-native_delivery-test_native_delivery.log` each reruns all **140 actual safe-Bridge cases**, not Stage4a's unsafe simulation. `48-repeat-{1..5}-test-test_adapter_bridge.log` reruns B1; scheduler logs each contain 17 scenarios in the latest `complete-*` set. Numeric runtime IDs 40–51 below refer to that latest prefix; mutation IDs 30/31 additionally have final `verified-*` reruns. `41-forced-stage1-4.log` contains complete forced regressions (compiler-negative errors are expected assertions). Sanitizers are `49-sanitize-*.log`. Prior eleven control/publication mutations remain at `../control-publication/45-*-red.log`, Appender mutations at `../appender/`; no prior source/test body is altered here.

| Required source row | Admission/lifetime classification | Current evidence |
| --- | --- | --- |
| Resource.execute/execute_transaction/with_admission/child_operation | Owner/request/facade/transaction identity + exclusive availability + latch under admission; cleanup differs from user work. | B1 repeated alias/concurrent/nested/child exclusions; 140-case native logs. Original owner Busy, revoked aliases Closed, live prepared/result/appender exclusion. |
| Resource.raw_execute / resource_stubs.ml_duckdb_execute | Extraction, prepare, execute each USER-admitted against persistent native latch; CLEANUP before raw result/prepared/extracted destruction; post-return checkpoint. F.clear_work fallback has nothing left on ordinary return/cancel. | `running-reset`, `recovered-interruption`, `transaction-interrupted`, `after-extract`, `after-prepare`, selected/raw-destructor cases in native logs; scheduler execute/result/prepared/extracted heartbeats + real interrupted errors and finish-depth zero locked engine work; unsafe one-shot/reset negative separately in repeated stage4-test_interrupt_evidence logs. |
| Resource.with_transaction/revoke_and_drain/rollback/discard/release | Request lease spans BEGIN/work/child drain/COMMIT or rollback. BEGIN/COMMIT own native USER decision. Failed/exceptional rollback discards. Ordinary rollback retains same delivery-ineligible controller; cancellation-driven rollback joins after actual foreign drain, before terminal cleanup. No controller restart. | Native rollback-before/after/drains-foreign condition-wait oracle, control BEGIN/COMMIT cases, recovery repetitions. Both scheduler rollback native heartbeats after interrupted native return observe joined controller; actual abandoned/protected exception rollback races instead assert ordinary admitted rollback retains controller until terminal settlement. |
| Resource.with_child_snapshot | Same native BEGIN/COMMIT decisions and rollback obligations as explicit transactions; failure uses common destroy_connection, not bare disconnect. Query result reservation follows latch check. | control-snapshot-before/entry/after/exception composites, snapshot rollback races, B1 snapshot/native-root tests; repeated native/recovery suites and sanitizers. |
| Query.prepare_on/validate_parameter_schema/reset/bind/execute_prepared | Initial/fresh extraction/prepare/execute USER; bind/reset/temporal scalar subcalls noninterruptible but individually latch-admitted. Result publication is checked separately, cleanup closes produced-cancelled results. | All prior Query gates in 140-case logs, COPY prepare/bind/execute gates, private compiled controls 45; forced typed roundtrips/schema/signal tests 41. Remaining scalar variants use audited common helpers, not independently timed per-cell races. |
| Query.fold_internal/fold_rows/prepared/result close; prepared_stubs prepare/fetch/clear | Chunk fetch USER; old-chunk destruction CLEANUP before fetch rearm. Callback batch/Stop/empty/exhaustion checkpoints; no per-cell scheduling. Explicit result/prepared close releases runtime; held finish is backstop only. | Query metadata/fetch/Stop/Continue/empty/exhausted/selected close cases; borrowed/effect negatives 46 and installed 43. Scheduler Chunk uses actual safe prepared result and cancels inside borrowed fold; actual chunk/result/prepared cleanup restores counters. Independent result-finish and prepared-finish mutations each fail both schedulers at named locked-engine assertion (30-*), restore green 31. |
| Appender.open/operation/append_rows/flush/normal-close/destroy/scoped close | Metadata USER subcalls; create/scalar mutation noninterruptible latch admission; per-row/end-row/auto-flush classification retained. Normal close flush is user work; cancellation cleanup clears before destroy, never flushes discarded buffered rows. | All 45 prior Appender cases in 140-case repetitions (including real end-row/flush reset/running, ignored/caught errors and durable sequence). Scheduler appender-clear/appender-destroy hold actual cancelled child's native cleanup after controller join. Appender-finish mutation red in both schedulers. |
| appender_stubs metadata/append loop/close_native/delete_owner | Copied cell/input storage stays native-owned. Metadata result/chunk/prepared/error/type cleanup occurs with phase visibility; native clear/destroy is noninterruptible. finish_appender_close can destroy in exceptional fallback, but ordinary cancellation has already cleared/destroyed unlocked. | Prior Appender selected metadata/clear/destroy/error/type gates, strict C and sanitizer. New scheduler finish-depth/runtime observer wraps actual destructors including error/type/value cleanup; no remaining held engine work in measured ordinary paths. |
| Parquet.fold_rows/export/publish/remove | Check per-next-file, temp reservation, COPY prepare/bind/execute and actual publication decision. Link remains inside transaction callback BEFORE COMMIT; only owned temp cleanup, never final output removal by cancellation. | control-next-file/temp-before/admitted/reserved/COPY/publication-before/entry/after/precommit, Destination_exists/unlink/composites, independent row/file observers in native logs; dedicated Parquet regression/sanitizer. New scheduler actual link and owned-temp unlink heartbeats. |
| local_file_stubs publish/remove/finish | Filesystem calls NONINTERRUPTIBLE, no DuckDB interrupt arming. Copied paths/native parent ref rooted through admitted work. Latch winning decision suppresses entry; losing decision can leave durable final file. finish frees storage/ref, not filesystem effects. | Prior reserve-decision observer proves controller actually polled and delivery ineligible at link; file-admission/noninterruptible/retirement mutations. Both scheduler file gates show native heartbeat, zero interrupts, eventual controller join, no locked finish/last-unref engine work. |
| Resource.close_connection/force_close/destroy_connection/database close/force_close_child/destroy_children | Manual Busy/Live_children vs scoped revoke/drain remain distinct. Database revoke-all-before-wait; foreign drain, selected retirement/controller join, child cleanup and native detach precede owner disconnect. Scope/rollback discard not exempt. | B1 parent-close, native selected-terminal, query/appender manual/scoped/selected, snapshot discard; repeated resource-lifecycle mechanism tests separately labeled USER-disabled. New scheduler actual disconnect and enclosing database-close heartbeats after native interruption. Database close can be after request Settled, so late cancel is Closed rather than a fabricated Pending guarantee. |
| Native connection/database/prepared/appender clear/delete/unref/finalizers; query_native.h | Shell refs do not alone preserve live engine. Stable request storage/roots + short native guard protect engine lifetime. No guard across allocation/destruction/wait/runtime transition; controller try-delivery is one guard attempt and rechecks eligibility after pause. Finalizers fail closed on unsupported contention, never spin/join/free-on-contention. | Source audit cited above, preserved native root/idle/whole-tree/child-last/finalizer mechanism tests, selected real-safe races and strict C/sanitizers. New finish-depth wrappers cover raw clear_work and every finish ABI, actual nested destructors/last-parent unrefs; connection/database finish mutations fail in both schedulers. No universal finalizer responsiveness or static foreign-lifetime claim. |
| Scalar/Row/Config construction, Query cached scalar/metadata and Borrowed_chunk reads, Parquet.path | Pure owned construction or synchronous noninterruptible metadata/scalar batches. Parquet.path may call getcwd without request parameter. These are not interruptible user SQL or independently cancellable per-cell operations. | Source classification/common helper audit + complete scalar/schema/path/borrowed/effect tests and compiler controls. No per-cell latency/performance guarantee; scheduler path construction remains offloaded in test worker. |

### Every mandatory B4 checklist item

| Gate | Evidence/status |
| --- | --- |
| Stage4a races via actual safe Bridge, five repetitions, reset-surviving delivery and separate unsafe one-shot negative | Seven executables × five runs in complete-48 logs: native140, B1, Async17, Eio17, recovery, resource lifecycle and Stage4a unsafe mechanism. Same-owner A completes, B reaches actual native execution, then repeated delayed A.cancel returns Closed while B remains Pending and subsequently succeeds with zero interruption. Actual dispatched workers latch before Bridge.run, zero SQL/controller joins. Quota-queued third job cannot offload until a slot frees. Saturation observes two distinct live engine connection identities interrupted before releasing native gates, then two real interrupted errors and two joins; extra cancelled job executes no SQL. Never relabel global Async pool saturation. |
| Alias/request/transaction/child revocation, admissions, close-versus-delivery | B1/native140/resource lifecycle repeated, exact guarded mechanisms/source audit unchanged. |
| Persistent latch after success/dropped/caught cancellation/native errors; suppress later call/COMMIT/publication if cancellation wins | Native140 Query/Appender/control cases + B1 + independent durable observer facts; no error-by-string control logic in safe code (diagnostic substring only test assertion). |
| Delivery quiescence before internal destruction; retirement/join before terminal cleanup/rollback/discard/release/disconnect | Preserved selected/internal-destruction/post-pause/drain/reuse races; new held-native-seam heartbeats distinguish live ineligible controller during internal/ordinary-admitted rollback versus joined controller for cancellation-driven terminal work. |
| Rollback/cleanup result/exception failures retain primary/composite/backtrace and discard; durable commit/link races | Native140 includes all explicit and private snapshot composite combinations, commit/publication observers, actual error/exception source traces. New actual Bridge abandoned Async producer resolves once before monitor delivery after rollback; Eio repeated waiter cancellation protects independent producer completion and rethrows original cancellation plus original worker/cleanup composite with named callback source trace. |
| Installed isolation/private Resource/forgery/domain/borrowed rejection; scheduler-free core graph/startup | 43-installed.log expands exact independent FFI→safe build/install and external consumer commands. Copied source hashes match current originals; entire producer hidden; compiler -I paths audited to prefix+pinned deps, never source _build/.private. Public owned Bridge+transaction/fold runs twice. Five intended source negatives. META exactly base duckdb-ffi threads; one task before/after Fresh creation proves no module scheduler startup; pinned DuckDB loader and no host rpath. |
| Ordinary cancellation avoids potentially blocking held-runtime fallback; actual native heartbeats and independent control | Each scheduler 12 actual native seams + dispatched/saturation/same-owner stale cancellation + two exceptional-settlement cases. No gate artificially unlocks runtime. Runtime-release observer plus finish-depth and actual destructor wrappers give zero held engine calls; 4 or 8 finish calls per native scenario, live/fallback inventory baseline without GC. Five independent production mutants move work into finish backstop and each fails named assertion in both schedulers, exit 1/2, no watchdog/timeout; three production files restored byte-for-byte. |
| Full build/forced Stage1–4; compiler controls; strict authored C; authored-C ASan/UBSan | 40–47 all pass; 47 enumerates every authored C translation unit in lib/test/stage1/stage2/stage4. Seven 49 sanitizer targets pass including both scheduler binaries. Prebuilt runtime/Base/DuckDB excluded; detect_leaks=0, known unsuppressed whole-process LSan limitation not rerun/fixed/claimed success. |
| Independent full bridge specification/implementation review and parent verification | **Pending by workflow, not claimed by writer.** All executable writer gates pass; ready for full-source/full-matrix independent review only. No full bridge accepted flag, Stage4c/adapter package or publication authorization. |

### Limits retained

No static foreign-lifetime, linear destruction, zero-allocation, global-pool saturation, bounded join, universal finalizer responsiveness or whole-process leak-free claim. Ordinary unsupported unsafe concurrent FFI use, OOM, arbitrary/repeated signals, asynchronous-exception acquisition/bookkeeping gaps, foreign callbacks/engine/filesystem work that never returns, crash/process/hostile-filesystem limits remain. A watchdog/timeout is failure, never resource reuse permission. Cancellation racing already-admitted commit or link can leave durable writes/output; link still precedes COMMIT and cancellation never unlinks the final destination as rollback. Existing signal backstops remain necessary and potentially held-runtime. Test fixtures may remove their own final output only after binding completion for fixture hygiene, not as production cancellation semantics.

### Final artifact preservation and review handoff

`focused.diff` compares this phase with `da780c80`; `full-wave.diff` compares the
finish wave with `aa76d86c`; `final-state.diff` preserves the whole unpublished
bridge diff over `3db90c1d`, with generated `.pi/tasks` sections excluded. These
artifacts exist and are refreshed after this final documentation append.
`preservation.log` verifies every nonallowlisted baseline source/hash and diff
section, all six protected paths, the complete old test Dune prefix and historical
validation body, unchanged public declarations (comments stripped), and all three
production mutation targets against their backups. `final-source.sha256` covers
all tracked files except generated task bookkeeping; `changed-files.json` lists
exactly the bounded phase edits. `evidence-index.json` records the 52 complete
command logs, 35 five-repetition logs, seven sanitizer runs and expected case
counts. An initial index glob accidentally included `final-ref.log` (which is not
a command log); the corrected checker targets numeric command names and validates
the latest `complete-*`/`verified-*` sets. No failed command was overwritten or
relabeled a pass.

Durable writer report: `.local/stage4b/finish-bridge/acceptance/handoff.md`, also
returned through the managed structured-output contract. **Ready for independent
whole-bridge review only. Parent acceptance and subsequent Stage4c planning remain
separate gates.** No adapter package or remote publication is authorized by this
writer result.

## Whole-bridge review and parent acceptance (2026-09-13)

**Stage4b B1–B4 accepted, unpublished, within the supported contract and the
limits above.** All mandatory B4 checklist rows are satisfied. This supersedes
the historical pending-acceptance statements; it does not implement adapters or
authorize remote publication.

Independent reviewer `a59288d0-bdf2-4a89-95a8-8c92afe6fa62` returned **pass, no
findings** after inspecting the entire bridge: public/private signatures,
Resource/controller/root/guard protocol, all production C units, Query/Appender/
control/Parquet, every close/finalizer route, installed isolation and all B4
evidence. The reviewer did not edit or rerun tests. Native structured output is
preserved as `.local/stage4b/finish-bridge/acceptance-review-recovered.json`;
the managed Markdown artifact was empty, as in the earlier phases. Recovery
used native subagent status, not an alternate agent execution mode. Workflow:
`b92c50c2-3b10-416f-a7d2-4ab1ed4ec716` (six successful children).

Parent verification, from the project root:

```sh
VALIDATION_PREFIX=parent- bash .local/stage4b/finish-bridge/acceptance/validate.sh
```

This command exits **0**. `acceptance/parent-validation-transcript.log` retains
the full output. `parent-evidence-index.json` independently checks all **52**
`parent-[0-9]*.log` command exits and exact repeated case counts:

- Full `@all`, forced regression and separate forced Stage4 tests.
- Fresh independent FFI→safe installed smoke, public runtime and five intended
  privacy/forgery/domain/borrowed compiler negatives; source/prefix/loader/META
  isolation. Parent fixture: `.local/stage4b/installed/bridge.0l3IpR/`.
- Async and Eio responsiveness plus all private/safe compiler controls and strict
  warnings-as-errors on every authored C translation unit.
- **35 repetition runs**: five each of native140, B1, Async17, Eio17, recovery,
  Resource lifecycle and separately labeled unsafe reset-loss evidence.
- **Seven authored-C ASan/UBSan targets**, preserved-six hashes and pinned-tool/
  DuckDB hashes. Sanitizer/LSan limitations above remain unchanged.

The initial worker-manifest check exited **1**, solely for
`test/install_adapter_bridge_smoke.sh`. Comparison against reviewed snapshot
`1eceed4b` showed formatting only (semicolon/newline and case-arm layout), with
identical commands and assertions. `parent-pre-source-check.log` and
`parent-smoke-diff.log` preserve that failure and exact comparison. The parent
reran the complete gate on the current formatted source; the original manifest
was not overwritten or relabeled a pass. After verification, parent edits only
updated acceptance documentation/checklist and the public interface's status
comment; no declaration or executable production code changed.

`parent-final-source.sha256`, `parent-final-checks.log` and `parent-final.diff`
record the final source and post-documentation build/preservation checks. Primary
LSP diagnostics were clean on the six checked Resource/Query/Appender/Parquet/
scheduler-test modules before the full build. Earlier explicitly adjudicated
stale-CMI and POSIX/GNU protocol diagnostics remain historical evidence, not a
blanket suppression. Mutation reds/restoration were independently reviewed worker
evidence; the parent reran the entire final validation, not the mutation edits.

Next work is a separate Stage4c adapter plan; no adapter package was started by
this finish wave. No raw Git, commit/new change, bookmark movement, publication,
sudo, dependency reinstall, shared configuration edit or cache deletion occurred.
