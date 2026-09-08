# Stage 3c: appender ingestion and typed local Parquet

Validated 2026-09-08 on the existing x86-64 Linux/glibc toolchain, from reviewed
`2892e0f5584c582faacfaff3603ec4ec9086f16b`. **Implementation checks pass;
independent review required.** This completes this synchronous slice, not the
adapters, cancellation, benchmarks, publication or overall project.

Plan: [stage3c execution plan](superpowers/plans/2026-09-08-stage3c-ingestion-parquet.md),
written before interfaces/implementation. Public API: `lib/duckdb/duckdb.mli`.
Raw outputs and probes are ignored under `.local/logs/stage3c/` and
`.local/stage3c/`. Earlier stage1/2/3a/3b guarantees and limitations still apply.

## Appender API and settlement

- Abstract `appender`, `Cell : 'a Scalar.field * 'a -> cell` complete owned cells.
  `append_rows` accepts a list of complete rows, not a reversed `Row.Map` decoder.
- `open_appender` takes a **transaction**, optional schema (default `main`), and
  table name. `with_appender_transaction` scopes that child without settling the
  caller's transaction. `with_appender` on a connection owns the complete
  BEGIN/callback/close/COMMIT or rollback lifecycle.
- `flush_appender` flushes buffered data **into the transaction**, not a commit.
  `close_appender` flushes only a healthy owner, then clears and destroys it.
  Completed repeated close succeeds; subsequent operations return `Closed`.
- One safe admission and one unlocked native call cover a **whole batch**. All
  rows are shape/type/range/NULL-checked and encoded before that call. The C shell
  copies the batch and string/blob bytes before runtime release. Native code
  uses actual `duckdb_appender_create_ext`, `duckdb_append_value`, begin/end-row,
  flush, close, clear and destroy APIs; it does not implement repeated INSERTs.
- Exact engine column types and table NOT NULL metadata are checked before any
  partial native row mutation. Required fields cannot encode NULL; Nullable
  fields can, but NOT NULL tables reject those cells before entering C. Failed
  shape/type/range/NULL validation poisons the whole appender transaction,
  including prior successful batches. There is no implicit narrowing or unit
  conversion and no partially entered row exposed to callers.

| State or outcome | Contract |
| --- | --- |
| Live appender | Retained transaction-owned child, exclusively reserves connection until close; same-token SQL/prepared operations and ordinary aliases are Busy |
| Manual connection close while appender lives | Busy under the transaction lease; never waits on callback |
| Concurrent append/flush/close | Fail-fast Busy; one native admission at a time |
| Native append/automatic flush failure | First error retained; owner poisoned, no further append/flush permitted, transaction cannot commit even if caller ignores the error |
| Explicit flush or successful close | Data remains uncommitted until caller's transaction settlement |
| Poisoned close/destruction | Clear buffered data before destroy; never retry a failed flush implicitly |
| Unclosed manual child at transaction exit | Revoke/drain, discard its buffer, poison transaction and roll back |
| Callback error/exception/effect denial | Poison settlement, including after manual close and when a caller catches/ignores the scope failure |
| Scope exits with unjoined admitted work | Drain before destruction. An implicit close encountering Busy returns an error and rolls back, not an implicit successful commit |
| Rollback failure | Preserve original plus rollback error using existing composites, discard connection; never reuse unknown transaction state |
| Break after COMMIT | May follow committed writes. New observer test sees one appender row after commit-reacquire Break and verifies original connection discarded |

The minimal API appends all physical columns in order. It does not expose
per-cell mutation, defaults, selected-column mutation, arbitrary appender SQL or
an autocommit raw appender. The table is in the current database; schema/table
names use stored catalog spelling and are bound as data, not interpolated SQL.
Generated-column tables and metadata spanning more than one native metadata
chunk are explicitly rejected rather than confusing logical/physical positions.
These are conservative initial coverage limits, not unsupported-type coercions.

All Scalar representations tested in stage3b also roundtrip through the actual
appender: bool, Int8/16/32/64, Float32/64, VARCHAR/BLOB, Date, Timestamp_s/ms/us/ns
and Timestamp_tz, nullable values, signed extrema/native infinity sentinels,
negative ticks and dates, exact BIGINT `9007199254740993`, signed zero, NaN and
infinities. String/blob tests include embedded NUL, non-UTF8 blob bytes and long
owned copies. Finite Float32 values must already be exactly representable;
`Scalar.round_float32` remains explicit opt-in rounding. NaN payload preservation
and throughput/zero-copy/allocation-free claims are not made.

## Why the appender owns a snapshot and why clear precedes destroy

Read immutable DuckDB v1.5.5 source revision
`d8cdaa33fda8df955cc76ef58a280f68f4cd43fa`, matching the previously verified pinned
library source ID. Downloads are read-only evidence, not copied engine code:

- `src/main/capi/appender-c.cpp`: `duckdb_appender_destroy` calls close before
  deleting the wrapper; clear invokes `BaseAppender::Clear`.
- `src/main/appender.cpp:45–55,568–569,744–758`: C++ destruction can close again
  and swallows exceptions; Close can flush, while Clear resets the chunk,
  collection and partial-column position. We explicitly clear before destruction
  even following successful close, and always before discarding failed data.
- `appender.cpp:71–82,393–418,760–782`: end-row can flush a chunk and trigger an
  automatic flush; a returned append error is not necessarily a per-cell error.
  Tests distinguish successful buffered append followed by explicit constraint
  failure from a 220,000-row duplicate batch failing during automatic flush.
- `appender.cpp:497–507,606–620`: Appender retains a table description, builds an
  internal INSERT from its buffered typed collection, and executes at flush.
  It is **not** safe to cache the original types across unrelated autocommit DDL.
  Existing stage3b catalog/transaction-source evidence still establishes the
  explicit connection snapshot used by metadata, creation and flush.

`schema-native.txt` demonstrates the need using public C APIs: create a BIGINT
appender, ALTER to DOUBLE on another connection, append `9007199254740993`, then
flush. Without a transaction it succeeds and stores **9007199254740992**. With
an explicit transaction it fails and rollback leaves zero rows. The safe API
never exposes the former path. Ten handshake races cover the point after
metadata/before create, native append, explicit flush, close, and before COMMIT,
with both connection-owned and explicit-transaction scopes. Each concurrent
ALTER is rejected by engine transaction conflict rather than storing rounded
data; observer connection sees zero rows. Same-connection DDL cannot run while
the appender reserves admission. No global/database-wide mutex is added.

Source SHA256:

- `appender.cpp`: `9c6d9c0198539da598055f0a052e4266474e76c93f9cf73631d21d4bffeb003b`
- `appender-c.cpp`: `602bc7ae6856310f4f13c2031553306cf0ffd5c1d75f74ca2c003a77e25f170d`

## Dedicated local Parquet API

`Parquet.path`, `Parquet.fold_rows`, `Parquet.export` are scheduler-free public
conveniences; callers do not write read_parquet/COPY SQL.

- `path` is abstract and validates an exact filename: nonempty, NUL/colon/
  backslash/glob-free. Relative paths become absolute at construction; the
  restrictions also apply to characters contributed by the current directory. No URI,
  remote/S3/HTTPS support, glob expansion, tilde expansion, credentials or
  extension download management. Legal Unix filenames containing the rejected
  characters are deliberately outside this initial exact-path API.
- `fold_rows` takes one or multiple paths, reusing the existing Row decoder,
  materialized Query result and borrowed chunk traversal. Each file is opened
  and schema-checked separately, including empty files. This avoids DuckDB's
  cross-file union/type coercion. An empty list is an error; Stop stops the whole
  list. Earlier callbacks may have run before a later corrupt/mismatched file
  fails. This is not a multi-file filesystem snapshot or streaming-query claim.
- `export` independently engine-prepares one parameter-free SELECT and checks
  its output types; it does not execute that SELECT just to check types. It then
  engine-prepares the constructed single COPY, binding the destination path as
  a parameter. Source and COPY share an explicit transaction snapshot. No
  lexical SQL classifier or security-sandbox claim is made. Omit the source
  statement's trailing semicolon; trailing line comments are safely separated
  from the wrapper by a newline. Arbitrary input SQL retains engine semantics.
- No public identifier/path/options string is concatenated unchecked. Read
  filenames are SQL literal escaped; COPY destination is bound. There is no
  untyped options surface. The engine's default Parquet writer is used.

### Exact representation policy

Parquet roundtrip tests preserve nullable bool, Int8/16/32/64, Float32/64,
String/Blob, Date, Timestamp_us/ns/tz, including signed extrema/infinity sentinels,
NUL/binary data, Float32 widened exact values and negative/nonintegral-second
native ticks. Date and timestamp extrema were tested, not inferred from formats.
The pinned writer/reader returns **Timestamp_s and Timestamp_ms as Timestamp_us**;
export rejects those source schemas with `Unsupported_parquet_type {column;
actual}` before creating output. Explicit SQL conversion opts into conversion.
Other unsupported schemas, including HUGEINT/lists, are likewise rejected.
Reading requests must match the engine's actual schema; no unit rescaling is
hidden in Row decoding. NaN payload identity is not promised.

### Filesystem effects and no-overwrite policy

COPY writes a uniquely reserved same-parent temporary file. Only after successful
COPY is it hard-linked to the requested target **without replacement**. Existing
files, directories and dangling symlinks produce `Destination_exists`; tests
compare existing bytes and dangling-link contents. The owned temporary path is
removed on success and tested failures, using an unlocked rooted native unlink
helper; ENOENT is idempotent success for the single-Break cleanup retry.
Other cleanup failures remain exceptions/composites, not silent successes.

This is not a DuckDB/filesystem atomic transaction, fsync/crash-durability,
hostile-directory or rollback-of-COPY guarantee. Publication can have happened
before interruption or later transaction settlement failure. Real publish-leave
and post-publication cleanup Break tests preserve the final output while rolling
back/discarding database state appropriately. Only the owned temporary file is
removed: final output is never silently deleted after publication. Crashes,
process termination or interruption in acquisition/setup can leave temporary
files; arbitrary/repeated interruption remains unproved. No existing user file
is overwritten. Tests mutate only their own temporary directories/files.

## Native ownership, interruption and test-first debugging

New native shells retain parent connection shells independently of OCaml
finalization order. Safe parent retention/admission remains authoritative.
C-owned identifiers, schemas and complete batch copies stay stable across GC
and runtime release. New unlocked appender, publication and unlink calls all
explicitly process pending actions after reacquisition, inside an inner
`Sys.with_async_exns`. Native completion is idempotent and may block while holding
the runtime lock on exceptional fallback. This is not adapter responsiveness.
The existing deep no-escape barrier, transaction revocation and local chunk
interfaces/negative controls are retained, not replaced.

| Red/diagnosis | Correction/green |
| --- | --- |
| `appender-red.txt`, `parquet-red.txt`: interfaces/tests without implementations | Actual engine ingestion and BIGINT export/read compile/run |
| `signals-first.txt`: discard-enter SIGSEGV; `discard-gdb.txt` pinpoints status access after finished shell | Resource retries cleanup after one Break; appender destruction now tests shell completion before status read. All discard-enter/leave cases pass without GC |
| `closed-scope-red.txt`: manually close, throw/catch outside scope, then ignored failure commits | Scope-level result/exception poisoning includes post-work effect denial and closed children; `closed-scope-green.txt` verifies rollback |
| `remove-red.txt`: native removal interface absent | Rooted unlocked idempotent removal; success/failure cleanup entry/reacquire Break cases pass |
| Native probe autocommit rounds BIGINT after concurrent ALTER | Transaction-owned safe API and ten real DDL races reject/no insert |
| Exact compiler errors: Base Exit deprecation, test parentheses, ambiguous warning-50 doc placement | Fixed actual pinned diagnostics; final authored development warnings-as-errors pass |
| `resume-path-red.txt`: relative filename under a glob-containing current directory bypassed validation | Validate the complete absolute path after resolution; `resume-path-green.txt` passes |
| COPY signal oracle initially omitted prepared native handle | Source-accounted enter/leave counts corrected from 5/6 to 6/7; assertions retain exact counts |

Twenty-one new real SIGUSR1/Sys.Break cases assert one injection/handler, expected
live counts at injection, zero live binding resources and zero fallback reclaims
**without GC**. Appender counters include shell, engine appender, retained name/
schema arrays and copied batch storage; file helpers count shell and path copies.
Representative enter/leave counts: create **7/10**, string batch **12/10**, flush
**10/10**, close/discard **10/9**, COMMIT **5/4**, COPY execute **6/7**, publication
**7/7**, removal **6/6**. Removal is tested after both successful publication and
failed COPY, preserving composite original errors. A live callback is **10**.
These are targeted single-thread, single-signal transition guarantees, not
arbitrary asynchronous-exception, OOM or concurrent signal-routing proofs.

Tests additionally cover 220,000-row/empty/multiple batches, invalid row shape,
width/range/Float32/NULL validation, explicit/automatic flush constraints,
first-error poisoning, scoped/manual aliases, unclosed child rollback, success
and explicit rollback, callback exceptions/effects after close, native rollback
fault with original error retained and connection discarded, unlocked compaction
under dynamic large-string input, Busy admission, actual condition-wait draining,
quote/space/injection-like identifiers/paths, missing/corrupt/empty files, early
Stop, multi-file schema mismatch without coercion and failed-export cleanup.
Worker exceptions are transported through join; handshakes do not assume elapsed
time. Three new standalone compiler controls reject connection-as-transaction,
appender-as-connection and chunk-as-appender with specific abstract-type
mismatches; positive typed cells/owners compile. All prior local-mode suites pass.

## Final commands and limitations

All project commands use the existing `stage1/run`; no dependency reinstall,
shared/editor/opam configuration change, sudo, raw Git or remote publication.

```sh
stage1/run build @all
stage1/run runtest --force
bash test/install_smoke.sh
stage1/run exec examples/synchronous.exe
python3 -m unittest discover -s stage1 -p 'test_*.py' -v
python3 -m unittest discover -s test -p 'test_*.py' -v
# Each of test_appender, test_appender_concurrency, test_parquet:
ASAN_OPTIONS=detect_leaks=0:halt_on_error=1 UBSAN_OPTIONS=halt_on_error=1 \
  timeout 120 stage1/run exec --profile stage3a-sanitize \
  --build-dir "$PWD/.local/build-stage3c-sanitize" test/test_appender.exe
# Same profile, all 21 modes of test/test_stage3c_signals.exe, 30-second timeout.
# Normal --no-build: each of the three executables and all 21 signal modes,
# five repetitions, 45-second executable / 30-second signal timeout.
clang -std=c11 -Wall -Wextra -Werror -fsyntax-only \
  -I.deps/duckdb -I_opam/lib/ocaml \
  lib/ffi/{appender_stubs,local_file_stubs,prepared_stubs}.c \
  test/{appender_hooks,stage3c_signal_stubs}.c
# Each of those five files:
clangd --check=lib/ffi/appender_stubs.c \
  --compile-commands-dir=.local/stage3c --tweaks=
cc -Wall -Wextra -Werror -I.deps/duckdb .local/stage3c/schema.c \
  -L.deps/duckdb -lduckdb -o .local/stage3c/schema
LD_LIBRARY_PATH="$PWD/.deps/duckdb" .local/stage3c/schema
```

- Full build and stage1/2/3a/3b/3c runtest pass (`build-final.txt`,
  `runtest-final.txt`). Python suites: **8 + 2 tests OK**.
- Installed consumer runs the extended prepared/appender/Parquet example from
  outside the source tree against separately installed packages and relocated
  native library. Private Resource remains unbound; FFI dependency list empty,
  safe META still `base duckdb-ffi threads`, no Async/Eio startup/dependency.
  Existing source-relative direct-child install workaround is unchanged.
- Authored-C ASan/UBSan with leak detection disabled passes for three main new
  executables and all **21** new signal modes. Five normal repetitions add
  **105 counted signal checks, 50 DDL races and 15 runtime suite runs**, including
  five rollback-fault/drain tests. C warnings-as-errors passes; all five
  diagnostic-only clangd checks report **0 errors**.
- **Whole-process LSan does not pass.** The new exploratory Parquet run with
  `detect_leaks=1` exits **1**, reporting **1,296 bytes in 56 allocations** in
  runtime mutex/condition/thread/bigarray and Basement allocation sites
  (`whole-process-lsan.txt`). No reported allocation stack names authored
  binding code. This is not suppressed or described as a leak-free process.
  Instrumentation does not cover the prebuilt engine, runtime or Base.
- **Ambient OCaml LSP remains unavailable**, not passed. It reports incompatible
  compiler/extension/local-syntax diagnostics and lacks config for deliberately
  standalone fixtures. The pinned compiler, independent interface controls and
  installed consumer builds are the source oracle; valid OxCaml source and user
  editor/shared configuration were not altered to appease incompatible tooling.
- OOM/native allocation exhaustion, arbitrary/repeated signals, metadata-lock
  handoff interruption, acquisition/protection setup gaps, hostile filesystem
  races, process crashes and foreign callbacks that never finish remain unproved.
  Draining has no deadline. Finalizers are eventual backstops only.
- Dune install smoke is **not** an actual opam solver/install run. Missing
  maintainer/authors/homepage/license publication metadata remains unchanged;
  no attribution/license was invented. Only the stale package description was
  updated to describe the implemented synchronous features.

Rechecked pins (`pins.txt`): compiler `5.2.0+ox` /
`oxcaml-compiler.5.2.0minus39`, inherited exact source revision
`2515546fea38e21e8143cc41db663bd56efc8d06`; Dune `3.22.2` / `3.22.2+ox`, Base
`v0.18~preview.130.106+341`, jj `0.42.0`, GCC `16.1.1 20260625`. Header SHA256
`48e716b9ce96ca8fead9cb35693fdc0343ac0fc1f6e7db5561fa0f44b674153d` and library
`fc23f12e376c47be520f75221288281906e7942e8fd6f6ce4849198ba60d0405` are unchanged.
The six pre-existing formatting-only paths remain byte-identical to the saved
baseline diff and are excluded from implementation commits. No staging is used.
The runtime implementation report records the immutable jj commit and ignored
`.local/stage3c-review.diff` from the reviewed baseline.

## Stage 4 obligations

Async/Eio adapters remain separate optional packages. They must independently
prove bounded offload/pooling, lease ownership, operation identity and late
interrupt exclusion, independent interrupt locking, foreign completion before
reuse, clean-or-discard outcomes, queued/running/completion cancellation,
responsiveness (including blocking flush/destruction/file operations), shutdown
and scheduler error routing. Neither appender rollback nor Parquet cleanup makes
cancellation evidence that writes/files were never committed/published. No new
adapter, pool, cancellation or performance claim is made by this slice.

## Same-protocol completion resume

A provider failure interrupted the original implementation before its final
commit/report. On the user-authorized resume, the working diff, preserved
formatting and raw logs were inspected without restarting implementation or
changing provider/mode/toolchain. The only production correction in that resume
was validation of the fully resolved Parquet path, as recorded above. Fresh
`resume-build.txt`, `resume-runtest.txt`, `resume-install.txt`,
`resume-example.txt` and `resume-sanitize-parquet.txt` confirm the completed
revision after that change. Existing repetition/native-source/signal evidence
remains identified separately rather than claimed as newly rerun. Independent
review has not yet occurred.
