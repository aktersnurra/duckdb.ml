# Stage 2: scoped BIGINT borrowing — evidence and decision

Validated 2026-09-08, x86-64 Artix/glibc. **Private stage-2 gate demonstrated; independent review required.** No public package/interface is frozen. Stages 3–5 are not implemented. Stage 1 remains unchanged, including the user's uncommitted whitespace in `stage1/ffi/check_unboxed.sh`.

## Decision and exact compiled interface

Choose **hidden ownership plus scoped local views**, not a claim of linear ownership. `stage2/borrowed.mli` compiles against its implementation with the pinned compiler:

```ocaml
type view
type error = Embedded_nul | Native_error of string | Unsupported_schema | Effects_not_allowed
type access_error = Out_of_bounds of int
type 'a step = Continue of 'a | Stop of 'a
val fold : string -> init:'a -> f:(view @ local -> 'a -> 'a step) -> ('a, error) result
val length : view @ local -> int
val get : view @ local -> int -> (int64 option, access_error) result
val copy : view @ local -> int64 option list
```

`fold` opens an independent in-memory database/connection, runs one query, validates exactly one BIGINT column, and visits nonempty chunks. `Continue` advances only after the callback returns; `Stop` returns its owned accumulator without fetching again. The only caller-visible capability is an abstract view. There is **no owner, close, reset, fetch, pointer, or conversion-to-owner operation** in this interface. Thus reentrant calls can open independent scopes but cannot invalidate an outer chunk. Views can alias within a callback; no affine/unique claim is made. Range-checked `get` returns an owned boxed scalar/NULL; `copy` makes an owned immutable list. The callback and accumulator are global; the view argument is local. This intentionally conservative callback signature rejects capturing an outer view even in another synchronous fold callback.

The private unsafe bridge (`Borrowed_ffi`, never a public safe interface) includes:

```ocaml
type owner
val create : unit -> owner
val prepare : owner -> string -> unit
val next : owner -> int
val close : owner -> unit
val length : owner @ local -> int
val valid : owner @ local -> int -> bool
val value : owner @ local -> int -> int64#
val box : int64# -> int64
```

Its native accessor returns actual DuckDB `int64_t` buffer contents as `int64#`, then the safe wrapper boxes them. `duckdb_vector_get_validity` is checked independently (NULL pointer means all-valid; otherwise bit `i % 64` in word `i / 64`). No NULL data slot is read. Foreign memory is **not** cast to an OCaml/OxCaml array. Neither zero-allocation, zero-copy-result, nor performance improvement is claimed. Handwritten stubs remain selected for the demonstrated native bits64 ABI, not speed.

## Compiler exploration and static restrictions

Read the existing SHA256-verified compiler archive, not current upstream HEAD. Exact revision: [2515546fea38e21e8143cc41db663bd56efc8d06](https://github.com/oxcaml/oxcaml/tree/2515546fea38e21e8143cc41db663bd56efc8d06). Relevant sources at that revision:

- `jane/doc/extensions/_02-stack-allocation/intro.md`: local callback arguments prevent ordinary escape; mutable fields cannot retain local values. `reference.md`, tail-call section: local closures require a non-tail call while their region is live. The copy loop uses the documented `[@nontail]`, not a cast.
- `jane/doc/extensions/_07-uniqueness/{intro,borrow,pitfalls,reference}.md` and `testsuite/tests/typing-unique/borrow.ml`: borrow regions, consuming unique uses, conservative closure capture, mode crossing and pattern-match cautions.
- `jane/doc/extensions/_05-modes/intro.md`, “Future modes: Yielding”: **not** a proof that ordinary `Effect.perform` is forbidden. `testsuite/tests/typing-local/effects.ml` explicitly demonstrates local stacks surviving captured continuations.
- Installed `stdlib/effect.mli:87–99` takes global computation closures for `Deep.match_with`/`try_with`. Installed `effect.ml` implements `discontinue` by resuming with an exception and deep handlers by `with_stack`; `None` forwards an effect, while our handler always returns `Some`.

`stage2/check_modes.sh` independently compiles the actual `.mli` sources and paired controls with `%{ocamlc} -extension-universe beta`. It checks intended diagnostics, not just nonzero status. Ten negative cases:

| Source in `stage2/experiments` | Required diagnostic / guarantee |
| --- | --- |
| `return.ml.fail` | View inside returned `Some`/`Stop`: local but expected global |
| `store.ml.fail` | View in global mutable ref: local but expected global |
| `capture.ml.fail` | Returned closure captures view: local but expected global |
| `domain.ml.fail` | `Domain.Safe.spawn (fun () -> view)`: **view** local but expected global, not an unrelated nonportable function |
| `owner_transition.ml.fail` | Passing view to existing FFI `close`: `Borrowed.view` is not `Borrowed_ffi.owner` |
| `owner_reuse.ml.fail` | Passing view to existing FFI `next`: same abstract-type mismatch |
| `unique_destroy.ml.fail` | Candidate unique owner consumed during `borrow_`: “being borrowed” |
| `unique_reuse.ml.fail` | Candidate owner used after consuming close: “already been used as unique” |
| `unique_closure.ml.fail` | Borrow in a closure then unique close: “already been borrowed in a closure that might be called later” |
| `inner_effect_escape.ml.fail` | Callback-owned handler's computation captures view: local but expected global |

Positive controls compile safe aliases, owned return/store/closure capture/domain transfer, independent FFI owner cleanup, and `Unique.use (borrow_ owner); Unique.close owner` against an abstract candidate signature `create : unit -> owner @ unique`, `use : owner @ local -> unit`, `close : owner @ unique -> unit`. These are **compiler experiments**, not native unique-destructor evidence. `local_only.ml` deliberately compiles a counterexample: a local-view callback can call close through an independently captured owner alias. Locality alone does not prevent invalidation. A closure-based unique borrow/protect design is not accepted by this compiler as written; other ownership designs are not asserted impossible. The smaller hidden-owner design needs no speculative uniqueness benefit or phantom state.

## Effects: compile acceptance is not runtime permission

`effect_counterexample.ml` compiles an outer handler capable of storing a continuation containing the borrowed callback. This proves that locality annotations alone do not express an effect-free callback. The first runtime test did **not** actually leak that continuation: it raised `Effect.Unhandled(Pause)`. Source investigation found `runtime/callback.c:544–560`: `Sys.with_async_exns` uses `caml_callback_exn`, introducing a C callback boundary effects cannot cross.

With supervisor approval, an explicit private deep barrier inside that boundary now:

1. Never forwards an escaping effect or gives its continuation to caller code.
2. Marks the scope as denied and synchronously `discontinue`s under the deep handler, including effects performed during unwinding.
3. Returns `Error Effects_not_allowed` on its private denial exception or normal return after a caught denial. Catch/reperform therefore cannot silently succeed.
4. Preserves independent ordinary callback exceptions and Sys.Break. A callback-created wrapper exception such as `Base.Exn.Finally(denial, denial)` remains an exception rather than being silently erased.

This is a **runtime no-escape barrier, not global effect purity**. Callback-owned inner handlers can process effects whose computation does not capture a borrowed view; those effects need not reach the barrier. Attempting to capture the view in such an inner computation is a paired compile rejection. Nested independent folds have their own barriers. Tests assert outer-handler non-delivery, catch/reperform rejection, effects in callback cleanup, one execution of that cleanup, preservation of composite exceptions, a successful inner handler and zero retained native resources. No adapter or scheduler is implemented. Callbacks that never return are outside any termination/cleanup guarantee.

## Native ownership and cleanup boundary

`native_borrow.c` uses public DuckDB 1.5.5 chunk/vector APIs. A rooted custom block owns stable C storage. SQL is copied and all native handles extracted **before** `caml_enter_blocking_section`; unlocked prepare/fetch code reads only native storage. The native owner receives query results (even failed results) and chunks before reacquisition. No movable OCaml pointer is retained across unlock. GC/compaction under concurrent systhread pressure exercises both dynamic SQL and this handoff.

`Borrowed.fold` establishes `Exn.protect` before prepare/fetch, with `Sys.with_async_exns` **inside** its body. A locked, nonallocating destructor makes no OCaml callbacks, polling or runtime unlocks. It clears derived data/validity pointers and destroys **chunk → result → connection → database**, then remaining SQL and owner storage. This intentionally holds the runtime lock during possibly blocking destruction: safe for this private synchronous prototype, **not** an acceptable adapter responsiveness claim. Query/fetch remain unlocked.

Native diagnostics check the actual close trace (`1234` for early exit with live chunk, `234` after exhaustion/error, `5` for SQL-only acquisition), cleared length/pointers and idempotent second close. The FFI clears its owner slot; two FFI closes are also tested. Atomic live-resource counters include native owner, SQL, database, connection, result and chunk. A separate counter detects **GC-finalizer reclamation**, so forced GC cannot make a fallback look deterministic.

### What is and is not deterministic

- Ordinary successful completion, early stop, query/schema errors, ordinary callback exceptions and effect-abort paths destroy all native resources without requiring GC.
- Real SIGUSR1 handlers raising the exact runtime `Sys.Break` are injected before query enter/leave, first fetch enter/leave, subsequent fetch enter/leave, in a live borrowed callback, and immediately before the destructor on normal/exceptional exit. All nine tests assert one injection/handler, expected live-resource count at injection, zero live resources afterwards and **zero fallback reclaims**.
- The query-enter mutation removing the **inner** `Sys.with_async_exns` fails the zero-resource assertion (exit 2); restoration passes. An ordinary protect alone is demonstrably insufficient on this runtime.
- **Not an unconditional deterministic-close guarantee:** asynchronous interruption in acquisition/protect setup or outside the protected body, arbitrary repeated interruption, OOM/fault exhaustion and fatal process termination are not proved. The constructor can leave an empty native owner shell for finalization if interrupted before protection is established. The finalizer remains an eventual backstop, with no deadline. Escaped usable views/owner invalidation are prevented independently; delayed reclamation is not permission to access freed storage.
- Pinned `runtime/signals.c:209–222` processes handlers before releasing the runtime; `273–302` makes arbitrary raising handlers fatal except Sys.Break. Installed `sys.mli:415–423` documents the per-domain (not per-fiber) asynchronous-exception boundary. `runtime/callback.c:550–557` drains pending actions before re-raising ordinarily. This evidence is specific to the pinned runtime, not a portable promise.

## Red/green and final commands

All commands run from repository root unless stated. Raw logs are ignored under `.local/logs/stage2/`.

| Check | Observation |
| --- | --- |
| `.mli` + tests before implementation, `stage1/run build stage2/borrowed_tests.exe` | Red: missing `borrowed`/`borrowed_ffi` implementations (`runtime-red.txt`) |
| First mode positive domain copy | Red: unconstrained polymorphic list is contended in portable closure; concrete `int64 option list` annotation passes, without weakening domain checking |
| First implementation compile | Red: copy-loop local closure in tail position; documented `[@nontail]` fixes it (`build-first.txt`) |
| Effect test before explicit barrier | Red: `Effect.Unhandled(Pause)` rather than structured denial (`effect-red.txt`); final tests pass (`effect-green.txt`) |
| Remove inner async boundary, `timeout 30 stage1/run exec stage2/signal_tests.exe -- query-enter` | Red: zero-live-resource assertion, exit 2 (`async-boundary-mutation-red.txt`); restored green (`async-boundary-green.txt`) |
| `stage1/run clean && stage1/run build @all` | Pass; only documented stage-1 Ctypes vendor macro warnings (`clean-build.txt`) |
| `stage1/run runtest --force` | Pass all stage-1 + stage-2 tests (`final-runtest.txt`) |
| `python3 -m unittest discover -s stage1 -p 'test_*.py' -v` | 8 tests, OK (`bootstrap-tests.txt`) |
| Each of eight original signal cases + borrowed/effect executables, 10 repetitions via `timeout 30 stage1/run exec --no-build ...`; callback case separately 10 times | 90 signal checks + 10 borrowed + 10 effect runs pass (`repeated.txt`, `repeated-callback.txt`) |
| `clang -std=c11 -Wall -Wextra -Werror -fsyntax-only -I.deps/duckdb -I_opam/lib/ocaml stage2/native_borrow.c stage2/borrowed_stubs.c stage2/native_diagnostics.c stage2/signal_test_stubs.c` | Exit 0, no diagnostics (`clang.txt`) |
| `clangd --check=stage2/<file>.c --compile-commands-dir=.local --tweaks=` for the same four files | All report 0 errors; only ignored project-local compilation database updated |
| `ldd _build/default/stage2/borrowed_tests.exe` | `libduckdb.so` resolves to project `.deps/duckdb/libduckdb.so` |

Representative final outputs:

```text
modes: positive controls and 10 intended rejections passed
borrowed: chunks=3 rows=5000 null/extrema/copy/domain/GC/stop/exn/reentrant/cleanup=ok
effects: outer non-delivery/catch-reperform/cleanup/nested-handler=ok
query-enter: live-at-signal=2 deterministic-cleanup=ok
fetch-leave: live-at-signal=5 deterministic-cleanup=ok
callback: live-at-signal=5 deterministic-cleanup=ok
native-borrow: DuckDB v1.5.5, 30 nullable/multichunk/empty/extrema/error/order/idempotence cycles, ASan/UBSan/LSan=ok
```

Runtime data checks include zero callbacks for empty results, 5,000 ordered rows in three chunks, validity across 64-bit words, all-NULL, both signed extrema, negative/end indices, SQL/schema/NUL errors, copied results after scope and `Domain.Safe.spawn`, compaction while views are live, three dynamically allocated long SQL queries during background GC, 100 repeated query cleanup cycles, aliases, reentrant independent queries, early stop and ordinary exceptions. DuckDB did not produce an intermediate zero-length chunk in these queries; the skip branch exists but is not separately fault-injected.

ASan/UBSan/LSan diagnostics instrument `native_borrow.c` and the native test, not the prebuilt DuckDB engine, OCaml runtime or OCaml-boundary stubs. Counters, runtime tests and source inspection cover those boundaries. Allocation exhaustion, failed connection/fetch fault injection and arbitrary asynchronous interruption remain untested. Error text is bounded to 511 bytes.

## Pins, diagnostics and next-stage contract

No toolchain/native change or install occurred. Compiler package `oxcaml-compiler.5.2.0minus39` reports `5.2.0+ox`; Dune package `3.22.2+ox` via `stage1/run`; Base remains `v0.18~preview.130.106+341`. Rechecked SHA256: compiler archive `93dbcf859e655d2a2b41dfa077c126fa5a15fd0205b1c57dbb5ff2cc9d595462`; DuckDB header `48e716b9ce96ca8fead9cb35693fdc0343ac0fc1f6e7db5561fa0f44b674153d`; library `fc23f12e376c47be520f75221288281906e7942e8fd6f6ce4849198ba60d0405`.

Ambient OCaml LSP remains **unavailable**, not passed: it cannot parse this pinned OxCaml's `@ local`, `borrow_`, `int64#` or compiler flags, and standalone compile-fixture files intentionally have no Dune library module. Repeated editor diagnostics were not used to change valid source or user/shared settings. Real compiler failures (mode errors, local tail call, Base deprecation warnings-as-errors) were investigated and fixed; all final compiler/native checks pass.

Stage 3 may build on hidden-owner scoped traversal and explicit owned copying. It must separately design reusable database/connection handles, parent-child invalidation, dynamic state/lease checks if handles are exposed, broader typed columns, deterministic-close wording and typed local Parquet/appender functionality. Do not infer those guarantees from this prototype. Retain the effect no-escape boundary and negative suite, or demonstrate a replacement before changing them. No Async/Eio borrowed callbacks, pooling, cancellation or public performance claims follow from this stage.
