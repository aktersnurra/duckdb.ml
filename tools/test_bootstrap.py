"""Offline regression tests for the isolated project-local bootstrap."""

import hashlib
import importlib.util
import pathlib
import tarfile
import tempfile
import unittest

SOURCE = pathlib.Path(__file__).with_name("bootstrap.py")


class SetupTests(unittest.TestCase):
    def setUp(self):
        self.assertTrue(
            SOURCE.exists(), "tools/bootstrap.py must implement bootstrap validation"
        )
        spec = importlib.util.spec_from_file_location("bootstrap", SOURCE)
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

    def test_lock_pins_hegel_release(self):
        archive = self.setup.load_lock()["archives"]["hegel"]
        self.assertTrue(archive["url"].startswith("https://"))
        self.assertRegex(archive["sha256"], "^[0-9a-f]{64}$")
        self.assertNotIn("revision", archive)

    def test_lock_requires_hegel(self):
        lock = self.setup.load_lock()
        del lock["archives"]["hegel"]
        with self.assertRaisesRegex(ValueError, "hegel"):
            self.setup.validate_lock(lock)

    def hegel_tarball(self, directory, platform_file="libhegel-linux-amd64.so"):
        source = pathlib.Path(directory) / "src/hegel-0.17.2"
        for path, text in {
            "lib/hegel.ml": "let x = 1\n",
            "lib/ffi/loader.ml": "let y = 2\n",
            "lib/jane/hegel_jane.ml": "let z = 3\n",
            "LICENSE": "MIT\n",
            "prebuilt/" + platform_file: "engine",
        }.items():
            (source / path).parent.mkdir(parents=True, exist_ok=True)
            (source / path).write_text(text)
        archive = pathlib.Path(directory) / "hegel.tar.gz"
        with tarfile.open(archive, "w:gz") as output:
            output.add(source, arcname="hegel-0.17.2")
        return archive

    def test_vendor_hegel_extracts_library_license_and_engine(self):
        with tempfile.TemporaryDirectory() as directory:
            archive = self.hegel_tarball(directory)
            destination = pathlib.Path(directory) / "vendor/hegel"
            for _ in range(2):  # re-extracting replaces the previous copy
                self.setup.vendor_hegel(archive, destination, system="Linux", machine="x86_64", patch=None)
            self.assertEqual((destination / "lib/hegel.ml").read_text(), "let x = 1\n")
            self.assertTrue((destination / "lib/ffi/loader.ml").exists())
            self.assertFalse((destination / "lib/jane").exists())
            self.assertEqual((destination / "LICENSE").read_text(), "MIT\n")
            self.assertEqual((destination / "libhegel.so").read_text(), "engine")

    def test_vendor_hegel_rejects_unsupported_platform(self):
        with tempfile.TemporaryDirectory() as directory:
            archive = self.hegel_tarball(directory)
            with self.assertRaisesRegex(RuntimeError, "libhegel"):
                self.setup.vendor_hegel(archive, pathlib.Path(directory) / "v", system="Linux", machine="riscv64",
                                        patch=None)


if __name__ == "__main__":
    unittest.main()
