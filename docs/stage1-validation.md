# Stage 1 validation and FFI decision

Date: 2026-09-07 (UTC). **Stage-1 checks pass; ready for independent review.** This is a private compatibility experiment, not a safe/public DuckDB library. Stages 2–5 remain unimplemented.

## Upstream inspection and pins

The machine is Artix Linux x86-64, kernel `7.0.13-artix1-2`, glibc 2.43. Native tools: GCC `16.1.1 20260625`, CMake 4.3.4, opam 2.5.1, jj 0.42.0; autoconf, patch, rsync, bwrap, pkg-config and Clang are present. Ninja and Valgrind were not found. Approximately 27 GiB disk was initially available. An empty C program compiled with `cc -Wall -Wextra -Werror -fsanitize=address,undefined` and ran successfully. `bwrap --unshare-user --uid 0 --gid 0 --ro-bind / / --proc /proc --dev /dev true` exited 0. These diagnose host prerequisites, not DuckDB memory safety.

Read-only inspection of shared switch `5.2.0+ox` confirmed Base `v0.18~preview.130.83+317`, Dune `3.21.0+ox`, and no Async/Eio/Ctypes. It is not used as stage-1 build evidence. No shared switch or user configuration is changed by the bootstrap.

Sources inspected on 2026-09-07:

- [OxCaml setup](https://oxcaml.org/get-oxcaml/): still recommends switch name `5.2.0+ox`, glibc, x86-64/ARM64 and autoconf; documents `-extension-universe beta` for unstable extensions. Do **not** run the page's global `opam update --all` instructions in this project.
- [OxCaml repository snapshot](https://github.com/oxcaml/opam-repository/tree/bb4555262936283daf5cbc82423509d4e7069b15), [default repository snapshot](https://github.com/ocaml/opam-repository/tree/05a124531b858bfe809b43572a4df078761e83d3). Their SHA256-verified archives are pinned in `stage1/toolchain.lock.json`.
- [Compiler main observed](https://github.com/oxcaml/oxcaml/commit/06acfb1d1788d34618901097b66850fdc041a020), **not** the chosen build revision.
- [Chosen compiler package](https://github.com/oxcaml/opam-repository/blob/bb4555262936283daf5cbc82423509d4e7069b15/packages/oxcaml-compiler/oxcaml-compiler.5.2.0minus39/opam): `oxcaml-compiler.5.2.0minus39`, exact compiler [2515546fea38e21e8143cc41db663bd56efc8d06](https://github.com/oxcaml/oxcaml/commit/2515546fea38e21e8143cc41db663bd56efc8d06). Enables flambda2, runtime5, stack checks, poll insertion and multidomain. Its bootstrap uses OCaml 5.4.0, Dune 3.20.2 and Menhir 20231231 with checksums in pinned metadata. This does not mean the selected final compiler is upstream OCaml 5.4.
- [Async package](https://github.com/oxcaml/opam-repository/blob/bb4555262936283daf5cbc82423509d4e7069b15/packages/async/async.v0.18~preview.130.106%2B341/opam): latest available preview `v0.18~preview.130.106+341`, [source 5c1c47bb66487f536ff4c3927ffdb0448636bb48](https://github.com/janestreet/async/tree/5c1c47bb66487f536ff4c3927ffdb0448636bb48). Explicitly conflicts with OxCaml `<5.2.0minus39` **or** `>=5.4.0-ox1`. Therefore choose the non-avoid-version minus39 release, not the repository's newer avoid-version 5.4.0-ox2. Base is pinned to the same preview. Metadata compatibility is not compiled compatibility.
- [Eio OxCaml package](https://github.com/oxcaml/opam-repository/blob/bb4555262936283daf5cbc82423509d4e7069b15/packages/eio/eio.1.3%2Box/opam): `1.3+ox`, ISC, exact fork [7de26f5331f1e7aac1c086a5ebe849dd940b5c3e](https://github.com/oxcaml/eio/tree/7de26f5331f1e7aac1c086a5ebe849dd940b5c3e), requires OCaml >=5.2. Local metadata replaces the VCS transport for eio/eio_main/eio_linux/eio_posix with a SHA256-verified archive of the **same** commit. It does not patch library code.
- [Ctypes package](https://github.com/oxcaml/opam-repository/blob/bb4555262936283daf5cbc82423509d4e7069b15/packages/ctypes/ctypes.0.24.0%2Box/opam): `0.24.0+ox`, MIT, upstream 0.24.0 plus pinned `bigarray.patch`. [Dune package](https://github.com/oxcaml/opam-repository/blob/bb4555262936283daf5cbc82423509d4e7069b15/packages/dune/dune.3.22.2%2Box/opam): `3.22.2+ox`, upstream source hash `df26745e52be99ecdb2ff994feab1eacd858b226` plus pinned OxCaml patch.
- [DuckDB release v1.5.5](https://github.com/duckdb/duckdb/releases/tag/v1.5.5): project-local glibc `libduckdb-linux-amd64.zip`, SHA256 `1fb8ce388157d84a25abe685a8a2520bf00c00321821968e4bb398fd766e7abb`, matches GitHub release asset digest and locally downloaded bytes. Use matching header/library, not host packages. DuckDB is MIT licensed; no project license is selected here.

The compiler source also uses a commit-addressed archive instead of the release tag URL: OxCaml metadata itself warns that release tags can move. All compiler patches and bootstrap checksums remain those of the pinned opam snapshot. Transitive package versions come from immutable repository snapshots. The completed full/frozen solution is `.local/stage1-switch.export` (SHA256 `23e6a58b350ec1ede83bb962c5a1e27fb9d67a6be4cdadcec9d7230075c6c1ad`); package names/versions are in `.local/logs/installed-packages.txt`. Source checksums and bootstrap recipes remain in the pinned snapshots.

## Existing OCaml bindings: inspect, do not adopt

- [mt-caret/duckdb-ocaml](https://github.com/mt-caret/duckdb-ocaml/tree/6d62a7fa4101eed935f5b83eef7c6ea4ef8ddd08): MIT (`LICENSE`, copyright 2025 mtakeda). Ctypes generated stubs with Dune `(concurrency unlocked)`, Core wrappers, scoped resources, appender, prepared queries, chunk/vector, function APIs and date/time tests. `src/stubs/function_description.ml` includes current `duckdb_fetch_chunk`; README explicitly calls it work in progress with incomplete logical types/conversion support. Worth studying, but mode/lifetime guarantees and unlocked string handling must be independently validated against the chosen Ctypes/compiler. No code copied or dependencies adopted.
- [deepmarker/ocaml-duckdb](https://github.com/deepmarker/ocaml-duckdb/tree/8f192e26c1ee5e9f3ee25c9fef24c90f1c84c281): handwritten stubs, chunks/vectors/appender. No LICENSE file found; opam license is the placeholder `LICENSE`, GitHub reports no license. Do not copy. The inspected `ml_duckdb_query` holds the runtime lock and raises on error without explicit result destruction; custom result operations use `custom_finalize_default`. `ml_duckdb_close` releases the lock then evaluates `Database_val(db)` (OCaml custom-block access) while unlocked. These are concrete reasons not to adopt its resource/locking approach. It uses the now-deprecated `duckdb_result_get_chunk`.

## Public C API findings

Pinned [DuckDB 1.5.5 public header](https://github.com/duckdb/duckdb/blob/v1.5.5/src/include/duckdb.h), downloaded header SHA256 `48e716b9ce96ca8fead9cb35693fdc0343ac0fc1f6e7db5561fa0f44b674153d`:

- `duckdb_query` explicitly requires `duckdb_destroy_result` **even on failure**, to free error storage.
- `duckdb_fetch_chunk` returns owned chunks requiring `duckdb_destroy_data_chunk`; inspect result error when fetch returns null rather than assuming successful exhaustion.
- `duckdb_data_chunk_get_vector`, `duckdb_vector_get_data`, and `duckdb_vector_get_validity` expose foreign storage. A null validity pointer means all rows valid. Their existence does not establish an OCaml borrowed-view lifetime guarantee.
- `duckdb_result_get_chunk`, `duckdb_result_chunk_count` and legacy cell accessors are deprecated in this header; use sequential `duckdb_fetch_chunk` in new probes.
- Copy SQL and extract all native handles while holding the runtime lock. Retain native-owned allocations across unlocked calls, then reacquire before accessing any OCaml heap object. Destruction and fetching may block too.

## Bootstrap evidence

Commands from repository root:

```sh
python3 -m unittest discover -s stage1 -p 'test_*.py' -v
python3 stage1/setup.py --check
python3 stage1/setup.py --fetch
python3 stage1/setup.py --install > .local/logs/setup.log 2>&1
```

- First unittest run: **6 failures**, `stage1/setup.py must implement bootstrap validation` (file intentionally absent).
- Additional HTTPS rejection test: **1 failure**, `ValueError not raised`, before source scheme validation was added.
- Green run: **7 tests, OK**. Covers exact checksum acceptance, corrupted bytes, missing pins, mutable revision, missing checksum, non-HTTPS URL, and ignoring inherited shared switch/environment settings.
- `--check`: exit 0, reports glibc 2.43/opam 2.5.1 and passes sandbox check.
- `--fetch`: exit 0; all five pinned archives verified. Raw logs remain ignored under `.local/logs/`.

`--install` completed, including the frozen export and compiler/Dune version commands. Compiler output: `5.2.0+ox`, `flambda2: true`, `runtime5: true`, `multidomain: true`, `ox: true`; installed compiler metadata records release `5.2.0minus-39`, commit `2515546fea38e21e8143cc41db663bd56efc8d06`. Dune's binary prints `3.22.2` (package `3.22.2+ox`). `opam lint` on the derived compiler recipe: **Passed**.

## Runtime and negative-test evidence

OCaml/Dune commands below use the exact local switch through `stage1/run`; Python and native-loader checks use the host tools (exit 0 unless an expected failure is explicitly listed):

| Command | Observed result |
| --- | --- |
| `stage1/run exec stage1/async_probe.exe` | `async: worker=42 heartbeat=ok` |
| `stage1/run exec stage1/eio_probe.exe` | `eio: worker=42 heartbeat=ok` |
| `stage1/run runtest --force` | Both scheduler cram tests, FFI tests, compile-negative control and native diagnostics passed |
| `python3 -m unittest discover -s stage1 -p 'test_*.py' -v` | 8 tests, OK |
| `stage1/run clean && stage1/run build @all` | Clean rebuild passes; only the two documented vendor macro warnings |
| `ldd _build/default/stage1/ffi/ffi_tests.exe` | `libduckdb.so` resolves to this project's `.deps/duckdb/libduckdb.so` |

Scheduler probes use `Async.In_thread.run` and `Eio_unix.run_in_systhread` in **separate executables**. Each worker waits for a scheduler heartbeat acknowledgement after publishing its running flag. The scheduler waits for actual worker startup before acknowledging; neither success condition relies on the former 20/200-ms window. Bounded wait budgets, explicit failure release/join, and 30-second outer process timeouts prevent hanging probes. A scheduler-controlled startup gate and injected heartbeat failure exercise both paths. Full Async and Eio dependency stacks compiled, not just scheduler interfaces.

TDD checkpoints: scheduler tests first failed with `No rule found for stage1/async_probe.exe` and `eio_probe.exe`. FFI tests first failed with `No implementations provided` for `Handwritten_probe` and `Generated_probe`. These were followed by green runs. An initial BIGINT-minimum SQL fixture failed because DuckDB cast the positive magnitude before unary negation; the fixture was corrected to a quoted BIGINT cast, without weakening the boundary assertion. The bootstrap HTTPS check's distinct assertion-red is recorded above.

Self-review added an explicit `OPAMNODEPEXTS=true` guard: a new test first failed with `None != 'true'`, then all **8** tests passed. This prevents future opam runs from automatically attempting host package installation; the actual initial build had not invoked sudo or a system package manager. A dry-run of the exact pinned `opam install` request under the final isolated environment reports every requested package already installed (exit 0). No compiler/dependency rebuild or pin change was made.

Final `runtest` output (raw log `.local/logs/final-runtest.txt`; clean-build log `.local/logs/final-clean-build.txt`):

```text
ctypes: boxed witness accepted; native int64# witness rejected as expected
held-lock negative control: lock-control=ok
handwritten: lock-control=ok
generated: lock-control=ok
handwritten boxed: query/errors/chunks/cleanup=ok
handwritten native int64#: query/errors/chunks/cleanup=ok
generated int64_t: query/errors/chunks/cleanup=ok
handwritten: gc-stress=ok
generated: gc-stress=ok
native: DuckDB v1.5.5, 100 query/error/open-failure cycles, ASan/UBSan/LSan=ok
```

Assertions cover `[|0L;1L;2L|]`, empty results, 5,000 rows crossing chunk boundaries, both signed BIGINT extrema, invalid SQL followed by valid queries, rejected NULL/wrong type/multiple columns, and embedded-NUL rejection. Both wrappers run dynamically allocated long SQL while another OCaml thread allocates and calls full GC/compaction. Native diagnostics additionally repeat failed opens under `/proc/duckdb-stage1-missing/database` and assert no retained helper responses after every cycle.

Dune compiles the native diagnostic executable with `-fsanitize=address,undefined -fno-omit-frame-pointer -g -O1 -Wall -Wextra -Werror`, then runs with `ASAN_OPTIONS=detect_leaks=1:halt_on_error=1` and `UBSAN_OPTIONS=halt_on_error=1`. No sanitizer errors/leaks were reported. This instruments the shared helper, **not the prebuilt DuckDB engine or the entire OCaml runtime**. Connect failure and allocation exhaustion were not fault-injected.

The extracted library SHA256 is `fc23f12e376c47be520f75221288281906e7942e8fd6f6ce4849198ba60d0405`; the matching header hash is above. The native test asserts `duckdb_library_version() = "v1.5.5"`.

## FFI comparison and decision

**Choose handwritten stubs for the next prototype**, based on explicit native ownership/lock boundaries and the demonstrated native `int64#` accessor, **not** a speed or allocation claim. Ctypes-generated stubs are viable for ordinary boxed access and passed the same runtime tests.

The supervisor approved a shared private `stage1/ffi/native_probe.c` helper so both real wrappers exercise identical DuckDB lifecycle/query/cleanup code. It uses only public C APIs, compiles with `DUCKDB_API_NO_DEPRECATED`, returns owned numeric copies, destroys all chunks/results (including failed query results), disconnects/closes and frees open errors before returning. This comparison isolates marshalling/locking/accessors; it does **not** prove broad direct-C-API binding coverage.

| Capability | Handwritten | Ctypes-generated |
| --- | --- | --- |
| SQL lifetime | Rooted custom block owns stable native `{sql,response}` storage before release; SQL is freed/cleared before reacquiring, with a finalizer backstop if release raises | `CArray.of_string` and a NULL-initialized native response slot are retained through the protected query, decoding and cleanup, including exceptional exits |
| Embedded NUL | Rejected as `Embedded_nul`, never silently truncated | Same rejection |
| Long call | Releases/reacquires around the complete native query/lifecycle; accesses only the stable native owner while released; response ownership is established before reacquiring | Actual generated `stage1_query_into` extracts both native pointers **before** release and returns `Val_unit` after reacquiring; the native slot already owns the response before any allocating pointer read |
| Runtime evidence | Heartbeat/GC progresses during native sleep | Same; held-lock control observes zero in-flight heartbeats |
| Numeric accessor | `stage1_hand_value_unboxed` returns C `int64_t` directly to an OxCaml `int64#` external, tested at extrema | Generated `int64_t` binding reacquires the lock and calls `caml_copy_int64`; its OCaml return is boxed `int64` |
| Native bits64 witness | Compiled/running | `int64# Ctypes.typ` rejected: `layout ... bits64 ... must be a value layout`; same compiler accepts boxed `int64 Ctypes.typ` |

Generated files are reproducible under `_build/default/stage1/ffi/`. The long-operation generator uses `Cstubs.unlocked` for both C and ML; the separate free-only `Cleanup` generator uses the default sequential mode. Its generated C reads the slot, calls `stage1_destroy_slot`, and returns `Val_unit`, without runtime calls, OCaml allocation or lock release. Both orderings were inspected, not inferred from generator options. Generated C also releases around fast getters, so this is not a proposed final per-cell scheduling design. Vendor `ocaml_integers.h` emits `Int8_val`/`Int16_val` macro-redefinition warnings with this compiler; generated/vendor code is not subject to authored-code warnings-as-errors. No vendored source was patched to suppress them.

The unboxed handwritten query wrapper ultimately **boxes into an owned OCaml array**; it is not zero-copy or allocation-free. The out-slot removes the previously unowned Ctypes query-result marshalling boundary. Allocation exhaustion, arbitrary/repeated asynchronous interruption of OCaml cleanup code, and complete runtime/OOM safety remain unproven; the targeted signal guarantees below are not a public safe-API guarantee. Native error text in this helper is bounded to 511 bytes. These limitations prohibit treating the probes as a public safe API.

## Stage-1 review fixes: exception boundaries and scheduler handshake

Follow-up to reviewed `b746e7ba6dfe09d241b873a2e471c760c6fcae3d`; same compiler/DuckDB pins, no dependency installation or toolchain changes. Fixes are limited to the private stage-1 probes.

**Exact runtime finding:** pinned compiler `runtime/signals.c:209–222` processes pending signal handlers before releasing the runtime lock. Lines 273–302 terminate the process for arbitrary handler exceptions; `Sys.Break` instead propagates asynchronously. `stdlib/sys.mli` (installed `sys.mli:415–423`) documents `Sys.with_async_exns`: async Break bypasses ordinary handlers up to that boundary. `caml_leave_blocking_section` reacquires and marks signals pending, without immediately invoking the handler; subsequent polling/allocation can deliver it. These specifics refine the original review's generic “raising handler” description. The first custom-exception experiment exited fatally; `.local/logs/stage1-fixes/fatal-custom-signal.txt` retains that observation. Final regressions use genuine SIGUSR1 handlers raising `Sys.Break`, not a mocked exception/transition.

- **Handwritten SQL ownership:** the rooted custom block points to a stable native owner initialized before allocating SQL. The owner owns SQL before release and receives the native response before reacquisition. Unlocked code never dereferences the movable custom block. Normal cleanup frees and clears SQL; the finalizer idempotently frees any remaining SQL, response and owner. A Break before the raw query returns still relies on **eventual GC-finalizer recovery**, not deterministic scope cleanup. Release/reacquisition regressions check live allocation snapshots at injection and zero counts after explicit GC. Normal unwrapped query tests still check deterministic response destruction.
- **Generated cleanup/handoff:** supervisor-approved private `query_into`/NULL response slot replaces the unowned pointer return. `Exn.protect` is established before native work; `Sys.with_async_exns` is inside its body, so async Break unwinds to that boundary and then propagates ordinarily through cleanup, never as a query error. The SQL and slot CArray owners remain live through cleanup on either exit. A separate generated locked `destroy_slot` frees the response and resets the slot to NULL; repeated destruction is tested. Long calls remain unlocked. Targeted generated signal tests require zero live responses **without forcing GC**.
- **Regression instrumentation:** `signal_test_stubs.c` is linked only into `signal_tests.exe`. GNU linker wrappers queue real signals immediately before the real pinned enter/leave transitions or before the generated destructor's first instruction. Native SQL-copy/live-response counters record that the intended allocation existed at injection. Tests assert one injection and one executed raising handler, restore handlers/injection state, and use a 30-second outer timeout. No compiler/runtime source is patched. These single-thread, single-signal boundary probes do not prove cleanup under arbitrary repeated signals or fatal handler exceptions.
- **Scheduler handshake:** `async_probe.ml` and `eio_probe.ml` keep the worker in flight until a scheduler acknowledgement. The `STAGE1_DEFER_WORKER_START` fixture uses an atomic gate, not a chosen delay; the old timer-first assertion cannot pass with that gate closed. `STAGE1_FAIL_HEARTBEAT` verifies failure releases waiting workers before joining them (Async exit 1, Eio uncaught exception exit 2, neither timeout). The independent FFI slow-call/held-lock controls are unchanged.

Red/green evidence is retained under `.local/logs/stage1-fixes/`:

| Check | Red | Green |
| --- | --- | --- |
| `hand-enter` | SQL counter remains nonzero after explicit GC (`red-hand-enter.txt`, exit 2) | SQL finalizer backstop restores zero |
| `generated-cleanup` | Response counter nonzero after exceptional finally (`red-generated-cleanup.txt`, exit 2) | Locked cleanup restores zero before GC; idempotent second cleanup |
| `generated-leave` | Response leaks at pending-signal handoff (`red-generated-leave.txt`, exit 2) | Protected out-slot restores zero before GC |
| Destructor mutation | Re-enable unlocked cleanup generation only: same final regression fails (`red-unlocked-destructor-mutation.txt`, exit 2) | Restore sequential generation: passes |
| Deferred worker start | Async assertion failure; Eio old failure cleanup hangs until the 5-second outer red-test timeout | Both gated-start checks pass |
| Injected heartbeat failure | Old probes incorrectly exit 0 (`red-scheduler-failure-cleanup.txt`) | Exit 1/2 with expected error and no hang |

`hand-leave` was already green before the fix under the pinned non-raising reacquire; it remains a control, not a claimed red test. Additional generated release-before-query and release-during-decode tests pass. A new signal-handler counter initially failed the compiler's portability check when implemented as a mutable ref; using `Stdlib.Atomic` fixed the real mode error. A test-only linker archive-order issue was resolved by explicitly retaining the wrapped destructor symbol. The timeout-wrapped Dune test now declares its executable dependency explicitly, preventing stale test execution. These were implementation/test-fixture corrections, not infrastructure or dependency changes.

Commands (all from repository root; final commands exit 0):

```sh
stage1/run build @all
stage1/run runtest --force
# Each of six signal tests, 20 repetitions:
timeout 30 stage1/run exec --no-build stage1/ffi/signal_tests.exe -- hand-enter
# Other arguments: hand-leave generated-cleanup generated-leave generated-enter generated-decode
# Each scheduler, normal + deferred start, 20 repetitions:
timeout 30 stage1/run exec --no-build stage1/async_probe.exe
STAGE1_DEFER_WORKER_START=1 timeout 30 stage1/run exec --no-build stage1/async_probe.exe
# Same commands for eio_probe.exe; failure injection repeated 10 times each:
STAGE1_FAIL_HEARTBEAT=1 timeout 30 stage1/run exec --no-build stage1/async_probe.exe
# Expected failure exit 1 (Async), 2 (Eio); error text asserted.
ASAN_OPTIONS=detect_leaks=1:halt_on_error=1 UBSAN_OPTIONS=halt_on_error=1 \
  timeout 60 stage1/run exec stage1/ffi/native_diagnostics.exe
clang -std=c11 -Wall -Wextra -Werror -fsyntax-only -I.deps/duckdb -I_opam/lib/ocaml \
  stage1/ffi/native_probe.c stage1/ffi/handwritten_stubs.c \
  stage1/ffi/native_diagnostics.c stage1/ffi/signal_test_stubs.c
# Repeated for all four C files above:
clangd --check=stage1/ffi/handwritten_stubs.c --compile-commands-dir=.local --tweaks=
```

`build-all.txt` and `runtest.txt` record final full checks. `repeated-focused.txt`: **120 signal checks + 80 scheduler checks pass**. `repeated-failure-cleanup.txt`: **20 expected failures exit promptly**. `native-diagnostics.txt`: **100 query/error/open-failure cycles pass ASan/UBSan/LSan**, now also covering instrumented SQL copies, native out-slots, clearing and repeated destruction. This instruments the helper, not handwritten OCaml-boundary stubs, the OCaml runtime, or prebuilt DuckDB; counters plus source inspection cover the OCaml signal boundary. All four diagnostic-only clangd checks report **0 errors**; clang warnings-as-errors syntax check passes. The native compilation database was extended only in ignored `.local/`. Bootstrap files were not touched, so bootstrap tests were not rerun for these fixes. Ambient OCaml LSP remains unavailable for the already-approved compiler mismatch; valid `int64#` source is unchanged. An ambient reserved-identifier hint for the existing required `_POSIX_C_SOURCE` feature-test macro is not a C compiler failure; explicit native diagnostics pass.

## Diagnostics, recovery and scope limits

- Ambient `ocamllsp` is `1.21.0` from the shared `freight-vcaml` switch, not a matching project-local server. It reports `Compiler version mismatch`, `unknown flag -extension-universe`, and cannot parse valid `int64#` externals. **OCaml LSP validation is unavailable, not passed.** The supervisor explicitly approved relying on the pinned compiler/Dune tests without modifying shared/editor settings or changing valid OxCaml code. Initial missing-module/config diagnostics were separately checked against successful local Dune builds.
- `clangd 22.1.6 --check` passes `native_probe.c` and `native_diagnostics.c` using `.local/compile_commands.json`. Its full handwritten-stub check fails inside the `SwapBinaryOperands` **refactoring self-test** on OCaml macros (26 overlapping-replacement errors); there are no source diagnostic errors. The explicit diagnostic-only check `clangd --check=stage1/ffi/handwritten_stubs.c --compile-commands-dir=.local --tweaks=` passes. `clang -std=c11 -Wall -Wextra -Werror -fsyntax-only -I.deps/duckdb -I_opam/lib/ocaml stage1/ffi/native_probe.c stage1/ffi/handwritten_stubs.c stage1/ffi/native_diagnostics.c` also passes. Raw original and diagnostic-only logs are retained; the full refactoring check is not claimed to pass.
- The original worker timed out after 30 minutes while detached bootstrap PIDs 3027/3481 continued. Recovery verified both had exited successfully, read the completed log/export, and did **not** start another install or modify active build inputs.
- With supervisor approval, only the already-installed, inactive compiler build tree `/home/aktersnurra/projects/duckdb.ml/_opam/.opam-switch/build/oxcaml-compiler.5.2.0minus39` was removed. Resolved path and active process working directories were checked first. Installed compiler, pinned sources and downloads were retained. Diagnostics/config logs were archived to `.local/logs/completed-compiler-diagnostics.tar.gz` (SHA256 `c96dd73ee50c67054ca71237b80bf8d891b20604fea00e1471b98dbe4eec8733`). Recovered **6,426,169,344 bytes**; free space increased from **5,488,545,792** to **11,914,715,136 bytes**. Final free disk is approximately 8 GiB. No other successful build tree was removed.
- Shared `5.2.0+ox` package listing is byte-identical before/after. No shared switches, global configuration, bookmarks or remotes were changed; no sudo, raw Git commands, publishing or external agents were used.
- Ownership, borrowed views, static lifetime guarantees, public core, adapters/pools/cancellation and Parquet are **not implemented**. Next is stage 2's ownership/invalidation prototype, with its own compiled positive/negative evidence before freezing any interface.

## Review checkpoint

Code implementation revision: `ff008140789f8bf06d7ac6d297f73c9a7e16a626`, following plan `d2b28a25` and bootstrap `2168f850`. The final documentation revision and exact reviewed commit are recorded in the runtime handoff and ignored `.local/stage1-reviewed-commit.txt` (avoids a self-referential commit hash in this file).

Review package: `.local/stage1-review.diff`, produced with `jj diff --git --from 24850d1b --to <reviewed-commit>`. It covers the complete stage-1 changes from the approved-spec baseline, not merely the last working change. The original review identified the two P1 exception-path leaks and P2 scheduler timing issue addressed above. The follow-up `.local/stage1-fix-review.diff` covers `b746e7ba` to the fixed commit; the full review diff is refreshed from `24850d1b`. Exact immutable identities are recorded in the runtime handoff. Independent review remains required; optional editor diagnostics and explicitly bounded prototype guarantees remain limitations.
