# Stage4e Eio validation

`duckdb-eio` is a separately installable direct-style SQL and synchronous
whole-transaction adapter.  It has no import-time scheduler startup.  Its
standalone example executes SQL and a two-statement transaction and explicitly
settles shutdown.

## Parent acceptance

Stage4e is accepted for SQL and synchronous whole transactions; Stage4f typed
Eio requests remain outside this slice. No publication is authorized or performed.
Independent reviewer `9dd07218-51c7-47cf-af04-46f1a3f09e7f` closed all remaining
findings without new issues; `.local/stage4e/final-review-recovered.json` retains
that result, separately from the historical blocked reviews.

Parent ran eight exit-zero checks: reviewed source/generated hashes, protected-six
hashes, baseline scope, `./stage1/run build @all`, `./stage1/run runtest --force`,
the standalone Eio example, strict C, and post-run source/generated hashes.
All 342 non-task source files stayed unchanged throughout validation; accepted
core/FFI/Async and old test sources match `be070451`. The forced regression
includes corrected native cleanup, both active-B cases, caller-observed dispatch
frame/zero-work checks, and source-specific compiler controls on backend `linux`.
Commands, exits and logs: `.local/stage4e/parent-evidence-index.json` and
`.local/stage4e/parent-logs/`. Only acceptance documentation changed afterward;
`.local/stage4e/parent-final-source.sha256` records the final snapshot.

Primary LSP checks confirmed all four production Eio files; four test-file LSP
checks were unavailable, so compiled tests supply that evidence. A stale
auxiliary EOF syntax finding on unchanged Async source was marked false-positive
against the fresh pinned build/regression, without source/config workarounds.
Reviewed installed-package, meaningful-control and current pristine/generated
sanitizer evidence below remains applicable; those campaigns were not duplicated.

## Reviewed three-oracle corrections

The prior `.local/stage4e/closure-review-recovered.json` identified the three
gaps below. Their corrected causal evidence and claims are now independently
closed and parent-verified.

- `Foundation_eio.held_child_cleanup`, `held_rollback`, and `held_disconnect`
  require `eio_foundation_held_entry`, separate from total destructor counts.
  C publishes it only for an enabled, matched gate after verifying runtime
  release. Result/chunk matches must be non-null selected owners. BEGIN result
  destruction cannot satisfy it. All six cleanup kinds retain pending completion
  through heartbeat and ordinary cancellation, with release before joins.
  Disabling each gate fails its unchanged selected-held assertion, not a timeout.
- Generated `Gates.delayed_a_cancellation_active_b` holds A's caller only AFTER
  its real private completion resolves (permit/slot settlement is finished).
  B starts on the reused or replaced single slot and acknowledges actual native
  held entry. Only then is A cancelled; A's cancellation is delivered/awaited
  while B remains held/pending, with zero native interrupts. B succeeds after
  release, subsequent work proves capacity, and shutdown proves exact inventory.
  Disabled-B and B-completed-before-cancellation controls fail the unchanged
  selected-entry/pending assertions. The older `running_cancellation_then_reuse`
  and `foreign_return_then_reuse` cases prove later usability, not this race.
- `Gates.dispatch_fault` catches the original exception after real adapter
  delivery, reads its raw backtrace and requires the named
  `Test_support.dispatch_fault_source_frame` in the actual test source.
  The Operation-phase fault has zero independently observed operation-worker
  entries and zero native prepared executions; close/replacement is counted
  separately and allowed. Subsequent worker/native execution and final drain
  are checked. Lost-frame, dispatch-after-worker and dispatch-after-native
  controls fail their specific assertions. Dispatch attempts are not submissions.

Exact commands, exits, control/restoration hashes and generated input/output
manifests: `.local/stage4e/THREE-ORACLES-fix.md`. Current checks are the forced
Eio suite, strict C, pristine-adapter and generated-adapter Eio sanitizers, and
three focused repetitions. Historical `final-*` logs below are not evidence for
these corrected causal assertions and were not rewritten or rerun as a campaign.

## Other corrected coverage

The default backend is `linux`.  `foundation_eio` and `cancellation_eio` cover
bounded admission, causally admitted queued cancellation/removal, caller-context
creation cancellation, callback reentry, foreign-return and terminal races,
between-statement transaction exclusion/effect barrier, replacement versus
shutdown, lifecycle composition, and selected native cleanup responsiveness.
The cleanup gates select actual result/prepared/chunk/appender, rollback, and
disconnect owners; normal and ordinary-cancellation cases require a held native
entry, released runtime, unresolved completion, and scheduler heartbeat before
release.

`test/eio/instrumented` is a fail-closed generated copy of the current Eio
adapter/private worker capsule.  It allowlists one post-completion-await seam
and one offload-dispatch seam (including an atomic operation-worker-entry
observer inside its systhread closure), hashes source/output, has a disabled-seam healthy
control, and records a deletion mutant that fails the unchanged post-await
cancellation oracle.  It is test-only: production adapter sources and public
API contain no hooks.  The dispatch case is a synthetic pre-systhread dispatch
fault, not a claim about operating-system thread exhaustion.

`test/eio/check_modes.sh` compiles an owned transaction-result positive and
checks borrowed callback escape/domain handoff plus opaque/private pool, worker,
and resource negatives.  The installed smoke repeats the applicable controls
against the isolated installed public API; these controls make no static-purity
or arbitrary-owned-value domain claim.

The installed smoke copies FFI/core/Eio sources, removes Async before producer
builds, installs FFI -> core -> Eio under an isolated prefix, hides the producer,
and then checks the public consumer, privacy controls, META/native loader paths,
no import-time scheduler, and installed example.  `duckdb-eio.opam` depends on
`eio` (and its `eio.unix` library through Dune), but not `eio_main`; `eio_main`
remains an executable/test dependency.

## Historical consolidated correction run (before the three-oracle review)

All commands below used the unchanged pinned `stage1/run` and exited 0. Logs are
under `.local/stage4e/final-*.log`.

```sh
./stage1/run build @all
./stage1/run runtest test/eio --force
timeout 600 ./stage1/run runtest --force
./stage1/run exec --no-build examples/eio.exe
./stage1/run build @install
./stage1/run exec -- bash test/eio/check_modes.sh
./stage1/run exec -- bash test/install_eio_smoke.sh
cc -std=c11 -Wall -Wextra -Werror -fsyntax-only -I.deps/duckdb -I_opam/lib/ocaml test/eio/foundation_hooks.c
ASAN_OPTIONS=detect_leaks=0:halt_on_error=1 UBSAN_OPTIONS=halt_on_error=1 \
  timeout 300 ./stage1/run exec --profile stage3a-sanitize \
  --build-dir "$PWD/.local/stage4e/build-sanitize" test/eio/foundation_eio.exe
```

The strict-C invocation is the source-approved GNU/POSIX wrapper protocol;
`__real_*`/`__wrap_*` and `_POSIX_C_SOURCE` are required linker/feature-test
identifiers rather than authored public identifiers.  That historical sanitizer run covered
authored C and the then-current Eio native selectors, not the three corrected
oracles above. `detect_leaks=0` is not an LSan
claim, and prebuilt DuckDB/the runtime are outside this instrumentation.

Stage4e acceptance does not authorize publication. There is no timeout,
recycle, thread termination, streaming, performance/allocation, OOM, hostile
filesystem, or nonreturning native/user-work shutdown guarantee.
