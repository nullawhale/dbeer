"""Regression checks for omission and unsupported native acceptance claims."""
import contextlib
import copy
import io
import sys
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
import check


class ParityInventoryChecks(unittest.TestCase):
    def altered(self, mutate):
        registry = copy.deepcopy(check.read("registry.json"))
        mutate(registry)
        original = check.read
        with patch.object(check, "read", side_effect=lambda name: registry if name == "registry.json" else original(name)):
            with self.assertRaises(ValueError):
                check.validate()

    def test_frozen_inventory_validates_without_changing_native_results(self):
        before = check.read("registry.json")
        with contextlib.redirect_stdout(io.StringIO()):
            check.validate()
        self.assertEqual(check.read("registry.json"), before)

    def test_empty_row_links_cannot_hide_all_scenarios(self):
        def remove(registry):
            for feature in registry["features"]:
                feature["scenario_ids"] = []
                feature["test_ids"] = []
        self.altered(remove)

    def test_feature_cannot_borrow_another_features_scenario(self):
        self.altered(lambda registry: registry["features"][0].update(scenario_ids=["PARITY-F02"]))

    def test_native_pass_cannot_be_invented_from_arbitrary_strings(self):
        def invent(registry):
            for feature in registry["features"]:
                for result in feature["results"].values():
                    result.update(status="passed", artifact="anything", summary="anything")
        self.altered(invent)

    def test_omitted_platform_or_owner_is_rejected(self):
        self.altered(lambda registry: registry["features"][0]["results"].pop("ubuntu2404-x64-x11"))
        self.altered(lambda registry: registry["features"][0].update(owner=""))


if __name__ == "__main__":
    unittest.main()
