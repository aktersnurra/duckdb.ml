"""Bounded real behavior mutants; unchanged assertions and bytewise restoration.

Next-file mutant uses the SAME cancelled native connection after the selected
first statement retires. No safe core or production adapter source is edited.
"""

import hashlib
import json
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
OUT = ROOT / ".local/stage4f/parquet-mutations"
NATIVE = ROOT / "test/eio/parquet_hooks.c"
CASES = ROOT / "test/eio/parquet_cases.ml"
GENERATOR = ROOT / "test/eio/parquet_native/generate.py"
NEXT = """wait_at(1, first);
  if (first && atomic_load(&selected_kind) == 1 && atomic_load(&counts[0]) == 1) {
    char sql[8192]; snprintf(sql, sizeof sql, "SELECT * FROM read_parquet('%s')", second_path);
    duckdb_extracted_statements e = NULL;
    duckdb_prepared_statement next = NULL;
    duckdb_result result = {0};
    if (__wrap_duckdb_extract_statements(mutant_connection, sql, &e) == 1 &&
        __wrap_duckdb_prepare_extracted_statement(mutant_connection, e, 0, &next) == DuckDBSuccess) {
      (void)__wrap_duckdb_execute_prepared(next, &result);
      __wrap_duckdb_destroy_result(&result);
    }
    if (next) __wrap_duckdb_destroy_prepare(&next);
    if (e) duckdb_destroy_extracted(&e);
  }"""
CONTROLS = {
    "delete_actual_published_final": (
        CASES,
        "export_boundaries",
        "published final from cancelled request survives",
        [
            (
                "let published_final_side_effect_mutation _destination = ()",
                "let published_final_side_effect_mutation destination = Stdlib.Sys.remove destination",
            )
        ],
    ),
    "next_file_same_cancelled_owner": (
        NATIVE,
        "between_files",
        "second file native work and callbacks suppressed",
        [
            (
                "static _Thread_local duckdb_extracted_statements selected_extracted;",
                "static _Thread_local duckdb_extracted_statements selected_extracted;\nstatic _Thread_local duckdb_connection mutant_connection;",
            ),
            (
                "  extracted_first = first_path[0]",
                "  mutant_connection = c;\n  extracted_first = first_path[0]",
            ),
            ("wait_at(1, first);", NEXT),
        ],
    ),
    "select_premature_schema_validator": (
        NATIVE,
        "between_files",
        "first file callbacks and actual children retired before cancellation",
        [
            (
                "if (first) atomic_compare_exchange_strong(&first_prepared, &empty, (uintptr_t)*p);",
                "if (first) atomic_store(&first_prepared, (uintptr_t)*p);",
            )
        ],
    ),
    "bypass_selected_hold": (
        NATIVE,
        "between_files",
        "between_files selected released native entry",
        [("wait_at(1, first);", "wait_at(1, false && first);")],
    ),
    "leave_actual_parquet_tls": (
        GENERATOR,
        "read_semantics",
        "Stop actual worker TLS restored",
        [],
    ),
}


def run(selector, path):
    command = [
        "timeout",
        "90",
        "stage1/run",
        "exec",
        "test/eio/parquet_native/parquet_native.exe",
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
    for name, (path, selector, failure, edits) in CONTROLS.items():
        original = path.read_bytes()
        record = {
            "name": name,
            "unchanged_assertion": failure,
            "before_sha256": hashlib.sha256(original).hexdigest(),
        }
        try:
            source = original.decode()
            for before, after in edits:
                assert source.count(before) == 1
                source = source.replace(before, after)
            if name == "leave_actual_parquet_tls":
                before = "Thread.TLS.set active previous; Typed_probe.callback_cleanup"
                after = "Thread.TLS.set active (previous || true); Typed_probe.callback_cleanup"
                source += f"\np = Path('worker_owner.ml')\ns = p.read_text()\nassert s.count({before!r}) == 1\np.write_text(s.replace({before!r}, {after!r}))\n"
            path.write_text(source)
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
