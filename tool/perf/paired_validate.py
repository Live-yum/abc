#!/usr/bin/env python3
"""Validate one paired suite with the unchanged comparator from pinned cddd936."""
import argparse
import importlib.util
import json
from pathlib import Path
import re
import subprocess
import sys

from paired_contract import COMMON_HARNESS, FROZEN_VALIDATOR, OUT_OF_SCOPE, PINS, SUITES, schedule
from paired_runner import digest, save, source, verify_harness


def validate_session(session, suite):
    assert suite in SUITES and session["suite"] == suite, "Unexpected suite"
    assert session["schema"] == "abc.paired-performance.v1"
    assert session["pins"] == PINS and session["harnessCommit"] == PINS["candidate"]["commit"]
    assert session["status"] == "completed", "Preparation/measurement failed or unfinished"
    assert session["sequence"] == schedule(), "Pair order changed"
    workflow = session["workflowSource"]
    assert workflow["dirty"] is False
    assert all(re.fullmatch(r"[0-9a-f]{40}", workflow[key]) for key in ("commit", "tree"))
    attempts = session["attempts"]
    assert len(attempts) == 6, "Keep all six planned processes, including failed attempts"
    snapshots = {}
    for role in PINS:
        preparation = session["preparation"][role]
        assert preparation["status"] == "passed", "Both builds must complete before measurement"
        value = preparation["snapshot"]
        assert value["source"] == {**PINS[role], "dirty": False}
        assert value["harness"] == COMMON_HARNESS
        assert value["machine"] == session["machine"], "Runner changed"
        assert value["artifacts"] and value["fixtures"]
        snapshots[role] = value
    for key in ("machine", "toolchain", "fixtures"):
        assert snapshots["baseline"][key] == snapshots["candidate"][key], f"A/B {key} differs"
    for actual, expected in zip(attempts, schedule()):
        assert all(actual[key] == value for key, value in expected.items()), "Wrong/missing pair slot"
        assert actual["status"] == "passed" and actual["exitCode"] == 0, "Retained failed process"
        assert actual["before"] == actual["after"] == snapshots[expected["role"]], "Per-process drift"
        assert actual["output"] == f"raw/{expected['role']}/{expected['slot']}", "Unexpected report path"


def load_frozen(candidate):
    verify_harness(candidate)
    verify_harness(candidate, FROZEN_VALIDATOR)
    # Other test modules may have imported the current-head comparators. Load
    # only the validated pin, including its imports, then restore caller state.
    names = ("compare", "ui_compare", "ui_validate")
    saved = {name: sys.modules.pop(name, None) for name in names}
    sys.path.insert(0, str(candidate / "tool/perf"))
    try:
        spec = importlib.util.spec_from_file_location("paired_frozen_compare_ci",
                                                     candidate / "tool/perf/compare_ci.py")
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module
    finally:
        sys.path.pop(0)
        for name, value in saved.items():
            sys.modules.pop(name, None)
            if value is not None:
                sys.modules[name] = value


def verify_report_artifact(report, snapshot, suite):
    observed = report["toolchain"]
    expected = snapshot["artifacts"]
    if suite in ("native", "map-generation"):
        assert observed["nativeLibrarySha256"] == expected["build/native-perf/libabc_engine.so"]["sha256"]
    else:
        recorded = {value["id"]: value for value in observed["artifacts"]}
        if suite == "map-dart2js":
            assert recorded["compiled-map-benchmark"]["sha256"] == expected["build/perf/map-actions.js"]["sha256"]
        else:
            for kind, name in (("wld", "world"), ("plr", "player")):
                assert recorded[f"{kind}-wasm"]["sha256"] == expected[f"build/engine-web/{name}.wasm"]["sha256"]
                assert recorded[f"{kind}-wasm"]["loaderSha256"] == expected[f"build/engine-web/{name}.js"]["sha256"]


def verify_protocol(report, suite):
    expected = {"native": ("native-actions", "flutter-test-debug-with-release-native-library", 5),
                "wasm": ("wasm-actions", "release-wasm-node", 5),
                "map-generation": ("native-map-generation", "release", 0),
                "map-dart2js": ("map-actions", "dart2js-O2", 0)}
    report_suite, mode, warmup = expected[suite]
    assert (report["suite"], report["buildMode"], report["tier"]) == (report_suite, mode, "ci"), "Wrong benchmark/build mode"
    assert report["methodology"]["warmupCycles"] == warmup, "Warmup protocol changed"
    assert report["methodology"]["measuredCycles"] == 25, "Measured-cycle protocol changed"
    assert {row["phase"] for row in report["operations"]} == {"cold", "warm"}, "Cold/warm evidence missing"


def validate(root, candidate, suite):
    result = {"schema": "abc.paired-performance-summary.v1", "suite": suite,
              "diagnosticStatus": "invalid", "pins": PINS,
              "scope": "Only this fixed-pin paired suite; not current-head acceptance",
              "overallAcceptance": "unestablished",
              "otherSuites": {name: "inconclusive-same-environment-comparison-required" for name in OUT_OF_SCOPE},
              "newWorkloads": "uncompared-without-matching-baseline",
              "originalFailureRetained": "https://github.com/Live-yum/abc/actions/runs/37920825896",
              "limitations": ["Same runner reduces cross-host confounding, not all ambient-load drift.",
                              "No outlier removal or changed statistical thresholds.",
                              "No-observed-regression does not prove equivalence or UI smoothness."]}
    try:
        session = json.loads((root / "paired-session.json").read_text())
        result["workflowSource"] = session["workflowSource"]
        result["harnessCommit"] = session["harnessCommit"]
        validate_session(session, suite)
        source(candidate, PINS["candidate"])
        frozen = load_frozen(candidate)
        groups = {}
        all_ids = []
        for role in PINS:
            group_root = root / "raw" / role
            entries = frozen.load_group(group_root, suite, 3)
            expected_paths = {group_root / item["slot"] / f"{suite}.run-1.json"
                              for item in schedule() if item["role"] == role}
            assert {entry[0] for entry in entries} == expected_paths, "Unexpected/replaced process reports"
            assert len(list(group_root.rglob("*.execution.json"))) == 3, "Extra attempted executions must remain visible"
            for path, report, execution in entries:
                assert execution["source"]["commit"] == PINS[role]["commit"]
                verify_protocol(report, suite)
                verify_report_artifact(report, session["preparation"][role]["snapshot"], suite)
                all_ids.append(execution["runId"])
            groups[role] = entries
        assert len(set(all_ids)) == 6, "A/B reused process execution IDs"
        reference = frozen.environment(groups["baseline"][0])
        assert all(frozen.environment(entry) == reference for group in groups.values() for entry in group), "Report environment differs"
        comparison = root / "paired-comparison.json"
        assert not comparison.exists(), "Never overwrite prior comparison evidence"
        argv = [sys.executable, str(candidate / "tool/perf/compare.py"), "--require-baseline"]
        for role, entries in groups.items():
            for path, _, _ in entries:
                argv += [f"--{role}", str(path)]
        completed = subprocess.run(argv + ["--output", str(comparison)], check=False, timeout=180)
        detail = json.loads(comparison.read_text())
        result.update(diagnosticStatus=detail["status"], comparatorExitCode=completed.returncode,
                      comparison= comparison.name, comparisonSha256=digest(comparison),
                      baselineProcesses=3, candidateProcesses=3)
        if completed.returncode == 0:
            assert detail["status"] == "no-observed-regression", "Unexpected successful comparison"
        return_code = int(completed.returncode != 0)
    except (AssertionError, KeyError, TypeError, ValueError, OSError, subprocess.SubprocessError) as error:
        result.update(diagnosticStatus="invalid", reason=str(error))
        return_code = 1
    root.mkdir(parents=True, exist_ok=True)
    destination = root / "paired-summary.json"
    assert not destination.exists(), "Never replace an existing diagnostic summary"
    save(destination, result)
    markdown = ["# Fixed-pin paired performance diagnostic", "",
                f"Suite: {suite}; result: **{result['diagnosticStatus']}**", "",
                "Baseline: " + PINS["baseline"]["commit"],
                "Candidate product: " + PINS["candidate"]["commit"],
                "Workflow/test head: " + result.get("workflowSource", {}).get("commit", "unavailable"), "",
                "This checks two fixed older product pins, not the current PR product head.",
                "The other five suites remain inconclusive; new workloads remain uncompared.",
                "Original failures and all attempts are retained; overall acceptance is unestablished."]
    if "reason" in result:
        markdown += ["", result["reason"]]
    (root / "paired-summary.md").write_text("\n".join(markdown) + "\n")
    return return_code


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--suite", choices=SUITES, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--candidate", type=Path, required=True)
    args = parser.parse_args()
    return validate(args.output.resolve(), args.candidate.resolve(), args.suite)


if __name__ == "__main__":
    raise SystemExit(main())
