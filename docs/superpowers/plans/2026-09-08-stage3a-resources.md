# Stage 3a synchronous resources implementation plan

> Single writer executes inline; no subagents. This slice does not complete stage 3.

**Goal:** Installable unsafe FFI and safe synchronous resource packages, tested against the existing exact local pins.

**Architecture:** Abstract reusable handles have short metadata mutexes, explicit busy/closing state and revocable transaction capabilities. Stable native custom owners retain parents independently of OCaml finalizer order; native work copies inputs before unlock. Scoped cleanup revokes admission and drains operations; manual close is fail-fast. No scheduler dependency or thread affinity.

**Tech stack:** OxCaml 5.2.0minus39 / compiler 2515546fea38e21e8143cc41db663bd56efc8d06, Dune 3.22.2+ox, Base v0.18~preview.130.106+341, DuckDB 1.5.5, handwritten C.

## Constraints and decisions

- Preserve private stage1/2 and pre-existing whitespace. Use `stage1/run`, jj only, no installs into shared switches/configuration. License metadata omitted.
- Public handles are nonportable; system-thread offloading is tested with both installed adapter runtimes. No domain-safety claim.
- Repeated close succeeds. Manual parent close rejects live children. Manual close during an operation/lease returns Busy, never waits on its own callback.
- Scoped cleanup revokes aliases, drains existing foreign operations and leases, then closes children before parents. A callback that never returns or query that never finishes has no termination deadline.
- Transactions use a distinct capability; the original connection remains Busy throughout begin/callback/commit/rollback. Capabilities are revoked before draining callback-launched operations. Nested transactions through the connection return Busy.
- SQL accepts exactly one engine-parsed statement. Transaction control and indirect SQL EXECUTE/PREPARE/CALL and EXPLAIN wrappers are rejected by prepared statement type before execution; engine rewrites such as PRAGMA version to SELECT are allowed; public prepared values belong to 3b, but internal preparation is needed to classify SQL without parsing it ourselves.
- Scoped callbacks have a deep no-escape effect barrier inside `Sys.with_async_exns`; ordinary protect alone is insufficient. Cleanup retries a single Break and reraises after cleanup. Original exception plus rollback error is preserved in a named exception; result failures combine with rollback failures in an ADT.
- Native close normally unlocks; a nonallocating held-lock completion backstop handles interrupted close entry. It runs only after operations drain. No adapter responsiveness guarantee for that fallback/finalization; acquisition/OOM/repeated interruption are explicitly unproved.
- Native dependency is external, pinned, and documented. Installed stubs use `-lduckdb`, not developer absolute rpaths. Smoke test uses a separate prefix/native directory and explicit loader environment.

## Settled public interface (`lib/duckdb/duckdb.mli`)

```ocaml
type error = Invalid_configuration of string | Embedded_nul | Closed
  | Busy | Live_children | Native_error of string | Unsupported_statement
  | Effects_not_allowed | Rollback_failed of error * error
exception Rollback_exception of exn * error
exception Cleanup_exception of error * exn
module Config : sig
  type t
  type storage = Memory | File of string
  type access = Read_write | Read_only
  val create : ?threads:int -> ?memory_limit_bytes:int -> ?access:access -> storage -> (t, error) result
end
type database
type connection
type transaction
val open_database : Config.t -> (database, error) result
val close_database : database -> (unit, error) result
val connect : database -> (connection, error) result
val close_connection : connection -> (unit, error) result
val execute : connection -> string -> (unit, error) result
val execute_transaction : transaction -> string -> (unit, error) result
val with_database : Config.t -> f:(database -> ('a, error) result) -> ('a, error) result
val with_connection : database -> f:(connection -> ('a, error) result) -> ('a, error) result
val with_transaction : connection -> f:(transaction -> ('a, error) result) -> ('a, error) result
```

## File ownership

- `lib/ffi/duckdb_ffi.{mli,ml}`, `resource_stubs.c`: explicitly unsafe custom owners, opening, connecting, execution, closing, private interruption seam and counters. No safe representation operations.
- `lib/duckdb/duckdb.{mli,ml}`: configuration, lifecycle/lease state, effect/async boundaries and transaction outcome algebra.
- `dune-project`, package opam files, library Dune files: package boundary; development-only warning policy.
- `test/test_duckdb.ml`: lifecycle/config/SQL/persistence/transaction/effect/thread tests.
- `test/async_handoff.ml`, `test/eio_handoff.ml`: actual offload compatibility, not adapters.
- `test/signal_stubs.c`, `test/test_signals.ml`: exact-runtime linker-wrapper signal injection and deterministic counters.
- `test/install_smoke.sh`, `examples/synchronous.ml`: separate-prefix packaging and executable example.
- `docs/stage3a-validation.md`: exact evidence, limits and stage3b contract.

## Test cycles

### 1. Interfaces and package baseline

- [x] Write both `.mli` files and configuration/open/connect/query/close assertions before implementation. `Config.create ~threads:0 Memory` must return Invalid_configuration; valid in-memory handles execute `create table t(i integer)` and repeat close successfully.
- [x] Run `stage1/run build test/test_duckdb.exe`; retain missing-implementation red log.
- [x] Implement native ownership and minimal Base safe state; run the same command and executable to green. Compile actual Async/Eio offload examples early.

### 2. Reusable state, scoped ownership and transactions

- [x] Add regression tests and refine failing state transitions: alias close -> Closed, live child -> Live_children, original connection and nested transaction -> Busy, escaped token -> Closed; persisted table reopened successfully.
- [x] Add rollback regression assertions using `select case when count(*) = 0 then 1 else error('rollback failed') end from t`; test result failure, ordinary exception, successful commit and SQL-error recovery. Reject `COMMIT`, multi-statement SQL and SQL EXECUTE before side effects.
- [x] Run failing cases; implement lease admission/revocation and rollback outcome preservation; rerun.
- [x] Add effect escape/catch/reperform and thread ownership/drain tests. Use atomic handshakes and timeouts, not timing alone. Implement no-escape barrier and force cleanup; verify counters without GC.

### 3. Native transitions and diagnostics

- [x] Add signal tests for open/connect/query/close enter and leave, live transaction callback and rollback. Run under real SIGUSR1 raising Sys.Break; assert one handler and no native fallback reclamation.
- [x] Demonstrate a failing mutation without inner async boundary; restore and verify green.
- [x] Run authored C warnings-as-errors diagnostics; sanitizer checks where applicable. Record honestly which native code is instrumented and acquisition/OOM/repeated-signal limits.

### 4. Distribution and full regression gate

- [x] Install `duckdb-ffi` alone then `duckdb` into a temporary prefix with `stage1/run install --prefix ...`; build/run an external consumer using relocated native dependency, without repository rpath/absolute installed references. Check scheduler-free dependency closure.
- [x] Run `stage1/run build @all`, `stage1/run runtest --force`, bootstrap Python regressions, package smoke, native diagnostics. Capture exact logs.
- [x] Write validation, update checklist, commit coherent files with explicit jj paths excluding `stage1/ffi/check_unboxed.sh`. Save `.local/stage3a-review.diff` from 066efff8 to final commit; return independent-review evidence. No claim later slices complete.

## Execution refinements and completed evidence

- The public interface was written first and the baseline executable failed on
  missing implementations. Expanded transaction assertions also served as controls
  for the initial implementation; not every assertion had an independent red run.
- Actual engine preparation rewrites some PRAGMAs to SELECT. The final contract is
  an engine statement-type allowlist, not lexical parsing. EXPLAIN wrappers are
  rejected to avoid indirect transaction control.
- `Cleanup_exception` was added to preserve a primary result error when cleanup
  raises. Ordinary pairs of exceptions use `Base.Exn.Finally`.
- Tests exposed concurrent double destruction and a close-reacquire pending-signal
  self-wait. Shared close ownership and explicit post-reacquire pending-action
  delivery inside the rooted async boundary fixed them. An inner-boundary mutation
  independently reproduces the self-wait and restoration passes.
- The final suite has 18 counted signal boundaries, persistent COMMIT outcome
  checks, actual Async/Eio handoffs, GC pressure, condition-wait handshakes,
  rollback-failure injection, and dynamic revocation of inner continuations.
- Independent Dune package builds/installations and external consumers pass;
  actual opam installation is untested. Owner-approved missing publication metadata
  leaves `opam lint` failing. Whole-process LSan reports runtime/Base bookkeeping;
  authored-stub ASan/UBSan and deterministic native counters pass. Neither limit is
  hidden or described as a passed leak/publication gate.
- Exact commands, red/green logs, limits, and next-slice obligations are recorded in
  `docs/stage3a-validation.md`. Commit identity/review diff live in the runtime
  report. The pre-existing whitespace is excluded from the commit.
