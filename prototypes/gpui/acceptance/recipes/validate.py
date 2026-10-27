"""Read-only AST/JSON/DSL preparation validation; no product/test execution.

Safe to use before final integration. Does not import test_recipes, acceptance
run/core, platform bindings, subprocess, databases or OS credential packages.
"""
from __future__ import annotations

import ast
import hashlib
import json
import sys
from pathlib import Path

try:
    from .coverage import build, load_strict
    from .fragments import catalog
    from .oracle import canonical, expected_manifest
except ImportError:
    from coverage import build, load_strict
    from fragments import catalog
    from oracle import canonical, expected_manifest

# These imports are pure schema/data code; no core/run/native adapter is loaded.
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from plan import SCHEMAS, validate_action, validate_scenario, required_plan
OPS = set(SCHEMAS)
NATIVE = {"inspect", "assert", "wait", "focus", "invoke", "select", "scroll", "set-text"}


def validate(root):
    root = Path(root)
    recipes = root / "prototypes/gpui/acceptance/recipes"
    fixtures = root / "prototypes/gpui/fixtures/installed-acceptance/recipes"
    python_count = 0
    sources = list(recipes.parent.rglob("*.py")) + [root / "prototypes/gpui/verification/owned_databases.py"]
    for path in sources:
        source = path.read_text(encoding="utf-8")
        tree = ast.parse(source, filename=str(path))
        compile(tree, str(path), "exec")  # In-memory syntax compile, never exec.
        python_count += 1
    files = list(fixtures.rglob("*.json"))
    for path in files:
        load_strict(path)
    prepared = catalog()
    if canonical(load_strict(fixtures / "action-fragments.json")) != canonical(prepared):
        raise ValueError("Generated current-DSL fragments differ from source.")
    source_path = root / "prototypes/gpui/fixtures/installed-acceptance/scenarios.json"
    expected_coverage = build(load_strict(source_path), prepared)
    expected_coverage["frozenCatalogSha256"] = hashlib.sha256(source_path.read_bytes()).hexdigest()
    if canonical(load_strict(fixtures / "coverage.json")) != canonical(expected_coverage):
        raise ValueError("Coverage differs from exact frozen assertions/source plans.")
    values = load_strict(fixtures / "expected-values.json")
    pins = values.pop("sourcePins")
    for relative, expected_hash in pins.items():
        if hashlib.sha256((root / relative).read_bytes()).hexdigest() != expected_hash:
            raise ValueError("Expected-data source pin changed; explicit re-review required.")
    if canonical(values) != canonical(expected_manifest()):
        raise ValueError("Independent expected corpus/export values changed.")
    intentions = load_strict(fixtures / "selector-intentions.json")
    assertion_ids = {a["id"] for row in expected_coverage["scenarios"] for a in row["assertions"]}
    actions = 0
    def walk(items):
        for action in items:
            yield action
            if action.get('op') == 'persistence-case':
                yield from walk(action['actions'])
    for item in prepared["fragments"]:
        if item["nativeObserved"] or item["selectorIntegrationReviewed"] or item["standaloneScenario"]:
            raise ValueError("Source fragment cannot become reviewed/native evidence.")
        if not item["actions"] or not item["preconditions"] or not item["limitations"]:
            raise ValueError("Empty fragment or missing safety preconditions.")
        for action in walk(item["actions"]):
            actions += 1
            validate_action(action)
            if action.get("op") not in OPS:
                raise ValueError("Unsupported operation mislabeled as current DSL.")
            if "assertion" in action and action["assertion"] not in assertion_ids:
                raise ValueError("Assertion does not belong to exact frozen procedure.")
            if action["op"] == "native":
                if action.get("action") not in NATIVE or action.get("selector") not in intentions["selectors"]:
                    raise ValueError("Missing source semantic intention.")
                if "assertion" in action and (action["action"] != "assert" or not action.get("expectedSha256")):
                    raise ValueError("Click cannot close an assertion.")
                if action.get("readValue") and action["selector"] == "profiles.password":
                    raise ValueError("Password capture refused.")
            if action["op"] == "wait-server-count" and "assertion" not in action:
                raise ValueError("Current DSL requires explicit count assertion ID.")
    staged = load_strict(fixtures / 'source-inputs.json')
    if hashlib.sha256((fixtures / 'input-corpus.json').read_bytes()).hexdigest() != staged['corpusSha256']:
        raise ValueError('Fixed corpus pin differs.')
    for entry in staged['sources'].values():
        data = (root / entry['path']).read_bytes()
        if len(data) != entry['size'] or hashlib.sha256(data).hexdigest() != entry['sha256']:
            raise ValueError('Staged fixed source pin differs.')
    # Complete explicit pending plan validates structure without executing a gate.
    pending = load_strict(fixtures / 'required-plan.pending.json')
    requirements = required_plan(load_strict(source_path))
    if set(pending['scenarios']) != set(requirements):
        raise ValueError('Required plan omits a frozen scenario.')
    for feature, pending_actions in pending['scenarios'].items():
        validate_scenario(feature, pending_actions, requirements)
    return {"kind": "static-recipe-preparation-only", "pythonSyntaxFiles": python_count,
            "jsonFiles": len(files), "sourceExpectedFragments": len(prepared["fragments"]),
            "dslActions": actions, "mappedScenarios": 57,
            "mappedFrozenAssertions": expected_coverage["assertionCount"],
            "nativeCellsNotRun": 171, "runtimeTestsExecuted": False,
            "nativeObserved": False, "selectorIntegrationReviewed": False}


if __name__ == "__main__":
    print(json.dumps(validate(Path(__file__).resolve().parents[4]), sort_keys=True))
