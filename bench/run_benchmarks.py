#!/usr/bin/env python3
"""Run and summarize the synchronous processing benchmark."""

import argparse
import csv
import hashlib
import json
import math
import os
import pathlib
import platform
import re
import shutil
import subprocess

FIELDS = (
    "sample",
    "path",
    "order",
    "rows",
    "checksum",
    "nulls",
    "execute_ns",
    "process_ns",
    "minor_words",
    "promoted_words",
    "major_words",
    "minor_collections",
    "major_collections",
    "compactions",
)
INT_FIELDS = {
    "sample",
    "rows",
    "checksum",
    "nulls",
    "execute_ns",
    "process_ns",
    "minor_collections",
    "major_collections",
    "compactions",
}
METRICS = FIELDS[6:]
PATHS = ("borrowed_chunks", "owned_rows")
ROOT = pathlib.Path(__file__).resolve().parents[1]


def median(values):
    ordered = sorted(values)
    size = len(ordered)
    if not size:
        raise ValueError("empty metric")
    middle = size // 2
    return ordered[middle] if size % 2 else (ordered[middle - 1] + ordered[middle]) / 2


def nearest_rank_p95(values):
    if not values:
        raise ValueError("empty metric")
    ordered = sorted(values)
    return ordered[math.ceil(0.95 * len(ordered)) - 1]


def coefficient_of_variation(values):
    if not values:
        raise ValueError("empty metric")
    average = sum(values) / len(values)
    if average == 0:
        return 0.0
    return (
        math.sqrt(sum((value - average) ** 2 for value in values) / len(values))
        / average
    )


def parse_tsv(text):
    lines = [line for line in text.splitlines() if line and not line.startswith("#")]
    if not lines:
        raise ValueError("missing TSV")
    reader = csv.DictReader(lines, delimiter="\t")
    if tuple(reader.fieldnames or ()) != FIELDS:
        raise ValueError("unexpected TSV header")
    result = []
    for raw in reader:
        try:
            row = {
                field: (
                    int(raw[field])
                    if field in INT_FIELDS
                    else float(raw[field])
                    if field.endswith("words")
                    else raw[field]
                )
                for field in FIELDS
            }
        except (KeyError, TypeError, ValueError) as error:
            raise ValueError("invalid TSV value") from error
        if row["path"] not in PATHS or row["order"] not in (
            "owned_first",
            "borrowed_first",
        ):
            raise ValueError("unknown path or order")
        if any(
            not math.isfinite(float(row[field])) or float(row[field]) < 0
            for field in METRICS
        ):
            raise ValueError("negative or nonfinite metric")
        result.append(row)
    return result


def validate_rows(rows, expected_samples=None):
    grouped = {path: [] for path in PATHS}
    for row in rows:
        grouped[row["path"]].append(row)
    if not all(grouped.values()):
        raise ValueError("missing benchmark path")
    for path in grouped:
        grouped[path].sort(key=lambda row: row["sample"])
        samples = [row["sample"] for row in grouped[path]]
        expected = (
            list(range(len(samples)))
            if expected_samples is None
            else list(range(expected_samples))
        )
        if samples != expected:
            raise ValueError("missing or duplicate sample")
    reference = [
        (row["sample"], row["rows"], row["checksum"], row["nulls"])
        for row in grouped[PATHS[0]]
    ]
    other = [
        (row["sample"], row["rows"], row["checksum"], row["nulls"])
        for row in grouped[PATHS[1]]
    ]
    if reference != other:
        raise ValueError("checksum/count mismatch")
    return {path: grouped[path] for path in sorted(grouped)}


def summarize(grouped):
    return {
        path: {
            metric: {
                "median": median([row[metric] for row in rows]),
                "p95": nearest_rank_p95([row[metric] for row in rows]),
                "min": min(row[metric] for row in rows),
                "max": max(row[metric] for row in rows),
                "cv": coefficient_of_variation([row[metric] for row in rows]),
            }
            for metric in METRICS
        }
        for path, rows in grouped.items()
    }


def parse_cpu_list(value):
    cpus = []
    for part in value.strip().split(","):
        match = re.fullmatch(r"(\d+)(?:-(\d+))?", part)
        if not match:
            raise ValueError("invalid CPU affinity")
        start, end = int(match.group(1)), int(match.group(2) or match.group(1))
        if end < start:
            raise ValueError("invalid CPU range")
        cpus.extend(range(start, end + 1))
    return sorted(set(cpus))


def affinity_command(command, cpu):
    return command if cpu is None else ["taskset", "--cpu-list", str(cpu), *command]


def command_output(argv):
    try:
        return subprocess.run(
            argv,
            cwd=ROOT,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=30,
            check=False,
        ).stdout.strip()
    except (OSError, subprocess.TimeoutExpired) as error:
        return "unavailable: " + str(error)


def sha256(path):
    digest = hashlib.sha256()
    with open(path, "rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def source_manifest():
    listed = subprocess.run(
        ["jj", "file", "list"], cwd=ROOT, text=True, capture_output=True, check=True
    ).stdout.splitlines()
    excluded = (
        ".pi/",
        ".pi-lens/",
        ".local/",
        ".ruff_cache/",
        "__pycache__/",
        "_build/",
        "_opam/",
        ".deps/",
    )
    entries = []
    for name in listed:
        if name.startswith(excluded):
            continue
        path = ROOT / name
        if path.is_file():
            entries.append(f"{sha256(path)}  {name}")
    return "\n".join(sorted(entries)) + "\n"


def discover_affinity():
    if shutil.which("taskset") is None:
        return None, "taskset unavailable"
    output = command_output(["taskset", "-pc", str(os.getpid())])
    match = re.search(r":\s*([0-9,-]+)\s*$", output)
    if not match:
        return None, "taskset affinity query failed: " + output
    try:
        return parse_cpu_list(match.group(1))[0], "pinned"
    except ValueError as error:
        return None, str(error)


def metadata(executable, manifest_sha256):
    header = ROOT / ".deps/duckdb/duckdb.h"
    library = ROOT / ".deps/duckdb/libduckdb.so"
    return {
        "kernel": platform.platform(),
        "cpu_model": next(
            (
                line.split(":", 1)[1].strip()
                for line in pathlib.Path("/proc/cpuinfo").read_text().splitlines()
                if line.startswith("model name")
            ),
            "unavailable",
        ),
        "load_average": list(os.getloadavg()),
        "ocamlc": command_output([str(ROOT / "_opam/bin/ocamlc"), "-version"]),
        "dune": command_output([str(ROOT / "tools/run"), "--version"]),
        "jj": command_output(["jj", "--version"]),
        "duckdb_header_sha256": sha256(header),
        "duckdb_library_sha256": sha256(library),
        "executable_sha256": sha256(executable),
        "source_manifest_sha256": manifest_sha256,
    }


def run_once(rows, warmups, samples, output, label, manifest_sha256):
    executable = ROOT / "_build/default/bench/benchmark_processing.exe"
    command = [
        str(ROOT / "tools/run"),
        "exec",
        "--no-build",
        "bench/benchmark_processing.exe",
        "--",
        "--rows",
        str(rows),
        "--warmups",
        str(warmups),
        "--samples",
        str(samples),
    ]
    cpu, affinity = discover_affinity()
    expanded = affinity_command(command, cpu)
    (output / f"{label}-command.txt").write_text(
        "COMMAND " + json.dumps(expanded) + "\n"
    )
    try:
        completed = subprocess.run(
            expanded, cwd=ROOT, text=True, capture_output=True, timeout=300, check=False
        )
    except subprocess.TimeoutExpired as error:
        (output / f"{label}-stderr.txt").write_text(
            (error.stderr or "") if isinstance(error.stderr, str) else "timeout"
        )
        raise RuntimeError("benchmark timeout") from error
    (output / f"{label}-stdout.txt").write_text(completed.stdout)
    (output / f"{label}-stderr.txt").write_text(completed.stderr)
    (output / f"{label}-command.txt").open("a").write(f"EXIT {completed.returncode}\n")
    if completed.returncode:
        raise RuntimeError(f"benchmark exited {completed.returncode}")
    grouped = validate_rows(parse_tsv(completed.stdout), samples)
    summary = summarize(grouped)
    (output / f"{label}.tsv").write_text(
        "\n".join(
            line for line in completed.stdout.splitlines() if not line.startswith("#")
        )
        + "\n"
    )
    data = {
        "label": label,
        "affinity": affinity,
        "cpu": cpu,
        "metadata": metadata(executable, manifest_sha256),
        "summary": summary,
        "correctness": {
            key: grouped[PATHS[0]][0][key] for key in ("rows", "checksum", "nulls")
        },
    }
    (output / f"{label}-summary.json").write_text(
        json.dumps(data, indent=2, sort_keys=True) + "\n"
    )
    return data


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--rows", type=int, required=True)
    parser.add_argument("--warmups", type=int, required=True)
    parser.add_argument("--samples", type=int, required=True)
    parser.add_argument("--output-dir", type=pathlib.Path, required=True)
    parser.add_argument("--correctness-only", action="store_true")
    args = parser.parse_args()
    if args.rows <= 0 or args.warmups < 0 or args.samples <= 0:
        parser.error("rows/samples must be positive and warmups nonnegative")
    if not args.correctness_only and args.samples != 10:
        parser.error(
            "measured mode requires exactly ten samples; use --correctness-only for tiny runs"
        )
    args.output_dir.mkdir(parents=True, exist_ok=True)
    manifest_bytes = source_manifest().encode()
    manifest_path = args.output_dir / "source-manifest.sha256"
    manifest_path.write_bytes(manifest_bytes)
    (args.output_dir / "source-manifest-bytes.sha256").write_text(
        hashlib.sha256(manifest_bytes).hexdigest() + "\n"
    )
    manifest_sha256 = hashlib.sha256(manifest_bytes).hexdigest()
    first = run_once(
        args.rows, args.warmups, args.samples, args.output_dir, "run-1", manifest_sha256
    )
    needs_rerun = any(
        first["summary"][path]["process_ns"]["cv"] > 0.20 for path in PATHS
    )
    if needs_rerun:
        run_once(
            args.rows,
            args.warmups,
            args.samples,
            args.output_dir,
            "run-2",
            manifest_sha256,
        )
    print(
        json.dumps(
            {"reported_run": "run-1", "rerun_retained": needs_rerun}, sort_keys=True
        )
    )


if __name__ == "__main__":
    main()
