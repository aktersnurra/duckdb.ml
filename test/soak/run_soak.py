#!/usr/bin/env python3
"""Run the fixed adapter causal selectors with reproducible ordering."""

import argparse
import pathlib
import random
import subprocess
import sys
import time

ASYNC = (
    "fifo_survivors",
    "running_reset",
    "stale_reuse",
    "stale_replacement",
    "transaction_exclusion",
    "shutdown_running",
    "heartbeat_cancel_result",
    "heartbeat_and_cancel_ingest",
    "parquet_cancel_between_files",
    "parquet_export_cancellation_and_publication",
)
EIO = (
    "queue_and_admission",
    "running_cancellation_then_reuse",
    "foreign_return_then_reuse",
    "transaction_between_statements",
    "replacement_shutdown_wins",
    "saturated_shutdown",
    "native_cancellation",
    "metadata_race",
    "between_files",
    "export_boundaries",
)


class ChildFailure(RuntimeError):
    pass


def manifest(adapter):
    if adapter == "async":
        return ASYNC
    if adapter == "eio":
        return EIO
    raise ValueError(f"unknown adapter: {adapter}")


def ordered_manifest(seed, adapter):
    values = list(manifest(adapter))
    random.Random(seed).shuffle(values)
    return values


GENERATED_EIO = {
    "native_cancellation",
    "metadata_race",
    "between_files",
    "export_boundaries",
}


def marker_for(adapter, selector):
    if selector not in manifest(adapter):
        raise ValueError(f"unknown {adapter} selector: {selector}")
    if adapter == "async":
        return f"PASS {selector}"
    generated = " generated=true" if selector in GENERATED_EIO else ""
    return f"{selector}: PASS{generated}"


def append(log, text):
    with log.open("a", encoding="utf-8") as handle:
        handle.write(text + "\n")


def run_child(
    argv,
    marker,
    timeout,
    log,
    adapter,
    seed,
    index,
    selector,
    repetition=0,
    effective_seed=None,
):
    if effective_seed is None:
        effective_seed = seed + repetition
    append(
        log,
        f"COMMAND adapter={adapter} base_seed={seed} repetition={repetition} effective_seed={effective_seed} index={index} selector={selector} argv={argv!r}",
    )
    started = time.monotonic()
    try:
        completed = subprocess.run(
            argv,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            timeout=timeout,
            check=False,
        )
    except subprocess.TimeoutExpired as error:
        append(
            log,
            f"EXIT timeout adapter={adapter} seed={seed} index={index} duration={time.monotonic() - started:.3f}",
        )
        raise ChildFailure(
            f"timeout adapter={adapter} seed={seed} index={index}: {error}"
        ) from error
    output = completed.stdout[-16000:]
    append(
        log,
        f"EXIT code={completed.returncode} adapter={adapter} seed={seed} index={index} duration={time.monotonic() - started:.3f}\n{output}",
    )
    if completed.returncode != 0 or marker not in output:
        raise ChildFailure(
            f"failure adapter={adapter} seed={seed} index={index} selector={selector} exit={completed.returncode}"
        )


def command(adapter, selector):
    if adapter == "async":
        return [
            "./tools/run",
            "exec",
            "--no-build",
            "test/async/test_duckdb_async.exe",
            "--",
            selector,
        ]
    if selector in {"native_cancellation", "metadata_race"}:
        target = "test/eio/query_ingest/query_ingest.exe"
    elif selector in {"between_files", "export_boundaries"}:
        target = "test/eio/parquet_native/parquet_native.exe"
    else:
        target = "test/eio/foundation_eio.exe"
    return ["./tools/run", "exec", "--no-build", target, "--", selector]


def main(argv=None):
    parser = argparse.ArgumentParser()
    parser.add_argument("--seed", type=int, action="append", required=True)
    parser.add_argument("--repetitions", type=int, default=2)
    parser.add_argument("--timeout", type=float, default=120)
    parser.add_argument("--output", type=pathlib.Path, required=True)
    args = parser.parse_args(argv)
    if args.repetitions <= 0 or args.timeout <= 0:
        parser.error("repetitions and timeout must be positive")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text("")
    index = 0
    for adapter in ("async", "eio"):
        for repetition in range(args.repetitions):
            for seed in args.seed:
                for selector in ordered_manifest(seed + repetition, adapter):
                    run_child(
                        command(adapter, selector),
                        marker_for(adapter, selector),
                        args.timeout,
                        args.output,
                        adapter,
                        seed,
                        index,
                        selector,
                        repetition,
                        seed + repetition,
                    )
                    index += 1


if __name__ == "__main__":
    try:
        main()
    except ChildFailure as error:
        print(error, file=sys.stderr)
        sys.exit(1)
