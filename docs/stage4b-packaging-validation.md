# Stage4b packaging prerequisite: compiled evidence, not a production bridge

Validated 2026-09-09 over accepted Stage4a `2978138c` and Stage4 plan `1333a3de`.
Published master remains `8bb77a2f`. **Fixture checks and independent packaging
review pass.** The packaging/type-usability prerequisite is accepted.
Engine lifetime, production native phases/cancellation and real safe-core
boundaries remain unimplemented. No adapter package or final public signature
is accepted by this report.

Canonical next plan:
[`2026-09-09-stage4b-bridge.md`](superpowers/plans/2026-09-09-stage4b-bridge.md).
Fixture repro instructions: [`stage4/packaging/README.md`](../stage4/packaging/README.md).

## Scope and installation boundaries

Authored paths are only `stage4/packaging/` and the two new documents. All OCaml
sources are `.in` templates; there is no new root/Stage4 Dune integration. No
`lib/`, root dune-project, opam, dependency, native library, shared switch or
editor/global configuration was changed. The six unrelated formatting files
were preserved byte-for-byte. Generated `.pi/tasks` state is excluded from the
authored review diff; no raw Git, commit, staging, bookmark movement or remote
publication was performed. `jj` has no staging area.

`bash stage4/packaging/check.sh MODE` creates a fresh disposable tree with
`mktemp` **only under** `.local/stage4b/packaging/`:

- `core/` project, source-relative `core/_build`, package `packaging-core`,
  public module `Packaging_core`, `private_modules resource`, Base only.
- `consumer/` independent project and `consumer/_build`, package/executable
  `packaging-consumer`, dependencies Base/threads/installed packaging-core.
- `prefix/` receives only these two fixture packages. No opam package is
  installed/reinstalled, and no shared/local opam package prefix is overwritten.
- After installing core, the script renames **the entire producer source/build
  directory** to `core.hidden`. The consumer must then build from installation.
- The nested Dune command gets `OCAMLPATH="$prefix/lib:$root/_opam/lib"`
  **after** `stage1/run` establishes its opam environment. There is no source
  `_build/install` path, producer build include path or `.private` include path.
- Dune's installed private CMI is under
  `prefix/lib/packaging-core/.private/packaging_core__Resource.cmi`; the public
  library directory does not contain that CMI. Source/CMX installation follows
  Dune's usual private-module layout; this is supported public search-path
  abstraction, not protection against unsafe code or manually adding private
  paths. Both qualified public and internal module access reject.
- Installed metadata contains ordinary prefix `sections` paths (this prefix is
  intentionally inside the repository's ignored `.local`). It contains no
  producer source/build path, root `_build` path or tracked fixture-source path.
  Core META says exactly `requires = "base"`. There is no engine/FFI linkage.

Final successful generated tree:
`.local/stage4b/packaging/green.rgfISn/`. The installed executable was run from
`prefix/bin/packaging-consumer`; after negatives, the restored consumer was
rebuilt and run again. `logs/green-work.txt` records the latest invocation's tree;
subsequent repro runs deliberately use fresh prefixes/builds, not cached packages.
Raw command outputs are under `.local/stage4b/packaging/logs/`.

## What was compiled and exercised

Public/private explicit `.mli` templates and the positive consumer's `.mli/.ml`
preceded fixture implementations. Private Resource defines the representation;
public Packaging_core includes it behind an explicit abstract interface. Exact
provisional Bridge declarations are reproduced in the plan, not a proposed
native-pointer conversion. The fixture's request is opaque and single-use; it
also provides cancellation acknowledgement and nonblocking Pending/Settled
observation. There is no public settlement setter or arbitrary connection
interrupt function.

**Sequential simulated behavior only:** no DuckDB, native pointer, transaction,
controller, finalizer or database framework exists. `check` is simulated
admission, not SQL. The consumer checks:

- owned string returned through public `Bridge.run` and usable facade inside;
- original owner Busy while leased; same request's reentrant run Busy;
- facade/request aliases revoked on success and callback exception;
- second run and terminal cancellation return Closed; owner usable after run;
- pre-entry repeated cancellation suppresses the callback;
- cancellation handed to one ordinary system thread, then joined before the
  worker reads simulated state; pinned compiler accepts this capture shape;
- deliberately dropped Cancelled result followed by Ok cannot erase the latch;
- exceptional callback still settles/revokes and preserves exception identity.

No simultaneous state mutation/admission race is asserted by the joined
handoff. No static linearity, portability, native lifetime, engine interruption,
transaction rollback, finalizer or scheduler responsiveness follows from it.
The production core's real mode/admission controls remain B1 obligations.

Five independent source-specific negative compiles replace only consumer
`main.ml`; each positive build/run precedes them, and each negative must have
line-1 source plus the intended diagnostic, not just a nonzero exit:

| Source under `stage4/packaging/negative/` | Observed rejection |
| --- | --- |
| `private_resource.ml.fail` | `Packaging_core__Resource.check`: Unbound module `Packaging_core__Resource` |
| `public_resource.ml.fail` | `Packaging_core.Resource.check`: Unbound module `Packaging_core.Resource` |
| `forge_request.ml.fail` | `()` has type unit, expected `Packaging_core.Bridge.request` |
| `forge_pointer.ml.fail` | `Nativeint.zero` has type nativeint, expected `Packaging_core.connection` |
| `extract_pointer.ml.fail` | highlighted connection has type `Packaging_core.connection`, expected nativeint |

These prove the tested safe source forms cannot forge the opaque capability or
convert to/from a native pointer representation. They are not a security claim
against Obj/unsafe FFI, whose use is forbidden in the safe API.

## Red/green history and exact commands

Commands run from the repository root. The script contains the complete
reproducible nested Dune project generation/build/install/consumer commands;
no Makefile wrapper or external dependency installation is used.

```sh
bash stage4/packaging/check.sh interface-red
bash stage4/packaging/check.sh latch-red
bash stage4/packaging/check.sh green
bash -n stage4/packaging/check.sh
stage1/run exec --no-build -- ocamlc -version
stage1/run exec --no-build -- dune --version
jj --version
stage1/run build @all
stage1/run runtest --force
sha256sum --check .local/stage4b/preserved-six.sha256
sha256sum .deps/duckdb/duckdb.h .deps/duckdb/libduckdb.so \
  .local/upstream/compiler.tar.gz
jj bookmark list
jj status
```

The script expands build/install commands as follows (`project` is each
independent generated root, source-relative `_build` is intentional):

```sh
stage1/run exec --no-build -- /usr/bin/env \
  OCAMLPATH="$prefix/lib:$root/_opam/lib" "$root/_opam/bin/dune" \
  build --root "$project" --build-dir _build @install
stage1/run exec --no-build -- /usr/bin/env \
  OCAMLPATH="$prefix/lib:$root/_opam/lib" "$root/_opam/bin/dune" \
  install --root "$project" --build-dir _build --prefix "$prefix" "$package"
timeout 30 "$prefix/bin/packaging-consumer"
```

| Run / raw log | Exit and result |
| --- | --- |
| First interface attempt, `project-name-error.txt` | **1**, Dune requires single package/project names match. Corrected generated project names from underscores to hyphens. Not counted as intended interface red. |
| Interface red before implementations, `interface-red.txt`; final repro `final-interface-red.txt` | **1**, `Some modules don't have an implementation`, names `packaging_core resource`. Final repro removes only generated `.ml` implementations. |
| First implementation compile, `green-first.txt` | **1**, development warning 50 for ambiguous docstrings. Added paragraph spacing in explicit interface, no warning suppression. |
| First consumer/negative run, `green-second.txt` | **1**, positive runs and intended negative rejection worked, but diagnostic guard omitted compiler's quotation marks. Corrected guard to match quoted modules and exact source expression. Not counted as a type-restriction red. |
| Metadata guard run, `green.txt` | **1**, all then-present negatives worked; guard incorrectly rejected legal install-prefix paths because disposable prefix is under repository root. Narrowed guard to producer/source/build paths; no metadata rewrite or consumer include-path relaxation. |
| Behavioral mutation, `latch-red.txt`; final `final-latch-red.txt` | **2**, `Failure("expected latch")` at the swallowed-cancellation assertion. Mutation changes only generated `Ok _ when request.cancelled` post-callback check to `when false`. Public interface and tracked implementation stay unchanged. |
| Restored fixture, `final-green.txt` | **0**, installed run and restored positive run succeed; **all five** source-specific negatives reject. No timeout. |
| Shell syntax | **0**; tool-provided shell diagnostics also clean. |
| Full `@all`, `build-all.txt` | **0**. No authored root Dune integration changed, but regression was run anyway. |
| Forced full Stage1–4a tests, `runtest-all.txt` | **0**, existing scheduler/native/mode/single-signal tests pass. This does not turn the fixture into a safe-bridge runtime test. |
| Six-file hash check, `preserved-six.txt` | **0**, all six OK; original manifest `.local/stage4/preserved.sha256` remains untouched. |

Final positive output:

```text
packaging fixture: owned access, single use, alias revocation, pre-entry/caught latch, exceptional settlement=ok (SIMULATED)
packaging fixture: installed consumers + five source-specific negatives=ok
```

Initial failed guards are kept as separate logs, not concealed or labelled
infrastructure failures. No provider/toolchain/backend failure or mode switch
occurred. The intentionally failing raw red commands are checked for their
exact exit and diagnostic by the verification command, not relabelled green.

## Versions, provenance and limits

Fresh `versions-hashes.txt`: compiler **5.2.0+ox**, Dune **3.22.2**, jj **0.42.0**.
Existing lock `stage1/toolchain.lock.json`: compiler package
`oxcaml-compiler.5.2.0minus39`, source
`2515546fea38e21e8143cc41db663bd56efc8d06`; Dune package `3.22.2+ox`, Base
`v0.18~preview.130.106+341`. No new dependency was resolved or installed.

Fresh hashes match accepted Stage4a provenance:

| Existing artifact | SHA256 |
| --- | --- |
| `.deps/duckdb/duckdb.h` | `48e716b9ce96ca8fead9cb35693fdc0343ac0fc1f6e7db5561fa0f44b674153d` |
| `.deps/duckdb/libduckdb.so` | `fc23f12e376c47be520f75221288281906e7942e8fd6f6ce4849198ba60d0405` |
| `.local/upstream/compiler.tar.gz` | `93dbcf859e655d2a2b41dfa077c126fa5a15fd0205b1c57dbb5ff2cc9d595462` |

Stage4a's immutable engine source/disassembly/noalloc audit, scheduler routing,
native race logs and cleanup limits were reused, not redownloaded/researched.
This task read Resource, Query, Appender, Parquet, FFI resource/prepared/typed/
appender/local-file cleanup and native parent-shell seams to map the execution
plan. Shell references are not engine lifetime; F.execute destroys native work
before ML return. Both remain explicit production stop gates.

Ambient OCaml LSP is incompatible/unavailable, not passed; pinned compiler is
authoritative. No new authored-C sanitizer run is relevant to this OCaml-only
fixture. The full baseline reruns existing helper native diagnostics, but does
not instrument all engine/runtime code. **Unsuppressed whole-process LSan
remains failing**, not rerun/fixed/suppressed here. Prior OOM, arbitrary/repeated
signals, asynchronous-exception acquisition/bookkeeping gaps, foreign callbacks
that never return, unsafe FFI misuse and hostile-filesystem/process-crash limits
remain. Nothing proves bounded shutdown, cancellation-safe reuse, zero-copy,
allocation-free behavior or absence of durable effects after cancellation.

## Review package and readiness

Baseline retained: `.local/stage4b/before-packaging.diff`.
Focused authored diff from `2978138c`:
`.local/stage4b-packaging-review.diff`, selected explicitly with `jj diff --git`:

```sh
jj diff --git --from 2978138c -- \
  stage4/packaging docs/stage4b-packaging-validation.md \
  docs/superpowers/plans/2026-09-09-stage4b-bridge.md \
  > .local/stage4b-packaging-review.diff
```

The `--git` flag selects diff format; no raw Git command is used. Unrelated
formatting and `.pi/tasks` are absent from that artifact. Tracked template
changes, validation commands and residual gates are separately reviewable from
future production implementation. **Accepted for B1 execution only, not adapter
implementation.** Review `beecaaa8` accepted the fixture and found B1 ready. Its
P2 plan clarification is incorporated: native delivery is excluded/quiescent
before internal destructors, while complete ticket retirement/controller join
precedes terminal ML cleanup, rollback, owner release and disconnect.

The parent freshly ran `bash -n stage4/packaging/check.sh` and
`bash stage4/packaging/check.sh green`, exit **0**, including installed consumer
execution and all five intended compiler rejections. Log:
`.local/stage4b/packaging/logs/parent-green.txt`. This remains simulated packaging
evidence, not production engine safety. Start only B1, then review the real
Resource/FFI gates before proceeding.
