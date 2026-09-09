import hashlib
import json
from pathlib import Path

source = Path("lib_source.ml").read_text()
seams = [
    (
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
        """let offload phase f =
  try Eio_unix.run_in_systhread (fun () -> capture phase f)
""",
        """let offload phase f =
  try
    Test_support.before_offload_dispatch (match phase with Operation -> 0 | Connect -> 1 | Close_connection -> 2 | Close_database -> 3);
    Eio_unix.run_in_systhread (fun () -> capture phase f)
""",
    ),
]
out = source
for before, after in seams:
    if out.count(before) != 1:
        raise SystemExit("source drift")
    out = out.replace(before, after)
needle = """        let result = Eio.Promise.await completion in
        Eio.Fiber.check ();
        match result with"""
if out.count(needle) != 1:
    raise SystemExit("post-await seam drift")
out = out.replace(
    needle,
    """        let result = Eio.Promise.await completion in
        match result with""",
)
Path("duckdb_eio_mutant.ml").write_text(out)
Path("insertions.json").write_text(
    json.dumps(
        {
            "producer_sha256": hashlib.sha256(source.encode()).hexdigest(),
            "generated_sha256": hashlib.sha256(out.encode()).hexdigest(),
            "mutation": "removed submit post-await Eio.Fiber.check",
        },
        indent=2,
    )
    + "\n"
)
