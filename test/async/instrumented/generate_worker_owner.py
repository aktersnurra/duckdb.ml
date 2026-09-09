"""Fail-closed worker-side callback cleanup observer for instrumented tests."""

import hashlib
import json
from pathlib import Path

source = Path("worker_owner_source.ml").read_text()
before = (
    """  Exn.protect ~f ~finally:(fun () -> System_thread.TLS.set active previous)"""
)
after = """  Exn.protect ~f ~finally:(fun () ->
    System_thread.TLS.set active previous;
    Test_support.observe_callback_cleanup (not (System_thread.TLS.get active)))"""
flush_before = """D.flush_appender appender"""
flush_after = """(Test_support.observe_explicit_flush (); D.flush_appender appender)"""
if source.count(before) != 1 or source.count(flush_before) != 1:
    raise SystemExit(
        "worker-owner test seam drift: expected exactly one insertion each"
    )
output = source.replace(before, after).replace(flush_before, flush_after)
Path("worker_owner.ml").write_text(output)
Path("worker_owner-insertions.json").write_text(
    json.dumps(
        {
            "producer_sha256": hashlib.sha256(source.encode()).hexdigest(),
            "generated_sha256": hashlib.sha256(output.encode()).hexdigest(),
            "insertions": [
                "worker-side callback finally after TLS restoration",
                "explicit-flush adapter call",
            ],
        },
        indent=2,
    )
    + "\n"
)
