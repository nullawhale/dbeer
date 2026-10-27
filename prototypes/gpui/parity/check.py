#!/usr/bin/env python3
"""Validate the frozen parity inventory or execute its existing Swift oracle.

Inventory validation never changes feature status. Native acceptance is a
separate, platform-bound task; this runner cannot turn a source test into it.
"""
import argparse
import hashlib
import json
import pathlib
import re
import subprocess
import sys
import time

HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parents[2]
TARGETS = {"windows11-x64", "ubuntu2404-x64-wayland", "ubuntu2404-x64-x11"}


def read(name):
    return json.loads((HERE / name).read_text(encoding="utf-8"))


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def require(condition, message):
    if not condition:
        raise ValueError(message)


def validate():
    registry, scenarios, baseline = read("registry.json"), read("scenarios.json"), read("baseline.json")
    references = read("references.json")
    checks = read("reference-tests.json")["checks"]
    fixture_sets = read("fixture-sets.json")
    require(registry["schemaVersion"] == 1, "Unsupported registry schema; native acceptance needs an explicitly versioned evidence contract")
    expected = {f"F{i:02}" for i in range(1, 58)}
    features = registry["features"]
    require(len(features) == 57 and {f["id"] for f in features} == expected, "Feature inventory must contain F01-F57 exactly once")
    cases = scenarios["scenarios"]
    require(len(cases) == 57 and {s["feature"] for s in cases} == expected, "Each feature needs a concrete scenario")
    require(len({s["id"] for s in cases}) == 57, "Duplicate scenario ID")
    index = {s["id"]: s for s in cases}
    test_count = set()
    referenced_scenarios = []
    for feature in features:
        groups = feature["implementation_reference"]["reference_groups"]
        require(isinstance(feature["owner"], str) and feature["owner"].strip() and groups, f"Missing owner/reference: {feature['id']}")
        require(feature["scenario_ids"] and feature["test_ids"], f"Feature needs nonempty scenario/test links: {feature['id']}")
        require(feature["status"] in {"open", "in-progress", "blocked"}, "Frozen v1 cannot mark a feature accepted")
        require(set(feature["results"]) == TARGETS, f"Incomplete native matrix: {feature['id']}")
        for result in feature["results"].values():
            require(result["status"] in {"not-run", "blocked", "failed"}, "Native pass/equivalence requires a future versioned structured evidence schema; frozen v1 cannot accept it")
            if result["status"] == "not-run":
                require(result["artifact"] is None and result["summary"] is None, "Not-run must not carry pass evidence")
        for group in groups:
            require(group in references and references[group], f"Missing reference group: {group}")
            for path in references[group]:
                require((ROOT / path).exists(), f"Missing implementation reference: {path}")
        for scenario_id in feature["scenario_ids"]:
            require(scenario_id in index, f"Missing scenario: {scenario_id}")
            referenced_scenarios.append(scenario_id)
            scenario = index[scenario_id]
            require(scenario["feature"] == feature["id"], "Mismatched scenario")
            require(scenario["steps"] and all(s["action"] and s["assertions"] for s in scenario["steps"]), "Scenario needs actions/assertions")
            require(scenario["precondition_set"] in scenarios["precondition_sets"], "Missing preconditions")
            require(feature["test_ids"] == scenario["reference_checks"], "Test links differ between row and scenario")
            for fixture in fixture_sets[scenario["fixture_set"]]:
                require((HERE / fixture).resolve().is_relative_to(ROOT), "Fixture path outside repository")
                require((HERE / fixture).is_file(), f"Missing fixture: {fixture}")
            for check_id in scenario["reference_checks"]:
                require(check_id in checks, f"Missing executable check: {check_id}")
                check = checks[check_id]
                source = (ROOT / check["path"]).read_text(encoding="utf-8")
                require(re.search(r"\b(?:struct|class)\s+" + re.escape(check["suite"]) + r"\b", source), "Missing suite")
                require(check["test_ids"], "Reference suite must identify tests")
                for test in check["test_ids"]:
                    require(re.search(r"\bfunc\s+" + re.escape(test.split("/")[1]) + r"\s*\(", source), f"Missing reference test: {test}")
                    test_count.add(test)
    require(len(referenced_scenarios) == len(index) and set(referenced_scenarios) == set(index), "Every scenario must be linked exactly once by its feature; orphan/duplicate links are invalid")
    for fixture in read("fixture-manifest.json")["files"]:
        require(digest(ROOT / fixture["path"]) == fixture["sha256"], f"Frozen fixture changed: {fixture['path']}")
    require(baseline["id"] == registry["baselineID"] == scenarios["baselineID"], "Baseline mismatch")
    require(baseline["defaultsDecision"] == "D01", "Explicit new-profile decision required")
    for item in baseline["acceptanceInventory"]["files"]:
        require(digest(HERE / item["path"]) == item["sha256"], f"Frozen scenario/test specification changed: {item['path']}")
    print(f"Inventory valid: 57 features, 57 concrete scenarios, {len(test_count)} linked reference test IDs, 171 native result cells.")
    print("This is structural verification only; no feature or native acceptance result was changed.")


def verify_source():
    manifest = read("source-manifest.json")
    errors = []
    for item in manifest["files"]:
        path = ROOT / item["path"]
        actual = hashlib.sha256(path.readlink().as_posix().encode()).hexdigest() if item["kind"] == "symlink" and path.is_symlink() else digest(path) if path.is_file() else None
        if actual != item["sha256"]:
            errors.append(item["path"])
    require(not errors, "Frozen source differs; use the replay archive for the original oracle:\n" + "\n".join(errors))
    print(f"Frozen source hashes match ({len(manifest['files'])} files). New implementation work must not redefine baseline v1.")


def verify_artifacts():
    baseline = read("baseline.json")
    for artifact in baseline["localArtifacts"]:
        path = ROOT / artifact["path"]
        require(path.is_file(), f"Local evidence absent: {path}; recover from your retained baseline archive")
        require(digest(path) == artifact["sha256"], f"Local evidence hash mismatch: {path}")
    app = ROOT / baseline["referenceApp"]["path"]
    manifest = read("reference-app-manifest.json")
    actual_paths = {str(path.relative_to(app)) for path in app.rglob("*") if path.is_file() or path.is_symlink()}
    require(actual_paths == {item["path"] for item in manifest["files"]}, "Reference app file inventory changed")
    for item in manifest["files"]:
        path = app / item["path"]
        actual = hashlib.sha256(path.readlink().as_posix().encode()).hexdigest() if item["kind"] == "symlink" and path.is_symlink() else digest(path)
        require(actual == item["sha256"], f"Reference app file changed: {item['path']}")
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
    print("Local source replay, signed reference app and completed-run evidence match baseline hashes.")


def show(feature):
    scenario = next(s for s in read("scenarios.json")["scenarios"] if s["feature"] == feature)
    checks = read("reference-tests.json")["checks"]
    expanded = dict(scenario)
    expanded["reference_checks"] = {key: checks[key] for key in scenario["reference_checks"]}
    expanded["fixtures"] = read("fixture-sets.json")[scenario["fixture_set"]]
    expanded["preconditions"] = read("scenarios.json")["precondition_sets"][scenario["precondition_set"]]
    expanded["native_execution"] = read("scenarios.json")["native_execution_policy"]
    print(json.dumps(expanded, ensure_ascii=False, indent=2))


def reference(features, print_only):
    validate()
    checks = read("reference-tests.json")["checks"]
    suites = sorted({checks[check_id]["suite"] for scenario in read("scenarios.json")["scenarios"]
                     if scenario["feature"] in features for check_id in scenario["reference_checks"]})
    require(suites, "Select at least one existing feature")
    command = ["./scripts/test.sh"]
    for suite in suites:
        command += ["--filter", suite]
    print("Reference command:", " ".join(command), flush=True)
    print("Database/installed/native prerequisites and any skipped cases must be reported separately.", flush=True)
    if print_only:
        return
    output = ROOT / "build/gpui-parity/reference-runs" / time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
    output.mkdir(parents=True, exist_ok=False)
    result = subprocess.run(command, cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    log = result.stdout
    (output / "run.log").write_text(log, encoding="utf-8")
    completed = re.findall(r"Test run with [1-9][0-9]* tests?.*passed after[^\n]*", log)
    summary = {"scope": "existing Swift reference assertions only", "features": features,
               "command": command, "exitCode": result.returncode, "completedSummaries": completed,
               "skippedOutput": [line for line in log.splitlines() if "skip" in line.lower()],
               "nativeAcceptance": "not-run; registry unchanged"}
    (output / "summary.json").write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")
    print("\n".join(completed) if completed else "No completed nonempty passing reference run.")
    print("Evidence:", output)
    require(result.returncode == 0 and completed, "Reference run did not complete successfully; inspect its run.log")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    for command in ["validate", "verify-source", "verify-artifacts"]:
        sub.add_parser(command)
    sub.add_parser("show").add_argument("feature", choices=[f"F{i:02}" for i in range(1, 58)])
    run = sub.add_parser("reference")
    run.add_argument("--feature", action="append", required=True, choices=[f"F{i:02}" for i in range(1, 58)])
    run.add_argument("--print-only", action="store_true")
    args = parser.parse_args()
    if args.command == "validate": validate()
    elif args.command == "verify-source": verify_source()
    elif args.command == "verify-artifacts": verify_artifacts()
    elif args.command == "show": show(args.feature)
    else: reference(args.feature, args.print_only)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
