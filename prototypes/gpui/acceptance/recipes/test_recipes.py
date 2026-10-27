"""Prepared meaningful pure checks. Runtime execution is deferred by user policy."""
from __future__ import annotations

import copy
import json
from pathlib import Path
import unittest

try:
    from .oracle import (COUNT, NULL_MARKER, SPECIAL, assert_snapshot, assert_effect_snapshot, effect_snapshot,
                         complete_json, csv_bytes, duplicate_rows, head_rows,
                         loaded_csv, loaded_json, native_text_sha, snapshot)
    from .identity import bind_policy_assertion, discover_created, resolve_profile
    from .coverage import build, load_strict
    from .fragments import catalog
except ImportError:
    from oracle import (COUNT, NULL_MARKER, SPECIAL, assert_snapshot, assert_effect_snapshot, effect_snapshot,
                        complete_json, csv_bytes, duplicate_rows, head_rows,
                        loaded_csv, loaded_json, native_text_sha, snapshot)
    from identity import bind_policy_assertion, discover_created, resolve_profile
    from coverage import build, load_strict
    from fragments import catalog

ROOT = Path(__file__).resolve().parents[4]
FIXTURES = ROOT / "prototypes/gpui/fixtures/installed-acceptance"


class IndependentOracleTests(unittest.TestCase):
    def test_expected_metadata_is_not_actual_output_as_oracle(self):
        for engine in ("postgresql", "mysql"):
            actual = snapshot(engine, "values-head")
            assert_snapshot(actual, engine, "values-head")
            for key, value in (("index", 4), ("index", False), ("nativeType", "FLOAT"), ("encoding", "hex")):
                changed = copy.deepcopy(actual)
                changed["columns"][3][key] = value
                with self.assertRaises(ValueError):
                    assert_snapshot(changed, engine, "values-head")

    def test_null_empty_literal_and_binary_are_distinct(self):
        rows = head_rows()
        self.assertIsNone(rows[0][1])
        self.assertEqual(rows[1][1], "")
        self.assertEqual(rows[2][1], "NULL")
        self.assertEqual(rows[0][3], "AP8=")
        self.assertEqual(rows[1][3], "")
        self.assertIsNone(rows[2][3])
        self.assertEqual(rows[3][1], SPECIAL)
        self.assertEqual(rows[3][4], str(len(SPECIAL)))
        for changed_value in ("", "NULL", "null"):
            changed = snapshot("postgresql", "values-head")
            changed["rows"][0][1] = changed_value
            with self.assertRaises(ValueError):
                assert_snapshot(changed, "postgresql", "values-head")

    def test_full_and_loaded_expected_counts_and_metadata(self):
        for engine, count in COUNT.items():
            self.assertEqual(len(duplicate_rows(engine, complete=True)), count)
            full = json.loads(complete_json(engine))
            loaded = json.loads(loaded_json(engine))
            self.assertEqual(len(full["resultSets"][0]["rows"]), count)
            self.assertEqual(len(loaded["resultSets"][0]["rows"]), 1000)
            self.assertFalse(full["resultSets"][0]["metadata"]["truncated"])
            self.assertTrue(loaded["resultSets"][0]["metadata"]["truncated"])
            self.assertEqual(loaded["resultSets"][0]["metadata"]["rowCount"], count)
            self.assertNotEqual(complete_json(engine), loaded_json(engine))

    def test_null_marker_collision_refuses_and_csv_keeps_embedded_crlf(self):
        for engine in COUNT:
            with self.assertRaises(ValueError):
                csv_bytes(engine, complete=True, null_marker="\\N")
            data = csv_bytes(engine, complete=True)
            self.assertTrue(data.startswith(b"x,x,payload\n"))
            self.assertIn(SPECIAL.replace('"', '""').encode(), data)
            self.assertIn(NULL_MARKER.encode(), data)
            self.assertTrue(loaded_csv(engine).startswith(b"x,x,payload\r\n"))

    def test_exactly_once_checks_reject_zero_and_duplicate(self):
        for engine in COUNT:
            assert_snapshot(snapshot(engine, "composite", suffix="!"), engine, "composite", suffix="!")
            for suffix in ("", "!!"):
                with self.assertRaises(ValueError):
                    assert_snapshot(snapshot(engine, "composite", suffix=suffix), engine, "composite", suffix="!")
            for case in ("apply-commit", "full-export", "sql-commit"):
                actual = effect_snapshot(engine, case)
                assert_effect_snapshot(actual, engine, case)
                for value in ("0", "2"):
                    changed = copy.deepcopy(actual)
                    next(row for row in changed["rows"] if row[0] == case)[1] = value
                    with self.assertRaises(ValueError):
                        assert_effect_snapshot(changed, engine, case)


class IdentityBindingTests(unittest.TestCase):
    first = "00000000-0000-4000-8000-000000000001"
    second = "00000000-0000-4000-8000-000000000002"

    def test_discovery_requires_new_unique_matching_ui_record(self):
        rows = [{"id": self.first, "name": "Original", "engine": "postgresql"},
                {"id": self.second, "name": "Synthetic", "engine": "mysql"}]
        expected = native_text_sha("Synthetic")
        self.assertEqual(discover_created([self.first], rows, engine="mysql", name_sha256=expected,
                                         text_hash=native_text_sha), self.second)
        for before, after in (([self.second], rows), ([], rows + rows), ([], [])):
            with self.assertRaises(ValueError):
                discover_created(before, after, engine="mysql", name_sha256=expected, text_hash=native_text_sha)

    def test_binding_rejects_literal_stale_and_unknown_ids(self):
        item = {"op": "assert-profile-policy", "profileId": "capture.mysql-profile", "expected": {"readonly": False}}
        bound = bind_policy_assertion(item, {"mysql-profile": self.second}, [self.second])
        self.assertEqual(bound["profileId"], self.second)
        self.assertEqual(item["profileId"], "capture.mysql-profile")
        for reference, captures, current in ((self.second, {}, [self.second]),
                                             ("capture.unknown", {}, [self.second]),
                                             ("capture.mysql-profile", {"mysql-profile": self.second}, [self.first])):
            with self.assertRaises(ValueError):
                resolve_profile(reference, captures, current)


class CoveragePreparationTests(unittest.TestCase):
    def test_full_assertion_mapping_keeps_all_native_cells_notrun(self):
        source = load_strict(FIXTURES / "scenarios.json")
        result = build(source, catalog())
        self.assertEqual(result["scenarioCount"], 57)
        self.assertEqual(result["nativeCellCount"], 171)
        self.assertGreater(result["assertionCount"], 100)
        self.assertTrue(all(set(row["nativeCells"].values()) == {"not-run"} for row in result["scenarios"]))
        changed = copy.deepcopy(source)
        changed["scenarios"][0]["procedure"][0]["assertions"].append("Unreviewed new assertion")
        with self.assertRaises(ValueError):
            build(changed, catalog())

    def test_empty_or_missing_engine_scenarios_never_pass(self):
        source = load_strict(FIXTURES / "scenarios.json")
        source["scenarios"] = []
        with self.assertRaises(ValueError):
            build(source, catalog())
        for engines in ([], ["postgresql"]):
            changed = load_strict(FIXTURES / "scenarios.json")
            row = next(row for row in changed["scenarios"]
                       if "independent-physical-database-observer" in row["proofKinds"])
            row["engines"] = engines
            with self.assertRaises(ValueError):
                build(changed, catalog())


if __name__ == "__main__":
    unittest.main()
