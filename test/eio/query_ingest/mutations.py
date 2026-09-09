"""Focused behavior mutants, unchanged assertions, exact finally restoration.

Only test sources or generated private copies change. No core/FFI/adapter file
is edited. Logs are deliberately retained, including any failed control.
"""

import hashlib
import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
GENERATOR = ROOT / "test/eio/query_ingest/generate.py"
NATIVE = ROOT / "test/eio/foundation_hooks.c"
OUT = ROOT / ".local/stage4f/query-mutations"
CONTROLS = {
    "omit_explicit_flush": (
        "ingest_semantics",
        "explicit flush plus close flush",
        "worker_owner.ml",
        "Typed_probe.explicit_flush (); D.flush_appender appender",
        "Typed_probe.explicit_flush (); Ok ()",
    ),
    "leave_callback_tls": (
        "typed_values_and_failures",
        "Stop actual worker TLS restored",
        "worker_owner.ml",
        "Thread.TLS.set active previous; Typed_probe.callback_cleanup",
        "Thread.TLS.set active (previous || true); Typed_probe.callback_cleanup",
    ),
    "extra_operation_worker": (
        "typed_values_and_failures",
        "query one Operation worker",
        "duckdb_eio.ml",
        "Finished (offload Operation (fun () -> run owner request.bridge))",
        "let _ = offload Operation (fun () -> Ok ()) in Finished (offload Operation (fun () -> run owner request.bridge))",
    ),
    "bypass_selected_end_row": (
        "native_cancellation",
        "ingest_end_row selected released native entry",
        None,
        "typed_gate(3, (uintptr_t)appender == atomic_load(&typed_appender) &&",
        "typed_gate(3, false && (uintptr_t)appender == atomic_load(&typed_appender) &&",
    ),
    "extra_native_row_after_cancel": (
        "native_cancellation",
        "ingest_end_row no subsequent end-row work",
        None,
        "duckdb_state state = __real_duckdb_appender_end_row(appender);",
        """duckdb_state state = __real_duckdb_appender_end_row(appender);
  if (row == 1 && atomic_load(&typed_kind) == 3 && atomic_load(&typed_ack) == 1) {
    (void)duckdb_appender_begin_row(appender);
    (void)duckdb_append_int64(appender, 999);
    (void)__wrap_duckdb_appender_end_row(appender);
  }""",
    ),
}


def run(selector, path):
    command = [
        "timeout",
        "90",
        "stage1/run",
        "exec",
        "test/eio/query_ingest/query_ingest.exe",
        "--",
        selector,
    ]
    with path.open("w") as log:
        result = subprocess.run(
            command, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT, check=False
        )
    return {
        "command": command,
        "exit": result.returncode,
        "log": str(path.relative_to(ROOT)),
    }


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    selected = sys.argv[1:] or list(CONTROLS)
    for name in selected:
        selector, failure, generated, before, after = CONTROLS[name]
        path = GENERATOR if generated else NATIVE
        original = path.read_bytes()
        old_hash = hashlib.sha256(original).hexdigest()
        record = {
            "name": name,
            "unchanged_assertion": failure,
            "before_sha256": old_hash,
        }
        try:
            if generated:
                insertion = f"\np = Path({generated!r})\ns = p.read_text()\nassert s.count({before!r}) == 1\np.write_text(s.replace({before!r}, {after!r}))\n"
                path.write_bytes(original + insertion.encode())
            else:
                source = original.decode()
                assert source.count(before) == 1
                path.write_text(source.replace(before, after))
            record["red"] = run(selector, OUT / f"{name}-red.log")
            text = (ROOT / record["red"]["log"]).read_text()
            record["expected_red"] = (
                record["red"]["exit"] not in (0, 124, 137)
                and f'Failure("{failure}")' in text
            )
        finally:
            path.write_bytes(original)
            record["restored_sha256"] = hashlib.sha256(path.read_bytes()).hexdigest()
            record["exact_restoration"] = path.read_bytes() == original
        record["green"] = run(selector, OUT / f"{name}-green.log")
        (OUT / f"{name}.json").write_text(json.dumps(record, indent=2) + "\n")
        print(json.dumps(record), flush=True)
        if (
            not record.get("expected_red")
            or record["green"]["exit"] != 0
            or not record["exact_restoration"]
        ):
            raise SystemExit(f"failed mutation control: {name}")


if __name__ == "__main__":
    main()
