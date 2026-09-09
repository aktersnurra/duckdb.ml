"""Fail-closed, allowlisted ML test insertions; never alter producer sources."""

import hashlib
import json
from pathlib import Path

source = Path("lib_source.ml").read_text()
insertions = [
   (
      "reserve",
      "Result.map_error (In_thread.Helper_thread.create_now ())",
      "Result.map_error (Test_support.before_reserve (); In_thread.Helper_thread.create_now ())",
   ),
   (
      "release",
      "In_thread.Helper_thread.finished_with helper; Ok ()",
      "In_thread.Helper_thread.finished_with helper; Test_support.helper_released (); Ok ()",
   ),
   (
      "dispatch",
      "Ok (In_thread.run ~thread:helper",
      "Test_support.before_dispatch (); Ok (In_thread.run ~thread:helper",
   ),
   (
      "entry",
      "  let work () =\n",
      "  let work () =\n    Test_support.worker_entry ();\n",
   ),
   (
      "returned",
      "    with_gate gate (fun () -> gate.execution <- Returned);\n    result",
      "    with_gate gate (fun () -> gate.execution <- Returned);\n    Test_support.worker_returned ();\n    result",
   ),
]
output = source
for name, before, after in insertions:
   if output.count(before) != 1:
      raise SystemExit(f"{name}: source drift: expected exactly one insertion seam")
   output = output.replace(before, after)
Path("duckdb_async.ml").write_text(output)
Path("insertions.json").write_text(
   json.dumps(
      {
         "producer_sha256": hashlib.sha256(source.encode()).hexdigest(),
         "generated_sha256": hashlib.sha256(output.encode()).hexdigest(),
         "unchanged_inputs": {
            name: hashlib.sha256(Path(name).read_bytes()).hexdigest()
            for name in ["duckdb_async.mli", "worker_owner.ml", "worker_owner.mli"]
         },
         "insertions": insertions,
      },
      indent=2,
   )
   + "\n"
)
