"""Fail-closed generated Eio scheduler-seam test copies; production is never edited."""

import hashlib
import json
from pathlib import Path

source = Path("lib_source.ml").read_text()
seams = [
    (
        "post_await",
        """      try
        let result = Eio.Promise.await completion in
        Eio.Fiber.check ();
""",
        """      try
        protected (fun () ->
          Test_support.before_completion_await (fun () -> Eio.Promise.await completion));
        let result = Eio.Promise.await completion in
        Eio.Fiber.check ();
""",
    ),
    (
        "offload_dispatch",
        """let offload phase f =
  try Eio_unix.run_in_systhread (fun () -> capture phase f)
""",
        """let offload phase f =
  try
    Test_support.before_offload_dispatch (match phase with Operation -> 0 | Connect -> 1 | Close_connection -> 2 | Close_database -> 3);
    Eio_unix.run_in_systhread (fun () ->
      Test_support.operation_worker_entry (match phase with Operation -> 0 | Connect -> 1 | Close_connection -> 2 | Close_database -> 3);
      capture phase f)
""",
    ),
]
out = source
for name, before, after in seams:
    if out.count(before) != 1:
        raise SystemExit(f"{name}: expected exactly one allowlisted seam")
    out = out.replace(before, after)
Path("duckdb_eio.ml").write_text(out)
Path("insertions.json").write_text(
    json.dumps(
        {
            "producer_sha256": hashlib.sha256(source.encode()).hexdigest(),
            "generated_sha256": hashlib.sha256(out.encode()).hexdigest(),
            "unchanged_inputs": {
                name: hashlib.sha256(Path(name).read_bytes()).hexdigest()
                for name in ["duckdb_eio.mli", "worker_owner.ml", "worker_owner.mli"]
            },
            "insertions": [name for name, _, _ in seams],
        },
        indent=2,
    )
    + "\n"
)
