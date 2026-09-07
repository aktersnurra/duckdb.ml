# duckdb.ml agent guidance

Read `docs/superpowers/specs/duckdb-design.md` before implementation. User approved the specification and autonomous incremental execution. This is full OxCaml, not an upstream-OCaml compatibility project.

- Use `jj` for version control; never raw Git commands. No remote publication without approval.
- Preserve shared opam switches and user-wide configuration. Use a project-local pinned toolchain and project-local DuckDB headers/library. Never install with sudo autonomously.
- Use explicit `.mli` files first, Base by default, named ADT errors and result for expected failure. Async and Eio are both explicitly authorized, in separate optional packages.
- No unsafe casts in the safe API. Native/representation-sensitive operations belong in `duckdb-ffi`. No static lifetime or performance claims without compiled evidence.
- Use TDD for implementation, including compile-failure tests for promised static restrictions. Record exact commands, tool revisions, outputs, and limitations.
- Keep implementation single-writer. Plan stage 1 first, then later stages based on evidence. Do not invent ownership signatures before the prototype.
- Apply warnings-as-errors to authored development code, not to downstream distributed builds or vendored sources.
- Keep build caches, local dependency downloads, switches and raw logs ignored. Use Dune, not Makefile wrappers.
- Current scope includes dedicated typed local Parquet reads and exports in stage 3; no remote storage initially.
