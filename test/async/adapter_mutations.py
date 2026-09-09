"""Restored Stage4d oracle controls; run only as the sole writer.

These mutations deliberately exercise only the Stage4d additions.  They are not
an historical Stage4c campaign and restore the exact bytes after every red run.
"""

import hashlib
import json
import subprocess
import sys
from pathlib import Path

root = Path(__file__).resolve().parents[2]
out = root / ".local/stage4d/mutations"
out.mkdir(parents=True, exist_ok=True)


def run(label, args, expected, assertion):
    result = subprocess.run(
        args, cwd=root, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, check=False
    )
    text = result.stdout.decode(errors="replace")
    (out / f"{label}.log").write_text(
        "$ " + " ".join(args) + "\n" + text + f"\nexit={result.returncode}\n"
    )
    if (
        result.returncode != expected
        or assertion not in text
        or result.returncode == 124
    ):
        raise RuntimeError(
            f"{label}: exit={result.returncode}; expected={expected}; assertion={assertion!r}"
        )


def mutate(name, path, before, after, selector, assertion, instrumented=False):
    original = path.read_bytes()
    text = original.decode()
    if text.count(before) != 1:
        raise RuntimeError(f"{name}: mutation seam drift")
    try:
        path.write_text(text.replace(before, after))
        target = (
            "test/async/instrumented/test_duckdb_async.exe"
            if instrumented
            else "test/async/test_duckdb_async.exe"
        )
        run(f"{name}-build", ["tools/run", "build", target], 0, "")
        run(
            f"{name}-red",
            [
                "timeout",
                "30",
                "tools/run",
                "exec",
                "--no-build",
                target,
                "--",
                *(["--instrumented"] if instrumented else []),
                selector,
            ],
            1,
            assertion,
        )
    finally:
        path.write_bytes(original)
    if path.read_bytes() != original:
        raise RuntimeError(f"{name}: restoration mismatch")
    run(f"{name}-restored-build", ["tools/run", "build", target], 0, "")
    run(
        f"{name}-restored-green",
        [
            "timeout",
            "120",
            "tools/run",
            "exec",
            "--no-build",
            target,
            "--",
            *(["--instrumented"] if instrumented else []),
            selector,
        ],
        0,
        "PASS " + selector,
    )
    return {
        "name": name,
        "assertion": assertion,
        "restored_sha256": hashlib.sha256(original).hexdigest(),
    }


selected = set(sys.argv[1:])
if not selected:
    selected = {"explicit_flush_omission", "published_final_side_effect"}
unknown = selected - {"explicit_flush_omission", "published_final_side_effect"}
if unknown:
    raise RuntimeError(f"unknown mutation(s): {sorted(unknown)}")

records = []
try:
    if "explicit_flush_omission" in selected:
        records.append(
            mutate(
                "explicit_flush_omission",
                root / "lib/async/worker_owner.ml",
                "if flush then D.flush_appender appender else Ok ()",
                "if flush then (if false then D.flush_appender appender else Ok ()) else Ok ()",
                "ingest_rollback_and_auto_flush",
                "explicit flush is adapter initiated before close",
                instrumented=True,
            )
        )
    if "published_final_side_effect" in selected:
        records.append(
            mutate(
                "published_final_side_effect",
                root / "test/async/test_typed_cases.ml",
                "published_final_side_effect_mutation destination;",
                "published_final_side_effect_mutation destination; Stdlib.Sys.remove destination;",
                "parquet_export_cancellation_and_publication",
                "published final from cancelled request survives",
            )
        )
finally:
    (out / "restoration.json").write_text(json.dumps(records, indent=2) + "\n")

print(
    "PASS Stage4d oracle mutations: exact restoration and named non-timeout reds",
    flush=True,
)
