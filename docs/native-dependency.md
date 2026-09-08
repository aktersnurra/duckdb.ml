# Native dependency and package installation

Initial supported target: x86-64 Linux/glibc, exact OxCaml compiler
`2515546fea38e21e8143cc41db663bd56efc8d06` (opam `5.2.0minus39`), Dune
`3.22.2+ox`, Base `v0.18~preview.130.106+341`. These are **not** upstream OCaml
packages. See [stage 1](stage1-validation.md) for the toolchain bootstrap.

`duckdb-ffi` requires the matching DuckDB **v1.5.5** header and shared library.
Neither package bundles the engine or installs native/system packages. The FFI
also rejects a different engine version when opening a database. ABI/version
checks do not replace matching the pinned header and library.

From a source checkout, provision only the native dependency into a writable
local directory (no opam switch changes, sudo, or scheduler installation):

```sh
python3 tools/setup_duckdb.py --prefix "$PWD/.deps/duckdb"
# Offline: add --archive /path/to/libduckdb-linux-amd64.zip
```

The script uses the immutable URL and SHA256 in `stage1/toolchain.lock.json`:
`1fb8ce388157d84a25abe685a8a2520bf00c00321821968e4bb398fd766e7abb`.
It verifies bytes before extracting only `duckdb.h` and `libduckdb.so`.
Expected extracted SHA256:

- Header: `48e716b9ce96ca8fead9cb35693fdc0343ac0fc1f6e7db5561fa0f44b674153d`.
- Library: `fc23f12e376c47be520f75221288281906e7942e8fd6f6ce4849198ba60d0405`.

For a provisioned exact local switch, the normal package workflows are:

```sh
export DUCKDB_INCLUDE_DIR=/your/native/directory
export LIBRARY_PATH="$DUCKDB_INCLUDE_DIR${LIBRARY_PATH:+:$LIBRARY_PATH}"
export LD_LIBRARY_PATH="$DUCKDB_INCLUDE_DIR${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
dune build -p duckdb-ffi
dune install --prefix /your/temporary/prefix duckdb-ffi
# Include that prefix in OCAMLPATH when separately building duckdb:
export OCAMLPATH=/your/temporary/prefix/lib${OCAMLPATH:+:$OCAMLPATH}
dune build -p duckdb
dune install --prefix /your/temporary/prefix duckdb
```

Development uses `stage1/run` instead of ambient Dune: it selects only the
existing project-local switch and prepends the project native link/loader path.
Installed archives contain `-lduckdb`, **not** a developer absolute rpath. Deploy
`libduckdb.so` separately and configure your application loader environment or
application-owned rpath. Moving the native directory requires updating that
environment, not rebuilding the OCaml packages. Both native executables and
bytecode stubs need the native library at runtime.

`bash test/install_smoke.sh` builds/installs the FFI package alone, runs a separate
FFI consumer, then builds the safe package against that **installed** FFI with
its source package excluded. Another external consumer runs against a newly
extracted temporary native prefix. It checks `META` dependency boundaries and
ELF loader paths, the prepared/typed example, and an external compile rejection
of private resource admission operations. The safe package uses Dune
`private_modules`: internal CMIs are not on the public consumer search path.

**Pinned Dune build-directory limitation:** use the default `_build` or a
source-relative **direct-child** build directory when installing a package with
private modules. An external absolute build directory triggers an internal
`Obj_dir.External.encode` exception in this exact Dune. The smoke test therefore
uses an ignored root `.install-smoke.XXXXXX` directory for the safe package and
cleans it on exit; it does not edit generated metadata or expose private modules.
See the [stage-3b reproducer evidence](stage3b-validation.md).

The smoke test does not run `opam install`, change the local switch, or
install either scheduler. Both `.opam` files use these demonstrated Dune build
and installation workflows; opam solver/installation execution is untested in
this slice.

Package boundary: `duckdb-ffi` has no OCaml library dependencies; `duckdb` depends
on `base`, `threads`, and `duckdb-ffi`. Async/Eio occur only in separate test
executables, not in either installed package. Test dependencies need not be
installed by consumers.

Publication metadata remains unresolved by owner choice: `opam lint` reports
error 23 (no maintainer), plus missing authors/homepage/bug-reports/license
warnings. No identity, contact, license or attribution is invented here.
These packages are locally installable, **not publication-ready**.
