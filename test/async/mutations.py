"""Independent, restored Stage4c regressions; run only as the sole writer."""

import hashlib
import json
import subprocess
from pathlib import Path

root = Path(__file__).resolve().parents[2]
source = root / "lib/async/duckdb_async.ml"
original = source.read_bytes()
out = root / ".local/stage4c/implementation/mutations"
out.mkdir(parents=True, exist_ok=True)
(out / "duckdb_async.ml.backup").write_bytes(original)
mutations = [
    (
        "queue_bound",
        ">= pool.limits.queue_capacity",
        "> pool.limits.queue_capacity",
        "zero_queue",
        "zero queue rejects one waiting",
        False,
    ),
    (
        "prefix_release",
        "combine result (release_helpers (List.rev !held))",
        "result",
        "reserve_partial_failure",
        "partial reservations released exactly once",
        True,
    ),
    (
        "terminal_latch",
        "with_gate r.gate (fun () -> r.gate.cancelled <- true);",
        "with_gate r.gate (fun () -> r.gate.cancelled <- false);",
        "cancel_at_terminal",
        "preterminal cancellation wins",
        True,
    ),
    (
        "notification_early",
        "    r.outcome <- Some result;",
        "    r.outcome <- Some result;\n    notify r.observer result;",
        "worker_exception_monitor",
        "completion before exceptional monitor",
        False,
    ),
    (
        "dispatched_completion_early",
        "  don't_wait_for (offload slot.helper work",
        "  Ivar.fill_exn r.result (Error (Expected Cancelled));\n  don't_wait_for (offload slot.helper work",
        "dispatched_cancel",
        "dispatched capsule retained before acknowledgement",
        True,
    ),
    (
        "completion_early",
        "    r.outcome <- Some result;",
        "    r.outcome <- Some result;\n    Ivar.fill_exn r.result result;",
        "replacement_stop",
        "completion after actual native heartbeat",
        False,
    ),
    (
        "shutdown_candidate_close",
        "| Stopping | Stopped -> slot.state <- Needs_close));",
        "| Stopping | Stopped -> slot.state <- Closed; finish_lease slot));",
        "replacement_stop",
        "replacement candidate closed before stopped request completion",
        False,
    ),
    (
        "helpers_early",
        "      then (\n        pool.maintenance_busy <- true;",
        "      then (\n        pool.lifecycle_result <- combine pool.lifecycle_result (release_helpers pool.helpers);\n        pool.helpers <- [];\n        pool.maintenance_busy <- true;",
        "shutdown_helpers",
        "helpers retained until last job acknowledges",
        True,
    ),
    (
        "slot_failure_order",
        "slot.cleanup_result <- combine slot.cleanup_result (Error failure);",
        "slot.cleanup_result <- Ok (); pool.lifecycle_result <- combine pool.lifecycle_result (Error failure);",
        "close_failure_slot_order",
        "independent close failures ordered by acquisition slot",
        False,
    ),
    (
        "stale_routing",
        "| Finished -> Ok Already_finished",
        "| Finished -> List.iter r.pool.slots ~f:(fun slot -> Option.iter slot.lease ~f:(fun (Pack current) -> latch current)); Ok Already_finished",
        "stale_reuse",
        "late A causes zero B interrupt",
        False,
    ),
]
records = []


def command(label, args, expected=0, assertion=None):
    result = subprocess.run(
        args, cwd=root, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, check=False
    )
    text = result.stdout.decode(errors="replace")
    (out / (label + ".log")).write_text(
        "$ " + " ".join(args) + "\n" + text + f"\nexit={result.returncode}\n"
    )
    if result.returncode != expected or (assertion and assertion not in text):
        raise RuntimeError(
            f"{label}: exit {result.returncode}, expected {expected}; assertion={assertion!r}"
        )
    return text


try:
    for name, before, after, case, assertion, instrumented in mutations:
        text = original.decode()
        if text.count(before) != 1:
            raise RuntimeError(f"{name}: mutation seam drift")
        source.write_text(text.replace(before, after))
        target = (
            "test/async/"
            + ("instrumented/" if instrumented else "")
            + "test_duckdb_async.exe"
        )
        try:
            command(name + "-build", ["tools/run", "build", target])
            args = [
                "timeout",
                "120",
                "tools/run",
                "exec",
                "--no-build",
                target,
                "--",
                case,
            ]
            if instrumented:
                args.append("--instrumented")
            command(name + "-red", args, expected=1, assertion=assertion)
        finally:
            source.write_bytes(original)
        command(name + "-restored-build", ["tools/run", "build", target])
        command(name + "-restored-green", args)
        records.append(
            {
                "name": name,
                "assertion": assertion,
                "restored_sha256": hashlib.sha256(source.read_bytes()).hexdigest(),
            }
        )
        (out / "restoration.json").write_text(json.dumps(records, indent=2) + "\n")
        print("PASS independent mutation", name, "restored exact bytes", flush=True)
    # Keep the independent Bridge defense: do not delete two checks to force red.
    before = "Awaiting_entry -> if gate.cancelled then false else"
    assert original.decode().count(before) == 1
    target = "test/async/instrumented/test_duckdb_async.exe"
    try:
        source.write_text(
            original.decode().replace(
                before, "Awaiting_entry -> if false then false else"
            )
        )
        command("dispatch-gate-redundancy-build", ["tools/run", "build", target])
        command(
            "dispatch-gate-redundancy-green",
            [
                "timeout",
                "120",
                "tools/run",
                "exec",
                "--no-build",
                target,
                "--",
                "dispatched_cancel",
                "--instrumented",
            ],
        )
    finally:
        source.write_bytes(original)
    command("dispatch-gate-restored-build", ["tools/run", "build", target])
    command(
        "dispatch-gate-restored-green",
        [
            "timeout",
            "120",
            "tools/run",
            "exec",
            "--no-build",
            target,
            "--",
            "dispatched_cancel",
            "--instrumented",
        ],
    )
    print(
        "REDUNDANT dispatch gate: unchanged independent Bridge latch still suppresses work; not counted as red",
        flush=True,
    )
finally:
    source.write_bytes(original)
    assert source.read_bytes() == original
