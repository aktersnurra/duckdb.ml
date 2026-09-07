"""Offline regression tests for the isolated stage-1 bootstrap."""

import hashlib
import importlib.util
import pathlib
import tempfile
import unittest

SOURCE = pathlib.Path(__file__).with_name("setup.py")


class SetupTests(unittest.TestCase):
    def setUp(self):
        self.assertTrue(
            SOURCE.exists(), "stage1/setup.py must implement bootstrap validation"
        )
        spec = importlib.util.spec_from_file_location("stage1_setup", SOURCE)
        assert spec is not None and spec.loader is not None
        self.setup = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.setup)

    def test_checksum_accepts_exact_bytes(self):
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / "archive"
            path.write_bytes(b"pinned bytes")
            self.setup.verify_sha256(path, hashlib.sha256(b"pinned bytes").hexdigest())

    def test_checksum_rejects_corruption(self):
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / "archive"
            path.write_bytes(b"corrupted")
            with self.assertRaisesRegex(ValueError, "checksum mismatch"):
                self.setup.verify_sha256(path, "0" * 64)

    def test_lock_rejects_missing_pin(self):
        with self.assertRaisesRegex(ValueError, "missing"):
            self.setup.validate_lock({})

    def test_lock_rejects_mutable_revision(self):
        lock = self.setup.load_lock()
        lock["archives"]["ox"]["revision"] = "main"
        with self.assertRaisesRegex(ValueError, "revision"):
            self.setup.validate_lock(lock)

    def test_lock_rejects_missing_checksum(self):
        lock = self.setup.load_lock()
        del lock["archives"]["duckdb"]["sha256"]
        with self.assertRaisesRegex(ValueError, "sha256"):
            self.setup.validate_lock(lock)

    def test_lock_rejects_non_https_source(self):
        lock = self.setup.load_lock()
        lock["archives"]["ox"]["url"] = "file:///etc/passwd"
        with self.assertRaisesRegex(ValueError, "https"):
            self.setup.validate_lock(lock)

    def test_environment_disables_system_dependency_installation(self):
        environment = self.setup.local_environment({"OPAMNODEPEXTS": "false"})
        self.assertEqual(environment.get("OPAMNODEPEXTS"), "true")

    def test_environment_ignores_shared_switch(self):
        environment = self.setup.local_environment(
            {
                "HOME": "/home/example",
                "PATH": "/shared/bin:/usr/bin",
                "OPAMROOT": "/shared/opam",
                "OPAMSWITCH": "shared",
                "OCAMLPATH": "/shared/lib",
                "CAML_LD_LIBRARY_PATH": "/shared/stubs",
                "OPAMEXTERNALSOLVER": "untrusted-solver",
                "DUNE_CACHE_ROOT": "/shared/cache",
            }
        )
        self.assertEqual(environment["OPAMROOT"], str(self.setup.ROOT / ".local/opam"))
        self.assertEqual(environment["OPAMSWITCH"], str(self.setup.ROOT))
        self.assertEqual(environment["HOME"], "/home/example")
        self.assertEqual(environment["PATH"], "/usr/bin:/bin")
        self.assertNotIn("OCAMLPATH", environment)
        self.assertNotIn("CAML_LD_LIBRARY_PATH", environment)
        self.assertNotIn("OPAMEXTERNALSOLVER", environment)
        self.assertEqual(
            environment["DUNE_CACHE_ROOT"], str(self.setup.ROOT / ".local/dune-cache")
        )


if __name__ == "__main__":
    unittest.main()
