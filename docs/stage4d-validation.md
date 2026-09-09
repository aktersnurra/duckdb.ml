# Stage4d validation

Stage4d is accepted within the supported surface and limits below after
independent review closure and fresh parent verification. Publication requires
separate authorization.

## Parent acceptance

Final independent review `12ca2602-2fc4-4219-a5d7-0ca7be0b2f60` closed all
behavioral/test-oracle findings. The parent addressed its remaining notes by
correcting the unsupported threshold explanation (without changing the observed
204,800-row boundary) and running that corrected AUTO selector under sanitizers.

All eight parent commands exited 0:

```sh
sha256sum --check .local/stage4b/preserved-six.sha256
stage1/run build @all
stage1/run runtest --force
# Each executable below ran with ASAN_OPTIONS=detect_leaks=0:halt_on_error=1
# and UBSAN_OPTIONS=halt_on_error=1:
stage1/run exec --profile stage3a-sanitize --build-dir "$PWD/.local/stage4d/build-sanitize" test/async/test_duckdb_async.exe -- ingest_rollback_and_auto_flush
stage1/run exec --profile stage3a-sanitize --build-dir "$PWD/.local/stage4d/build-sanitize" test/async/instrumented/test_duckdb_async.exe -- --instrumented ingest_rollback_and_auto_flush
clang -std=c11 -Wall -Wextra -Werror -fsyntax-only -I.deps/duckdb -I_opam/lib/ocaml test/async/async_hooks.c
stage1/run exec --no-build examples/asynchronous.exe
sha256sum --check .local/stage4d/parent-pre-validation.sha256
```

Exact commands, exits and logs are in `.local/stage4d/parent-evidence-index.json`
and `parent-logs/`. All 298 tracked non-task source hashes matched after these
checks. `jj diff --name-only -- lib/duckdb lib/ffi` was empty against accepted
Stage4c; the six protected files also matched. Existing installed-consumer and
mutation evidence was retained rather than needlessly repeated.

The initial worker manifest had one stale documentation hash
(`docs/stage4d-validation.md`); its other 18 entries matched. The discrepancy is
recorded in `parent-pre-source-check.json`; a new explicit parent manifest was
used for final checks. The primary OxCaml language server confirmed the changed
test clean. An auxiliary `ocamllsp` end-of-file syntax report disagreed with that
result and the successful pinned builds/tests; no source suppression or editor
configuration workaround was applied.

Only this acceptance documentation changes after final verification;
`parent-final-source.sha256` records the final documentation as well.

## Supported surface and limits

`Duckdb_async.query` returns owned `Duckdb.Row` values. `fold_rows` and
`parquet_fold_rows` run synchronous callbacks on their request worker and return
an owned accumulator. `ingest` owns its transaction/appender and calls the core
explicit flush only for `~flush:true`; it exposes no appender to user code, so a
user-unclosed-appender state is source-unreachable. Local Parquet paths are
constructed on the worker and export uses the core temporary/publication
protocol. Every new operation is one request offload; conservative retirement
is maintenance, not per-row/cell admission.

This evidence does not claim streaming, backpressure, performance/allocation,
remote storage, crash durability, hostile-filesystem behavior, OOM resilience,
bounded shutdown for a non-returning foreign call, or whole-process LSan.
ASan runs set `detect_leaks=0`: the prebuilt DuckDB/runtime process-leak limit
is deliberately not relabelled as LSan coverage.

## Corrected source-named oracles

- `parquet_export_cancellation_and_publication` holds the real post-link
  publication seam, cancels the same still-active request, then reads its
  surviving `7L` final; it separately verifies before-publication cancellation,
  owned temporary unlink/inventory, failed export cleanup/preserved final, and
  a post-terminal `Already_finished` control.
- `parquet_cancel_between_files` selects the first prepared owner after actual
  destruction, proves one first callback and zero second execution before and
  after cancellation, then checks an ordered successful two-file control.
- `ingest_rollback_and_auto_flush` gates real explicit flush/end-row/destroy,
  checks COMMIT suppression and visibility on cancellation, and changes schema
  from a second leased connection.  Its automatic-flush control appends 220,000
  duplicate primary-key rows: the real `duckdb_appender_end_row` wrapper records
  its first engine error at row 204,800, before close, with zero COMMITs.  The
  selected cancellation then gates exactly row 204,800 of a distinct admitted
  204,800-row request; it cancels, suppresses COMMIT, leaves no rows and retires
  the owner. This is the empirically observed boundary of the pinned engine,
  independently established by the end-row error control, not derived from an
  assumed default threshold. `appender.cpp:393-418,760-781` supports the
  `FlushChunk -> ShouldFlush -> FlushInternal` path.
  Generated instrumentation additionally observes the adapter explicit flush
  before close; it is an isolated test seam, not production API.
- `fold_callbacks` observes worker TLS after Stop/error/exception, checks the
  named raw `fold_callbacks` backtrace and settlement before monitor delivery.
  `heartbeat_and_cancel_fold` holds real native execute through `A.fold_rows`.
  `parquet_read_failures_and_callbacks` separately raises `Exit` from the named
  `parquet_callback_failure_frame` callback and requires both that original
  exception identity and that frame in the returned raw backtrace; this is an
  `A.parquet_fold_rows` oracle, not a substitution by the ordinary fold test.
- `wide_and_multichunk` compares all 3,000 ordered values. Generated query,
  fold, ingest and Parquet selectors assert one request admission plus bounded
  close/replacement maintenance only.
- `examples/asynchronous.ml` now runs ingestion, owned query/fold, and local
  Parquet export/read; installed-consumer coverage already uses the same public
  operations.

## Mutation and sanitizer evidence

The explicit-flush omission control is recorded in
`.local/stage4d/mutations-focused.log`; the corrected publication control was
run separately with `python3 test/async/stage4d_mutations.py published_final_side_effect`.
Its actual red/restored-green logs and `restoration.json` are under
`.local/stage4d/mutations/`. These are new Stage4d controls:
omission of the adapter explicit flush fails the named
`explicit flush is adapter initiated before close` assertion in the generated
selector.  The publication control leaves its preservation assertion unchanged
and mutates only the isolated fixture's post-cancellation seam to actually
remove its published destination while the real request is still held; it then
fails `published final from cancelled request survives`. Each restores exact
source bytes and rebuilds/runs green; neither red is a process timeout. The
former assertion-to-`false` attempt is retained as invalid history under
`.local/stage4d/mutations/invalid-require-false/`. It does not replay Stage4c
mutations.

Both pristine and generated selectors passed under the existing profile:

```sh
env ASAN_OPTIONS=detect_leaks=0:halt_on_error=1 UBSAN_OPTIONS=halt_on_error=1 \
  timeout 300 stage1/run exec --profile stage3a-sanitize \
  --build-dir "$PWD/.local/stage4d/build-sanitize" \
  test/async/test_duckdb_async.exe -- <ten Stage4d selectors>
# same command with test/async/instrumented/test_duckdb_async.exe -- --instrumented <selectors>
```

The exact selector output is retained in `.local/stage4d/sanitize-ordinary.log`
and `.local/stage4d/sanitize-instrumented.log`; both exit 0 with every new
query/fold/ingest/Parquet selector passing.  The correction-specific pristine
and generated Parquet/fold rerun, including the named raw-backtrace assertion,
is `.local/stage4d/final-TRACE.log`; both ASan/UBSan commands exit 0.

## Historical consolidated validation and current source basis

The following consolidated commands exited 0 before the focused TRACE source
change and are retained verbatim in `.local/stage4d/final-validation.log`:

```sh
stage1/run build @all
timeout 360 stage1/run runtest test/async --force
timeout 600 stage1/run runtest --force
timeout 120 stage1/run exec --no-build examples/asynchronous.exe
bash test/install_async_smoke.sh
bash test/async/check_interfaces.sh
clang -std=c11 -Wall -Wextra -Werror -fsyntax-only -I.deps/duckdb -I_opam/lib/ocaml test/async/async_hooks.c
sha256sum --check .local/stage4b/preserved-six.sha256
test -z "$(jj diff -- lib/duckdb lib/ffi)"
```

`runtest test/async` executes ordinary and fail-closed generated selectors;
the full forced regression includes inherited suites. Expected compiler errors
from negative compile fixtures are part of the successful interface/install
scripts. The TRACE change is instead covered by the focused pristine/generated
and ASan/UBSan commands in `final-TRACE.log`; it deliberately does not claim to
replay that historical full campaign. The parent subsequently completed that consolidated gate and the corrected AUTO
sanitizer runs, as recorded above. `.local/stage4d/source-manifest.sha256` and
`.local/stage4d/review.diff` retain the pre-parent evidence basis; the separate
parent manifests record the final verified source and acceptance documentation.
