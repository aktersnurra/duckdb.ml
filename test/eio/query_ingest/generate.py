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
            "~finally:(fun () -> Thread.TLS.set active previous)",
            "~finally:(fun () -> Thread.TLS.set active previous; Typed_probe.callback_cleanup (Thread.TLS.get active))",
        ),
        (
            "if flush then D.flush_appender appender else Ok ()",
            "if flush then (Typed_probe.explicit_flush (); D.flush_appender appender) else Ok ()",
        ),
    ],
)
manifest["probe"] = generate(
    "probe_source.ml", "typed_probe.ml", [("let enabled = false", "let enabled = true")]
)
Path("insertions.json").write_text(json.dumps(manifest, indent=2) + "\n")
