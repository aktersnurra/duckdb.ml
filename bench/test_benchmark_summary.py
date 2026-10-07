import importlib
import pathlib
import tempfile
import unittest
from unittest.mock import patch

runner = importlib.import_module("bench.run_benchmarks")

PATHS = (
    "borrowed_chunks",
    "owned_rows",
    "column_views",
    "collect",
    "row_ingest",
    "columnar_ingest",
)
HEADER = "sample\tpath\torder\trows\tchecksum\tnulls\texecute_ns\tprocess_ns\tminor_words\tpromoted_words\tmajor_words\tminor_collections\tmajor_collections\tcompactions\n"


def row(
    sample,
    path,
    checksum=45,
    process=10,
    execute=5,
    order="first=borrowed_chunks",
    **metrics,
):
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
                    order,
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


def sample_rows(sample, **overrides):
    """One row per path; [overrides] maps a path to that row's keyword args."""
    order = "first=" + PATHS[sample % len(PATHS)]
    return "".join(
        row(sample, path, **{"order": order, **overrides.get(path, {})})
        for path in PATHS
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
            + sample_rows(1, borrowed_chunks={"process": 30}, owned_rows={"process": 20})
            + sample_rows(0, borrowed_chunks={"process": 40}, owned_rows={"process": 10})
        )
        grouped = runner.validate_rows(runner.parse_tsv(text))
        self.assertEqual(list(grouped), sorted(PATHS))
        for path in PATHS:
            self.assertEqual([item["sample"] for item in grouped[path]], [0, 1])
        self.assertEqual(
            [item["process_ns"] for item in grouped["owned_rows"]],
            [10, 20],
        )

    def test_invalid_evidence_is_rejected(self):
        runner.validate_rows(runner.parse_tsv(HEADER + sample_rows(0)))
        for path in PATHS:
            with self.subTest(path=path), self.assertRaises(ValueError):
                runner.validate_rows(
                    runner.parse_tsv(HEADER + sample_rows(0, **{path: {"checksum": 46}}))
                )
        with self.assertRaises(ValueError):
            runner.validate_rows(
                runner.parse_tsv(HEADER + sample_rows(0) + row(1, "owned_rows"))
            )
        with self.assertRaises(ValueError):
            runner.parse_tsv(HEADER + row(0, "owned_rows", process=-1))

    def test_order_must_name_a_known_first_path(self):
        for order in ("owned_first", "borrowed_first", "first=", "first=bogus", "x=collect"):
            with self.subTest(order=order), self.assertRaises(ValueError):
                runner.parse_tsv(HEADER + row(0, "collect", order=order))
        runner.parse_tsv(HEADER + row(0, "collect", order="first=columnar_ingest"))

    def test_rotation_must_start_sample_at_its_path(self):
        runner.validate_rows(runner.parse_tsv(HEADER + sample_rows(0) + sample_rows(1)))
        # Sample 1 must start at PATHS[1]; one row naming another start fails.
        broken = sample_rows(1, collect={"order": "first=borrowed_chunks"})
        with self.assertRaises(ValueError):
            runner.validate_rows(runner.parse_tsv(HEADER + sample_rows(0) + broken))
        # A sample consistently labelled with the wrong start fails too.
        with self.assertRaises(ValueError):
            runner.validate_rows(runner.parse_tsv(HEADER + sample_rows(0).replace(
                "first=borrowed_chunks", "first=owned_rows")))

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
