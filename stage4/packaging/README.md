# NON-PRODUCTION packaging prerequisite

Two disposable Dune packages, **not Duckdb or an adapter**. `Packaging_core`
wraps a private `Resource`; `packaging-consumer` builds and runs against only its
installation. All tracked OCaml files are templates, so root Dune never builds
this fixture accidentally.

From the repository root:

```sh
bash stage4/packaging/check.sh interface-red # expected exit 1: missing implementations
bash stage4/packaging/check.sh latch-red     # expected exit 2: generated latch mutation
bash stage4/packaging/check.sh green         # expected exit 0
```

Each invocation creates a fresh source/build/prefix tree under ignored
`.local/stage4b/packaging/`; `logs/*-work.txt` identifies it. The runner sets
`OCAMLPATH` **after** the pinned runner's opam environment to only that prefix
and `_opam/lib`. It renames the entire producer source/build tree before the
consumer build. It does not install dependencies or modify an opam package.
The core's private CMI stays in `.private`, never on a consumer include path.
The installed consumer executable is run, then five separately compiled,
source-specific negatives reject public/internal Resource access, a forged
request, a nativeint used as a connection and a connection used as a nativeint. This is type abstraction, not a
security boundary against unsafe OCaml/FFI or manually supplied private paths.

`check` is a sequential simulated admission test, **not SQL**. The tiny
implementation has no native pointer, transaction, thread, finalizer, controller,
engine, filesystem operation or scheduler. The consumer additionally hands the
opaque request to one system thread for cancellation, joining it before reading
simulated state; this compiles system-thread capture, not concurrent admission
or domain transfer. Its single-use request also serves
as the cancellation/settlement capability; no public setter can claim settlement.
`cancel` acknowledges a latch, not completion. `settlement` reports only
Pending/Settled; the return/exception from `run` owns the actual outcome. Errors
and callback exceptions are not replaced by a success merely because settlement
finished. The callback's connection facade and its aliases are dynamically
revoked, not statically local or linear. The fixture demonstrates source/type
usability and a simulated latch check after a caught error; it proves **nothing**
about production concurrency, engine lifetime, transaction rollback or native
interrupt safety.

Evidence: `docs/stage4b-packaging-validation.md`.
Next execution plan: `docs/superpowers/plans/2026-09-09-stage4b-bridge.md`.
Both remain subject to independent review; no production signature is frozen.
