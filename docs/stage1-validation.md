# Stage 1 validation checkpoint

Date: 2026-09-07 (UTC). Stage 1 is **not complete** at this checkpoint.

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

The compiler source also uses a commit-addressed archive instead of the release tag URL: OxCaml metadata itself warns that release tags can move. All compiler patches and bootstrap checksums remain those of the pinned opam snapshot. Transitive package versions come from immutable repository snapshots; an installed full/frozen switch export is required before calling the complete dependency solution validated.

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

## Test evidence so far

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

Scheduler compilation/execution, DuckDB query, cleanup diagnostics, lock-release comparison and unboxed accessors have **not yet passed**. The FFI decision is deferred until both compiled experiments are available. No public package, ownership API, zero-copy guarantee or performance claim exists at this checkpoint.
