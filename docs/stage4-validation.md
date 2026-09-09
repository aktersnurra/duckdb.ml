# Stage4 validation status

Stage4 is parent-accepted. Stage4e provides bounded Eio SQL and synchronous
transactions; see [stage4e-validation.md](stage4e-validation.md). Stage4f adds
typed Eio owned query/fold, whole-request ingestion, local Parquet read/export,
and isolated four-package integration.

Combined reviewer `59307997-b225-4dbd-a199-a566e5a7da30` found no production,
ownership, lifetime, cancellation, publication, or package-boundary defect. Its
three evidence findings and one correction-induced selector regression were
closed by focused reviews `7057a115-4709-4dbd-a199-a566e5a7da30` and
`5c4a469f-2659-400c-ac25-bb1a193cb680`. Focused causal evidence is retained in
`.local/stage4f/API.md`, `QUERY_INGEST.md`, `PARQUET.md`, `INTEGRATION.md`, and
`SELECTOR-FIX.md`.

Parent acceptance then ran nine exit-zero checks on the reviewed snapshot:
source and protected-six hashes, scope/preservation, `build @all`, one full
forced regression, all three examples, four-package installation smoke, strict
C, and post-run hashes across 370 non-task source files. Exact commands and logs
are in `.local/stage4f/parent-evidence-index.json` and `parent-logs/`. Primary
LSP diagnostics were clean for all nine checked production/test files.

The representative pinned integration commands are:

```sh
stage1/run build @all
stage1/run runtest --force
stage1/run exec examples/synchronous.exe
stage1/run exec examples/asynchronous.exe
stage1/run exec examples/eio.exe
bash test/install_adapters_smoke.sh
```

Installation smoke independently stages FFI, core, and exactly one adapter
with the sibling adapter source/package absent. It validates installed public
consumers, private-module rejection, package dependency metadata, and dynamic
loading of a relocated project-local DuckDB library. The full regression records
selected ordinary/generated query, ingestion and Parquet boundaries, including
the observed 204800 end-row automatic-flush error and zero second-file work.
Reviewed sanitizer records contain exact stage3a-sanitize commands and ASan/UBSan
linkage for all four new ordinary/generated targets; `detect_leaks=0` is not an
LSan or whole-process leak-free claim.

Acceptance does not exercise an opam solver, authorize publication, or make
Stage5 performance, allocation, streaming, nonreturning-work shutdown, remote
Parquet, cross-domain handle, or broader static-safety guarantees.
