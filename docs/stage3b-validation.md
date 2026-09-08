# Stage 3b: prepared statements, typed decoding and scoped chunks

Validated 2026-09-08, x86-64 Linux/glibc, against reviewed stage3a
`cb310c6623b8320327370f925ccf1619f9b557ea`. **Implementation checks pass;
independent review required.** This is stage 3b, not completion of stage 3,
Parquet/appender, adapters, cancellation or the project.

Plan: [stage3b execution plan](superpowers/plans/2026-09-08-stage3b-prepared.md),
written before implementation. Public contract:
[`lib/duckdb/duckdb.mli`](../lib/duckdb/duckdb.mli). Raw command output is retained
in ignored `.local/logs/stage3b/`.

## API and ownership contract

New abstract `prepared`, `query_result` and local `chunk` capabilities:

- `prepare` / `prepare_transaction`, their scoped forms, `parameter_count`,
  typed `bind`, `reset`, `execute_prepared`, `close_prepared`, `close_result`.
- `Scalar.t` witnesses, `Required` / `Nullable` fields, and an explicit owned
  `Row.t` decoder (`Empty`, `Column`, `Map`). This validates arbitrary SQL at
  runtime; it is not a SQL DSL, ORM or compile-time SQL/schema proof.
- `fold_chunks`, range/type-checked `column`, `chunk_length`, and `fold_rows`.
  An admitted fold consumes/closes the result on exhaustion, Stop, error,
  exception or effect denial. Busy admission does **not** consume it.
- `Data_error` wraps named range, type/schema, NULL, index, column-count and
  unbound-parameter errors. Schema diagnostics contain the expected type name,
  actual DuckDB public type ID and index. NULL errors identify zero-based column
  and chunk-relative row. Native errors retain the existing 511-byte text limit.

| State/operation | Rule |
| --- | --- |
| Prepared without a result | Retained connection child; other ordinary work may run between admitted operations |
| Bind | One-based index; all parameters must be bound before execute; rebind permitted |
| Known parameter type | Exact engine type required; no implicit integer/float/temporal coercion |
| Unresolved parameter | INVALID/ANY at prepare accepts the supplied witness; reset/rebind can change it |
| Binding persistence | Successful execution retains bindings; reset clears all |
| Invalid index/type/range | Previous binding unchanged (validation precedes mutation) |
| Native failed/interrupted bind | Affected parameter marked unbound; engine may retain its old binding but it cannot be executed through this API |
| Failed/interrupted reset | All parameters marked unbound |
| Live result | Exclusively reserves the connection until closed; unrelated execute/prepare/transaction admission is Busy |
| Reset/reexecute/close owning prepared with live result | Live_children (Busy while an operation/callback is admitted) |
| Manual close during operation | Busy, never waits on its own callback |
| Repeated completed close | Ok; operations on closed/revoked aliases return Closed |
| Manual connection close with prepared children | Live_children, or Busy for an operation/transaction/result lease |
| Scoped prepared/parent close | Revoke, drain admitted operations/foreign transaction lease, then destroy children before parent |
| Transaction-owned prepared/result | Revoked and destroyed before transaction settlement; cannot escape as usable capabilities |
| Prepared from original connection during transaction | Busy; cannot bypass the token lease |

Metadata mutexes protect short admission/state transitions, **not** DuckDB calls
or arbitrary callbacks. One admitted operation covers the whole borrowed fold,
including each user callback. Reentrant and concurrent aliases therefore fail
fast rather than destroying/resetting/fetching under a live view. Scoped cleanup
is private, so a callback cannot invoke the blocking close of its own scope.
A sibling's scoped close cannot clear another result's reservation: release
checks identity. Prepared scope cleanup also respects an unrelated transaction
lease, including BEGIN/settlement where stage3a deliberately uses the lease
rather than the ordinary busy flag.

Stage3a lifecycle code moved to private `Resource` only to share this admission
and child-retention seam with private `Query`. Typed conversion, row specification
and borrowed reads are separate small modules. Native code is split into
`resource_stubs.c`, `prepared_stubs.c`, `typed_stubs.c` and private
`query_native.h`; there is no new monolithic C implementation. The safe package
contains no casts or pointer representations. Native prepared shells retain
reference-counted connection shells, which retain database shells independently
of OCaml finalizer order. Explicit safe parent lifetime still controls use.

Preparation uses DuckDB's **public extracted/prepared C API**, sharing the exact
stage3a engine statement allowlist. There is no SQL PREPARE/EXECUTE implementation
or new transaction-control bypass. Arbitrary SQL remains subject to engine
semantics, not a security sandbox. `duckdb_execute_prepared` produces a materialized
result; chunk traversal is not a promise of streaming SQL execution or bounded
whole-query memory.

## Widths, temporal units, NULL and owned values

| Witness | Owned representation and conversion |
| --- | --- |
| Bool | bool |
| Int8 / Int16 | int; binding validates [-128,127] / [-32768,32767] |
| Int32 / Int64 | int32 / int64, native signed widths preserved |
| Float32 | float containing exactly widened binary32; binding rejects implicit finite rounding |
| Float64 | float, native double |
| String / Blob | immutable owned string, explicit byte lengths; embedded NUL preserved |
| Date | int32 native signed days since 1970-01-01 |
| Timestamp_s/ms/us/ns | int64 native ticks since epoch, timezone-free, distinct witnesses |
| Timestamp_tz | int64 microseconds, UTC instant; original timezone identity is not retained |

No float-based temporal conversion, calendar conversion or implicit change of
units occurs. Native extrema/infinity sentinels roundtrip without normalization.
Tests independently check SQL literals for -1 day, 1 second, 1001 milliseconds,
-1 microsecond, 1000000001 nanoseconds and a +01:00 timestamp representing epoch
UTC. Wrong timestamp units are schema/binding errors, not rescaled values.

`Scalar.round_float32` is the explicitly named native binary32 rounding operation.
`Scalar.validate Float32` accepts only a finite value that roundtrips exactly
through that conversion, plus infinities/NaN; signed zero survives. NaN payload
preservation is not claimed. Float32 result widening to float is exact. Integer
result conversion reads the schema-validated physical width; it does not read
HUGEINT/unsigned/decimal as a signed integer. Unsupported types (including lists,
TIME and decimal) return Type_mismatch, including for empty owned-row queries.

Nullable fields return options; Required rejects an actual NULL cell. DuckDB's
arbitrary-SQL result metadata does not prove non-nullability, so a Required field
with matching type and **no rows** is accepted. Bare `SELECT NULL` is materialized
as INTEGER by pinned DuckDB 1.5.5, not logical SQLNULL: use Nullable Int32 or an
explicit SQL cast. Tests verify this actual engine schema; no invented coercion
of unknown NULL schemas was added.

`fold_rows` validates the entire decoder's column count and exact types **before
fetching**, including empty results. `column` checks its own column/type and row
on every access. An unaccessed unsupported column can be discarded with
`fold_chunks`; that function has no requested schema. Returned scalar values,
strings/blobs, row products and user-mapped rows are owned and survive scope.

Borrowed reads access actual `duckdb_vector_get_data` / validity storage.
Validity NULL means all valid; bitmaps are checked before reading a nullable
slot. The native integer accessor returns `int64_t` through the compiled
`int64#` ABI and boxes an owned scalar only afterwards. No foreign buffer is cast
to a managed array, and no allocation-free, zero-copy-result or speed claim is
made. The borrowed capability itself does not own/destroy native memory.

## Static versus dynamic safety and exact-runtime limits

The chunk is a stack-allocated local record exposing no owner or transition.
Seven source-named compile-negative fixtures reject returning/storing/capturing
a chunk, domain escape, capturing it in an inner handler computation, passing it
to result close, and passing it to prepared reset. Diagnostics require actual
local/global or abstract-type mismatches, not filenames/nonzero exit alone.
Paired controls compile ordinary local aliases, owned returns/domain transfer
and a captured result alias (which is dynamically Busy inside the callback).
All earlier stage1/2/3a compile suites remain unchanged and pass.

The stage2 no-escape deep effect barrier is reused **inside** the inner
`Sys.with_async_exns`. It discontinues outward effects, remembers caught denials,
preserves independent exceptions/composite cleanup exceptions, and never hands
the borrowed continuation to an outer scheduler. Inner handled computations not
capturing the chunk can succeed; this is not global effect purity. The API is
synchronous and does not support scheduler-yielding borrowed callbacks.

Stable native shells own SQL and string/blob copies before runtime release;
all scalar arguments and native handles are extracted while locked. Native
prepared/result/chunk ownership is stored in the shell before reacquisition.
Every unlocked prepared/bind/reset/execute/fetch/destruction wrapper explicitly
processes pending actions **after reacquisition**, while the caller's inner
async boundary remains active. Locked nonallocating completion frees any
remaining resources after interrupted destruction entry. This exceptional
fallback can block the runtime; it is not adapter responsiveness evidence.

The exact runtime findings in [stage2](stage2-validation.md) and
[stage3a](stage3a-validation.md) remain limits, not universal interruption safety:
pending handlers can raise before release; reacquisition only marks them pending;
`Sys.with_async_exns` converts asynchronous Break at its boundary. A new mutation
removing just prepared-close pending-action delivery fails the prepared-revoked
assertion after close-reacquire; removing just its inner async boundary also
fails. Restoring each passes. Ordinary protect alone is insufficient.

Twenty-five real SIGUSR1/Sys.Break cases cover prepare, string bind, integer bind,
float bind, NULL bind, reset, execute, first/next fetch, result close, prepared
close, live-chunk cleanup entry/reacquisition, and a live callback. Tests check
exact native live counts at injection, one injection/handler, zero binding
resources and zero finalizer fallback reclaims **without GC**. Close tests catch
the Break and verify revocation/result release plus connection reuse before
propagating it. Representative snapshots: prepare 6/6, string bind 7/6,
execute 6/7, first fetch 7/8, next fetch 8/8, result close 7/6, prepared close
6/5, live chunk close 8/6, callback 8. Integer/float/NULL bind and reset are 6/6.

These are targeted single-signal, single-OCaml-thread transition tests.
Acquisition/protection setup gaps, arbitrary metadata/bookkeeping interruption,
repeated signals, concurrent signal routing, OOM/fault exhaustion and process
termination remain unproved. Finalization is eventual only. Draining has no
time bound if work/callbacks never finish. Interruption does not prove writes
did not commit; original transaction outcome/rollback guarantees are preserved.
No portable/domain-safe resource-handle, cancellation or adapter claim follows.

## Test-first failures and debugging evidence

All commands are from repository root using the existing `stage1/run` pins.

| Cycle | Red / diagnosis | Green |
| --- | --- | --- |
| `.mli` plus tests before implementation | `scalar-red.txt`, `query-red.txt`: missing implementations | scalar and query executables compile/run |
| Exact compiler refinements | warning-50 documentation placement; GADT or-patterns do not refine; local tail call/recursive closure needed explicit local argument | `build-fifth.txt` and final full build exit 0 |
| Domain negative fixture | First fixture rejected nonportable accessor, not local chunk | fixture returning chunk specifically rejects highlighted local chunk; paired owned control passes |
| NULL schema assumption | `sqlnull-diagnosis.txt`: expected BIGINT, actual 4 (INTEGER) | `null-schema-green.txt`; engine-inferred schema retained, speculative SQLNULL branch removed |
| Sibling close reservation | Reintroduce unconditional result release: `sibling-lease-mutation-red.txt`, exit 2 | identity-aware release, restored test exit 0 |
| Scoped close versus transaction | Omit lease wait: `scoped-lease-mutation-red.txt`, exit 2 | wait for foreign/revoked token lease; restored exit 0 |
| Thread test oracle | Initial exploratory worker exception was printed but Thread.join still exited 0 | all concurrency workers transport exceptions back to join; mutation now exits 2 |
| Inner async close boundary | `inner-async-mutation-red.txt`, exit 2 | restored close/reuse checks pass |
| Reacquire pending actions | `pending-action-mutation.txt`, exit 2: interrupted close did not revoke prepared | `async-pending-restored.txt`, exit 0 |
| Installed private modules | external build directory causes actual Dune internal exception | supported source-relative direct-child build directory installs with internals hidden |

Runtime tests cover every supported scalar and NULL at boundaries, explicit
Float32 policy, embedded NUL and long strings/blobs, parameter index/count/
unbound/rebind/reset, dynamic parameter types, prepare/execution failures and
reuse, empty/multichunk results, unsupported/incorrect schema, manual/scoped
parent-child closure, retained transaction aliases, early stop/error/ordinary
exception/Break, effect unwind/catch-reperform/inner handling, owned copies after
scope and domain transfer. Injected native bind/fetch failures exercise cleanup
and statement recovery (test-only wrappers, not engine allocation-fault proof).

Concurrency tests use handshakes, not elapsed-time assumptions: native execute,
fetch, prepare extraction and length-aware string binding pause while another
thread proves Busy admission and runs compaction. Dynamic 100KB SQL and 200KB
embedded-NUL binding survive that GC pressure. A live borrowed callback joins a
thread attempting close/reset/fetch, demonstrating no callback-held metadata
mutex. Scoped prepared and transaction cleanup wait for actual condition-wait
entry before the admitted fetch is released. Worker exceptions are propagated.

## Installation blocker, minimized and resolved under the same pins

With supervisor approval, minimized the real Dune failure in ignored
`.local/stage3b-dune-repro/`: one public library, one private module, ordinary
`.mli` files. `stage1/run build --root .local/stage3b-dune-repro --build-dir
/tmp/stage3b-dune-repro-external @install` succeeds, but its matching `install`
fails (`dune-private-repro-external.txt`). The same build/install with default
`_build` or relative `.custom-build` succeeds (`dune-private-repro-relative.txt`,
`dune-private-repro-custom.txt`).

Read exact installed Dune source, not upstream HEAD:
`_opam/.opam-switch/sources/dune.3.22.2+ox/src/dune_rules/obj_dir.ml:101–107`
encodes private_dir with `Path.descendant |> Option.value_exn`;
`otherlibs/stdune/src/path.ml:539–547` returns None for External paths.
`bin/install_uninstall.ml:269–294` parses/re-encodes package metadata at install.
Thus this is an external-build-layout limitation, not a reason to expose private
modules, change the compiler or hand-edit metadata. A nested relative build
path is separately rejected by this Dune; the supported workaround is a direct
child. `test/install_smoke.sh` creates/removes ignored `.install-smoke.XXXXXX`
for the safe build and preserves independent installed FFI resolution.

Final install smoke builds/installs FFI alone and runs its independent prepared/
int64# consumer; builds safe against that installed FFI with source FFI excluded;
runs the typed prepared transaction/Row example from a different directory and
native prefix; and verifies an external reference to
`Duckdb__Resource.native_connection` fails with **Unbound module**. Public
Scalar/Row constructors work. Scheduler-free META dependencies and relocated
native loader/no embedded rpath checks pass. No generated metadata was edited.

## Exact final commands and limitations

```sh
stage1/run build @all
stage1/run runtest --force
bash test/install_smoke.sh
stage1/run exec examples/synchronous.exe
python3 -m unittest discover -s stage1 -p 'test_*.py' -v
python3 -m unittest discover -s test -p 'test_*.py' -v
# Historical profile name, same authored-C instrumentation; no toolchain change:
ASAN_OPTIONS=detect_leaks=0:halt_on_error=1 UBSAN_OPTIONS=halt_on_error=1 \
  timeout 120 stage1/run exec --profile stage3a-sanitize \
    --build-dir "$PWD/.local/build-stage3b-sanitize" test/test_query.exe
# Same command for test/test_query_concurrency.exe.
clang -std=c11 -Wall -Wextra -Werror -fsyntax-only \
  -I.deps/duckdb -I_opam/lib/ocaml lib/ffi/resource_stubs.c \
  lib/ffi/prepared_stubs.c lib/ffi/typed_stubs.c \
  test/query_hooks.c test/query_signal_stubs.c
# Each of those five authored C translation units:
clangd --check=lib/ffi/prepared_stubs.c --compile-commands-dir=.local --tweaks=
# Each of the 25 signal modes, five repetitions; e.g.:
timeout 30 stage1/run exec --no-build test/test_query_signals.exe -- prepare-enter
# test_query.exe and test_query_concurrency.exe each repeated five times.
```

- Final full build/runtest, installed consumers, example and native diagnostics
  pass. Both Python suites pass: 8 bootstrap and 2 native setup tests.
- **125 counted new signal runs + 5 typed/lifecycle + 5 concurrency/fault/drain/GC
  runs pass**, `repeated.txt`. Added negative-index/cross-unit assertions also
  pass in `final-boundary-tests.txt`; final full suite is rerun after edits.
- ASan/UBSan with leak detection disabled passes on the actual authored FFI C
  stubs plus query hooks. It does not instrument the prebuilt engine, compiler
  runtime or Base. All five clangd diagnostic-only checks report 0 errors; C
  warnings-as-errors syntax checks pass. Only ignored compilation database/logs
  were updated.
- **Whole-process LSan is not a pass.** An exploratory `detect_leaks=1` run exits
  1 and reports **1,924 bytes in 84 allocations**, naming runtime mutex/condition,
  bigarray/thread and Basement allocation sites (`whole-process-lsan.txt`). No
  reported allocation stack names authored binding code. These reports are not
  suppressed. Binding-native counters and zero fallback counts are a narrower
  ownership oracle, not a leak-free process/engine guarantee.
- Intermediate zero-sized chunks, failed native connection/prepared allocation,
  memory exhaustion and arbitrary repeated asynchronous interruption are not
  fault-injected. The fetch-failure wrapper explicitly supplies a test error;
  ordinary materialized-result queries did not produce a natural fetch failure.
- Ambient OCaml LSP remains **unavailable**, not passed: it reports compiler
  mismatch, unknown `-extension-universe`, and rejects valid local/int64# syntax.
  Standalone/external compile fixtures also lack ambient editor configuration.
  Exact compiler builds and source-specific negative diagnostics are the oracle;
  no shared/editor settings or valid OxCaml source were changed to appease it.
- Opam solver/actual `opam install` was not run. Existing unresolved publication
  metadata/license is unchanged; Dune installation is not an opam-install claim.

Rechecked pins (`pins.txt`): compiler `5.2.0+ox`, package
`oxcaml-compiler.5.2.0minus39`, revision
`2515546fea38e21e8143cc41db663bd56efc8d06`; Dune `3.22.2` / `3.22.2+ox`;
Base `v0.18~preview.130.106+341`; jj `0.42.0`; GCC `16.1.1 20260625`.
Header/library SHA256 remain
`48e716b9ce96ca8fead9cb35693fdc0343ac0fc1f6e7db5561fa0f44b674153d` and
`fc23f12e376c47be520f75221288281906e7942e8fd6f6ce4849198ba60d0405`.
No dependency reinstall, raw Git, sudo, global/shared/editor change or remote
publication occurred. The five pre-existing formatting changes are preserved
and excluded from implementation commits. No files were staged (jj workflow).

## Stage 3c contract and review checkpoint

Next slice: appender plus dedicated typed **local** Parquet read/export, using
the existing resource/transaction admission rules and typed conversion policy.
New children must preserve close/revocation/drain order and result reservations;
do not bypass the prepared engine statement policy or expose native seams.
Keep the local borrowed view/no-escape barrier and compile-negative controls.
No remote storage, adapters, pools or cancellation implementation is included.
Adapters remain stage4 and must independently prove operation identity,
interruption locking, completion-before-reuse, scheduling and shutdown.

The runtime handoff records immutable jj commit IDs and the ignored
`.local/stage3b-review.diff` from `cb310c66` to the final implementation commit,
excluding unrelated formatting. Independent review remains required.
