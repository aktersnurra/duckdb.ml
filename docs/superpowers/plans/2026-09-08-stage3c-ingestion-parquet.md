# Stage 3c ingestion and local Parquet implementation plan

> Single-writer inline execution; no worker fanout. Follow the writing-plans TDD checkpoints below. Earlier stages and their limitations remain authoritative.

**Goal:** Actual native appender ingestion and dedicated typed local Parquet convenience APIs, without schedulers.

**Architecture:** Appenders are transaction-owned children. A connection convenience scope owns a transaction; explicit-transaction creation never settles the caller's transaction. An appender reserves its connection from creation/schema validation until destruction, so same-connection DDL cannot invalidate its schema. The transaction snapshot protects against other connections. Typed complete rows use existential scalar fields/values rather than the read-only Row.Map decoder. Parquet reads reuse Query/Row; exports use DuckDB COPY with bound destination and engine-parsed queries, private temporary output and no-overwrite publication.

**Tech stack:** Existing pinned OxCaml, Base, Dune, DuckDB 1.5.5 public C API. No dependency reinstall or scheduler library.

## Global constraints

- Preserve six unrelated formatting paths; use jj only, commit named implementation paths.
- Native ownership and asynchronous cleanup follow existing rooted shells, inner Sys.with_async_exns, explicit pending-action delivery and locked fallback completion.
- No deterministic arbitrary interruption, filesystem rollback, portable handle, performance or whole-process LSan claims.
- Write .mli contracts before implementations. Save raw red/green and native-source evidence under ignored `.local/logs/stage3c/`.

## Task 1: Pinned-engine behavioral evidence

Files: ignored `.local/stage3c/` probes and sources; `docs/stage3c-validation.md` final evidence.

- [x] Read approved spec and earlier validation; inspect Resource/Query/Scalar seams and pinned appender source.
- [x] Compile/run public-C probes for appender clear/close/destroy, explicit rollback, auto-flush errors, concurrent ALTER, COPY bound paths and Parquet type/unit fidelity.
- [x] Record source revision/checksums. Stop on a safety blocker instead of assuming casts or transaction behavior.

Commands: `cc -Wall -Wextra -Werror -I.deps/duckdb .local/stage3c/probe.c -L.deps/duckdb -lduckdb -o .local/stage3c/probe`; `LD_LIBRARY_PATH="$PWD/.deps/duckdb" .local/stage3c/probe`.

## Task 2: Transaction-owned complete-row appender

Files: new private `lib/duckdb/appender.{mli,ml}`, `lib/ffi/appender_stubs.c`; modify `lib/duckdb/{duckdb,resource}.{mli,ml}`, both library Dune files and `lib/ffi/duckdb_ffi.{mli,ml}`; new `test/test_appender.ml` and native test hooks.

Public interface shape:

```ocaml
type appender
type cell = Cell : 'a Scalar.field * 'a -> cell
val open_appender : transaction -> ?schema:string -> string -> (appender, error) result
val append_rows : appender -> cell list list -> (unit, error) result
val flush_appender : appender -> (unit, error) result
val close_appender : appender -> (unit, error) result
val with_appender : connection -> ?schema:string -> string -> f:(appender -> ('a,error) result) -> ('a,error) result
val with_appender_transaction : transaction -> ?schema:string -> string -> f:(appender -> ('a,error) result) -> ('a,error) result
```

- [x] Write contracts and failing test: create BIGINT table, append `Cell (Required Int64,9007199254740993L)`, close/commit, decode exact value with existing Row.
- [x] Run `stage1/run exec test/test_appender.exe`, retain absent-implementation red.
- [x] Implement typed batch validation (entire batch before native mutation), stable native row/batch storage, actual create/append_value/end_row/flush/close/clear/destroy calls; one admission and unlock per batch, no per-cell scheduling.
- [x] Native failure poisons the owner and transaction even if caller ignores the error. Transaction settlement checks its first poison before commit. Destruction clears buffered rows before destroy, never retries a failed flush implicitly. Unclosed manual children force rollback. Cleanup uses existing revocation/drain rules and parent references.
- [x] Test all supported Scalar values/NULL/binary NUL/extrema, wrong widths/shape/NULL/ranges, large/empty batches, constraints at explicit/auto flush, first-error preservation, aliases/close/parent/scoped drain, rollback and retained tokens, concurrent schema changes, unlocked GC and counted Break transitions.
- [x] Run appender tests and exact compiler/native checks, inspect failures systematically before edits.

## Task 3: Local Parquet convenience API

Files: new private `lib/duckdb/parquet.{mli,ml}`; modify public exports and library Dune file; new `test/test_parquet.ml`.

Public shape: abstract validated exact local `Parquet.path`; constructor rejects empty/NUL/URI/glob paths; read one or multiple paths through `fold_rows` using existing Row decoders and their borrowed chunk traversal; export single query to exact path with no implicit overwrite. No remote/extension management or generic options surface.

- [x] Write .mli and failing temporary-directory roundtrip test before implementation.
- [x] Probe COPY parameter binding and prepared-query metadata. Require explicit conversion/reject writer-normalized representations; never claim timestamp-second or infinity fidelity without evidence.
- [x] Implement internally constructed read_parquet SQL with bound path list or escaped literals, deliberate exact filename semantics; reuse borrowed traversal and cleanup.
- [x] Export through COPY to an exclusively reserved same-parent temporary file, publish only without replacement, remove only owned temporary output on every tested failure. Disclose nontransactional filesystem effects and publication/interruption uncertainty.
- [x] Test one/multiple/empty/missing/corrupt files, schema mismatch, NULL and exact scalar/temporal fidelity, quote/space/injection-like names, NUL/URI/glob rejection, preservation of existing targets and failed-export cleanup.

## Task 4: Regression, evidence and coherent commit

Files: `examples/synchronous.ml`, `docs/stage3c-validation.md`, test/Dune/install smoke only where required for new APIs.

- [x] Extend example with isolated temporary paths, appender and typed Parquet roundtrip.
- [x] Run `stage1/run build @all`, `stage1/run runtest --force`, `bash test/install_smoke.sh`, both Python unittest suites, and example.
- [x] Run authored-C ASan/UBSan with `detect_leaks=0`, source-specific native warnings-as-errors, new boundary/race repetitions, existing compile-negative controls; record exact limitations.
- [x] Update checkbox progress and final validation document truthfully. Confirm unrelated formatting byte-for-byte unchanged, no staged files.
- [x] Commit only coherent stage3c changes using jj; save ignored `.local/stage3c-review.diff` from `2892e0f5584c582faacfaff3603ec4ec9086f16b` to final implementation commit, excluding unrelated formatting. Independent review is the next gate after the implementation handoff.

## Completion notes

Implemented and checked in the original run, with one same-protocol resume after
a provider failure. No dependency/toolchain/provider-mode change was used to
resume. The final runtime report records the selective commit and review diff.

The minimal Parquet surface exports `fold_rows`; it reuses Query's borrowed
chunks rather than duplicating a dedicated chunk owner. Production COPY uses a
reserved same-parent temporary file and no-replace hard link, not a temporary
directory. Tests use isolated directories; hostile-directory/crash-durability
guarantees are explicitly excluded. These are recorded implementation
refinements, not atomic filesystem/transaction promises.

Resume inspection added a test-first correction: a relative path under a current
directory containing glob characters must also be rejected. Validation now
checks the fully resolved absolute path. `resume-path-red.txt` and
`resume-path-green.txt` retain the actual failing/passing test outputs. See
`docs/stage3c-validation.md` for completed APIs, tests, source evidence, exact
commands, known limitations, and remaining stage4 obligations.
