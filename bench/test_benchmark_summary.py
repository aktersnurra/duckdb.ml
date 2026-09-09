import importlib
import pathlib
import tempfile
import unittest
from unittest.mock import patch

runner = importlib.import_module("bench.run_benchmarks")

HEADER = "sample\tpath\torder\trows\tchecksum\tnulls\texecute_ns\tprocess_ns\tminor_words\tpromoted_words\tmajor_words\tminor_collections\tmajor_collections\tcompactions\n"


def row(sample, path, checksum=45, process=10, execute=5, **metrics):
    values = {
        "minor_words": 1,
        "promoted_words": 2,
        "major_words": 3,
        "minor_collections": 0,
        "major_collections": 0,
        "compactions": 0,
    }
    values.update(metrics)
    return (
        "\t".join(
            map(
                str,
                [
                    sample,
                    path,
                    "owned_first",
                    10,
                    checksum,
                    1,
                    execute,
                    process,
                    values["minor_words"],
                    values["promoted_words"],
                    values["major_words"],
                    values["minor_collections"],
                    values["major_collections"],
                    values["compactions"],
                ],
            )
        )
        + "\n"
    )


class SummaryTests(unittest.TestCase):
    def test_statistics(self):
        self.assertEqual(runner.median([1, 3, 5]), 3)
        self.assertEqual(runner.median([1, 3, 5, 7]), 4)
        self.assertEqual(runner.nearest_rank_p95([1, 2, 3, 4, 5]), 5)
        self.assertAlmostEqual(runner.coefficient_of_variation([10, 10]), 0.0)

    def test_grouping_and_order_are_deterministic(self):
        text = (
            HEADER
            + row(1, "borrowed_chunks", process=30)
            + row(0, "owned_rows", process=10)
            + row(1, "owned_rows", process=20)
            + row(0, "borrowed_chunks", process=40)
        )
        grouped = runner.validate_rows(runner.parse_tsv(text))
        self.assertEqual(list(grouped), ["borrowed_chunks", "owned_rows"])
        self.assertEqual([item["sample"] for item in grouped["owned_rows"]], [0, 1])

    def test_invalid_evidence_is_rejected(self):
        with self.assertRaises(ValueError):
            runner.validate_rows(
                runner.parse_tsv(
                    HEADER
                    + row(0, "owned_rows")
                    + row(0, "borrowed_chunks", checksum=46)
                )
            )
        with self.assertRaises(ValueError):
            runner.validate_rows(
                runner.parse_tsv(
                    HEADER
                    + row(0, "owned_rows")
                    + row(1, "owned_rows")
                    + row(0, "borrowed_chunks")
                )
            )
        with self.assertRaises(ValueError):
            runner.parse_tsv(HEADER + row(0, "owned_rows", process=-1))

    def test_source_manifest_is_source_only(self):
        manifest = runner.source_manifest()
        self.assertNotIn(".ruff_cache", manifest)
        self.assertNotIn(".local", manifest)
        self.assertIn("  tools/run\n", manifest)

    def test_measured_mode_requires_ten_samples(self):
        with (
            tempfile.TemporaryDirectory() as temporary,
            patch(
                "sys.argv",
                [
                    "run_benchmarks.py",
                    "--rows",
                    "1",
                    "--warmups",
                    "0",
                    "--samples",
                    "2",
                    "--output-dir",
                    str(pathlib.Path(temporary)),
                ],
            ),
            self.assertRaises(SystemExit),
        ):
            runner.main()

    def test_affinity(self):
        self.assertEqual(runner.parse_cpu_list("0-3"), [0, 1, 2, 3])
        self.assertEqual(runner.parse_cpu_list("2,4-5"), [2, 4, 5])
        self.assertEqual(runner.affinity_command(["tools/run"], None), ["tools/run"])


if __name__ == "__main__":
    unittest.main()
