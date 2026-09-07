# Stage 3a: synchronous resource foundation

Validated 2026-09-08 on x86-64 Artix/glibc with the existing local pins.
**Stage 3a implementation checks pass; independent review required.** This is
not completion of stage 3, the adapters, cancellation or the whole project.
Baseline: `066efff8` (reviewed stage 2 plus tightened negative diagnostics).

## API and package boundary

The complete public contract is [`lib/duckdb/duckdb.mli`](../lib/duckdb/duckdb.mli),
written before implementations, following the
[stage-3a plan](superpowers/plans/2026-09-08-stage3a-resources.md).

- Abstract reusable `database`, `connection`, and revocable `transaction`.
- `Config.create`: memory or local file, read/write or read-only, positive thread
  count (default 1), nonnegative memory limit in bytes (0 = engine default).
  Read-only memory and empty/NUL/colon-containing file paths are rejected.
  Colon rejection intentionally excludes DuckDB special/remote URI paths, and
  also excludes otherwise legal Unix filenames containing colons.
- `open_database`, `connect`, `close_database`, `close_connection`, `execute`.
- `with_database`, `with_connection`, `with_transaction`, `execute_transaction`.
- Named errors: `Invalid_configuration`, `Embedded_nul`, `Closed`, `Busy`,
  `Live_children`, `Native_error`, `Unsupported_statement`, `Effects_not_allowed`,
  and `Rollback_failed`. No unsafe representations or casts in the safe layer.
- Native diagnostics are bounded to 511 bytes, copied into `Native_error`.
- `duckdb-ffi` is a separately installable **unsafe** package, not an alternative
  safe contract. Its custom owners, native pointers and representation operations
  are confined to `lib/ffi`. Its raw interruption primitive is an internal seam,
  with caller-owned lifetime/operation-identity synchronization obligations.

SQL is exactly one **engine-parsed/prepared** statement, with discarded results.
An internal preparation step classifies before executing; this is not the public
prepared-statement API planned for 3b. Only prepared SELECT, INSERT, UPDATE,
DELETE, CREATE, ALTER, DROP, COPY, ANALYZE and MERGE are executed. Other types,
including transaction control, SQL PREPARE/EXECUTE, and EXPLAIN wrappers, are
rejected. An early test found `PRAGMA version` is rewritten by DuckDB to SELECT;
the contract deliberately describes engine statement types, not a lexical ban on
PRAGMA. No SQL parser/DSL is invented. Arbitrary SQL and engine external effects
are not a security sandbox; COPY output files are not rolled back by a transaction.

`duckdb-ffi` has no OCaml library dependencies. `duckdb` depends only on Base,
threads and `duckdb-ffi`. Neither package links Async/Eio or starts a scheduler.
Separate executable tests actually capture handles in `Async.In_thread.run` and
`Eio_unix.run_in_systhread`, execute, then close them via another offload call.
Both compile and run with the installed exact pins, not ambient OCaml.

## Lifecycle and ownership rules

| Action | Rule |
| --- | --- |
| Close an already closed handle | `Ok ()` |
| Manual close during work/another close/transaction lease | `Busy`; never waits on its own callback |
| Manual database close with live children | `Live_children` (or `Busy` during an active database operation) |
| Operation through closed/revoked alias | `Closed` |
| Ordinary operation during another operation | `Busy` |
| Ordinary connection use or nested transaction during lease | `Busy` for the entire begin/callback/commit/rollback |
| Scoped cleanup | Revoke admission, drain admitted operations/leases, destroy children before parent |
| Leaked scoped handle or transaction token | Retained aliases cannot regain validity |

Handles have short metadata mutexes and condition variables, not permanent thread
affinity. No mutex is held across a DuckDB call or user callback. Waiting releases
the metadata mutex needed by completing operations. Scoped force-close is not
public: callbacks can call only fail-fast manual close, so they cannot invoke
force-close and wait on their own lease. Once a transaction callback returns,
its token is revoked **before** waiting for admitted callback-launched operations.
The original connection remains leased until transaction settlement. Manual and
scoped concurrent destruction share the same busy/closed state transition.

A parent retains its children, including manually opened children whose caller
has dropped its alias. Manually opened resources require explicit close; dropped
aliases do not make parent close succeed. Native connection owners separately
retain a reference-counted native database shell, independent of OCaml finalizer
ordering. Finalizers are eventual backstops, never the deterministic-close proof.

There is **no portable/domain-safe handle claim**. The actual `.mli` compiles with
warnings-as-errors; paired standalone controls reject returning a connection
through `Domain.Safe.spawn` (the highlighted connection is contended but expected
uncontended in a portable closure), and reject passing a transaction token to
`close_connection` (abstract-type mismatch). Owned error transfer and ordinary
aliases compile. Unsafe domain-sharing escape hatches are outside the contract.

## Transaction outcomes and effects

- Normal callback success commits; callback result error, ordinary exception,
  effect denial or Break attempts rollback.
- Original result error plus rollback error: `Rollback_failed (primary, rollback)`.
- Original exception plus rollback error: `Rollback_exception (primary, rollback)`.
- Original result error plus exceptional cleanup: `Cleanup_exception (primary, exn)`.
- Original exception plus exceptional cleanup: `Base.Exn.Finally (primary, cleanup)`.
- Failed or exceptional rollback revokes and **discards the connection**, rather
  than returning unknown transaction state for reuse. A failed BEGIN can therefore
  be paired with the subsequent no-active-transaction rollback failure.
- A single Break interrupting rollback completion is retried for cleanup, then
  preserved, not converted into a query error. This is not a masking API.

The deep effect barrier sits **inside** `Sys.with_async_exns`. It refuses every
outward effect, discontinues the continuation under the deep handler, and remembers
caught denials. This prevents sending a live scope/lease continuation to an outer
scheduler. It is not global effect purity: callback-owned inner handlers can
capture a continuation containing reusable handles. A dedicated runtime test
resumes such a continuation after the transaction/scope has returned and verifies
its token returns `Closed`. This slice therefore relies on dynamic revocation for
that case, not stage 2's local-view static guarantee. Stage 3b borrowed views must
retain their independent local/no-owner-transition restrictions.

A persistent commit-boundary test proves the cancellation caveat concretely:
Break before COMMIT entry leaves zero inserted rows after reopening the file;
Break at COMMIT reacquire leaves **one committed row**, preserves the subsequent
rollback failure with the Break, and discards the connection. Interruption is
never evidence that writes did not commit. External side effects are governed by
DuckDB semantics, not undone by this binding.

## Native ownership and exact-runtime asynchronous cleanup

Every native operation owns its inputs/work in a stable C shell reached through
a rooted custom block. SQL and paths are copied and integer options extracted
before unlock. Unlocked code never reads movable OCaml fields. Query results,
including failed results, extracted statements and temporary prepared statements
are destroyed before reacquisition. Partial native handles are tested for NULL
before cleanup/error access. Shells and native parent references survive all
raising FFI transitions exercised here.

Normal opening, connecting, query work, result destruction, disconnect and database
close release the runtime lock. `duckdb_destroy_result`, statement destruction,
`duckdb_disconnect` and `duckdb_close` must be treated as potentially blocking.
Close leaves the stable shell rooted until runtime reacquisition completes. A
nonallocating locked completion frees any remaining resource after an interrupted
close entry, then clears its custom slot. This fallback (and finalization) can
hold the runtime lock while DuckDB blocks. **No adapter responsiveness claim**
follows from normal unlocked close or the handoff smoke tests.

Exact compiler sources already recorded in stage 2 remain authoritative:
`runtime/signals.c:209–222` can process a raising handler before unlock;
reacquisition marks signals pending rather than immediately delivering them;
`runtime/callback.c:544–561` implements the asynchronous-exception boundary.
A new public-handle test found a pending close-reacquire signal could otherwise
arrive during ML cleanup bookkeeping, skip it, and strand a busy state.
Every unlocked stub now explicitly calls `caml_process_pending_actions` **after
reacquisition but before returning**, inside the rooted caller's inner async
boundary. Ordinary `Exn.protect` alone is not sufficient.

Eighteen real SIGUSR1 cases use a handler raising runtime `Sys.Break`, test-only
GNU linker wrappers, exact allocation counts at injection, one handler/injection,
and zero live binding resources/fallback reclaims after unwinding without GC:

| Boundary | Live resources at enter / leave |
| --- | --- |
| Open | 2 / 2 |
| Connect | 3 / 4 |
| Query | 5 / 4 |
| Database close | 2 / 1 |
| Connection close | 4 / 3 |
| BEGIN | 5 / 4 |
| COMMIT | 5 / 4 |
| ROLLBACK | 5 / 4 |
| Live transaction callback, and rollback/reuse assertion | 4 each |

These are targeted **single-signal, single-OCaml-thread** transition guarantees.
Acquisition/protection setup gaps, metadata-lock acquisition/handoff interruption,
arbitrary interruption in OCaml bookkeeping, arbitrary/repeated signals, OOM,
failed connection/extraction allocation fault injection and process termination
remain unproved. Scoped draining has no time bound if an admitted query or leased
callback never finishes. Do not generalize these tests to concurrent signal
routing, cancellable adapters or universal deterministic cleanup. Exceptional
acquisition can leave an owner shell for eventual finalization; no timeout is
promised. Runtime/memory safety under arbitrary repeated interruption is not a
claim of this slice.

## Test-first failures, fixes and independent evidence

Raw logs: ignored `.local/logs/stage3a/`.

| Check | Red evidence | Green evidence |
| --- | --- | --- |
| `.mli` plus baseline tests before implementation | `interface-red.txt`: both implementations absent | baseline query/config/close executable passes |
| Engine statement classification | `state-red.txt`: assumed PRAGMA lexical rejection was false | documented actual engine-type allowlist; transaction/multi/indirect controls rejected |
| Manual close racing scoped cleanup | `state-race-red.txt`: allocator detects double destruction | shared close busy state; final test waits for actual condition-wait entry, not a timer |
| Close reacquire Break | `signals-first.txt`: exit 124; GDB `close-leave-deadlock.txt` shows self-wait on busy condition | explicit pending-action delivery inside FFI async boundary |
| Remove inner close async boundary only | `async-mutation-red.txt`: exit 124 (5-second timeout) | restore exact code: `async-mutation-restored.txt`, deterministic cleanup passes |
| Compiler diagnostics | actual warning-50 doc placement, Base.Mutex deprecation, continuation generalization, and fixture type errors fixed | pinned compiler/build and precise negative checks pass |
| Package smoke initial command | explicit `--root` duplicated Dune `-p`'s implicit root | corrected command; separate-prefix package smoke passes |

Expanded transaction/effect tests also serve as regression controls; not every
already-passing assertion is claimed to have had its own independent red run.
No additional property-test dependency was installed: pure configuration edges
are table-driven. Native hooks are linked only to tests, never installed libraries.

Normal tests cover memory and persistent/read-only operation; configured thread
count/memory limit; 20 failed opens and 50 failed-query/recovery cycles;
NUL/invalid/transaction-control/multi-statement SQL; aliases/repeated/parent-child
close; manual close within ordinary scopes; exceptions; nested/successful/failed
transactions; rollback on result error/exception/Break; retained/revoked tokens;
rollback-failure fault injection and connection discard; original outcome
preservation; outward effects and revoked inner continuations; runtime-unlocked
work with dynamic 100KB SQL and concurrent GC/compaction; operation ownership,
scoped draining, transaction token draining, concurrent destruction; and actual
native disconnect-before-database-close trace `12`. Counters are asserted before
GC. Final test GC only helps diagnose runtime bookkeeping; fallback count remains
zero afterwards too.

## Exact final commands and results

All project commands use the already installed pinned local switch via
`stage1/run`. No reinstall, shared/global opam/editor change, sudo or remote
publication occurred. The native setup smoke extracts the **already downloaded**
verified archive only into a temporary prefix. No engine source/library change.

```sh
stage1/run build @all
stage1/run runtest --force
python3 -m unittest discover -s stage1 -p 'test_*.py' -v
python3 -m unittest discover -s test -p 'test_*.py' -v
bash test/install_smoke.sh
stage1/run exec examples/synchronous.exe
ASAN_OPTIONS=detect_leaks=0:halt_on_error=1 UBSAN_OPTIONS=halt_on_error=1 \
  stage1/run exec --profile stage3a-sanitize \
    --build-dir "$PWD/.local/build-stage3a-sanitize" test/test_duckdb.exe
clang -std=c11 -Wall -Wextra -Werror -fsyntax-only \
  -I.deps/duckdb -I_opam/lib/ocaml \
  lib/ffi/resource_stubs.c test/test_hooks.c test/signal_stubs.c
# Each of the same three files:
clangd --check=lib/ffi/resource_stubs.c --compile-commands-dir=.local --tweaks=
```

- Full build and stage1+2+3a Dune tests pass, including prior native ASan/UBSan/LSan
  helpers, scheduler regressions and all ownership negative fixtures.
- Bootstrap Python: **8 tests OK**. Native setup Python: **2 tests OK**.
- New ASan/UBSan run passes with leak detection disabled. It instruments the actual
  authored FFI C stubs and test hooks, not the prebuilt engine/OCaml runtime/Base.
- **Whole-process LSan does not pass.** `sanitizers-leaks.txt` reports 2,772 bytes
  in runtime mutex/condition/thread and Base allocations; after final GC the
  exploratory run reports 1,624 bytes (`sanitizers-leaks-final-gc.txt`). Neither
  report names an authored binding allocation. These reports are retained, not
  suppressed or described as a leak-free runtime/engine result. Binding-native
  counters are zero before GC; that is a narrower ownership oracle.
- C warnings-as-errors passes; all three diagnostic-only clangd checks report
  **0 errors**. Only ignored `.local/compile_commands.json` was updated.
- **5 repeated full lifecycle/drain runs + 90 counted signal checks pass** using
  `timeout 30 stage1/run exec --no-build ...`; see `repeated.txt`.
- Example prints `synchronous transaction complete`.
- Separate-prefix install smoke passes both FFI-alone and safe-against-installed-FFI
  builds/external consumers, checks scheduler-free `META` dependencies, confirms
  relocated native loader resolution and no installed native rpath/source-root
  package metadata. Installed native debug provenance is not a loader dependency.
  See [native installation](native-dependency.md) for exact workflow and limits.
- Opam files use the demonstrated Dune workflows; an actual `opam install`/solver
  run was **not** performed. With supervisor approval `opam lint` remains a
  publication-metadata limitation: error 23 no maintainer, warnings 25/35/36/68 for
  authors/homepage/bug-reports/license. No attribution or license was invented.
- Ambient OCaml LSP remains **unavailable**, as already approved: it is incompatible
  with the pinned compiler. Standalone negative fixtures intentionally have no
  Dune library module. Real native/compiler diagnostics were fixed, not ignored.

Rechecked pins (`pins.txt`): compiler prints `5.2.0+ox`, package
`oxcaml-compiler.5.2.0minus39`, exact revision
`2515546fea38e21e8143cc41db663bd56efc8d06`; Dune prints `3.22.2`, package
`3.22.2+ox`; Base remains `v0.18~preview.130.106+341`; jj `0.42.0`, GCC
`16.1.1 20260625`. Header/library hashes remain respectively
`48e716b9ce96ca8fead9cb35693fdc0343ac0fc1f6e7db5561fa0f44b674153d` and
`fc23f12e376c47be520f75221288281906e7942e8fd6f6ce4849198ba60d0405`.

## Next-slice contract and review checkpoint

Stage 3b owns public prepared statements, typed parameters/results/columns and
borrowed/owned chunk traversal. New children must join the same admission,
parent-retention, revocation and drain rules; a transaction token cannot expose a
reusable connection or raw pointer. Keep the stage-2 local/no-owner-transition
negative suite and no-escape barrier when adding borrowed memory. Do not derive
borrowed lifetime guarantees from these reusable-handle tests. Stage 3c owns
appender and dedicated typed local Parquet. No pool, scheduler adapter, cancellation
API, broad placeholder exported surface or performance/zero-copy claim was added.

Future adapters must separately prove independent interruption locking, operation
identity/late-interrupt exclusion, waiting for foreign completion, cleanup/error
routing, responsiveness during exceptional destruction, and shutdown. The unsafe
FFI interrupt seam alone proves none of these.

All valuable stage1/2 source and validation are preserved. `stage1/run` gained only
project-local native include/link/loader environment for the public packages.
The pre-existing whitespace in `stage1/ffi/check_unboxed.sh` is preserved and
excluded from the implementation commit. Generated `*.install` files are ignored.
The exact commit identity and `.local/stage3a-review.diff` from `066efff8` are
recorded in the runtime implementation report to avoid a self-referential hash.
Independent review is still required; the implementation verdict is not a claim
that publication metadata, all of stage 3 or the overall project is complete.
