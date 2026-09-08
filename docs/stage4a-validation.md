# Stage4a: scheduler and interruption prerequisite evidence

Validated 2026-09-08 against accepted plan `1333a3de` and Stage3c `8bb77a2f`,
using the existing project-local toolchain and native library. **Runnable
prerequisite evidence passes; independent specification and quality review pass.
The public bridge signature gate remains closed.** No adapter, pool, installed package or production
change is included. Stage4b–f and Stage5 are not implemented here.

Authored paths are `stage4/`, this document, and a Stage4a-only clarification and
evidence link in the canonical plan. `lib/`, package opam files and `dune-project`
have an empty diff. The implementation worker made no commit, bookmark movement,
staging or publication.
Ignored sources, scripts and raw logs: `.local/stage4a/`; focused review diff:
`.local/stage4a-review.diff` (explicit authored path selection, from `1333a3de`).

## A1: scheduler and mode evidence

`evidence_support.mli` and the three executable `.mli` files preceded their
implementations. The exact requested two-target build failed with missing
implementations (`interface-red.txt`, exit **1**), then compiled and ran. The
existing ignored routing/capture probes were reused, not replaced with another
scheduler or toolchain. Additional behavioral assertions were added incrementally;
not every already-passing control is claimed to have an independent red run.

| Source-named case | Measured result and boundary |
| --- | --- |
| Async `cases` raw negative | Worker finally has run when the submitting monitor receives `Worker_failure`; raw `In_thread.run` deferred remains undetermined. That intentionally pending deferred is **never joined**. |
| Async owned settlement | Worker catches primary exception/backtrace and separately captures cleanup failure. Scheduler fills private completion exactly once **before** sending the primary with its captured backtrace to the caller monitor. Both failures remain in the completion record. |
| Async `abandoned_caller` | Detached caller monitor fails while the worker is held behind its release handshake. Outer-context producer survives the abandoned deferred, records both failures, fills completion once, then delivers the terminal exception. This is separate from the `Monitor.try_with` control. |
| Eio `raw_case` | Cancelling the raw worker fiber does not return/cancel the blocked system-thread call. After release it returns 42; the explicit following `Fiber.check` raises `Cancelled Requested`. |
| Eio `protected_case` | Independent switch-owned, protected producer resolves private completion after work and cleanup. Waiter cancellation is acknowledged **before worker release**; protected join persists through another cancellation request while cleanup is separately held. Original cancellation is reraised only after settlement. Cleanup-failure variant retains cancellation and the cleanup exception/backtrace in `Cancelled_with_cleanup`. All Eio context manipulation stays on scheduler fibers. |
| Both submission controls | Ordinary `Error Embedded_nul`, worker exception and injected synchronous dispatch exception remain separate owned outcomes. Injection is immediately before the real submission call; the worker-executed flag stays false. This tests the submission catch boundary, **not actual OS/thread-pool exhaustion**. No global pool settings change. |
| Both `transaction` controls | Whole database/connection/transaction/create/insert/prepared/fold/destruction lifecycle runs synchronously on the offload worker. The scheduler receives an owned `"owned"` string list after the fold/scopes have finished. Escaped transaction token reports `Closed`; native live/fallback counts are zero without GC. No deferred or yielding callback is passed to the transaction. |
| Eio `effects` | Calling real `Eio.Fiber.yield` inside the transaction is `Effects_not_allowed`. An explicit surrounding deep handler observes **zero deliveries**, callback cleanup executes, code after yield does not run, and a subsequent SQL assertion verifies rollback left zero rows. This is a deliberate denial test, not supported scheduler use inside a borrowed/core scope. |
| Handshake responsiveness | Scheduler can observe an actually started, still-blocked system worker and release it. These ML worker gates are not relabelled as proof of scheduler heartbeat during every native database/cleanup operation. |

`stage4/check_modes.sh` uses pinned `%{ocamlc}`, the current real public Duckdb
interface and installed real Async/Eio interfaces. It compiles the three positive
controls **first**, including explicit interfaces, then requires source-specific
negative diagnostics:

- `async_chunk.ml.fail`, `eio_chunk.ml.fail`: highlighted **chunk** is local but
  required global by the offload closure.
- `domain.ml.fail`: highlighted **connection** at characters 31–41 is contended
  but required uncontended inside the portable `Domain.Safe.spawn` closure.
  This is an actual safe connection, not an unrelated nonportable function.
- Paired owned-length scheduler controls are **compile-only**. They do not
  authorize executing scheduler calls from a live borrowed callback. Runtime
  positives complete the whole fold on the worker before transferring owned data.

First tracked mode run exited **1** because the diagnostic guard expected
`value "connection"`, whereas this compiler prints `This value` and highlights
`connection` in the source line. Corrected the guard to require the exact source
expression/location **and** contended/uncontended modes. The same fixture was
already correctly rejected; this was a test-guard correction, not an intended
static-restriction red (`runtest-first.txt`, `runtest-second.txt`).

### Mandatory joins and failure bounds

Supervisor explicitly resolved the helper-contract ambiguity: the 10-second
monotonic deadline detects a failed handshake/completion, but `Thread.join` has
no timeout. Every successfully created system worker is mandatorily joined even
following deadline failure, after the scenario body releases all gates. The
potentially unbounded join is explicit in `evidence_support.mli`. The executable's
`timeout 60` bounds **process failure**, not graceful cleanup or production
shutdown. A process timeout is a failed test and cannot claim deterministic
cleanup or permission to recycle a running connection.

`failed_handshake_join` raises a controlled handshake failure only after worker
start, releases the gate in the body's finally, and asserts worker exit before
that failure reaches the caller. It also checks idempotent joins, the original
worker exception/backtrace, and simultaneous body/worker failures with **both**
backtraces (`Multiple_failures`). No intentionally nonterminating test was added.
Every ticket-delivery failure path releases its ML gate before joining delivery;
owner shutdown follows delivery joins. No POSIX signal or thread termination is
used as cancellation.

## A2: immutable source audit and actual native behavior

Engine revision: `d8cdaa33fda8df955cc76ef58a280f68f4cd43fa` (v1.5.5).
Rerunning the existing native snapshot probe against `.deps/duckdb/libduckdb.so`
reports `source_id=d8cdaa33fd` (`pinned-source-id.txt`, exit **0**). No downloaded
engine code was built or executed. Existing cached prepared/ClientContext sources
were reused. Missing immutable files were fetched into ignored storage only.

The first file-output curl command was refused by the tool output-policy hook
before execution. Work stopped and the supervisor authorized the **same-tool,
same immutable URL, same destination** retry using silent file output. All six
subsequent immutable fetches exited **0**; no provider/backend/toolchain mode
switch, dependency install, HEAD substitution or configuration change occurred.

Source-to-mechanism audit:

1. `src/main/capi/duckdb-c.cpp:114–120` checks the C handle and calls
   `Connection::Interrupt`; `src/main/connection.cpp:65–67` calls
   `context->Interrupt`; cached `client_context.cpp:1189–1198` sets/reads/clears
   `interrupted`. `client_context.hpp:13,80–81` includes `common/atomic.hpp` and
   declares `atomic<bool>`; `atomic.hpp` aliases **std::atomic**. None of this
   valid-live-handle interrupt path acquires the query execution mutex, invokes
   cleanup or waits for a query. This is not a guarantee for invalid handles.
2. Disassembly of the **actual pinned shared library** corroborates the chain:
   C API null check/tail call; Connection loads its live context/tail calls;
   ClientContext `Interrupt` executes `mov $1,%eax; xchg %al,0x20(%rdi); ret`.
   No runtime release, allocation or execution-lock acquisition is inserted by
   the authored count-only wrapper. No general latency/performance guarantee is
   inferred from these instructions.
3. `prepared-c.cpp:424–436` executes with streaming disabled.
   `prepared_statement.cpp:73–96` reaches `ClientContext::Execute`;
   `client_context.cpp:808–834` reaches `PendingQueryPreparedInternal` and
   `InitialCleanup`, which clears interruption at **689–693**. Preparation also
   resets at **781,792**, parsing/pending-query paths at **1108,1136,1160**, and
   transaction preparation at **1248**. Error processing clears it at **1084**.
   An ML cancellation latch must therefore outlive these engine resets, successful
   results and any callback catching an error.
4. `pipeline_executor.cpp:188–195,427–428,549–552` reads the interrupted flag and
   throws `InterruptException`; ClientContext **660–686** translates interrupted
   execution to a failed result and invalidates the transaction. Executor
   **677–681** also interrupts sibling pipelines after internal errors. A native
   error is not automatically proof that user cancellation caused it.
5. Pinned compiler manual `manual/src/cmds/intf-c.etex:2424–2435` explicitly
   forbids releasing the domain lock in a `[@@noalloc]` call. Current
   `Duckdb_ffi.interrupt` has that annotation. The wrapper **only increments its
   atomic counter and calls the real primitive**. No gate, sleep, allocation,
   exception, callback or runtime transition exists in this native chain.

### Test-owned request experiment (not a safe adapter)

`test_interrupt_evidence.ml` exclusively owns an unsafe FFI database/connection
on the database system worker from construction through final close. The
controller gets only a test-owned slot used for synchronized interruption; it
never disconnects. Fresh identity objects avoid wrapping generation/ABA. One
short independent mutex controls current identity, phase, latch and in-flight
tickets; no SQL, callback, condition wait or scheduler effect holds it. Native
interrupt itself is serialized under that lock **after** any delivery pause.

Native gates are 1 (before real execute), 2 (after real execute), 4 (before real
disconnect), using C atomics and a monotonic watchdog; expiry fails the test.
**There is no native gate 3.** The ticket pause is bounded ML/system-thread code,
placed after reservation and before a second synchronized eligibility check.

| Case / oracle | Observed final and five-repeat results |
| --- | --- |
| `suppressed Queued/Dispatched` | Cancellation behind the actual worker-entry gate, including repeated cancellation, gives native execution delta **0**. Terminal cancellation/delivery gives interrupt delta **0**. Queued is a test-owned state, not a production admission queue. |
| `reset_and_running ~latched:false` | Native gate 1 entered, execute count increased exactly once, one interrupt delivered **before real engine entry**, finite query then completes normally. Latch stays set; one-shot interruption was lost to reset. This is intentionally negative evidence, not cancellation safety. |
| `reset_and_running ~latched:true` | Same pre-engine first delivery, then repeated identity-checked interrupts until the actual native **interrupted error and foreign return**. Observed **3** interrupt calls in each final/repeated run, both without and within an explicit transaction. Count is recorded, not hard-coded as a timing oracle. Latch remains set across startup/reset. No claim that wrapper entry means post-InitialCleanup engine startup. |
| Explicit running transaction | Controller stops before rollback; worker waits for that quiescence. COMMIT delta **0**, ROLLBACK delta **1**, only the one user execute. Interrupted connection is closed, not declared generally reusable. |
| `between_calls` | Successful INSERT completes; cancellation arrives at an explicit test-owned call boundary. No next user statement or COMMIT, rollback delta **1**, SQL checks zero rows. Delivery is ineligible in settlement, interrupt delta **0**. The real safe core has **no corresponding hook** today. |
| `retirement_race` | A delivery reserves ticket=1 and pauses in ML; A completes and enters Settling. Retirement marker stays false and disconnect delta stays **0**. Release → post-pause eligibility rejection → ticket retirement → delivery join → owner close. Native interrupt delta **0**, eventual disconnect delta **1**. Shutdown-style close waits for A; no engine handle is disconnected under a retained ticket. |
| `stale_and_error` | A finishes with an intentional native SQL error; B acquires the **same** engine connection with fresh identity. Delayed A notification causes **0** interrupts; B's known-clean SELECT succeeds. This control does not establish general reuse after interrupted or failed transaction settlement. |
| `close_gate` | Another system thread observes actual native disconnect held at gate 4 and releases it. This shows the normal FFI disconnect releases the runtime, not universal scheduler cleanup responsiveness. |
| Resource accounting | Every session returns binding live resources to its baseline, final live resources **0**, fallback count unchanged/final **0**, without requesting GC. These counters do not enumerate all temporary engine allocations. |

**Behavioral mutation red:** remove only the post-ML-pause eligibility check,
leaving initial identity check and ticket reservation intact. The native
executable exits **2** at the zero-late-interrupt assertion after A is settling,
with all gates released and joins performed (`post-pause-mutation-red.txt`).
Restore the check: exit **0** (`post-pause-restored-green.txt`). No production
source was mutated. This proves a pre-pause stale check alone is insufficient.

## A3: decision and remaining bridge gates

**Select a latched, identity-checked repeated interrupt driver for the next
bridge prototype**, not a one-shot interrupt. The measured reset gap rejects
one-shot delivery even for an already-entered C wrapper. A bounded number of
control workers must be independent of the database-worker quota: this experiment
progresses with its sole database slot occupied by the long query because the
controller is an independent system thread. It does **not** test saturation of
Async's shared pool or an implemented Eio adapter pool; those remain adapter
acceptance gates. Never allocate one waiting controller thread per queued caller.

Deliver only while the correct request/lease is Running; latch cancellation
before entry and at all subsequent user-call/commit/publication boundaries.
Serialize identity check plus native delivery with disarm/reuse/destruction;
retire and join all tickets before rollback/close. A ticket retains permission
to attempt delivery, not permission to bypass a post-pause eligibility check.
Keep interrupted connections conservatively discard-only until a narrower reuse
classification has independent evidence.

**Three separate prerequisites prevent a public signature now:**

- **Packaging:** `lib/duckdb/dune` still declares Resource private; installed
  `dune-package` places its CMI under `.private`; META remains
  `base duckdb-ffi threads`. Stage3c's accepted installed-consumer rejection of
  `Duckdb__Resource` is reused, not represented as freshly rerun installation.
  An external adapter cannot access `Resource.native_connection`. No casts or
  private-module exposure are an alternative. Before choosing a bridge signature,
  separately review a minimal non-production two-package fixture: private
  Resource, public opaque interruption capability/revocation seam, external
  consumer that compiles only the intended capability and still rejects Resource.
  No such new package was installed in this milestone.
- **Engine lifetime:** `resource_stubs.c` retains reference-counted native shells;
  `connection_clear` can still disconnect the engine connection. Shell retention
  alone does not authorize interruption. The real bridge must synchronize every
  close/discard/scoped/finalizer path with active request/ticket retirement. The
  experiment proves engine-handle validity by actual owner-close ordering, not by
  extra shell references.
- **Core boundaries:** Resource's private transaction/child-snapshot code can
  COMMIT after a synchronous successful callback and has no adapter latch check.
  Safe Query/Appender/Parquet operations include internal prepare/reset/control
  and publication boundaries. Required minimal production work is a reviewed
  opaque Resource capability plus cancellation checks/arming at those real
  boundaries, integration with transaction failure/revocation, and FFI lifetime
  synchronization where necessary. `between_calls` uses explicit unsafe
  test-owned transaction control and is **not passing safe adapter behavior**.
  `F.execute` also clears native results before returning to ML: the prototype's
  Running phase spans that internal cleanup. It does not establish a separately
  observable engine-completion/cleanup boundary for a future bridge.

### Held-runtime-lock cleanup audit

`resource_stubs.c` normal execute clears results/prepared/extracted/SQL before
reacquiring the runtime; normal disconnect/database close also unlock. With an
ordinary native interrupted return, subsequent ML `clear_work` has nothing left
to destroy in this tested path. `finish_connection_close` runs after native close
has cleared the handle. The measured driver stops before rollback/close.

However, locked `clear_work`, `finish_*`, finalizers and native shell unref paths
can destroy remaining results/connections when earlier cleanup was interrupted.
`prepared_stubs.c:19–35,94–106` and
`appender_stubs.c:56–76,215–220` retain such potentially blocking fallback paths.
Appender must clear before destroy because destruction may close/flush. Local
file publication/unlink unlock normally; `finish_local_file_work` frees copied
input/storage only and does not unlink. Resource/Query/Appender still invoke
these completions in exceptional cleanup. No general ordinary-adapter-cancellation
responsiveness follows from this experiment; changed bridge paths need held-native
scheduler heartbeats and a reachability audit before accepting an adapter.

## Exact verification commands and outputs

All commands from repository root. Final raw outputs named below are in
`.local/stage4a/logs/`; `commands.txt` retains expanded first-milestone commands.

```sh
# Missing-implementation red, then final green:
stage1/run build stage4/test_async_evidence.exe stage4/test_eio_evidence.exe
stage1/run build stage4/test_async_evidence.exe stage4/test_eio_evidence.exe \
  stage4/test_interrupt_evidence.exe
stage1/run runtest stage4 --force
for executable in test_async_evidence test_eio_evidence test_interrupt_evidence; do
  timeout 60 stage1/run exec --no-build "stage4/$executable.exe"
done
for iteration in 1 2 3 4 5; do
  timeout 60 stage1/run exec --no-build stage4/test_interrupt_evidence.exe
done
clang -std=c11 -Wall -Wextra -Werror -fsyntax-only \
  -I.deps/duckdb -I_opam/lib/ocaml stage4/interrupt_hooks.c
stage1/run build @all
stage1/run runtest --force
sha256sum --check .local/stage4/preserved.sha256
ASAN_OPTIONS=detect_leaks=0:halt_on_error=1 UBSAN_OPTIONS=halt_on_error=1 \
  timeout 120 stage1/run exec --profile stage3a-sanitize \
    --build-dir "$PWD/.local/stage4a/build-sanitize" stage4/test_interrupt_evidence.exe
# Mutation red and restored green both used:
timeout 60 stage1/run exec stage4/test_interrupt_evidence.exe
# Existing pinned source-ID probe, not a new discovery/rebuild:
LD_LIBRARY_PATH="$PWD/.deps/duckdb" .local/stage3b-schema/snapshot
for symbol in duckdb_interrupt _ZN6duckdb10Connection9InterruptEv _ZN6duckdb13ClientContext9InterruptEv; do
  objdump -d --disassemble="$symbol" .deps/duckdb/libduckdb.so
done
```

- Final focused build/runtest, three direct runs, **five native repetitions**, C
  warnings-as-errors syntax check, full `@all` build and full forced Stage1–4a
  regression: all exit **0** (`focused-build`, `focused-runtest`,
  `test_*-final`, `interrupt-repeat-1` through `5`, `clang`, `build-all`,
  `runtest-all`). Compiler-negative rejections are expected evidence inside the
  passing mode rule. One-shot reset control is expected negative evidence inside
  the passing native suite. No timeout occurred in final checks.
- Authored-C ASan/UBSan run: exit **0**, `sanitize.txt`, with **detect_leaks=0**.
  It instruments authored FFI C and new hooks, **not** prebuilt DuckDB, OCaml
  runtime or Base. Prior unsuppressed **whole-process LSan remains failing**;
  it was not rerun or suppressed. No leak-free process claim is made.
- Exact saved-hash check exits **1**: all six unrelated formatting files say
  **OK**; only generated `.pi/tasks/tasks-01a08274-8808-7730-9248-4a9a333e30e5.json`
  differs, as the parent warned its bookkeeping could. Worker never edited it.
  Separate six-file check exits **0** (`preserved-six.txt`). Original saved
  manifest was not rewritten; task state is excluded from the focused diff.
- Initial interface red exits **1**; post-pause mutation exits **2**; initial
  diagnostic-guard mismatch exits **1**. These are not concealed green runs.
- Ambient OCaml LSP validation is **unavailable**, not passed: observed
  `No config found` for new/standalone fixtures and `unknown flag
  -extension-universe` from the incompatible server. The generic reserved-name
  advisory for required `_POSIX_C_SOURCE` is not a native compiler error.
  Supervisor explicitly confirmed pinned compiler/native authority; no editor,
  user-wide or shared configuration changes were made. No claim that all ambient
  diagnostics passed accompanies the successful authoritative checks.

Additional exact source/pin commands:

```sh
# Each path listed in the source table used this same immutable fetch form:
curl -sS --fail --location --max-time 30 \
  https://raw.githubusercontent.com/duckdb/duckdb/d8cdaa33fda8df955cc76ef58a280f68f4cd43fa/src/main/capi/duckdb-c.cpp \
  -o .local/stage4a/sources/duckdb-c.cpp
stage1/run exec -- ocamlc -version
stage1/run exec -- dune --version
jj --version
clang --version
sha256sum .deps/duckdb/duckdb.h .deps/duckdb/libduckdb.so \
  .local/upstream/compiler.tar.gz .local/stage4a/sources/* \
  .local/stage3b-schema/client_context.cpp .local/stage3b-schema/prepared-c.cpp \
  .local/stage3b-schema/prepared_statement.cpp \
  .local/stage2-compiler/manual/src/cmds/intf-c.etex \
  _opam/lib/async_unix/in_thread.ml _opam/lib/async_unix/in_thread.mli \
  _opam/lib/eio/unix/thread_pool.ml _opam/lib/eio/core/promise.ml \
  _opam/lib/eio/core/cancel.ml
```

## Pins and SHA256 provenance

Compiler `5.2.0+ox`, installed package `oxcaml-compiler.5.2.0minus39`, immutable
source `2515546fea38e21e8143cc41db663bd56efc8d06`; Dune binary `3.22.2`, package
`3.22.2+ox`; Base/Async/Async_unix/Async_kernel
`v0.18~preview.130.106+341`; Eio/Eio_main `1.3+ox`; jj `0.42.0`; Clang `22.1.6`.
Async source `5c1c47bb66487f536ff4c3927ffdb0448636bb48`, Async_unix
`f2246763dc308b12dc2ac84820117b1ef07e4879`, Async_kernel
`69bd328f770d136faaf377622f84ae48d14a043c`; Eio source
`7de26f5331f1e7aac1c086a5ebe849dd940b5c3e`. Installed package directories and
metadata were inspected read-only (`packaging.txt`). The default Eio backend was
used; no alternate backend runtime claim or mode switch occurred.

Engine source paths below are relative to the immutable DuckDB revision above;
basenames identify ignored cached/downloaded files. Scheduler paths identify the
installed immutable sources. Fresh checksums are in `pins-hashes.txt`.

| File | SHA256 |
| --- | --- |
| `.deps/duckdb/duckdb.h` | `48e716b9ce96ca8fead9cb35693fdc0343ac0fc1f6e7db5561fa0f44b674153d` |
| `.deps/duckdb/libduckdb.so` | `fc23f12e376c47be520f75221288281906e7942e8fd6f6ce4849198ba60d0405` |
| Compiler archive | `93dbcf859e655d2a2b41dfa077c126fa5a15fd0205b1c57dbb5ff2cc9d595462` |
| Compiler `manual/src/cmds/intf-c.etex` | `2ce6820ece6acf6da63371402ec203269df347ecfcd30d6ca98e33bf2de7ef1f` |
| `src/main/capi/duckdb-c.cpp` | `5fc8409bf1e646218597202ba6c9f8a06e1032a26b4f93e2f5319aebe0f63217` |
| `src/main/connection.cpp` | `5b3de4c56c1c8e3f393e6a30ccbf919d14e0eefb9dc0e59a91acc2f0bf946539` |
| `src/include/duckdb/main/client_context.hpp` | `5ed443cdefc9d1cb27363ca85b8b4807b5c399c9526aae9c701a4f6cd13ba80d` |
| `src/include/duckdb/common/atomic.hpp` | `60d6a289e61d4e4f11a87736e64f7d03464f0c780baf4f24abc565cfa7694563` |
| `src/main/client_context.cpp` (cached) | `d5b4d9c1bc6af98bcad7612cb70d590214a29876e8674f1c5315894c12f55a5d` |
| `src/main/capi/prepared-c.cpp` (cached) | `89f91a03f865ead8eada0c295996cc85c45ee8bf0d7cfbc024080dbaf3292569` |
| `src/main/prepared_statement.cpp` (cached) | `f1fda1124d5c06011dbd693308c483c248d52f8c07c46f87e063bec00577eab4` |
| `src/parallel/executor.cpp` | `3ec2d58c227e7d42553b8ba39c7f0c387cfcb372f69c590718ddf9722a2a0444` |
| `src/parallel/pipeline_executor.cpp` | `ad3501e90ecbba881d1d8b856e76b6d9e89f9dc95e499f1ead47e382dea0b652` |
| Async_unix `in_thread.ml` | `de650876763647dd4d8d34e0ca4284a37b478e126927198b06d4b861117c226b` |
| Async_unix `in_thread.mli` | `c45c0cb3d4a582eb2705faaaab0dafefe1b85c026569078a37f04f459a3cb333` |
| Eio `unix/thread_pool.ml` | `422c6428d87486e1436e57e93e5b1485a6cb55855038b9e87ff9d2f05224a742` |
| Eio `core/promise.ml` | `5adf6b0c5fd1bce506f4e125ee1ce3af4f7cefdea598b72a2a611bcd322121c9` |
| Eio `core/cancel.ml` | `45917340460086d7c895d42d1a0aa6d34d4dee9c493bc29e7ae66b6f9b17032f` |

OOM, arbitrary/repeated signals, asynchronous-exception acquisition/bookkeeping
and mutex handoff gaps, foreign callbacks that never return, invalid unsafe FFI
use, hostile filesystem/process crash behavior and uninstrumented foreign runtime
limits remain unchanged. No domain transfer of handles, static linear-destruction,
zero-copy, general cancellation-safe reuse, bounded shutdown, absence of committed
writes/files after cancellation, or performance guarantee follows from Stage4a.

## Parent acceptance

Independent review `8bff78fe` found no issues and accepted specification and
quality for this prerequisite milestone only. The parent inspected the native
hooks, ticket/owner/join code, scope diff and validation report, then freshly ran
`stage1/run build @all` and `stage1/run runtest --force`: both exit **0**. Logs:
`.local/stage4a/logs/parent-build.txt` and `parent-runtest.txt`. Diagnostic-only
C LSP also reported clean; ambient OCaml LSP remains unavailable as above.

The repeated Eio cancellation requests target the same already-cancelled
context and are idempotent in the pinned runtime; this is not evidence for a
second independent cancellation source. The test-only evidence milestone is
accepted, not production cancellation or a public bridge signature. Next is the
separate packaging/bridge design gate; no publication is authorized by review.
