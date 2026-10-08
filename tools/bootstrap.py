#!/usr/bin/env python3
"""Project-local bootstrap. Never uses or updates a shared opam root."""

import argparse
import hashlib
import json
import os
import platform
import re
import shutil
import subprocess
import tarfile
import urllib.request
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CACHE = ROOT / ".local/upstream"
REPOS = ROOT / ".deps/repos"
HEGEL = ROOT / "vendor/hegel"
HEGEL_PATCH = ROOT / "tools/patches/hegel-0.17.2-no-dune-site.patch"
# The engine binaries bundled in Hegel's release tarball, by platform.
LIBHEGEL = {
    ("Linux", "x86_64"): "libhegel-linux-amd64.so",
    ("Linux", "aarch64"): "libhegel-linux-arm64.so",
    ("Darwin", "arm64"): "libhegel-darwin-arm64.dylib",
}


def verify_sha256(path, expected):
    with Path(path).open("rb") as source:
        actual = hashlib.file_digest(source, "sha256").hexdigest()
    if actual != expected:
        raise ValueError(
            f"checksum mismatch: {path}: expected {expected}, got {actual}"
        )


def validate_lock(lock):
    for field in ("compiler_package", "packages", "archives"):
        if field not in lock:
            raise ValueError(f"missing {field}")
    for name in ("ox", "default", "compiler", "eio", "duckdb", "hegel"):
        archive = lock["archives"].get(name, {})
        for field in ("url", "filename", "sha256"):
            if not archive.get(field):
                raise ValueError(f"missing {name}.{field}")
        if not archive["url"].startswith("https://"):
            raise ValueError(f"{name}.url must use https")
        if not re.fullmatch(r"[0-9a-f]{64}", archive["sha256"]):
            raise ValueError(f"invalid {name}.sha256")
        # Release assets (duckdb, hegel) are pinned by checksum alone.
        if name not in ("duckdb", "hegel") and not re.fullmatch(
            r"[0-9a-f]{40}", archive.get("revision", "")
        ):
            raise ValueError(f"invalid {name}.revision")
        if Path(archive["filename"]).name != archive["filename"]:
            raise ValueError(f"invalid {name}.filename")


def load_lock():
    lock = json.loads((ROOT / "tools/toolchain.lock.json").read_text())
    validate_lock(lock)
    return lock


def local_environment(source=None):
    source = os.environ if source is None else source
    environment = {
        key: value
        for key, value in source.items()
        if not key.startswith(("OPAM", "OCAML", "CAML", "DUNE"))
    }
    environment.update(
        OPAMROOT=str(ROOT / ".local/opam"),
        OPAMSWITCH=str(ROOT),
        OPAMJOBS="4",
        OPAMYES="1",
        OPAMNODEPEXTS="true",
        OPAMCOLOR="never",
        OPAMKEEPBUILDDIR="true",
        OPAMERRLOGLEN="100",
        PATH="/usr/bin:/bin",
        XDG_CACHE_HOME=str(ROOT / ".local/cache"),
        DUNE_CACHE_ROOT=str(ROOT / ".local/dune-cache"),
        DUNE_CACHE="disabled",
    )
    return environment


def run(*args):
    print("+", " ".join(map(str, args)), flush=True)
    subprocess.run(list(map(str, args)), cwd=ROOT, env=local_environment(), check=True)


def check():
    load_lock()
    if platform.machine() != "x86_64" or platform.libc_ver()[0] != "glibc":
        raise RuntimeError("stage 1 requires x86_64 Linux/glibc")
    for tool in (
        "opam",
        "cc",
        "c++",
        "make",
        "autoconf",
        "patch",
        "rsync",
        "bwrap",
        "unzip",
        "pkg-config",
    ):
        if not shutil.which(tool, path="/usr/bin:/bin"):
            raise RuntimeError(f"missing prerequisite: {tool}")
    print("host:", platform.platform(), "libc:", platform.libc_ver(), flush=True)
    print("free disk bytes:", shutil.disk_usage(ROOT).free, flush=True)
    run(
        "bwrap",
        "--unshare-user",
        "--uid",
        "0",
        "--gid",
        "0",
        "--ro-bind",
        "/",
        "/",
        "--proc",
        "/proc",
        "--dev",
        "/dev",
        "true",
    )
    run("opam", "--version")


def fetch(lock):
    CACHE.mkdir(parents=True, exist_ok=True)
    for archive in lock["archives"].values():
        target = CACHE / archive["filename"]
        if not target.exists():
            partial = target.with_suffix(target.suffix + ".partial")
            print("fetch", archive["url"], flush=True)
            # Sources are HTTPS-only and their bytes must match the committed SHA256.
            with (
                urllib.request.urlopen(archive["url"], timeout=180) as response,  # noqa: S310
                partial.open("wb") as output,
            ):
                shutil.copyfileobj(response, output)
            verify_sha256(partial, archive["sha256"])
            partial.replace(target)
        verify_sha256(target, archive["sha256"])
        print("verified", target.name, archive["sha256"], flush=True)


def prepare(lock):
    # Re-extract verified snapshots so local metadata edits cannot accumulate.
    for name in ("ox", "default"):
        destination = REPOS / name
        if destination.exists():
            shutil.rmtree(destination)
        destination.mkdir(parents=True)
        with tarfile.open(CACHE / lock["archives"][name]["filename"]) as archive:
            # Python's data filter rejects traversal and links outside destination.
            temporary = REPOS / (name + "-unpack")
            temporary.mkdir(exist_ok=True)
            archive.extractall(temporary, filter="data")
            children = list(temporary.iterdir())
            if len(children) != 1:
                raise ValueError(f"unexpected repository archive layout: {name}")
            for child in children[0].iterdir():
                shutil.move(str(child), destination)
            shutil.rmtree(temporary)
    # Same immutable sources, archive transport: avoid VCS commands and movable tags.
    package_paths = [(lock["compiler_package"], "compiler")]
    package_paths += [
        (name + ".1.3+ox", "eio")
        for name in ("eio", "eio_main", "eio_linux", "eio_posix")
    ]
    for package, source in package_paths:
        path = REPOS / "ox/packages" / package.split(".")[0] / package / "opam"
        archive = lock["archives"][source]
        replacement = (
            'url {\n  src: "'
            + archive["url"]
            + '"\n  checksum: "sha256='
            + archive["sha256"]
            + '"\n}'
        )
        text, count = re.subn(
            r"(?m)^url \{.*?^\}",
            lambda _, replacement=replacement: replacement,
            path.read_text(),
            flags=re.DOTALL,
        )
        if count != 1:
            raise ValueError(f"expected one url stanza: {path}")
        path.write_text(text)
    vendor_hegel(CACHE / lock["archives"]["hegel"]["filename"], HEGEL)
    native = ROOT / ".deps/duckdb"
    native.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(CACHE / lock["archives"]["duckdb"]["filename"]) as archive:
        for name in ("duckdb.h", "libduckdb.so"):
            (native / name).write_bytes(archive.read(name))


def vendor_hegel(archive, destination, system=None, machine=None, patch=HEGEL_PATCH):
    """Extract Hegel's library, licence and this platform's engine into
    [destination], replacing any previous copy, then apply [patch]: Hegel
    becomes private libraries of this project, without dune-site (whose
    libraries conflict with the OxCaml LSP build)."""
    platform_key = (system or platform.system(), machine or platform.machine())
    engine = LIBHEGEL.get(platform_key)
    if engine is None:
        raise RuntimeError(f"no bundled libhegel for {platform_key}")
    destination = Path(destination)
    if destination.exists():
        shutil.rmtree(destination)
    unpack = destination.with_name(destination.name + "-unpack")
    if unpack.exists():
        shutil.rmtree(unpack)
    unpack.mkdir(parents=True)
    with tarfile.open(archive) as source:
        source.extractall(unpack, filter="data")
    children = list(unpack.iterdir())
    if len(children) != 1:
        raise ValueError("unexpected hegel archive layout")
    root = children[0]
    destination.mkdir(parents=True)
    # lib/jane is Hegel's Core integration, which this project does not use.
    shutil.copytree(
        root / "lib",
        destination / "lib",
        ignore=lambda directory, _: {"jane"} if Path(directory) == root / "lib" else set(),
    )
    shutil.copy(root / "LICENSE", destination / "LICENSE")
    shutil.copy(root / "prebuilt" / engine, destination / "libhegel.so")
    shutil.rmtree(unpack)
    if patch is not None:
        subprocess.run(["patch", "-p1", "--forward", "--quiet", "-d", str(destination), "-i", str(patch)], check=True)


def install(lock):
    prepare(lock)
    if not (ROOT / ".local/opam/config").exists():
        run(
            "opam",
            "init",
            "--bare",
            "--no-setup",
            "--no-opamrc",
            "--no-git-location",
            "ox",
            REPOS / "ox",
        )
        run("opam", "repository", "add", "default", REPOS / "default", "--all-switches")
    if not (ROOT / "_opam/.opam-switch/switch-config").exists():
        run("opam", "switch", "create", ROOT, "--empty", "--repos=ox,default")
    run("opam", "install", lock["compiler_package"], *lock["packages"])
    run(
        "opam",
        "switch",
        "export",
        ROOT / ".local/stage1-switch.export",
        "--full",
        "--freeze",
    )
    run("opam", "exec", "--", "ocamlc", "-config")
    run("opam", "exec", "--", "dune", "--version")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--check", action="store_true")
    group.add_argument("--fetch", action="store_true")
    group.add_argument("--install", action="store_true")
    args = parser.parse_args()
    lock = load_lock()
    if args.check:
        check()
    else:
        fetch(lock)
        if args.install:
            check()
            install(lock)


if __name__ == "__main__":
    main()
