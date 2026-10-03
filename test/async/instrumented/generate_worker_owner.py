"""Fail-closed worker-side callback cleanup observer for instrumented tests."""

import hashlib
import json
from pathlib import Path

source = Path("worker_owner_source.ml").read_text()
before = "Duckdb_worker.Make (Duckdb_worker.Silent)"
after = """Duckdb_worker.Make (struct
  let callback_restored ~active = Test_support.observe_callback_cleanup (not active)
  let explicit_flush = Test_support.observe_explicit_flush
end)"""
if source.count(before) != 1:
    raise SystemExit("worker-owner test seam drift: expected exactly one probe seam")
output = source.replace(before, after)
Path("worker_owner.ml").write_text(output)
Path("worker_owner-insertions.json").write_text(
    json.dumps(
        {
            "producer_sha256": hashlib.sha256(source.encode()).hexdigest(),
            "generated_sha256": hashlib.sha256(output.encode()).hexdigest(),
            "insertions": [
                "worker-side callback probe after TLS restoration",
                "explicit-flush adapter probe",
            ],
        },
        indent=2,
    )
    + "\n"
)
