#!/usr/bin/env python3
"""Bounded provenance runner for public-adapter adapter model children."""

import argparse
import hashlib
import pathlib
import subprocess
import sys
import time

ROOT = pathlib.Path(__file__).resolve().parents[2]


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def append(path, line):
    with path.open("a", encoding="utf-8") as handle:
        handle.write(line + "\n")


def run_child(adapter, seed, episodes, timeout, log):
    source = ROOT / "test" / "soak" / f"soak_{adapter}.ml"
    executable = ROOT / "_build/default/test/soak" / f"soak_{adapter}.exe"
    argv = [
        "./tools/run",
        "exec",
        "--no-build",
        f"test/soak/soak_{adapter}.exe",
        "--",
        "--seed",
        str(seed),
        "--episodes",
        str(episodes),
    ]
    append(
        log,
        f"COMMAND adapter={adapter} seed={seed} episodes={episodes} source=test/soak/{source.name} source_sha256={digest(source)} executable={executable} executable_sha256={digest(executable)} argv={argv!r}",
    )
    started = time.monotonic()
    try:
        result = subprocess.run(
            argv,
            cwd=ROOT,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=timeout,
            check=False,
        )
    except subprocess.TimeoutExpired as error:
        append(
            log,
            f"EXIT timeout adapter={adapter} seed={seed} duration={time.monotonic() - started:.3f} output={(error.stdout or '')!r}",
        )
        raise RuntimeError(f"timeout adapter={adapter} seed={seed}") from error
    append(
        log,
        f"EXIT code={result.returncode} adapter={adapter} seed={seed} duration={time.monotonic() - started:.3f} output={result.stdout[-16000:]!r}",
    )
    if result.returncode:
        raise RuntimeError(
            f"failure adapter={adapter} seed={seed} exit={result.returncode}"
        )


def main(argv=None):
    parser = argparse.ArgumentParser()
    parser.add_argument("--seed", type=int, action="append", required=True)
    parser.add_argument("--episodes", type=int, default=24)
    parser.add_argument("--timeout", type=float, default=120)
    parser.add_argument("--output", type=pathlib.Path, required=True)
    args = parser.parse_args(argv)
    if args.episodes <= 0 or args.episodes % 8 or args.timeout <= 0:
        parser.error("episodes must be positive/divisible by 8 and timeout positive")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text("")
    for adapter in ("async", "eio"):
        for seed in args.seed:
            run_child(adapter, seed, args.episodes, args.timeout, args.output)


if __name__ == "__main__":
    try:
        main()
    except RuntimeError as error:
        print(error, file=sys.stderr)
        sys.exit(1)
