# Stage 2 borrowed columns implementation plan

> Execute inline, single writer, using writing-plans, executing-plans, type-driven TDD and systematic-debugging. No subagents. The stage-2 gate is experimental evidence, not a public API freeze.

**Goal:** Demonstrate safe synchronous scoped access to actual DuckDB BIGINT/validity buffers and select the smallest supported lifetime design.

**Architecture:** A separate private `stage2` Dune library hides the native owner and offers only scoped chunk callbacks and explicit owned copying. Native allocation, access, invalidation and destruction live in a handwritten FFI/C bridge. Compile experiments determine exact mode signatures before implementation; no uniqueness benefit is assumed.

**Tech Stack:** Existing pinned OxCaml 2515546fea38e21e8143cc41db663bd56efc8d06, Base preview, local Dune 3.22.2+ox, DuckDB 1.5.5 public C API.

## Global constraints

- Stage 2 only; no public packages, scheduler adapters, Parquet, appender or broad type support.
- Use `stage1/run`; no installation, shared/global configuration, sudo, raw Git or remote publication.
- Preserve and exclude existing `stage1/ffi/check_unboxed.sh` whitespace from commits. Commit only explicit new paths with jj.
- No foreign-buffer-to-managed-array casts; no movable heap pointers retained across unlock.
- `local` prevents escape, not invalidation. Hide owner transitions rather than invent linear ownership.
- Test deterministic cleanup separately from finalizer fallback, including genuine runtime Sys.Break; document fatal/repeated signal and allocation-failure limits precisely.
- Ambient OCaml LSP is unavailable; local compiler and C diagnostics are mandatory.

## Task 1: Compiler evidence and interface decision

Files: `stage2/experiments/*`, `stage2/check_modes.sh`, `stage2/dune`, `stage2/borrowed.mli`, `stage2/borrowed_ffi.mli`.

- [x] Extract only exact pinned compiler documentation, mode/uniqueness tests and runtime sources from existing verified archive into ignored `.local/stage2-compiler`.
- [x] Read locality, uniqueness, borrowing examples and `Sys.with_async_exns` implementation. Compile tiny experiments using `_opam/bin/ocamlc -extension-universe beta -c` via local Dune.
- [x] Establish whether a callback argument `view @ local` with global callback result rejects returned/stored/captured views. Test unique owner reuse separately and show why it does not alone protect foreign lifetime.
- [x] Write `.mli` first: abstract view, scoped query traversal, length/get/copy; named query/schema/index errors. Keep owner destruction/fetch/reset inaccessible. Define early-stop control separately from callback return payload if needed by compiled modes.
- [x] Add paired positive and intended-mode-negative tests for return, store, closure capture, domain transfer and invalid owner transitions. Check diagnostic substrings, not mere compiler failure. Unsupported alternatives remain explicit experiments rather than advertised guarantees.

## Task 2: Real chunk lifetime, type-driven TDD

Files: `stage2/borrowed.ml`, `stage2/borrowed_ffi.ml`, `stage2/borrowed_stubs.c`, `stage2/native_borrow.{h,c}`, `stage2/borrowed_tests.ml`, `stage2/native_diagnostics.c`.

- [x] Write tests before implementation: empty SQL result gives zero callbacks; range(5000) totals 5000 rows across more than one chunk; nullable extrema round-trip; owned copy survives scope and domain join; invalid SQL/schema/index/NUL return named errors.
- [x] Run `stage1/run build stage2/borrowed_tests.exe` to capture missing implementation red.
- [x] Implement stable C owner allocated/rooted before unlocked work. Owner retains SQL/result/chunk before reacquisition. Use `duckdb_fetch_chunk`, validate exactly one BIGINT column, read `int64_t*` and validity words directly. No managed pointer retained across unlock.
- [x] Scope owner acquisition/work in `Sys.with_async_exns` inside an established ordinary cleanup handler. Locked, allocation-free, idempotent destructor clears chunk before result before connection before database. No close/fetch escape hatch in the view interface.
- [x] Make tests pass, including nested/reentrant independent queries and aliases of the same view remaining readable, GC pressure, early stop, normal exception and repeated cleanup. Record exact semantics instead of advertising affine use if views can alias safely.
- [x] Compile standalone native owner diagnostics with ASan/UBSan/LSan; test chunk advance, bounds, invalidation and idempotent destruction counters/order. Instrument helper, not prebuilt DuckDB/runtime.

## Task 3: Exact signal cleanup and safety decision

Files: `stage2/signal_tests.ml`, `stage2/signal_test_stubs.c`, `docs/stage2-validation.md`.

- [x] Add linker wrappers injecting real SIGUSR1/Sys.Break before enter/leave transitions for query and fetch and at destructor entry; assert resources existed and all are gone before GC. Restore handlers and test state on exit.
- [x] Record a deliberate missing-inner-boundary mutation red, restore boundary, rerun green. Test-only counters must distinguish ordinary deterministic destruction from fallback.
- [x] Inspect runtime paths and explicitly settle limits: synchronous ordinary exception and tested single Break cleanup versus fatal process termination, repeated interruption, OOM/finalizer backstop. If these prevent any safe scoped prototype, report source-backed blocker rather than weaken claims silently.
- [x] Run focused tests repeatedly, `stage1/run build @all`, `stage1/run runtest --force`, bootstrap unittests and warnings-as-errors native syntax/sanitizer checks. Preserve stage 1.
- [x] Write exact compiled signatures, source citations, positive/negative diagnostics, red/green evidence, ownership decision and next-stage contract in `docs/stage2-validation.md`.
- [x] Commit plan and tested prototype with explicit jj paths, save `.local/stage2-review.diff` from 83b7d025 to final implementation commit, verify only original whitespace remains uncommitted, and write the required runtime artifact and structured acceptance report. Independent review remains required.

## Execution evidence and approved refinement

Completed on 2026-09-08. Exact signatures, restrictions, red/green outputs, source citations and limitations are in `docs/stage2-validation.md`. Runtime checks pass on three actual DuckDB chunks; ten intended type/mode rejections and paired positive controls pass. Nine genuine Sys.Break boundary cases and native ASan/UBSan/LSan checks pass without finalizer recovery.

A compiled effect-continuation counterexample motivated an explicit no-escape effect barrier, approved through the supervisor decision channel. Runtime investigation refined the initial hypothesis: the existing `Sys.with_async_exns` C callback boundary already blocked outer effect delivery; the explicit deep handler supplies structured denial even after callback catch/reperform. Inner-handler capture of the local view is compiler-rejected. Ordinary composite callback exceptions remain exceptions. No static effect-purity or unconditional async deterministic-close claim is made.

Implementation remains private and scoped; no stage-3 functionality or dependency change. Independent review of the saved stage-2 diff remains the next gate.
