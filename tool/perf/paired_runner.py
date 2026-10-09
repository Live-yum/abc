#!/usr/bin/env python3
"""Prepare two immutable builds, then preserve six serial AB/BA/AB processes."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import platform
import signal
import subprocess
import sys

from paired_contract import COMMON_HARNESS, FROZEN_VALIDATOR, PINS, SUITES, schedule


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def command(words, cwd=None):
    result = subprocess.run(words, cwd=cwd, capture_output=True, text=True, check=True)
    return (result.stdout or result.stderr).strip()


def source(root, expected=None):
    result = {"commit": command(["git", "rev-parse", "HEAD"], root),
              "tree": command(["git", "rev-parse", "HEAD^{tree}"], root),
              "dirty": bool(command(["git", "status", "--porcelain",
                                     "--untracked-files=normal"], root))}
    assert not result["dirty"], f"Dirty source: {root}"
    if expected:
        assert all(result[key] == value for key, value in expected.items()), "Wrong product pin/tree"
    return result


def verify_harness(root, expected=COMMON_HARNESS):
    actual = {name: digest(root / name) for name in expected}
    assert actual == expected, f"Frozen harness changed: {root}"
    return actual


def machine():
    cpu = next(line.split(":", 1)[1].strip() for line in
               Path("/proc/cpuinfo").read_text().splitlines() if line.startswith("model name"))
    return {"system": platform.system(), "release": platform.release(),
            "architecture": platform.machine(), "processors": os.cpu_count(),
            "cpuModel": cpu, "image": os.getenv("ImageOS"),
            "imageVersion": os.getenv("ImageVersion"),
            "runnerName": os.getenv("RUNNER_NAME"),
            "job": os.getenv("GITHUB_JOB"), "runId": os.getenv("GITHUB_RUN_ID"),
            "runAttempt": os.getenv("GITHUB_RUN_ATTEMPT"),
            "bootId": Path("/proc/sys/kernel/random/boot_id").read_text().strip()}


def toolchain(suite):
    words = {"python": [sys.executable, "--version"], "node": ["node", "--version"],
             "v8": ["node", "-p", "process.versions.v8"], "dart": ["dart", "--version"],
             "flutter": ["flutter", "--version", "--machine"],
             "compiler": ["cc", "--version"], "linker": ["ld", "--version"],
             "libc": ["ldd", "--version"]}
    if suite == "wasm":
        words["emscripten"] = ["emcc", "--version"]
    return {key: command(argv) for key, argv in words.items()}


def files(root, paths):
    return {name: {"bytes": (root / name).stat().st_size,
                   "sha256": digest(root / name)} for name in paths}


def artifacts(root, suite):
    paths = ["assets/private/circuit_rules_native.js", "web/engine/circuit_rules_web.js",
             "web/engine/map_worker.js"]
    if suite in ("native", "map-generation"):
        paths += ["build/native-perf/libabc_engine.so"]
    elif suite == "wasm":
        paths += [f"build/engine-web/{name}" for name in
                  ("world.js", "world.wasm", "player.js", "player.wasm", "manifest.json")]
    elif suite == "map-dart2js":
        paths += ["build/perf/map-actions.js"]
    result = files(root, paths)
    if suite == "native":
        quickjs = Path(os.environ["LIBQUICKJSC_TEST_PATH"])
        result["quickjs-runtime"] = {"bytes": quickjs.stat().st_size, "sha256": digest(quickjs)}
    return result


def fixtures(root, suite):
    paths = ["assets/qa/synthetic-circuit.wld", "assets/qa/synthetic-objects.wld",
             "build/perf/fixtures/synthetic-medium.wld"]
    if suite == "map-dart2js":
        paths += ["build/perf/fixtures/synthetic.map"]
    return files(root, paths)


def snapshot(root, role, suite):
    return {"source": source(root, PINS[role]), "harness": verify_harness(root),
            "artifacts": artifacts(root, suite), "fixtures": fixtures(root, suite),
            "machine": machine(), "toolchain": toolchain(suite)}


def prepare_commands(suite):
    commands = [["npm", "ci", "--ignore-scripts", "--no-audit", "--no-fund"],
                ["npm", "run", "verify:sources"], ["npm", "run", "build:circuit-rules"],
                ["flutter", "pub", "get", "--enforce-lockfile"],
                ["bash", "tool/build_map_worker.sh"],
                [sys.executable, "tool/perf/generate_synthetic_world.py",
                 "build/perf/fixtures/synthetic-medium.wld"]]
    if suite in ("native", "map-generation"):
        commands += [["cmake", "-S", "native", "-B", "build/native-perf",
                      "-DCMAKE_BUILD_TYPE=Release", "-DABC_PERF_COUNTERS=ON"],
                     ["cmake", "--build", "build/native-perf", "--parallel", "2"]]
    elif suite == "wasm":
        commands += [["bash", "tool/build_web_engine.sh"]]
    elif suite == "map-dart2js":
        commands += [["dart", "compile", "js", "-O2", "tool/perf/map_actions_web.dart",
                      "-o", "build/perf/map-actions.js"],
                     ["dart", "run", "tool/perf/write_map_fixture.dart",
                      "build/perf/fixtures/synthetic.map"]]
    return commands


def environment(root, role):
    env = dict(os.environ)
    # Public synthetic inputs only. Do not inherit private local/soak inputs.
    for name in ("ABC_PERF_WORLD", "ABC_PERF_WORLD2", "ABC_PERF_PLAYER", "ABC_PRIVATE_PACK"):
        env.pop(name, None)
    env.update(ABC_PERF_COMMIT=PINS[role]["commit"], ABC_PERF_TIER="ci",
               ABC_PERF_CYCLES="25", ABC_PERF_WARMUP="5", ABC_PERF_GC_DIAGNOSTICS="0",
               ABC_PERF_SYNTHETIC_WORLD=str(root / "build/perf/fixtures/synthetic-medium.wld"),
               ABC_PERF_FLUTTER_VERSION=(root / ".flutter-version").read_text().strip(),
               ABC_WEB_OUTPUT=str(root / "build/engine-web"),
               TERRAFORGE_ENGINE_LIBRARY=str(root / "build/native-perf/libabc_engine.so"),
               TERRA_WORLD_RUNTIME=str(root / "build/engine-web/world.js"),
               TERRA_PLAYER_RUNTIME=str(root / "build/engine-web/player.js"),
               PYTHONDONTWRITEBYTECODE="1")
    return env


def workload(suite):
    if suite == "native":
        return "ABC_PERF_REPORT", ["flutter", "test", "--no-pub", "--concurrency=1",
                                  "test/performance/native_actions_test.dart"]
    if suite == "wasm":
        return "ABC_PERF_REPORT", ["node", "--expose-gc", "tool/perf/benchmark_wasm.mjs"]
    if suite == "map-generation":
        return None, [sys.executable, "tool/perf/generate_native_map.py", "--library",
                      "build/native-perf/libabc_engine.so", "--input",
                      "build/perf/fixtures/synthetic-medium.wld", "--output",
                      "build/perf/fixtures/generated.map", "--fixture-id", "original-synthetic-world",
                      "--provenance", "original-synthetic", "--iterations", "26", "--report", "{report}"]
    if suite == "map-dart2js":
        return None, ["node", "tool/perf/run_map_web.cjs", "build/perf/map-actions.js", "{report}",
                      "build/perf/fixtures/synthetic.map", "repository-authored", "26"]
    raise ValueError(suite)


def save(path, value):
    path.write_text(json.dumps(value, indent=2) + "\n")


def prepare_command(argv, root, env, log):
    process = subprocess.Popen(argv, cwd=root, env=env, stdout=log,
                               stderr=subprocess.STDOUT, start_new_session=True)
    try:
        return_code = process.wait(timeout=1800)
    except subprocess.TimeoutExpired:
        # Reap the compiler's whole process group before preparing the other
        # pin. A timed-out shell must not leave a concurrent compiler behind.
        os.killpg(process.pid, signal.SIGTERM)
        try:
            process.wait(timeout=15)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait()
        raise
    if return_code:
        raise subprocess.CalledProcessError(return_code, argv)


def prepare(args):
    assert not args.output.exists(), "Evidence directory already exists; never overwrite an attempt"
    args.output.mkdir(parents=True)
    session = {"schema": "abc.paired-performance.v1", "suite": args.suite,
               "scope": "Fixed a5612b4/cddd936 diagnostic, not current-head performance acceptance",
               "pins": PINS, "sequence": schedule(), "harnessCommit": PINS["candidate"]["commit"],
               "workflowSource": source(args.workflow_root), "machine": machine(),
               "createdAt": datetime.now(timezone.utc).isoformat(),
               "preparation": {}, "attempts": [], "status": "preparing"}
    expected_head = os.environ["PAIR_WORKFLOW_HEAD"]
    assert session["workflowSource"]["commit"] == expected_head, "Wrong workflow checkout head"
    destination = args.output / "paired-session.json"
    save(destination, session)
    failed = False
    for role, root in (("baseline", args.baseline), ("candidate", args.candidate)):
        row = {"status": "running", "sourcePath": str(root)}
        session["preparation"][role] = row
        save(destination, session)
        try:
            row["source"] = source(root, PINS[role])
            row["harness"] = verify_harness(root)
            if role == "candidate":
                row["validator"] = verify_harness(root, FROZEN_VALIDATOR)
            (root / "build/perf/fixtures").mkdir(parents=True, exist_ok=True)
            with (args.output / f"prepare-{role}.log").open("x") as log:
                for argv in prepare_commands(args.suite):
                    log.write(json.dumps(argv) + "\n")
                    log.flush()
                    prepare_command(argv, root, environment(root, role), log)
            row["snapshot"] = snapshot(root, role, args.suite)
            row["status"] = "passed"
        except (AssertionError, OSError, KeyError, subprocess.SubprocessError) as error:
            row.update(status="failed", reason=str(error))
            failed = True
        save(destination, session)
    session["status"] = "preparation-failed" if failed else "prepared"
    save(destination, session)
    return int(failed)


def run(args):
    destination = args.output / "paired-session.json"
    session = json.loads(destination.read_text())
    assert session["status"] == "prepared" and not session["attempts"], "Never retry/overwrite evidence"
    assert session["suite"] == args.suite and session["pins"] == PINS
    session["status"] = "running"
    failed = False
    for item in schedule():
        role = item["role"]
        root = args.baseline if role == "baseline" else args.candidate
        output = args.output / "raw" / role / item["slot"]
        row = {**item, "status": "running", "output": str(output.relative_to(args.output)),
               "startedAt": datetime.now(timezone.utc).isoformat()}
        session["attempts"].append(row)
        save(destination, session)
        try:
            row["before"] = snapshot(root, role, args.suite)
            assert row["before"] == session["preparation"][role]["snapshot"], "Build/source/environment drift"
            report_env, words = workload(args.suite)
            argv = [sys.executable, str(root / "tool/perf/run_ci_suite.py"), "--suite", args.suite,
                    "--runs", "1", "--timeout-seconds", str(SUITES[args.suite]),
                    "--output-dir", str(output)]
            if report_env:
                argv += ["--report-env", report_env]
            argv += ["--", *words]
            with (args.output / f"driver-{item['slot']}.log").open("x") as log:
                result = subprocess.run(argv, cwd=root, env=environment(root, role),
                                        stdout=log, stderr=subprocess.STDOUT, check=False)
            row["exitCode"] = result.returncode
            row["after"] = snapshot(root, role, args.suite)
            assert row["before"] == row["after"], "Build/source/environment changed during measurement"
            row["status"] = "passed" if result.returncode == 0 else "failed"
            failed |= result.returncode != 0
        except (AssertionError, OSError, KeyError, subprocess.SubprocessError) as error:
            row.update(status="failed", reason=str(error))
            failed = True
        row["completedAt"] = datetime.now(timezone.utc).isoformat()
        save(destination, session)
    session["status"] = "failed" if failed else "completed"
    save(destination, session)
    return int(failed)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("phase", choices=("prepare", "run"))
    parser.add_argument("--suite", choices=SUITES, required=True)
    parser.add_argument("--baseline", type=Path, required=True)
    parser.add_argument("--candidate", type=Path, required=True)
    parser.add_argument("--workflow-root", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    for key in ("baseline", "candidate", "workflow_root", "output"):
        setattr(args, key, getattr(args, key).resolve())
    return prepare(args) if args.phase == "prepare" else run(args)


if __name__ == "__main__":
    raise SystemExit(main())
