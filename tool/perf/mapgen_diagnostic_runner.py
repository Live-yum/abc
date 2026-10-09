#!/usr/bin/env python3
"""Build four isolated source variants, preserve 12+12 MAP-only processes.

Local derived commits are experiment identities, never uploaded or represented
as the original A/B pins. Building all variants precedes any timed process.
"""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import signal
import subprocess
import sys
import time

from mapgen_diagnostic_contract import (BUILD_TIMEOUT, EXECUTION_BUDGET, FIXTURE, GROUPS, HARNESS,
                                       ITERATIONS, PINS, PROCESS_TIMEOUT, TREES, VARIANTS, schedule)


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def save(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2) + "\n")


def command(argv, cwd=None, env=None):
    result = subprocess.run(argv, cwd=cwd, env=env, text=True, capture_output=True, check=True)
    return (result.stdout or result.stderr).strip()


def source(root, expected=None):
    value = {"commit": command(["git", "rev-parse", "HEAD"], root),
             "tree": command(["git", "rev-parse", "HEAD^{tree}"], root),
             "dirty": bool(command(["git", "status", "--porcelain", "--untracked-files=normal"], root))}
    assert not value["dirty"], f"Dirty source: {root}"
    if expected:
        assert all(value[key] == expected[key] for key in ("commit", "tree")), "Wrong pin/tree"
    assert {path: digest(root / path) for path in HARNESS} == HARNESS, "Frozen harness changed"
    return value


def machine():
    cpu = next(line.split(":", 1)[1].strip() for line in Path("/proc/cpuinfo").read_text().splitlines()
               if line.startswith("model name"))
    return {"system": platform.system(), "release": platform.release(), "architecture": platform.machine(),
            "processors": os.cpu_count(), "cpuModel": cpu, "image": os.getenv("ImageOS"),
            "imageVersion": os.getenv("ImageVersion"), "runner": os.getenv("RUNNER_NAME"),
            "bootId": Path("/proc/sys/kernel/random/boot_id").read_text().strip(),
            "job": os.getenv("GITHUB_JOB"), "runId": os.getenv("GITHUB_RUN_ID"),
            "runAttempt": os.getenv("GITHUB_RUN_ATTEMPT")}


def toolchain():
    return {name: command(argv) for name, argv in {
        "python": [sys.executable, "--version"], "compiler": ["cc", "--version"],
        "linker": ["ld", "--version"], "cmake": ["cmake", "--version"],
        "make": ["make", "--version"], "libc": ["ldd", "--version"],
    }.items()}


def environment(commit):
    env = dict(os.environ)
    for name in ("ABC_PERF_WORLD", "ABC_PERF_WORLD2", "ABC_PERF_PLAYER", "ABC_PRIVATE_PACK"):
        env.pop(name, None)
    env.update(ABC_PERF_COMMIT=commit, ABC_PERF_TIER="ci", PYTHONDONTWRITEBYTECODE="1")
    return env


def execute(argv, cwd, env, log_path, timeout):
    """Preserve commands/logs and reap the entire process group on timeout."""
    record = {"argv": [str(word) for word in argv], "cwd": str(cwd),
              "startedAt": datetime.now(timezone.utc).isoformat(), "status": "running"}
    manifest = log_path.with_suffix(".command.json")
    assert not log_path.exists() and not manifest.exists(), "Never overwrite an attempt"
    save(manifest, record)
    start = time.monotonic()
    try:
        with log_path.open("x") as log:
            process = subprocess.Popen(argv, cwd=cwd, env=env, stdout=log,
                                       stderr=subprocess.STDOUT, start_new_session=True)
            record["pid"] = process.pid
            save(manifest, record)
            try:
                record["exitCode"] = process.wait(timeout=timeout)
                record["status"] = "passed" if process.returncode == 0 else "failed"
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGTERM)
                try:
                    process.wait(timeout=15)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait()
                record.update(status="timeout", exitCode=process.returncode)
    except OSError as error:
        record.update(status="failed", error=str(error))
    finally:
        record["elapsedSeconds"] = time.monotonic() - start
        save(manifest, record)
    return record


def derive(root, original, candidate, variant, evidence):
    base, paths = VARIANTS[variant]
    command(["git", "clone", "--no-hardlinks", "--no-checkout", str(original), str(root)])
    command(["git", "checkout", "--detach", PINS[base]["commit"]], root)
    source(root, PINS[base])
    for path in paths:
        shutil.copyfile(candidate / path, root / path)
    patch = subprocess.check_output(["git", "diff", "--binary", "HEAD"], cwd=root)
    patch_path = evidence / "variant.patch"
    patch_path.write_bytes(patch)
    changes = command(["git", "diff", "--name-only", "HEAD"], root).splitlines()
    assert sorted(changes) == sorted(paths), "Variant changed unintended files"
    if paths:
        command(["git", "add", "--", *paths], root)
        tree = command(["git", "write-tree"], root)
        env = dict(os.environ, GIT_AUTHOR_NAME="ABC local diagnostic", GIT_AUTHOR_EMAIL="diagnostic@example.invalid",
                   GIT_COMMITTER_NAME="ABC local diagnostic", GIT_COMMITTER_EMAIL="diagnostic@example.invalid",
                   GIT_AUTHOR_DATE="2026-10-09T00:00:00+00:00", GIT_COMMITTER_DATE="2026-10-09T00:00:00+00:00")
        derived = command(["git", "commit-tree", tree, "-p", PINS[base]["commit"], "-m",
                           f"Local MAP experiment {variant}; never an original product pin"], root, env)
        command(["git", "checkout", "--detach", derived], root)
    identity = source(root)
    assert identity["tree"] == TREES[variant], "Wrong derived source tree"
    return {"variant": variant, "kind": "derived-local-commit" if paths else "original-pin",
            "base": PINS[base], "source": identity, "changedPaths": list(paths),
            "patch": "variant.patch", "patchSha256": digest(patch_path),
            "replacementFileSha256": {path: digest(root / path) for path in paths}}


def archive_build(root, destination):
    build = root / "build/native-perf"
    selected = [path for path in build.rglob("*") if path.is_file() and
                (path.suffix in (".so", ".o", ".a", ".map") or path.name in
                 ("compile_commands.json", "CMakeCache.txt", "flags.make", "link.txt", "build.make"))]
    for path in selected:
        target = destination / path.relative_to(build)
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(path, target)
    return {str(path.relative_to(destination)): {"bytes": path.stat().st_size, "sha256": digest(path)}
            for path in sorted(destination.rglob("*")) if path.is_file()}


def snapshot(root):
    library = root / "build/native-perf/libabc_engine.so"
    fixture = root / "build/perf/fixtures/synthetic-medium.wld"
    return {"source": source(root), "library": {"bytes": library.stat().st_size, "sha256": digest(library)},
            "fixture": {"bytes": fixture.stat().st_size, "sha256": digest(fixture)}, "machine": machine()}


def prepare(args):
    assert not args.output.exists() and not args.work.exists(), "Use fresh work/evidence directories"
    args.output.mkdir(parents=True)
    args.work.mkdir(parents=True)
    state = {"schema": "abc.mapgen-factorial.v1", "status": "preparing", "pins": PINS,
             "groups": GROUPS, "sequence": schedule(), "harness": HARNESS,
             "workflowSource": source(args.workflow_root),
             "machine": machine(), "toolchain": toolchain(), "variants": {}, "attempts": [],
             "overallAcceptance": "unestablished", "newWorkloads": "uncompared",
             "scope": "Additional MAP-only source-factor experiment, not replacement of original comparisons",
             "buildEnvironment": {key: os.getenv(key) for key in
                                  ("CC", "CFLAGS", "CPPFLAGS", "LDFLAGS", "CMAKE_GENERATOR")},
             "unusedToolchains": ["Node", "Dart", "Flutter", "Emscripten"]}
    state["deadlineEpochSeconds"] = time.time() + EXECUTION_BUDGET
    state_path = args.output / "session.json"
    harness_root = args.output / "harness"
    for path in HARNESS:
        target = harness_root / "frozen" / path
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(args.candidate / path, target)
    diagnostic_files = list((args.workflow_root / "tool/perf").glob("mapgen_diagnostic*.py"))
    diagnostic_files += [args.workflow_root / ".github/workflows/performance-mapgen-diagnostic.yml"]
    state["diagnosticHarness"] = {}
    for path in diagnostic_files:
        relative = path.relative_to(args.workflow_root)
        target = harness_root / "diagnostic" / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(path, target)
        state["diagnosticHarness"][str(relative)] = digest(path)
    save(state_path, state)
    assert state["workflowSource"]["commit"] == os.environ["MAPGEN_WORKFLOW_HEAD"]
    source(args.baseline, PINS["A"])
    source(args.candidate, PINS["B"])
    for variant, (base, _) in VARIANTS.items():
        evidence = args.output / "variants" / variant
        evidence.mkdir(parents=True)
        root = args.work / variant
        row = {"status": "preparing", "sourcePath": str(root)}
        state["variants"][variant] = row
        save(state_path, state)
        try:
            original = args.baseline if base == "A" else args.candidate
            row["identity"] = derive(root, original, args.candidate, variant, evidence)
            save(evidence / "identity.json", row["identity"])
            env = environment(row["identity"]["source"]["commit"])
            argv_list = [
                [sys.executable, "tool/perf/generate_synthetic_world.py", "build/perf/fixtures/synthetic-medium.wld"],
                ["cmake", "-S", "native", "-B", "build/native-perf", "-G", "Unix Makefiles",
                 "-DCMAKE_BUILD_TYPE=Release", "-DABC_PERF_COUNTERS=ON", "-DCMAKE_EXPORT_COMPILE_COMMANDS=ON",
                 f"-DCMAKE_SHARED_LINKER_FLAGS=-Wl,-Map={root / 'build/native-perf/abc_engine.map'}"],
                ["cmake", "--build", "build/native-perf", "--parallel", "2", "--verbose"],
            ]
            for index, argv in enumerate(argv_list):
                remaining = int(state["deadlineEpochSeconds"] - time.time())
                assert remaining > 30, "Shared execution budget exhausted before next build command"
                execution = execute(argv, root, env, evidence / f"build-{index}.log", min(BUILD_TIMEOUT, remaining - 15))
                assert execution["status"] == "passed", f"Build command {index} failed"
            row["snapshot"] = snapshot(root)
            assert row["snapshot"]["fixture"] == FIXTURE, "Unexpected synthetic fixture"
            for name, argv in {"symbols": ["nm", "-an"], "elf": ["readelf", "-aW"],
                               "disassembly": ["objdump", "-d"]}.items():
                result = execute(argv + [str(root / "build/native-perf/libabc_engine.so")], root, env,
                                 evidence / f"{name}.log", 120)
                assert result["status"] == "passed", f"{name} failed"
            row["status"] = "passed"
        except Exception as error:
            row.update(status="failed", error=f"{type(error).__name__}: {error}")
        finally:
            row["buildArchive"] = archive_build(root, evidence / "build") if root.exists() else {}
            save(state_path, state)
    state["status"] = "prepared" if all(v["status"] == "passed" for v in state["variants"].values()) else "preparation-failed"
    save(state_path, state)
    return int(state["status"] != "prepared")


def run(args):
    state_path = args.output / "session.json"
    state = json.loads(state_path.read_text())
    assert state["status"] == "prepared" and not state["attempts"], "No retries/replacement of old attempts"
    assert state["machine"] == machine() and state["toolchain"] == toolchain(), "Build/measure environment drift"
    for path, expected in state["diagnosticHarness"].items():
        assert digest(args.workflow_root / path) == digest(args.output / "harness/diagnostic" / path) == expected, "Diagnostic harness drift"
    state["status"] = "running"
    save(state_path, state)
    halt_reason = None
    for group in GROUPS:
        for entry in schedule():
            variant = entry["variant"]
            root = args.work / variant
            output = args.output / "raw" / group / entry["slot"]
            output.mkdir(parents=True)
            row = {**entry, "group": group, "status": "running",
                   "output": str(output.relative_to(args.output))}
            state["attempts"].append(row)
            save(state_path, state)
            try:
                if halt_reason or state["deadlineEpochSeconds"] - time.time() < PROCESS_TIMEOUT + 30:
                    row.update(status="unstarted", reason=halt_reason or "shared-execution-budget-exhausted")
                    continue
                row["before"] = snapshot(root)
                assert row["before"] == state["variants"][variant]["snapshot"], "Source/artifact/machine drift"
                if group == "frozen":
                    workload = [sys.executable, "tool/perf/generate_native_map.py", "--library",
                                "build/native-perf/libabc_engine.so", "--input", "build/perf/fixtures/synthetic-medium.wld",
                                "--output", "build/perf/fixtures/generated.map", "--fixture-id", "original-synthetic-world",
                                "--provenance", "original-synthetic", "--iterations", str(ITERATIONS), "--report", "{report}"]
                else:
                    workload = [sys.executable, str(args.output / "harness/diagnostic/tool/perf/mapgen_diagnostic_probe.py"),
                                "--library", str(root / "build/native-perf/libabc_engine.so"),
                                "--input", str(root / "build/perf/fixtures/synthetic-medium.wld"), "--report", "{report}"]
                argv = [sys.executable, "tool/perf/run_ci_suite.py", "--suite", "map-generation", "--runs", "1",
                        "--timeout-seconds", str(PROCESS_TIMEOUT), "--output-dir", str(output), "--", *workload]
                result = execute(argv, root, environment(row["before"]["source"]["commit"]),
                                 output / "driver.log", None)
                # The frozen driver owns a separate benchmark process group
                # and enforces its 600s timeout plus TERM/KILL/reap. Do not put
                # a competing timeout on its parent: killing only the driver
                # could leave its child running alongside the next variant.
                # A stuck driver is bounded by the enclosing 60-minute job;
                # no later process starts while this wait remains pending.
                row.update(status=result["status"], exitCode=result.get("exitCode"))
                inner_path = output / "map-generation.run-1.execution.json"
                inner = json.loads(inner_path.read_text()) if inner_path.exists() else {}
                if inner.get("status") not in ("passed", "failed", "timeout", "missing-report"):
                    # An unexpectedly dead driver may have an orphan child in
                    # its own session. Fail closed: no next timed workload.
                    halt_reason = "driver-ended-without-terminal-child-record"
                    row.update(status="failed", reason=halt_reason)
                row["after"] = snapshot(root)
                assert row["after"] == row["before"], "Per-process drift"
            except Exception as error:
                row.update(status="failed", error=f"{type(error).__name__}: {error}")
            finally:
                save(state_path, state)
    state["status"] = "completed" if all(a["status"] == "passed" for a in state["attempts"]) else "failed"
    save(state_path, state)
    return int(state["status"] != "completed")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("prepare", "run"))
    for name in ("workflow-root", "baseline", "candidate", "work", "output"):
        parser.add_argument("--" + name, type=lambda value: Path(value).resolve(), required=True)
    args = parser.parse_args()
    return prepare(args) if args.action == "prepare" else run(args)


if __name__ == "__main__":
    raise SystemExit(main())
