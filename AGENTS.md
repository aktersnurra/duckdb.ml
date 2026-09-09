# duckdb.ml agent guidance

Read `docs/architecture.md` and `docs/development.md` before implementation.
This is full OxCaml, not an upstream-OCaml compatibility project.

- Use `jj` for version control; never raw Git commands. No remote publication without approval.
- Preserve shared opam switches and user-wide configuration. Use the project-local toolchain and DuckDB dependency; never install with sudo autonomously.
- Use explicit `.mli` files first, Base by default, named ADT errors and results for expected failure. Async and Eio belong in separate optional packages.
- No unsafe casts in the safe API. Native/representation-sensitive operations belong in `duckdb-ffi`.
- Use TDD, including compile-failure tests for promised static restrictions. Record exact commands, revisions, outputs, and limitations.
- Keep build caches, dependency downloads, switches, and raw logs ignored. Use Dune, not Makefile wrappers.
