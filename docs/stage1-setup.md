# Reproducing the stage-1 bootstrap

This is an experimental toolchain checkpoint, **not an installable DuckDB binding**. See [validation and decision](stage1-validation.md) before treating any compatibility requirement as passed. Later stages remain unimplemented.

## Requirements

x86-64 Linux with glibc, Python >=3.12 (tar data extraction filter), opam 2.5.1, C/C++ toolchain, GNU make (upstream compiler bootstrap only), autoconf, patch, rsync, bwrap, unzip and pkg-config. No sudo or host package installation is performed. Stage-1 authored builds will use Dune; there is no Makefile wrapper. Initial free disk was about 27 GiB; monitor available disk during the compiler/dependency build. Four build jobs are used.

All commands below run from the repository root. Do not activate or alter a shared opam switch. `stage1/setup.py` supplies explicit project-local `OPAMROOT` and `OPAMSWITCH`, strips inherited OCaml/opam/Dune settings, uses `/usr/bin:/bin` for bootstrap native tools, sets local cache paths, and initializes opam with `--no-setup --no-opamrc --no-git-location`. Shell startup files are not edited. Sandboxing remains enabled. The source recipes in pinned upstream metadata can use their normal build systems; authored OCaml probes must use Dune.

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

## Failure checkpoint

Keep `.local/logs/setup.log`, `.local/opam/log/`, and `_opam/.opam-switch/build/` for diagnosis. Builds intentionally retain upstream build trees (`OPAMKEEPBUILDDIR=true`). Stop on a demonstrated prerequisite/compiler incompatibility rather than switching to a shared switch, disabling sandboxing, changing compiler families or silently omitting an adapter.

Re-running `--install` resumes package installation in this project's existing switch; repository snapshots and local compiler/Eio source URL substitutions are deterministic. No automatic deletion of the local switch or shared state occurs. Network failures remain failures and must be diagnosed from the exact logged URL/status.

Useful read-only checks (environment isolation remains explicit):

```sh
OPAMROOT="$PWD/.local/opam" OPAMSWITCH="$PWD" opam list --readonly
OPAMROOT="$PWD/.local/opam" OPAMSWITCH="$PWD" opam switch list --readonly
tail -n 60 .local/logs/setup.log
df -h .
```

Raw logs, dependencies, downloaded archives, build caches, switch state and `.local/stage1-review.diff` are ignored. Committed documentation records meaningful outputs and limitations; no binary dependencies are committed.
