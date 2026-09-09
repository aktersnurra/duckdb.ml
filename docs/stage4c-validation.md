# Stage4c Async validation

Stage4c is accepted within its approved SQL/whole-transaction scope and the
limits below, following independent review and fresh parent verification.
Publication remains separately authorized. The complete command transcript and
per-command output are retained under `.local/stage4c/implementation/`.

## Parent acceptance

The final independent review (`f5030c24-0568-4dfd-805d-2968ba742a04`)
reported no mandatory findings after inspecting the actual production source,
interfaces, critical test oracles and evidence. The parent then independently
ran these checks, all exit 0:

```sh
sha256sum --check .local/stage4c/implementation/source-manifest.sha256
sha256sum --check .local/stage4b/preserved-six.sha256
sha256sum --check .local/stage4c/design/pins.sha256
stage1/run build @all
stage1/run runtest --force
sha256sum --check .local/stage4c/implementation/source-manifest.sha256
```

The source manifest matched before and after the forced full regression,
including the late swallowed-statement test. Primary LSP checks of both Async
interfaces and implementations reported no errors. Comparison against all 246
accepted Stage4b source hashes found only the authorized additive changes to
`dune-project` and `examples/dune`; accepted core/FFI and old tests are unchanged.
Evidence: `parent-evidence-index.json`, `parent-baseline-check.json`, and
`logs/parent-*.log` under the implementation evidence directory.

The prior mutation, repetition, installation, example and sanitizer evidence
was reviewed and retained rather than needlessly repeated. Its historical
wrapper failure remains recorded below. This acceptance update changes only
documentation; the pre-update source manifest is retained, with a separate
`parent-final-source.sha256` recording the final documentation hashes.

## Recovery consolidation

The interrupted final transcript predates the last source addition:
`swallowed_statement_error` in `test/async/test_native_cases.ml`. The current
source was rebuilt and the complete Async test alias rerun after that addition:

```sh
stage1/run build test/async/test_duckdb_async.exe
# exit 0

timeout 120 stage1/run exec --no-build test/async/test_duckdb_async.exe -- swallowed_statement_error
# exit 0; swallowed statement final=Ok(42)
# PASS ... opens=1 connects=2 disconnects=2 ... commits=1

stage1/run runtest test/async --force
# exit 0
```

Logs: `.local/stage4c/implementation/logs/recovery-swallowed-statement-error.log`
and `.local/stage4c/implementation/logs/recovery-runtest-async.log`.

The targeted callback calls `Duckdb.execute_transaction` with an invalid
single statement, observes and deliberately ignores its `Error`, rejects manual
`ROLLBACK` as `Unsupported_statement`, and returns `Ok 42`. The actual adapter
completion is `Ok 42`; before pool teardown it has replaced the transaction
connection (`connects=2`, `disconnects=1`). This is the intended conservative
retirement behavior, not a claim that the swallowed inner statement error is
propagated.

Applicability audit: the adapter callback receives only `Duckdb.transaction`
(`lib/async/worker_owner.ml`). `Resource.with_transaction` invokes outer
rollback only after that callback returns (`lib/duckdb/resource.ml`), so a
callback cannot itself swallow an *outer pooled-owner rollback failure*; that
mapping is unreachable and is not a runtime pass. Reachable callback operations
are manual transaction SQL, transaction-prepared Query operations, and
transaction Appender operations. Query errors can be returned/ignored by the
callback; Appender errors poison `tx.failure`, so `with_transaction` converts an
otherwise `Ok` callback result into an outer error. Manual control SQL is
rejected by the common engine statement policy; the recovery test executes the
`ROLLBACK` control rejection directly. Regardless of these distinctions,
`Duckdb_async.dispatch` retires every `Transaction _` lease rather than
publishing it Idle.

## Earlier final evidence reconciled

`final-validation-transcript.log` records exit 0 for the pre-existing final
build, focused suite, interfaces, mutations/restoration, full regression,
Stage4 regression, five pristine plus five instrumented repetitions, example,
installed smoke, strict C, pristine/instrumented ASan/UBSan, pins, protected
six, compiler/Dune/JJ/clang diagnostics, shell syntax and final build. Their
individual logs are `logs/final-01-build.log` through
`logs/final-17-final-build.log`. The final wrapper's only failure was copying an
ignored mode-444 evidence file after all numbered commands; this recovery does
not relabel it as a test failure.

The current source manifest is
`.local/stage4c/implementation/source-manifest.sha256`. Its protected-six
section was freshly checked with:

```sh
sha256sum --check .local/stage4b/preserved-six.sha256
# exit 0; all six OK
```

Current key hashes are `lib/async/duckdb_async.ml`
`67fdc4582a62bedb072de01ffbc0ad254e9aa7ec8ae743e66d543023d25bdd11`,
`test/async/test_native_cases.ml`
`3892d4dd63fcd9932c4570574fb32e88f6e0d02d38a46248c64612cc4dc4b5c5`, and
`test/async/test_failure_cases.ml`
`d2e7156fc06a2e81753ca324d6ad07620cccc7092e1567085ef013f95a78278d`.

## Limits

The known synthetic empty-shell failed-connect cleanup diagnostic remains a core
limitation: cleanup can mask the original failed-connect error if that synthetic
shell cleanup raises. No core repair was authorized, and this report makes no
universal primary-error-preservation claim for that case. Existing limits also
include non-returning native/callback work, OOM/asynchronous bookkeeping,
arbitrary repeated signals, and whole-process LSan; authored-C sanitizer runs
do not instrument DuckDB or the OCaml runtime. Dune install smoke is not an
opam solver/install or publication claim.
