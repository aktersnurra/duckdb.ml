#!/usr/bin/env python3
"""Extract ONLY the SHA256-pinned native dependency; never run opam or sudo."""

import argparse
import hashlib
import json
import shutil
import tempfile
import urllib.parse
import urllib.request
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def install_archive(archive, prefix, expected_sha256):
    if hashlib.sha256(archive.read_bytes()).hexdigest() != expected_sha256:
        raise ValueError("DuckDB archive SHA256 mismatch")
    with zipfile.ZipFile(archive) as source:
        contents = {name: source.read(name) for name in ("duckdb.h", "libduckdb.so")}
    prefix.mkdir(parents=True, exist_ok=True)
    for name, content in contents.items():
        (prefix / name).write_bytes(content)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--prefix", required=True, type=Path)
    parser.add_argument(
        "--archive", type=Path, help="use an already downloaded pinned archive"
    )
    args = parser.parse_args()
    pin = json.loads((ROOT / "tools/toolchain.lock.json").read_text())["archives"][
        "duckdb"
    ]
    with tempfile.TemporaryDirectory(prefix="duckdb-native-") as temporary:
        archive = args.archive
        if archive is None:
            archive = Path(temporary) / "duckdb.zip"
            parsed_url = urllib.parse.urlparse(pin["url"])
            if parsed_url.scheme != "https" or not parsed_url.netloc:
                raise ValueError("native dependency URL must use HTTPS")
            request = urllib.request.Request(pin["url"], method="GET")
            https_only = urllib.request.build_opener(urllib.request.HTTPSHandler())
            with (
                https_only.open(request, timeout=180) as source,
                archive.open("wb") as target,
            ):
                shutil.copyfileobj(source, target)
        install_archive(archive, args.prefix, pin["sha256"])
    print("DuckDB v1.5.5: verified and extracted", args.prefix)


if __name__ == "__main__":
    main()
