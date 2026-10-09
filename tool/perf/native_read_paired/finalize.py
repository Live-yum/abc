#!/usr/bin/env python3
"""Publish evidence files only; no world, executable, library or native scratch."""
import argparse
import datetime
import json
import os
from pathlib import Path
import shutil

TOP_LEVEL = {"manifest.json", "build.json", "session.json", "summary.json"}
RAW_FILES = {"report.json", "execution.json", "stdout.jsonl", "stderr.log", "os-samples.jsonl"}
LOG_FILES = {"contracts.log", "flutter-version.json", "dart-version.txt", "clang-version.txt",
             "cmake-version.txt", "ninja-version.txt", "native-configure.log", "native-build.log"}


def collect(root, outcomes):
    root = Path(root)
    evidence = root / "evidence"
    evidence.mkdir(parents=True, exist_ok=True)
    copied = []
    def copy(source, relative):
        if source.is_symlink():
            raise ValueError(f"Refusing evidence symlink: {source}")
        if source.is_file():
            target = evidence / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(source, target)
            copied.append(str(relative))
    state = root / "state"
    for name in TOP_LEVEL:
        copy(state / name, Path(name))
    for source in sorted(state.glob("build-*.log")):
        copy(source, Path("logs") / source.name)
    for slot in ("01-B", "02-A", "03-A", "04-B", "05-B", "06-A"):
        for name in RAW_FILES:
            copy(state / "raw" / slot / name, Path("raw") / slot / name)
    for name in LOG_FILES:
        copy(root / "logs" / name, Path("logs") / name)
    for source, relative in [
        (root / "native-build.json", "provenance/native-build.json"),
        (root / "inputs/input-manifest.json", "provenance/public-input-manifest.json"),
        (root / "candidate/derivation.json", "provenance/candidate-derivation.json"),
        (Path(__file__).parent / "source-manifest.json", "provenance/diagnostic-source-manifest.json"),
    ]:
        copy(source, Path(relative))
    errors = []
    def load(name):
        try:
            return json.loads((state / name).read_text())
        except (OSError, ValueError) as error:
            errors.append(f"Missing or invalid {name}: {error}")
            return {}
    session, summary, manifest = load("session.json"), load("summary.json"), load("manifest.json")
    if session.get("status") != "passed" or session.get("completeness") != "complete":
        errors.append("Paired execution did not finish successfully")
    if summary.get("status") != "passed" or len(session.get("processes", [])) != 6:
        errors.append("All six validated processes are required")
    if manifest.get("order") != list("BAABBA") or manifest.get("cycles") != 8:
        errors.append("Unexpected complete-study protocol")
    if any(value != "success" for value in outcomes.values()):
        errors.append("One or more required workflow steps did not succeed")
    status = {"status": "failed-incomplete" if errors else "passed",
              "finishedUtc": datetime.datetime.now(datetime.timezone.utc).isoformat(),
              "stepOutcomes": outcomes, "errors": errors, "filesCollected": sorted(copied),
              "scope": "CI-internal AOT host-wrapper comparison; no Flutter frame proof or cross-host absolute comparison",
              "privacy": "No WLD, archive, AOT executable, shared library or native scratch uploaded",
              "interruptionPolicy": "Incomplete results remain incomplete; no single-arm resume or product-crash inference"}
    (evidence / "status.json").write_text(json.dumps(status, indent=2) + "\n")
    return status


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, required=True)
    args = parser.parse_args()
    status = collect(args.root, {key: os.environ.get(key, "missing") for key in
                                ("INPUTS_OUTCOME", "NATIVE_OUTCOME", "AOT_OUTCOME", "MEASUREMENT_OUTCOME")})
    text = f"Native READ paired diagnostic: {status['status']}. Complete BAABBA, eight cycles/process, counters OFF; host-wrapper evidence only."
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as output:
            output.write(text + "\n")
    print(json.dumps(status))
