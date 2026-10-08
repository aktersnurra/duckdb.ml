# Property-Based Tests (sub-project 5) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Hegel property tests for codecs, SQL semantics, query algebra, DML and windows, with Hegel vendored by the bootstrap.

**Architecture:** `tools/bootstrap.py` fetches the sha256-pinned Hegel 0.17.2 tarball, extracts its library and prebuilt `libhegel` into the gitignored `vendor/hegel/`, and patches it into private libraries without `dune-site`; `tools/run` points Hegel at the vendored engine. `test/property/` holds a support library and four test executables. Spec: [docs/design/property-tests.md](docs/design/property-tests.md).

**Tech Stack:** Python 3 (bootstrap, `unittest`), OxCaml, dune, Hegel 0.17.2, DuckDB 1.5.5.

---

## File structure

| File | Responsibility |
|---|---|
| `tools/toolchain.lock.json` | The `hegel` archive pin |
| `tools/bootstrap.py`, `tools/test_bootstrap.py` | Fetch, verify, vendor and patch Hegel; tests |
| `tools/patches/hegel-0.17.2-no-dune-site.patch` | Private libraries, no `dune-site`, no instrumentation |
| `tools/run`, `dune`, `.gitignore` | Engine environment, `(vendored_dirs vendor)`, `vendor/` |
| `test/property/*` | Support library and the four property executables |
| docs | README "Development", CHANGELOG, roadmap, design note |

### Task 1: Vendoring — DONE

- [ ] `tools/test_bootstrap.py`: the lock has a `hegel` archive (https, sha256, no revision); `validate_lock` requires it; `vendor_hegel` on a synthetic tarball (`hegel-0.17.2/lib/…`, `LICENSE`, `prebuilt/libhegel-linux-amd64.so`) extracts `lib` without `lib/jane`, `LICENSE` and `libhegel.so`, rejects an unknown platform, and re-extracts cleanly. Run: `python3 -m unittest tools/test_bootstrap.py` (red).
- [ ] Implement the lock entry, `vendor_hegel`, the patch application (`patch -p1 --forward`), `--install` extra packages (`ctypes-foreign ipaddr ocplib-endian`), and the call from `prepare`/`fetch`. Green.
- [ ] Run `python3 tools/bootstrap.py --fetch` and the vendoring step; `./tools/run build vendor` builds Hegel.

### Task 2: Runner and a first property — DONE

- [ ] `tools/run` sets `HEGEL_LIBHEGEL_PATH` and `HEGEL_LIBHEGEL_NO_DOWNLOAD=1`; root `dune` `(vendored_dirs vendor)`; `.gitignore` `vendor/`.
- [ ] `test/property/prop_support.ml` (`property` runner with `PROPERTY_CASES`, database off; a connected-session helper), `prop_codec.ml` with the int64 parameter round trip; a deliberately false property checked to fail with a shrunk counterexample, then removed.
- [ ] Green under `./tools/run runtest`.

### Task 3: Codec round trips

- [ ] All scalars and nullable forms, custom codec, through parameters, the appender and `value`.

### Task 4: SQL semantics

- [ ] Expression generator and evaluator; per-row comparison.

### Task 5: Query algebra

- [ ] where/order/limit/offset/distinct, group_by aggregates, joins, set operations against lists.

### Task 6: DML and windows

- [ ] Operation sequences against a map model; windows against a reference.

### Task 7: Documentation

- [ ] README "Development", CHANGELOG, roadmap (ppx dropped, row 5), design note status and failures found.
- [ ] `./tools/run build @all` clean; `./tools/run runtest --force` exit 0.
