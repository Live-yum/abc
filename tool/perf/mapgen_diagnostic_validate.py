#!/usr/bin/env python3
"""Validate all retained evidence; never feed auxiliary observations to compare."""
import argparse
import importlib.util
import json
import math
from pathlib import Path
import re
import subprocess
import sys

from mapgen_diagnostic_contract import (EXPECTED_MATCHES, FIXTURE, GROUPS, HARNESS,
                                       ITERATIONS, PINS, TREES, VARIANTS, schedule)
from mapgen_diagnostic_runner import digest, save


def read(path):
    return json.loads(path.read_text())


def validate_session(state):
    assert state["schema"] == "abc.mapgen-factorial.v1"
    assert state["status"] == "completed", "Failed/unfinished processes remain evidence, not a valid experiment"
    assert state["pins"] == PINS and state["harness"] == HARNESS
    assert state["groups"] == list(GROUPS) and state["sequence"] == schedule()
    assert state["overallAcceptance"] == "unestablished"
    assert set(state["variants"]) == set(VARIANTS)
    for variant, (base, paths) in VARIANTS.items():
        row = state["variants"][variant]
        assert row["status"] == "passed", "All four builds must precede measurement"
        identity = row["identity"]
        assert identity["base"] == PINS[base] and identity["changedPaths"] == list(paths)
        assert identity["source"]["tree"] == TREES[variant] and identity["source"]["dirty"] is False
        assert re.fullmatch(r"[0-9a-f]{40}", identity["source"]["commit"])
        if paths:
            assert identity["kind"] == "derived-local-commit"
            assert identity["source"]["commit"] not in {p["commit"] for p in PINS.values()}, "Do not label an experiment as an original pin"
        else:
            assert identity["kind"] == "original-pin" and identity["source"]["commit"] == PINS[base]["commit"]
        assert row["snapshot"]["source"] == identity["source"]
        assert row["snapshot"]["fixture"] == FIXTURE and row["snapshot"]["machine"] == state["machine"]
    expected = [{**entry, "group": group} for group in GROUPS for entry in schedule()]
    assert len(state["attempts"]) == len(expected) == 24, "Retain exactly all 12 frozen + 12 auxiliary attempts"
    for row, planned in zip(state["attempts"], expected):
        assert all(row[key] == value for key, value in planned.items()), "Order/variant/group changed"
        assert row["status"] == "passed" and row["exitCode"] == 0, "Failed attempt retained"
        assert row["output"] == f"raw/{row['group']}/{row['slot']}"
        assert row["before"] == row["after"] == state["variants"][row["variant"]]["snapshot"], "Artifact/source/machine drift"


def validate_auxiliary(report, snapshot):
    assert report["schema"] == "abc.mapgen-auxiliary.v1" and report["acceptanceEligible"] is False
    assert report["status"] == "passed" and report["sourcePreserved"] is True
    assert report["fixture"] == FIXTURE and report["library"] == snapshot["library"]
    assert report["iterations"] == ITERATIONS and len(report["records"]) == ITERATIONS * 2
    for number, row in enumerate(report["records"]):
        cycle, kind = number // 2, "lit" if number % 2 == 0 else "marked"
        assert (row["cycle"], row["operation"], row["phase"]) == (cycle, kind, "cold" if cycle == 0 else "warm")
        assert row["output"]["width"] == 512 and row["output"]["height"] == 256
        assert row["output"]["bytes"] > 12 and re.fullmatch(r"[0-9a-f]{64}", row["output"]["sha256"])
        assert re.fullmatch(r"[0-9a-f]{64}", row["response"]["sha256"])
        response = row["response"]["json"]
        assert response["status"] == "ok" and response["file_written"] is False
        assert response["map_bytes"] == row["output"]["bytes"]
        assert response["width"] == 512 and response["height"] == 256
        if kind == "marked":
            assert row["matches"] == EXPECTED_MATCHES, "Marked work count changed"
            assert all(response[key] == value for key, value in EXPECTED_MATCHES.items())
        for value in (row["wallMs"], row["cpuMs"], *row["usageDelta"].values()):
            assert isinstance(value, (float, int)) and math.isfinite(value) and value >= 0, "Invalid observer value"


def validate_archives(root, state):
    for variant, row in state["variants"].items():
        evidence = root / "variants" / variant
        assert read(evidence / "identity.json") == row["identity"]
        assert digest(evidence / "variant.patch") == row["identity"]["patchSha256"]
        archive = row["buildArchive"]
        actual = {str(p.relative_to(evidence / "build")) for p in (evidence / "build").rglob("*") if p.is_file()}
        assert actual == set(archive), "Missing/extra archived build files"
        assert {"libabc_engine.so", "compile_commands.json", "CMakeCache.txt", "abc_engine.map"} <= actual
        for name in ("terra_map.c.o", "terra_api.c.o", "terra_ops.c.o", "terra_hash.c.o", "terra_circuit_query.c.o", "abc_engine.c.o", "flags.make", "link.txt"):
            assert any(Path(path).name == name for path in actual), f"Missing {name}"
        for path, expected in archive.items():
            target = evidence / "build" / path
            assert not Path(path).is_absolute() and ".." not in Path(path).parts
            assert {"bytes": target.stat().st_size, "sha256": digest(target)} == expected, f"Artifact mismatch: {path}"
        assert archive["libabc_engine.so"] == row["snapshot"]["library"]
        for number in range(3):
            assert read(evidence / f"build-{number}.command.json")["status"] == "passed"


def validate(root, candidate):
    summary = {"schema": "abc.mapgen-factorial-summary.v1", "status": "invalid",
               "overallAcceptance": "unestablished", "auxiliaryPooledWithFrozen": False,
               "originalRegressionRetained": True,
               "otherFiveSuites": "inconclusive-same-environment-comparison-required",
               "newWorkloads": "uncompared", "comparisons": {}}
    destination = root / "summary.json"
    assert not destination.exists(), "Never replace old evidence"
    try:
        state = read(root / "session.json")
        validate_session(state)
        validate_archives(root, state)
        assert state["workflowSource"]["dirty"] is False
        for name in ("commit", "tree"):
            assert re.fullmatch(r"[0-9a-f]{40}", state["workflowSource"][name])
        for path, expected_hash in state["diagnosticHarness"].items():
            assert not Path(path).is_absolute() and ".." not in Path(path).parts
            assert digest(root / "harness/diagnostic" / path) == expected_hash
        for path, expected_hash in HARNESS.items():
            assert digest(root / "harness/frozen" / path) == expected_hash
        comparator = candidate / "tool/perf/compare.py"
        assert digest(comparator) == HARNESS["tool/perf/compare.py"]
        spec = importlib.util.spec_from_file_location("frozen_mapgen_compare", comparator)
        frozen = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(frozen)
        frozen_reports = {name: [] for name in VARIANTS}
        observed = {name: [] for name in ("lit", "marked")}
        ids, expected_manifests = set(), set()
        machine_fields = ("system", "release", "architecture", "processors", "cpuModel", "image", "imageVersion")
        for row in state["attempts"]:
            location = root / row["output"]
            path = location / "map-generation.run-1.json"
            manifest_path = location / "map-generation.run-1.execution.json"
            expected_manifests.add(manifest_path)
            manifest, report = read(manifest_path), read(path)
            assert manifest["status"] == "passed" and manifest["exitCode"] == 0
            assert manifest["reportSha256"] == digest(path)
            assert manifest["runId"] not in ids, "Independent process identity reused"
            ids.add(manifest["runId"])
            assert manifest["source"] == {"commit": row["before"]["source"]["commit"],
                                          "checkedOutHead": row["before"]["source"]["commit"], "dirty": False}
            assert manifest["machine"] == {key: state["machine"][key] for key in machine_fields}
            if row["group"] == "frozen":
                frozen.validate(report)
                assert report["suite"] == "native-map-generation" and report["tier"] == "ci"
                assert report["source"]["dirty"] is False
                assert report["source"]["commit"] == report["source"]["worktreeCommit"] == row["before"]["source"]["commit"]
                assert report["toolchain"]["nativeLibrarySha256"] == row["before"]["library"]["sha256"]
                assert report["methodology"]["totalCycles"] == ITERATIONS
                assert report["methodology"]["measuredCycles"] == 25 and report["methodology"]["warmupCycles"] == 0
                assert len(report["operations"]) == 4 and len(report["memory"]) == 26
                frozen_reports[row["variant"]].append(path)
            else:
                validate_auxiliary(report, row["before"])
                assert report["runId"] == manifest["runId"] and report["pid"] == manifest["pid"]
                journal = [json.loads(line) for line in path.with_suffix(".cycles.jsonl").read_text().splitlines()]
                assert journal == report["records"], "Partial/replaced observer journal"
                assert path.with_suffix(".maps.txt").is_file(), "Missing process address map"
                for item in report["records"]:
                    for suffix, key in ((".outputs", "output"), (".responses", "response")):
                        payload = path.with_suffix(suffix) / (item[key]["sha256"] + ".bin")
                        assert payload.stat().st_size == item[key]["bytes"] and digest(payload) == item[key]["sha256"]
                        if key == "response":
                            assert json.loads(payload.read_bytes().rstrip(b"\0")) == item[key]["json"]
                    observed[item["operation"]].append({"variant": row["variant"], "slot": row["slot"],
                        "cycle": item["cycle"], "output": item["output"], "matches": item["matches"]})
        assert set((root / "raw").rglob("*.execution.json")) == expected_manifests, "Unexpected/missing raw attempts"
        summary["outputConsistency"] = {
            name: {"uniqueOutputs": len({json.dumps(row["output"], sort_keys=True) for row in rows}),
                   "records": len(rows)} for name, rows in observed.items()}
        # Preserve every disagreeing cycle and identity in a distinct file.
        save(root / "output-observations.json", observed)
        for variant in ("A_SHA", "A_QUERY", "B"):
            target = root / f"frozen-A-vs-{variant}.json"
            assert not target.exists(), "Never overwrite a comparison"
            argv = [sys.executable, str(comparator), "--require-baseline", "--output", str(target)]
            for path in frozen_reports["A"]:
                argv += ["--baseline", str(path)]
            for path in frozen_reports[variant]:
                argv += ["--candidate", str(path)]
            result = subprocess.run(argv, capture_output=True, text=True, timeout=180, check=False)
            detail = read(target)
            summary["comparisons"][variant] = {"status": detail["status"], "exitCode": result.returncode,
                                               "report": target.name, "sha256": digest(target)}
            assert detail["status"] in ("regression", "no-observed-regression"), "Invalid frozen comparison"
        consistent = all(row["uniqueOutputs"] == 1 for row in summary["outputConsistency"].values())
        summary["status"] = "output-mismatch" if not consistent else "regression" if any(
            value["status"] == "regression" for value in summary["comparisons"].values()) else "no-observed-regression"
        summary["processes"] = {"frozen": 12, "auxiliary": 12}
    except (AssertionError, KeyError, TypeError, ValueError, OSError, subprocess.SubprocessError) as error:
        summary["reason"] = f"{type(error).__name__}: {error}"
    save(destination, summary)
    return int(summary["status"] != "no-observed-regression")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=lambda value: Path(value).resolve(), required=True)
    parser.add_argument("--candidate", type=lambda value: Path(value).resolve(), required=True)
    args = parser.parse_args()
    return validate(args.output, args.candidate)


if __name__ == "__main__":
    raise SystemExit(main())
