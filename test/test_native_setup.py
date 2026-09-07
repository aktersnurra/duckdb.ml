import hashlib
import importlib.util
import tempfile
import unittest
import zipfile
from pathlib import Path

spec = importlib.util.spec_from_file_location("setup_duckdb", Path(__file__).resolve().parents[1] / "tools/setup_duckdb.py")
assert spec is not None and spec.loader is not None
setup = importlib.util.module_from_spec(spec)
spec.loader.exec_module(setup)


class NativeSetup(unittest.TestCase):
    def test_checksum_rejection_has_no_output(self):
        with tempfile.TemporaryDirectory() as directory:
            archive = Path(directory) / "input.zip"
            archive.write_bytes(b"corrupt")
            prefix = Path(directory) / "native"
            with self.assertRaisesRegex(ValueError, "SHA256 mismatch"):
                setup.install_archive(archive, prefix, "0" * 64)
            self.assertFalse(prefix.exists())

    def test_extract_only_named_files(self):
        with tempfile.TemporaryDirectory() as directory:
            archive = Path(directory) / "input.zip"
            with zipfile.ZipFile(archive, "w") as output:
                output.writestr("duckdb.h", b"header")
                output.writestr("libduckdb.so", b"library")
                output.writestr("../escape", b"unwanted")
            prefix = Path(directory) / "native"
            setup.install_archive(archive, prefix, hashlib.sha256(archive.read_bytes()).hexdigest())
            self.assertEqual(sorted(p.name for p in prefix.iterdir()), ["duckdb.h", "libduckdb.so"])
            self.assertFalse((Path(directory) / "escape").exists())
