# Development

`tools/run` invokes Dune with only the checked-out local OxCaml environment and
project-local DuckDB headers and library. Bootstrap assets are `tools/bootstrap.py`
and `tools/toolchain.lock.json`; first verify prerequisites, then provision only
when necessary. Never modify a shared switch.

```sh
python3 tools/bootstrap.py --check
python3 tools/bootstrap.py --fetch
python3 tools/bootstrap.py --install
./tools/run build @all
./tools/run runtest --force
python3 -m unittest test.soak.test_run_soak bench.test_benchmark_summary tools.test_bootstrap
./tools/run exec examples/synchronous.exe
./tools/run exec examples/asynchronous.exe
./tools/run exec examples/eio.exe
bash test/install_adapters_smoke.sh
./tools/run exec --no-build test/soak/test_soak_support.exe
python3 test/soak/run_model_soak.py --seed 104729 --episodes 8 --output .local/soak-model.log
python3 test/soak/run_soak.py --seed 104729 --repetitions 1 --output .local/soak.log
python3 bench/run_benchmarks.py --correctness-only --rows 1000 --warmups 0 --samples 1 --output-dir .local/benchmark-check
```

Ordinary native sanitizer coverage is part of `./tools/run runtest test/native-ffi
--force`; it runs the native ASan/UBSan diagnostic executable. To instrument the
library and its test hooks as well, use the optional profile below. It does not
instrument the prebuilt DuckDB engine, OCaml runtime, or Base; disabling LSan is
not a whole-process leak-free claim.

```sh
ASAN_OPTIONS=detect_leaks=0:halt_on_error=1 UBSAN_OPTIONS=halt_on_error=1 \
  ./tools/run exec --profile stage3a-sanitize \
  --build-dir "$PWD/.local/build-sanitize" test/test_duckdb.exe
```

Static ownership controls are under `test/ownership/`; adapter lifecycle and
package-isolation controls are under `test/adapter/`. The benchmark checks
owned-row and borrowed-chunk checksums before reporting timing data.
