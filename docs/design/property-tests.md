# Property-based tests (sub-project 5)

Status: approved, 2026-10-08. Replaces roadmap row "later" (the
`[@@deriving duckdb]` ppx, dropped: declarations are one line per column,
written once; the real friction, positional binders, needs no ppx). Comes
before the 0.1.0 release.

## Goal

Check the library against generated inputs where example tests are thinnest:
every codec's round trip, SQL semantics against an OCaml model, query
algebra against list operations, and DML and windows against models, with
Hegel's shrinking reporting minimal counterexamples.

## Setup

Hegel 0.17.2 (MIT, [hegel-ocaml](https://github.com/hegeldev/hegel-ocaml))
runs a native engine, `libhegel`, in-process. Installing the opam package
into the project switch removes `ocaml-lsp-server`: every Hegel version
depends on `dune-site`, whose dune 3.22 libraries conflict with the only
OxCaml LSP build (1.19.0+ox2). Hegel uses `dune-site` in one place, its
loader's lookup of the `libhegel` bundled in the release tarball, which
`HEGEL_LIBHEGEL_PATH` bypasses. So Hegel is vendored at bootstrap:

- `tools/toolchain.lock.json` gains a `hegel` archive: the 0.17.2 opam
  release tarball's URL and sha256 (no revision: a release asset, as for
  `duckdb`).
- `tools/bootstrap.py` downloads and verifies it and extracts, into the
  gitignored `vendor/hegel/`: `lib/` without `lib/jane`, `LICENSE`, and the
  platform's prebuilt `libhegel` (Linux amd64/arm64, macOS arm64) as
  `vendor/hegel/libhegel.so`. It applies
  `tools/patches/hegel-0.17.2-no-dune-site.patch` (drops `from_site`, the
  `Hegel_sites` rule and the `dune-site` library). `--install` adds the
  conflict-free dependencies `ctypes-foreign`, `ipaddr`, `ocplib-endian`.
- The root `dune` declares `(vendored_dirs vendor)`.
- `tools/run` sets `HEGEL_LIBHEGEL_PATH=<root>/vendor/hegel/libhegel.so`
  and `HEGEL_LIBHEGEL_NO_DOWNLOAD=1`: tests never download or use
  `~/.cache`.

## Structure

`test/property/`:

| File | Content |
|---|---|
| `prop_support.ml` | Generators, table builders, a session helper, reference models, the `property` runner |
| `prop_codec.ml` | Codec round trips |
| `prop_semantics.ml` | Expressions against an OCaml evaluator |
| `prop_algebra.ml` | Queries against list operations |
| `prop_dml.ml` | DML sequences and windows against models |

Each property runs through `Hegel.run_hegel_test` (no ppx, no alcotest):
100 cases by default, `PROPERTY_CASES=n` for more, Hegel's example
database off (no files written). A failure prints the shrunk
counterexample and exits non-zero. All four executables run under
`runtest`.

## Properties

### Codec round trips

Generated values of every scalar codec and its nullable form: integers over
their full range with the extremes mixed in; floats with NaN, ±inf and
−0.0, float32 values exactly representable; Unicode strings without NUL;
blobs of any bytes; dates and timestamps within DuckDB's range; a custom
codec. Each value goes through three paths and comes back equal: a typed
parameter (`SELECT ?`), the appender into a table read back by
`Table.select`, and a `Sql.value` literal. NaN equals NaN; −0.0 keeps its
sign where DuckDB keeps it.

### SQL semantics against a model

Random rows (nullable int64 columns, a string, a bool) and random typed
expression trees to depth 4 over the `Null` operators, `coalesce`,
`is_null`, `is_true`, `like` (`%`, `_`, literal patterns) and integer `/`
with zero divisors; small values, so no overflow. An OCaml evaluator with
three-valued logic gives each row's expected result.

### Query algebra against lists

Random tables. `where`, `order_by`, `limit`, `offset`, `distinct`;
`group_by` with `count_star`, `count`, `sum`, `min`, `max`, `avg`; inner
joins and left joins (`None` for no match); `union`, `union_all`,
`intersect`, `except_` (multisets for `union_all`, sets otherwise). Results
are compared sorted, or ordered by a unique tiebreak, never relying on
DuckDB's row order.

### DML and windows against models

A random sequence of insert, upsert (`nothing_on`, `update_on`), update and
delete by key and `delete … all` applied to a map model: each step's count
or `returning` rows and the table afterwards match. Random partitioned data
with `row_number`, `rank`, `dense_rank`, `lag`, `lead` and a running
`Over.sum` against a reference computation, ordered by a unique key.

## Failures found

A failing property is triaged: a library bug becomes a regression example
test and a fix (test-first); a DuckDB behaviour the model missed corrects
the model and is recorded below.

(None yet.)

## Acceptance

`python3 tools/bootstrap.py --install` (adds the Hegel dependencies and
vendors Hegel), `./tools/run build @all`, `./tools/run runtest --force`
pass, with the four property executables among them.

Documentation: README "Development", CHANGELOG, core-redesign roadmap
(ppx dropped, property tests row), `PLAN_FEAT_property-tests.md`, this
note's status.
