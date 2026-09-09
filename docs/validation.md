# Validation

## Completed bounded campaign

The parent validation gate completed with exit 0. Primary LSP diagnostics scanned
19 files with no errors (`.local/release-cleanup/parent-gate/diagnostics.md`).
The retained command evidence is:

```sh
./tools/run build @all
./tools/run runtest --force
python3 -m unittest test.soak.test_run_soak bench.test_benchmark_summary tools.test_bootstrap
./tools/run exec --no-build examples/synchronous.exe
./tools/run exec --no-build examples/asynchronous.exe
./tools/run exec --no-build examples/eio.exe
bash test/install_adapters_smoke.sh
./tools/run exec --no-build test/soak/test_soak_support.exe
python3 test/soak/run_model_soak.py --seed 104729 --episodes 8 \
  --output .local/release-cleanup/parent-gate/model-soak.log
python3 test/soak/run_soak.py --seed 104729 --repetitions 1 \
  --output .local/release-cleanup/parent-gate/selector-soak.log
python3 bench/run_benchmarks.py --correctness-only --rows 1000 --warmups 0 \
  --samples 1 --output-dir .local/release-cleanup/parent-gate/benchmark
```

The full forced regression, build, eight Python test targets, soak-support,
all three examples, four-package installation smoke, bounded model soak (eight
episodes per adapter), and selector soak (ten selectors per adapter) passed.
Their logs are under `.local/release-cleanup/parent-gate/`; the model and
selector evidence is in `model-soak-evidence.log` and
`selector-soak-evidence.log`. The benchmark correctness record is
`benchmark/run-1-summary.json`: owned and borrowed processing agree on 1,000
rows, 100 nulls, and checksum 949500.

Ownership compile failures, native lifecycle, scheduler responsiveness, causal
cancellation, shutdown, package isolation, and native sanitizer checks are
executable regressions. The benchmark's matching owned/borrowed row, null, and
checksum counts are its correctness claim; timings are host- and
workload-specific, not performance guarantees. See [development](development.md)
for exact reproduction commands and sanitizer scope.

## Provenance status

The pre- and post-validation manifests at
`.local/release-cleanup/parent-gate/pre-validation-source.{json,sha256}` and
`.local/release-cleanup/parent-gate/post-validation-source.{json,sha256}` each
cover 366 source files and have the identical SHA-256
`7941c82dc335bebab607f3371279a361a76f5e615d5c3ccdede2bff1a7b4684d`.
The source-integrity and primary-diagnostics acceptance gates therefore passed.
