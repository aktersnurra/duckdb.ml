import importlib
import pathlib
import tempfile
import unittest
from unittest.mock import patch

runner = importlib.import_module("test.soak.run_soak")


class RunnerTests(unittest.TestCase):
    def test_order_and_unknown_selector(self):
        self.assertEqual(
            runner.ordered_manifest(104729, "async"),
            runner.ordered_manifest(104729, "async"),
        )
        with self.assertRaises(ValueError):
            runner.marker_for("async", "unknown")

    def test_generated_eio_targets_and_markers(self):
        self.assertIn(
            "test/eio/query_ingest/query_ingest.exe",
            runner.command("eio", "native_cancellation"),
        )
        self.assertIn(
            "test/eio/query_ingest/query_ingest.exe",
            runner.command("eio", "metadata_race"),
        )
        self.assertIn(
            "test/eio/parquet_native/parquet_native.exe",
            runner.command("eio", "between_files"),
        )
        self.assertIn(
            "test/eio/parquet_native/parquet_native.exe",
            runner.command("eio", "export_boundaries"),
        )
        self.assertEqual(
            runner.marker_for("eio", "native_cancellation"),
            "native_cancellation: PASS generated=true",
        )
        self.assertEqual(
            runner.marker_for("eio", "between_files"),
            "between_files: PASS generated=true",
        )

    def test_marker_timeout_and_nonzero(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = pathlib.Path(temporary) / "fake.py"
            path.write_text(
                "#!/usr/bin/env python3\nimport sys\nprint(sys.argv[1])\nsys.exit(int(sys.argv[2]))\n"
            )
            path.chmod(0o755)
            log = pathlib.Path(temporary) / "log"
            runner.run_child(
                [str(path), "PASS marker", "0"],
                "PASS marker",
                2,
                log,
                "async",
                7,
                0,
                "x",
            )
            self.assertIn("COMMAND", log.read_text())
            with self.assertRaises(runner.ChildFailure):
                runner.run_child(
                    [str(path), "wrong", "0"], "PASS marker", 2, log, "async", 7, 1, "x"
                )
            with self.assertRaises(runner.ChildFailure):
                runner.run_child(
                    [str(path), "PASS marker", "3"],
                    "PASS marker",
                    2,
                    log,
                    "async",
                    7,
                    2,
                    "x",
                )
            with (
                patch(
                    "test.soak.run_soak.subprocess.run",
                    side_effect=runner.subprocess.TimeoutExpired(["x"], 1),
                ),
                self.assertRaises(runner.ChildFailure),
            ):
                runner.run_child(["x"], "PASS", 1, log, "async", 7, 3, "x")


if __name__ == "__main__":
    unittest.main()
