"""Fail-closed Stage4f copies; insertion/removal equality is the no-op control."""

import hashlib
import json
from pathlib import Path


def generate(source, target, seams):
    original = Path(source).read_text()
    output = original
    for before, after in seams:
        if output.count(before) != 1:
            raise SystemExit(f"{source}: anchor count: {before!r}")
        output = output.replace(before, after)
    restored = output
    for before, after in reversed(seams):
        if restored.count(after) != 1:
            raise SystemExit("ambiguous reverse anchor")
        restored = restored.replace(after, before)
    assert restored == original
    Path(target).write_text(output)
    return {
        "source": hashlib.sha256(original.encode()).hexdigest(),
        "generated": hashlib.sha256(output.encode()).hexdigest(),
        "reverse_noop": restored == original,
    }


manifest = {}
manifest["adapter"] = generate(
    "adapter_source.ml",
    "duckdb_eio.ml",
    [
        (
            "Eio_unix.run_in_systhread (fun () -> capture phase f)",
            "Eio_unix.run_in_systhread (fun () ->\n    (match phase with Operation -> Typed_probe.operation_entry () | _ -> ());\n    capture phase f)",
        ),
        (
            "cancel request;\n        let settled",
            "cancel request;\n        Typed_probe.cancellation_latched ();\n        let settled",
        ),
    ],
)
manifest["capsule"] = generate(
    "owner_source.ml",
    "worker_owner.ml",
    [
        (
            "Duckdb_worker.Make (Duckdb_worker.Silent)",
            "Duckdb_worker.Make (struct\n  let callback_restored ~active = Typed_probe.callback_cleanup active\n  let explicit_flush = Typed_probe.explicit_flush\nend)",
        ),
    ],
)
manifest["worker"] = generate("worker_source.ml", "duckdb_worker.ml", [])
manifest["probe"] = generate(
    "probe_source.ml", "typed_probe.ml", [("let enabled = false", "let enabled = true")]
)
Path("insertions.json").write_text(json.dumps(manifest, indent=2) + "\n")
