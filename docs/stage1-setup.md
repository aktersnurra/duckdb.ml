# Reproducing the stage-1 bootstrap

This is an experimental toolchain checkpoint, **not an installable DuckDB binding**. See [validation and decision](stage1-validation.md) before treating any compatibility requirement as passed. Later stages remain unimplemented.

## Requirements

x86-64 Linux with glibc, Python >=3.12 (tar data extraction filter), opam 2.5.1, C/C++ toolchain, GNU make (upstream compiler bootstrap only), autoconf, patch, rsync, bwrap, unzip and pkg-config. No sudo or host package installation is performed. Stage-1 authored builds use Dune; there is no Makefile wrapper. Allow generous disk headroom (40 GiB free is recommended, not a measured minimum): the initial 27 GiB required an approved cleanup of the completed compiler build tree. Monitor disk throughout. Four build jobs are used.

All commands below run from the repository root. Do not activate or alter a shared opam switch. `stage1/setup.py` supplies explicit project-local `OPAMROOT` and `OPAMSWITCH`, strips inherited OCaml/opam/Dune settings, uses `/usr/bin:/bin` for bootstrap native tools, sets local cache paths, and initializes opam with `--no-setup --no-opamrc --no-git-location`. Shell startup files are not edited. `OPAMNODEPEXTS=true` disables automatic system-dependency handling: missing host prerequisites must be supplied by the user, not installed by this bootstrap. Sandboxing remains enabled. The source recipes in pinned upstream metadata can use their normal build systems; authored OCaml probes must use Dune.

```sh
mkdir -p .local/logs
python3 -m unittest discover -s stage1 -p 'test_*.py' -v
python3 stage1/setup.py --check
python3 stage1/setup.py --fetch
python3 stage1/setup.py --install > .local/logs/setup.log 2>&1
```

`--fetch` verifies every existing or downloaded archive against `stage1/toolchain.lock.json`; corrupted cached files are rejected rather than silently trusted. Delete only the identified corrupt project-local archive before retrying. The DuckDB zip's checksum also matches the upstream release asset digest.

The installer reconstructs `.deps/repos/{ox,default}` from those verified snapshots. Only compiler/Eio source URL stanzas are rewritten, to checksum-verified archives of the exact same upstream commits. All patches and other dependency metadata remain pinned. It initializes `.local/opam/`, creates the local `_opam/` switch, then requests the compiler and exact top-level dependency versions in the lock file. It never runs global `opam update`, adds a remote/bookmark, or invokes raw Git commands. The native library and matching header are extracted into `.deps/duckdb/`.

On successful completion, `.local/stage1-switch.export` contains a full frozen opam solution, followed in the setup log by `ocamlc -config` and `dune --version`. Absence of the export means this success checkpoint was **not** reached. Archive pins plus a solver plan are not proof of compiler, Async or Eio compatibility.

## Run the stage-1 checks

After successful installation:

```sh
stage1/run runtest --force > .local/logs/stage1-all.txt 2>&1
stage1/run exec stage1/async_probe.exe
stage1/run exec stage1/eio_probe.exe
python3 -m unittest discover -s stage1 -p 'test_*.py' -v
```

Expected: all commands exit 0; scheduler executables print `async: worker=42 heartbeat=ok` and `eio: worker=42 heartbeat=ok`. Cram compares scheduler output silently on success. The test alias also runs both FFI wrappers, the held-lock negative control, a native sanitizer executable and the Ctypes unboxed compile-failure test. The printed `bits64 ... must be a value layout` diagnostic is **expected**; its boxed positive control must compile and the test wrapper exits 0.

`stage1/run` fails rather than falling back if local `ocamlc`/`dune` are absent. It supplies the local DuckDB include/link path and embeds an absolute project-local RUNPATH for the native executables. `ldd _build/default/stage1/ffi/ffi_tests.exe` should resolve `libduckdb.so` to `.deps/duckdb/libduckdb.so`. Do not override this with a conflicting `LD_LIBRARY_PATH`/`LD_PRELOAD`. These private probes are not installable public packages.

### Optional native editor diagnostics

`.clangd` reads an ignored, project-local compilation database. Recreate it after moving the project:

```sh
python3 - <<'PY'
import json
from pathlib import Path
root = Path.cwd()
files = ['native_probe.c', 'handwritten_stubs.c', 'native_diagnostics.c']
commands = [{
    'directory': str(root),
    'file': str(root / 'stage1/ffi' / name),
    'arguments': ['cc', '-std=c11', '-Wall', '-Wextra', '-Werror',
                  '-I' + str(root / '.deps/duckdb'),
                  '-I' + str(root / '_opam/lib/ocaml'),
                  '-I' + str(root / '_opam/lib/ctypes'),
                  '-c', str(root / 'stage1/ffi' / name)]
} for name in files]
(root / '.local/compile_commands.json').write_text(json.dumps(commands, indent=2))
PY
clangd --check=stage1/ffi/native_probe.c --compile-commands-dir=.local
clangd --check=stage1/ffi/handwritten_stubs.c --compile-commands-dir=.local --tweaks=
clangd --check=stage1/ffi/native_diagnostics.c --compile-commands-dir=.local
clang -std=c11 -Wall -Wextra -Werror -fsyntax-only -I.deps/duckdb -I_opam/lib/ocaml \
  stage1/ffi/native_probe.c stage1/ffi/handwritten_stubs.c stage1/ffi/native_diagnostics.c
```

The explicit empty `--tweaks=` disables **refactoring action self-tests**, not C source diagnostics. The full clangd 22.1.6 handwritten-stub check trips a macro replacement-overlap bug, recorded in the validation document. Ambient upstream-OCaml LSP 1.21.0 is incompatible with this OxCaml build; valid `int64#` and `-extension-universe beta` must not be removed to satisfy it. A matching project-local editor server can be considered separately; no shared editor setup was changed.

## Failure checkpoint

Keep `.local/logs/setup.log`, `.local/opam/log/`, and `_opam/.opam-switch/build/` for diagnosis. Builds intentionally retain upstream build trees (`OPAMKEEPBUILDDIR=true`). Stop on a demonstrated prerequisite/compiler incompatibility rather than switching to a shared switch, disabling sandboxing, changing compiler families or silently omitting an adapter.

Once repository/switch initialization has completed, re-running `--install` resumes package installation in this project's existing switch; source substitutions are deterministic. If initialization itself was interrupted, inspect the local repository/switch state first. **Do not re-run while an existing setup/opam process is still building**: preparation reconstructs local repository inputs. No automatic deletion of the local switch or shared state occurs. Network failures remain failures and must be diagnosed from the exact logged URL/status.

If disk pressure requires cleanup, first preserve diagnostic/config logs and verify the target is an inactive, already-installed build tree belonging to this project. Do not delete installed artifacts, active build trees, pinned sources/downloads or shared files. This run's specifically approved compiler-tree removal and recovered bytes are recorded in the validation document.

Useful read-only checks (environment isolation remains explicit):

```sh
OPAMROOT="$PWD/.local/opam" OPAMSWITCH="$PWD" opam list --readonly
OPAMROOT="$PWD/.local/opam" OPAMSWITCH="$PWD" opam switch list --readonly
tail -n 60 .local/logs/setup.log
df -h .
```

Raw logs, dependencies, downloaded archives, build caches, switch state and `.local/stage1-review.diff` are ignored. Committed documentation records meaningful outputs and limitations; no binary dependencies are committed.
