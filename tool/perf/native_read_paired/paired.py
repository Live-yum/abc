#!/usr/bin/env python3
"""Pinned, offline, Linux AOT wrapper comparison. No product code is edited."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import selectors
import shutil
import statistics
import subprocess
import sys
import time

HERE = Path(__file__).resolve().parent
BASE_COMMIT = "1dac431c45f82bcc298ea4bbce6abebb126dfc33"
BASE_SHA = "5223b0ca10cdb243568927fd7ab911302438a7324ca7a7c456de913ef2c83aa2"
CANDIDATE_SHA = "478fcac164a132beee8e138046274bdd7156e633ceb080e6ee774e6b1bb19411"
WORLD_SHA = "55d0a24bd1f56d622003dbd30d52555e7d06d6d1bcacfc22ae506f2db5240c33"
PONG_SHA = "d2a7d5a26eb168a55c80ae60b32205957d8f2ae215cbdce7c5d50acc2049946d"
BINDING = "lib/engine/native_world_circuit_bindings.dart"
SOURCES = [BINDING, "lib/engine/engine.dart", "lib/engine/world_circuit_backend.dart",
           "lib/domain/computerraria_computer.dart"]
ORDER = list("ABBAAB")
ALLOWED_ORDERS = [list("ABBAAB"), list("BAABBA")]
MEMORY_METRICS = ["statusRssBytes", "statusHwmBytes", "smapsRssBytes",
                  "smapsPssBytes", "smapsUssBytes", "fdCount", "threadCount"]
PUBSPEC = """name: terraforge
publish_to: none
environment:
  sdk: '>=3.13.0 <4.0.0'
dependencies:
  ffi: 2.2.0
  crypto: 3.0.7
  typed_data: 1.4.0
  collection: 1.19.1
"""


def validate_order(order):
    if order not in ALLOWED_ORDERS:
        raise ValueError("Only the complete fixed ABBAAB or BAABBA order is allowed")
    return list(order)


def paired_slots(order):
    order = validate_order(order)
    return [(i + order[i:i + 2].index("A"), i + order[i:i + 2].index("B"))
            for i in range(0, len(order), 2)]


def write_json(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, ensure_ascii=False) + "\n")


def load_json(path):
    return json.loads(Path(path).read_text())


def digest(path):
    h = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for data in iter(lambda: stream.read(1024 * 1024), b""):
            h.update(data)
    return h.hexdigest()


def pin(path):
    path = Path(path).resolve()
    return {"path": str(path), "bytes": path.stat().st_size, "sha256": digest(path)}


def verify_pin(record):
    path = Path(record["path"])
    if path.stat().st_size != record["bytes"] or digest(path) != record["sha256"]:
        raise ValueError(f"Pinned file changed: {path}")


def assert_identity(path, size, sha):
    actual = pin(path)
    if actual["bytes"] != size or actual["sha256"] != sha:
        raise ValueError(f"Identity mismatch: {path}: {actual}")
    return actual


def runtime_env(root, pub_cache):
    env = dict(os.environ)
    env.update({"DART_SUPPRESS_ANALYTICS": "true", "FLUTTER_SUPPRESS_ANALYTICS": "true",
                "CI": "true", "PUB_CACHE": str(pub_cache),
                "XDG_CONFIG_HOME": str(root / "xdg"),
                "TMPDIR": str(root / "tmp")})
    for name in ("xdg", "tmp"):
        (root / name).mkdir(parents=True, exist_ok=True)
    return env


def validate_imports(root):
    """Reject imports beyond the frozen product closure; never substitute a fake API."""
    root = Path(root)
    for relative in SOURCES:
        for uri in re.findall(r"(?:import|export|part)\s+['\"]([^'\"]+)['\"]",
                              (root / relative).read_text()):
            if uri.startswith("dart:"):
                continue
            if uri.startswith("package:"):
                if uri.split("/", 1)[0] not in {"package:ffi", "package:crypto"}:
                    raise ValueError(f"Unexpected product package import: {uri}")
            else:
                resolved = ((root / relative).parent / uri).resolve().relative_to(root.resolve())
                if str(resolved) not in SOURCES:
                    raise ValueError(f"Unpinned product source: {resolved}")


def materialize_candidate(baseline, output):
    baseline, output = Path(baseline).resolve(), Path(output).resolve()
    fixture = HERE / "candidate_binding.dart.txt"
    if digest(baseline / BINDING) != BASE_SHA or digest(fixture) != CANDIDATE_SHA:
        raise ValueError("Unexpected baseline or reviewed candidate binding")
    if output.exists():
        raise ValueError("Candidate destination must be new")
    for relative in SOURCES:
        target = output / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(fixture if relative == BINDING else baseline / relative, target)
    validate_imports(output)
    write_json(output / "derivation.json", {
        "baselineCommit": BASE_COMMIT, "changedProductFiles": [BINDING],
        "baselineBindingSha256": BASE_SHA, "candidateBindingSha256": CANDIDATE_SHA,
        "fixture": pin(fixture), "sources": {name: pin(output / name) for name in SOURCES},
    })


def validate_native_provenance(provenance, library, baseline):
    if provenance.get("source", {}).get("commit") != BASE_COMMIT or provenance.get("source", {}).get("dirty"):
        raise ValueError("Native build is not from the expected clean fixed source")
    artifact = {key: library[key] for key in ("sha256", "bytes")}
    if provenance.get("artifacts", {}).get("libabc_engine.so") != artifact:
        raise ValueError("Shared native artifact identity mismatch")
    cmake = provenance.get("cmake", {})
    if cmake.get("ABC_PERF_COUNTERS") != "OFF" or cmake.get("CMAKE_BUILD_TYPE") != "Profile":
        raise ValueError("Native build must be Profile with counters OFF")
    if cmake.get("CMAKE_GENERATOR") != "Ninja" or "clang" not in Path(cmake.get("CMAKE_C_COMPILER", "")).name:
        raise ValueError("Native build must use the declared clang/Ninja toolchain")
    flags = provenance.get("effectiveCompileFlags", {})
    for target in ("abc_world_circuit.c.o", "terra_circuit_vm.c.o", "terra_circuit_world.c.o"):
        values = flags.get(target, "").split()
        if "-O3" not in values or "-DNDEBUG" not in values or "-O0" in values:
            raise ValueError(f"Unverified optimized native flags: {target}")
    for relative in SOURCES:
        if provenance["sourceFilesSha256"].get(relative) != digest(Path(baseline) / relative):
            raise ValueError(f"Baseline Dart source differs from fixed native build provenance: {relative}")


def prepare(args):
    root = args.output.resolve()
    if (root / "manifest.json").exists() or (root / "A").exists():
        raise ValueError("Output is already prepared; use a new output directory")
    root.mkdir(parents=True, exist_ok=True)
    baseline, candidate = args.baseline.resolve(), args.candidate.resolve()
    if digest(baseline / BINDING) != BASE_SHA or digest(candidate / BINDING) != CANDIDATE_SHA:
        raise ValueError("Baseline/candidate binding is not the frozen reviewed revision")
    for relative in SOURCES[1:]:
        if digest(baseline / relative) != digest(candidate / relative):
            raise ValueError(f"Only the binding may differ: {relative}")
    manifest = {
        "schema": 1, "scope": "pure-Dart AOT host wrapper, not Flutter UI/frame proof",
        "baselineCommit": BASE_COMMIT, "candidateDescription": "single-file READ reuse",
        "workflowCommit": os.environ.get("GITHUB_SHA"),
        "comparability": "Within this CI job only; do not pool absolute values with local runs",
        "order": validate_order(list(args.order)), "cycles": 8, "quietMilliseconds": 1200,
        "timeoutSecondsPerProcess": 600,
        "failurePolicy": "Stop at first failed/timeout/signal/invalid report; preserve partial evidence and rehash original source",
        "studyRole": "Full prespecified reverse-order confirmation" if args.order == "BAABBA" else "Initial fixed-order study",
        "sampleIntervalMilliseconds": 100, "progressIntervalMilliseconds": 20,
        "boundaryProtocol": "worker waits for external sample acknowledgment; operation timers exclude handshakes",
        "coldDefinition": "fresh process first cycle; OS cache not flushed",
        "nativeBuild": {"sourceCommit": BASE_COMMIT, "ABC_PERF_COUNTERS": "OFF",
                        "buildType": "Profile", "compiler": "clang", "generator": "Ninja",
                        "flags": "-O3 -DNDEBUG",
                        "interpretation": "rebuilt once on this CI runner from unchanged fixed 1dac C sources; "
                        "shared by both arms, counters OFF; not byte-identical to a local build"},
        "world": assert_identity(args.world, 405983441, WORLD_SHA),
        "library": pin(args.library),
        "pong": assert_identity(baseline / "assets/computer/pong.bin", 2288, PONG_SHA),
        "programs": pin(baseline / "native/fixtures/computerraria/programs.json"),
        "nativeProvenance": pin(args.native_provenance),
        "sourceRoots": {"A": str(baseline), "B": str(candidate)},
        "originalSourcePins": {}, "frozenFiles": {},
        "harness": {"paired.py": pin(HERE / "paired.py"),
                    "bin/benchmark.dart": pin(HERE / "bin/benchmark.dart")},
        "dart": pin(args.dart), "pubCache": str(args.pub_cache.resolve()),
        "prohibitions": ["no forced GC", "no VM service or AllocationProfile",
                         "no malloc_trim", "no outlier removal", "no absolute performance pass threshold"],
    }
    provenance = load_json(args.native_provenance)
    validate_native_provenance(provenance, manifest["library"], baseline)
    for variant, source_root in (("A", baseline), ("B", candidate)):
        validate_imports(source_root)
        manifest["originalSourcePins"][variant] = {}
        for relative in SOURCES:
            target = root / variant / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(source_root / relative, target)
            manifest["originalSourcePins"][variant][relative] = pin(source_root / relative)
            manifest["frozenFiles"][f"{variant}/{relative}"] = pin(target)
        target = root / variant / "bin/benchmark.dart"
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(HERE / "bin/benchmark.dart", target)
        (root / variant / "pubspec.yaml").write_text(PUBSPEC)
        shutil.copyfile(HERE / "standalone.pubspec.lock", root / variant / "pubspec.lock")
        for relative in ["bin/benchmark.dart", "pubspec.yaml", "pubspec.lock"]:
            manifest["frozenFiles"][f"{variant}/{relative}"] = pin(root / variant / relative)
    env = runtime_env(root / "prepare", args.pub_cache)
    result = subprocess.run([str(args.dart), "--version"], env=env,
                            capture_output=True, text=True, check=True)
    manifest["dartVersion"] = (result.stdout + result.stderr).strip()
    if not re.search(r"Dart SDK version: 3\.13\.5\b", manifest["dartVersion"]):
        raise ValueError("Diagnostic requires the fixed Dart 3.13.5 SDK")
    sdk = args.dart.resolve().parent.parent
    manifest["sdkRuntimePins"] = [pin(p) for p in [
        sdk / "bin/dart", sdk / "bin/dartaotruntime", sdk / "bin/dartvm",
        sdk / "bin/snapshots/gen_kernel_aot.dart.snapshot",
        sdk / "bin/snapshots/dartdev_aot.dart.snapshot",
        sdk / "bin/utils/gen_snapshot", sdk / "lib/_internal/vm_platform_strong.dill"] if p.is_file()]
    write_json(root / "manifest.json", manifest)
    print(json.dumps({"status": "prepared-only", "manifest": str(root / "manifest.json")}))


def verify_manifest(root, include_world=True):
    manifest = load_json(root / "manifest.json")
    validate_order(manifest["order"])
    if manifest["cycles"] != 8 or manifest["quietMilliseconds"] != 1200:
        raise ValueError("Protocol changed")
    for record in manifest["harness"].values():
        verify_pin(record)
    for record in manifest["frozenFiles"].values():
        verify_pin(record)
    for group in manifest["originalSourcePins"].values():
        for record in group.values():
            verify_pin(record)
    for key in ["library", "pong", "programs", "dart", "nativeProvenance"]:
        verify_pin(manifest[key])
    for record in manifest["sdkRuntimePins"]:
        verify_pin(record)
    if include_world:
        verify_pin(manifest["world"])
    return manifest


def package_pins(package_config):
    from urllib.parse import urljoin, urlparse, unquote
    config = load_json(package_config)
    output = {}
    for package in config["packages"]:
        if package["name"] == "terraforge":
            continue
        uri = urljoin(Path(package_config).resolve().as_uri(), package["rootUri"])
        if not uri.startswith("file:"):
            raise ValueError("Dependency is not a local package")
        root = Path(unquote(urlparse(uri).path))
        files = sorted((root / "lib").rglob("*.dart")) + [root / "pubspec.yaml"]
        output[package["name"]] = [pin(p) for p in files]
    if set(output) != {"ffi", "crypto", "typed_data", "collection"}:
        raise ValueError(f"Unexpected package closure: {sorted(output)}")
    return output


def build(args):
    root = args.output.resolve()
    manifest = verify_manifest(root)
    if (root / "build.json").exists():
        raise ValueError("Build already exists; do not overwrite pinned AOT artifacts")
    record = {"status": "running", "manifestSha256": digest(root / "manifest.json"),
              "commands": [], "executables": {}, "packagePins": {}}
    write_json(root / "build.json", record)
    try:
        for variant in ("A", "B"):
            variant_root = root / variant
            env = runtime_env(root / "build-env", Path(manifest["pubCache"]))
            dart = manifest["dart"]["path"]
            commands = [[dart, "pub", "get", "--offline", "--enforce-lockfile"],
                        [dart, "compile", "exe", "bin/benchmark.dart", "-o", "benchmark"]]
            for number, command in enumerate(commands):
                log = root / f"build-{variant}-{number}.log"
                with log.open("w") as stream:
                    result = subprocess.run(command, cwd=variant_root, env=env,
                                            stdout=stream, stderr=subprocess.STDOUT)
                record["commands"].append({"variant": variant, "command": command,
                                            "exitCode": result.returncode, "log": str(log)})
                write_json(root / "build.json", record)
                if result.returncode:
                    raise RuntimeError(f"Build failed; see {log}")
            record["executables"][variant] = pin(variant_root / "benchmark")
            record["packagePins"][variant] = package_pins(variant_root / ".dart_tool/package_config.json")
            record.setdefault("lockfiles", {})[variant] = pin(variant_root / "pubspec.lock")
        if record["packagePins"]["A"] != record["packagePins"]["B"]:
            raise ValueError("A and B dependency bytes differ")
        record["status"] = "passed"
    except Exception as error:
        record["status"], record["error"] = "failed", str(error)
        raise
    finally:
        write_json(root / "build.json", record)
    print(json.dumps({"status": "built-only", "build": str(root / "build.json")}))


def parse_kib(text):
    values = {}
    for line in text.splitlines():
        match = re.fullmatch(r"([^:]+):\s*(\d+)\s+kB", line)
        if match:
            values[match[1]] = int(match[2]) * 1024
    return values


def proc_sample(pid, proc_root=Path("/proc")):
    root = proc_root / str(pid)
    try:
        status_text = (root / "status").read_text()
    except (FileNotFoundError, ProcessLookupError):
        return None
    status = parse_kib(status_text)
    result = {"statusRssBytes": status.get("VmRSS"), "statusHwmBytes": status.get("VmHWM")}
    threads = re.search(r"^Threads:\s*(\d+)$", status_text, re.M)
    result["threadCount"] = int(threads[1]) if threads else None
    try:
        smaps = parse_kib((root / "smaps_rollup").read_text())
        result.update({"smapsRssBytes": smaps.get("Rss"), "smapsPssBytes": smaps.get("Pss"),
                       "smapsUssBytes": sum(smaps.get(k, 0) for k in
                           ["Private_Clean", "Private_Dirty", "Private_Hugetlb"]),
                       "smapsPrivateCleanBytes": smaps.get("Private_Clean"),
                       "smapsPrivateDirtyBytes": smaps.get("Private_Dirty"),
                       "smapsPrivateHugetlbBytes": smaps.get("Private_Hugetlb", 0)})
    except (OSError, ProcessLookupError) as error:
        result["smapsError"] = type(error).__name__
    try:
        result["fdCount"] = len(list((root / "fd").iterdir()))
    except OSError as error:
        result["fdError"] = type(error).__name__
    return result


def run_process(command, directory, env, timeout_seconds, interval_seconds=0.1):
    """Never probes the Dart VM. Keeps every observation, log and partial report."""
    directory.mkdir(parents=True, exist_ok=False)
    start = time.monotonic_ns()
    state = {"cycle": 0, "phase": "launch"}
    outcome = {"command": command, "status": "running", "timeoutSeconds": timeout_seconds}
    with (directory / "stdout.jsonl").open("wb") as out, \
         (directory / "stderr.log").open("wb") as err, \
         (directory / "os-samples.jsonl").open("w") as samples:
        process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=err, env=env,
                                   cwd=directory, start_new_session=True)
        outcome["pid"] = process.pid
        selector = selectors.DefaultSelector()
        selector.register(process.stdout, selectors.EVENT_READ)
        pending = b""
        next_sample = time.monotonic()
        def sample(kind):
            values = proc_sample(process.pid)
            samples.write(json.dumps({"kind": kind, "elapsedNanoseconds": time.monotonic_ns() - start,
                                      **state, "memory": values}) + "\n")
            samples.flush()
        try:
            while True:
                now = time.monotonic()
                if now >= next_sample:
                    sample("periodic")
                    next_sample = now + interval_seconds
                if (time.monotonic_ns() - start) / 1e9 > timeout_seconds:
                    outcome["status"] = "timeout"
                    process.terminate()
                    try:
                        process.wait(timeout=10)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait()
                    break
                ready = selector.select(timeout=max(0, min(0.1, next_sample - time.monotonic())))
                for key, _ in ready:
                    chunk = os.read(key.fileobj.fileno(), 65536)
                    if not chunk:
                        selector.unregister(key.fileobj)
                        continue
                    out.write(chunk)
                    out.flush()
                    pending += chunk
                    while b"\n" in pending:
                        line, pending = pending.split(b"\n", 1)
                        try:
                            event = json.loads(line)
                        except (ValueError, UnicodeDecodeError):
                            continue
                        if isinstance(event, dict) and event.get("event") == "boundary":
                            state.update(cycle=event["cycle"], phase=event["phase"])
                            sample("boundary")
                            process.stdin.write(b"ack\n")
                            process.stdin.flush()
                if process.poll() is not None and not selector.get_map():
                    break
        finally:
            selector.close()
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
            tail = process.stdout.read()
            if tail:
                out.write(tail)
            process.stdout.close()
            process.stdin.close()
        outcome["exitCode"] = process.returncode
        outcome["signal"] = -process.returncode if process.returncode < 0 else None
        outcome["shellEquivalentExitCode"] = 128 - process.returncode if process.returncode < 0 else process.returncode
        if outcome["status"] == "running":
            outcome["status"] = "passed" if process.returncode == 0 else "failed"
    outcome["elapsedSeconds"] = (time.monotonic_ns() - start) / 1e9
    write_json(directory / "execution.json", outcome)
    return outcome


def validate_report(report, variant):
    errors = []
    if report.get("status") != "passed":
        errors.append("worker did not pass")
    if report.get("variant") != variant or report.get("quietMilliseconds") != 1200:
        errors.append("worker protocol/variant mismatch")
    cycles = report.get("cycles", [])
    if [c.get("cycle") for c in cycles] != list(range(1, 9)):
        errors.append("must retain all eight ordered cycles")
    for cycle in cycles:
        if cycle.get("sourceSha256") != WORLD_SHA:
            errors.append("source hash mismatch")
        stats = cycle.get("openStats", [])
        if len(stats) != 24 or [stats[i] for i in (0, 2, 3, 10, 12)] != [2, 15200, 7200, 72939714, 13641575]:
            errors.append("full-world graph mismatch")
        correctness = cycle.get("correctness", {})
        if correctness.get("pongSha256") != PONG_SHA or len(correctness.get("pongFrames", [])) != 12:
            errors.append("Pong evidence missing")
        signature = correctness.get("cpu", {}).get("signature", [])
        if len(signature) != 48 or signature[-1] != 0x600dc0de:
            errors.append("48 physical CPU signatures missing")
        frames = correctness.get("pongFrames", [])
        if [f.get("clocks") for f in frames] != [128 * n for n in range(1, 13)]:
            errors.append("Pong clock trace differs from bounded protocol")
        if len({f.get("ramSha256") for f in frames}) < 2:
            errors.append("Pong physical RAM does not change")
        if len({f.get("displaySha256") for f in frames}) < 3:
            errors.append("Pong physical display does not change")
        timing = cycle.get("timings", {})
        if not isinstance(timing.get("openMicroseconds"), (int, float)) or timing["openMicroseconds"] <= 0:
            errors.append("open timing missing")
        if timing.get("actualQuietMicroseconds", 0) < 1200000:
            errors.append("quiet interval was shortened")
        if report.get("nativeCounterAvailable") and cycle.get("closedNativeLiveBytes") != 0:
            errors.append("native allocations remain after cycle")
        if not report.get("nativeCounterAvailable") and cycle.get("closedNativeLiveBytes") is not None:
            errors.append("unavailable native counter must remain null")
        if not cycle.get("closedHandleRejected"):
            errors.append("closed handle rejection missing")
    if not report.get("originalStatUnchanged"):
        errors.append("original source stat changed")
    cancellation = report.get("cancellation", {})
    if cancellation.get("reopenedSourceSha256") != WORLD_SHA or "cancelled" not in cancellation.get("error", ""):
        errors.append("cancellation/recovery evidence missing")
    if cycles and cancellation.get("reopenedStats") != cycles[0].get("openStats"):
        errors.append("cancellation recovery graph differs")
    if report.get("nativeCounterAvailable") and report.get("nativeLiveBytesAfterClose") != 0:
        errors.append("native allocations remain at exit")
    return errors


def outcomes(cycle):
    return {key: cycle.get(key) for key in ["sourceSha256", "openStats", "openFlags", "correctness"]}


def describe(values):
    return {"samples": values, "count": len(values), "median": statistics.median(values),
            "minimum": min(values), "maximum": max(values)} if values else None


def summarize(root):
    manifest = load_json(root / "manifest.json")
    order = validate_order(manifest.get("order", ORDER))
    summary = {"schema": 1, "scope": manifest["scope"], "nativeBuild": manifest["nativeBuild"],
               "order": order, "status": "passed", "errors": [], "processes": [],
               "allSamplesRetained": True, "notRunSlots": [],
               "thresholdPolicy": "No performance pass/fail threshold",
               "independentUnit": "fresh process, 3 per arm; warm cycles within a process are repeated observations"}
    reference = None
    expected_cpu = [item["expected"] for item in load_json(manifest["programs"]["path"])["main"]["checks"]]
    for slot, variant in enumerate(order, 1):
        directory = root / "raw" / f"{slot:02d}-{variant}"
        if not directory.exists():
            summary["notRunSlots"].append({"slot": slot, "variant": variant})
            continue
        item = {"slot": slot, "variant": variant, "path": str(directory)}
        summary["processes"].append(item)
        try:
            report = load_json(directory / "report.json")
            execution = load_json(directory / "execution.json")
            errors = validate_report(report, variant)
            if execution["status"] != "passed":
                errors.append(f"execution {execution['status']}")
            for cycle in report.get("cycles", []):
                if cycle.get("correctness", {}).get("cpu", {}).get("signature") != expected_cpu:
                    errors.append(f"cycle {cycle['cycle']} independent CPU expectations mismatch")
                observed = outcomes(cycle)
                if reference is None:
                    reference = observed
                elif observed != reference:
                    errors.append(f"cycle {cycle['cycle']} physical/hash/graph outcomes differ")
            item["validationErrors"] = errors
            summary["errors"].extend(f"{slot:02d}-{variant}: {e}" for e in errors)
            cycles = report["cycles"]
            item["coldOpenMs"] = cycles[0]["timings"]["openMicroseconds"] / 1000
            item["warmOpenMs"] = describe([c["timings"]["openMicroseconds"] / 1000 for c in cycles[1:]])
            item["phaseObservedMs"] = {
                stage: [c["timings"][f"{stage}ObservedMicroseconds"] / 1000
                        if f"{stage}ObservedMicroseconds" in c["timings"] else None for c in cycles]
                for stage in ("hash", "decode", "compile")}
            samples = [json.loads(line) for line in (directory / "os-samples.jsonl").read_text().splitlines()]
            measured = [s for s in samples if 1 <= s["cycle"] <= 8 and s.get("memory")]
            boundaries = [s for s in measured if s["kind"] == "boundary"]
            item["memory"] = {}
            for metric in MEMORY_METRICS:
                quiet = [s["memory"].get(metric) for s in boundaries if s["phase"] == "closedQuiet"]
                values = [s["memory"].get(metric) for s in measured]
                values = [v for v in values if v is not None]
                item["memory"][metric] = {
                    "sampledPeakAcrossEightCycles": max(values) if values else None,
                    "closedQuietByCycle": quiet,
                    "cycle8MinusCycle1": quiet[-1] - quiet[0] if len(quiet) == 8 and None not in quiet else None,
                }
                if len(quiet) != 8 or None in quiet:
                    summary["errors"].append(f"{slot:02d}-{variant}: incomplete {metric} quiet observations")
            item["boundarySamples"] = boundaries
        except (OSError, ValueError, KeyError, IndexError, TypeError) as error:
            item["reportError"] = str(error)
            summary["errors"].append(f"{slot:02d}-{variant}: {error}")
    summary["completeness"] = "incomplete" if summary["notRunSlots"] else "complete"
    if summary["notRunSlots"]:
        summary["errors"].append(f"Suite incomplete: {len(summary['notRunSlots'])} planned processes were not run")
    session_file = root / "session.json"
    if session_file.exists():
        session = load_json(session_file)
        summary["sourceVerificationAfter"] = session.get("sourceVerificationAfter")
        if session.get("sourceVerificationAfter", {}).get("status") == "failed":
            summary["errors"].append("Original source verification after execution failed")
    if summary["errors"]:
        summary["status"] = "failed"
    summary["arms"] = {}
    for variant in ("A", "B"):
        items = [p for p in summary["processes"] if p["variant"] == variant]
        summary["arms"][variant] = {
            "processColdOpenMs": describe([p["coldOpenMs"] for p in items if "coldOpenMs" in p]),
            "processWarmMedianOpenMs": describe([p["warmOpenMs"]["median"] for p in items if p.get("warmOpenMs")]),
        }
    summary["pairedComparisons"] = []
    by_slot = {item["slot"]: item for item in summary["processes"]}
    for a, b in paired_slots(order):
        left, right = by_slot.get(a + 1, {}), by_slot.get(b + 1, {})
        if left.get("warmOpenMs") and right.get("warmOpenMs"):
            summary["pairedComparisons"].append({
                "A_slot": a + 1, "B_slot": b + 1,
                "cold_B_minus_A_ms": right["coldOpenMs"] - left["coldOpenMs"],
                "warmMedian_B_minus_A_ms": right["warmOpenMs"]["median"] - left["warmOpenMs"]["median"],
            })
    summary["limitations"] = [
        "No Flutter/UI/render/frame acceptance; direct actual Dart wrapper with physical C engine.",
        "Cold means fresh process, not a cold OS page cache. Pin verification reads the WLD.",
        "Rebuilt fixed-source 1dac native binary shared by A/B, counters OFF; native live-byte fields are null. CI absolute values are not pooled with local runs.",
        "20ms progress observations are approximate stage timings; missing stages remain missing in raw data.",
        "100ms proc sampling can miss instantaneous peaks. /proc/status and smaps are read sequentially, not atomically.",
        "VmHWM/ProcessInfo.maxRss are lifetime high-water values, not current RSS or per-cycle peaks.",
        "USS = Private_Clean + Private_Dirty + Private_Hugetlb; RSS/PSS/USS are separate observations.",
        "Repeated eight-cycle slope is bounded evidence, not proof of no leak or a stable long-run plateau.",
        "One hash-stage cancellation plus recovery, not all operation/failure/allocation coverage.",
    ]
    write_json(root / "summary.json", summary)
    return summary


def run(args):
    root = args.output.resolve()
    manifest = verify_manifest(root)
    order = validate_order(manifest.get("order", ORDER))
    if args.timeout_seconds != manifest.get("timeoutSecondsPerProcess", 600):
        raise ValueError("Run timeout must match the frozen 600-second process bound")
    build_record = load_json(root / "build.json")
    if build_record["status"] != "passed" or build_record["manifestSha256"] != digest(root / "manifest.json"):
        raise ValueError("No successful build for this exact manifest")
    for record in build_record["executables"].values():
        verify_pin(record)
    for group in build_record["packagePins"].values():
        for files in group.values():
            for record in files:
                verify_pin(record)
    if (root / "raw").exists():
        raise ValueError("Raw results already exist; never overwrite or silently rerun a sample")
    (root / "raw").mkdir()
    uname = os.uname()
    session = {"status": "running", "manifestSha256": digest(root / "manifest.json"),
               "buildSha256": digest(root / "build.json"), "order": order,
               "timeoutSecondsPerProcess": args.timeout_seconds, "completeness": "incomplete",
               "failurePolicy": "stop after first failed, timed-out, signalled or invalid-report process; retain all raw evidence",
               "platform": {name: getattr(uname, name) for name in
                            ("sysname", "nodename", "release", "version", "machine")}, "processes": [],
               "globalMeminfoBefore": Path("/proc/meminfo").read_text(),
               "capacityCaveat": "Global meminfo is not a verified per-task/cgroup limit",
               "startedUnixSeconds": time.time()}
    write_json(root / "session.json", session)
    try:
        for slot, variant in enumerate(order, 1):
            # Verify executable/shared library again immediately before launch.
            verify_pin(build_record["executables"][variant])
            verify_pin(manifest["library"])
            directory = root / "raw" / f"{slot:02d}-{variant}"
            env = runtime_env(root / "runtime-env" / f"{slot:02d}-{variant}", Path(manifest["pubCache"]))
            command = [build_record["executables"][variant]["path"], manifest["library"]["path"],
                       manifest["world"]["path"], manifest["pong"]["path"], manifest["programs"]["path"],
                       str(directory / "report.json"), variant]
            result = run_process(command, directory, env, args.timeout_seconds)
            if result["status"] == "passed":
                try:
                    report_errors = validate_report(load_json(directory / "report.json"), variant)
                except (OSError, ValueError, TypeError) as error:
                    report_errors = [str(error)]
                if report_errors:
                    result["status"] = "invalid-report"
                    result["workerReportErrors"] = report_errors
            session["processes"].append({"slot": slot, "variant": variant, **result})
            write_json(root / "session.json", session)
            print(json.dumps({"slot": slot, "variant": variant, "status": result["status"]}), flush=True)
            if result["status"] != "passed":
                session["status"] = "failed"
                session["stoppedAfterSlot"] = slot
                session["stopReason"] = result["status"]
                break
        else:
            session["status"] = "passed"
            session["completeness"] = "complete"
    except BaseException as error:
        session["status"], session["error"] = "failed", str(error)
        raise
    finally:
        # A crash/timeout must still leave independent source-preservation
        # evidence. Failure to read/hash is recorded, never guessed as success.
        try:
            after = pin(manifest["world"]["path"])
            source_matches = all(after[key] == manifest["world"][key] for key in ("sha256", "bytes"))
            session["originalSourceSha256After"] = after["sha256"]
            session["sourceVerificationAfter"] = {"status": "passed" if source_matches else "failed", **after}
            if not source_matches:
                session["status"] = "failed"
        except (OSError, ValueError) as error:
            session["sourceVerificationAfter"] = {"status": "failed", "error": str(error)}
            session["status"] = "failed"
        session["finishedUnixSeconds"] = time.time()
        session["globalMeminfoAfter"] = Path("/proc/meminfo").read_text()
        write_json(root / "session.json", session)
        try:
            summary = summarize(root)
            if summary["status"] != "passed":
                session["status"] = "failed"
        except (OSError, ValueError, KeyError, TypeError) as error:
            session["summaryError"] = str(error)
            session["status"] = "failed"
        write_json(root / "session.json", session)
    return 0 if session["status"] == "passed" else 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["candidate", "prepare", "build", "run", "report", "check"])
    parser.add_argument("--output", type=Path, default=HERE / "prepared")
    parser.add_argument("--order", choices=["ABBAAB", "BAABBA"], default="ABBAAB",
                        help="Preparation only; run/report always use the frozen manifest order")
    parser.add_argument("--baseline", type=Path)
    parser.add_argument("--candidate", type=Path)
    parser.add_argument("--world", type=Path)
    parser.add_argument("--library", type=Path)
    parser.add_argument("--native-provenance", type=Path)
    parser.add_argument("--dart", type=Path)
    parser.add_argument("--pub-cache", type=Path)
    parser.add_argument("--timeout-seconds", type=int, default=600,
                        help="identical resource bound per process, not a performance pass threshold")
    args = parser.parse_args()
    if args.timeout_seconds <= 0:
        parser.error("timeout must be positive")
    if args.action == "candidate":
        if args.baseline is None:
            parser.error("candidate requires --baseline")
        materialize_candidate(args.baseline, args.output)
    elif args.action == "prepare":
        for name in ["baseline", "candidate", "world", "library", "native_provenance", "dart", "pub_cache"]:
            if getattr(args, name) is None:
                parser.error(f"prepare requires --{name.replace('_', '-')}")
        prepare(args)
    elif args.action == "build":
        build(args)
    elif args.action == "run":
        return run(args)
    elif args.action == "report":
        result = summarize(args.output.resolve())
        print(json.dumps({"status": result["status"], "errors": result["errors"]}))
        return 0 if result["status"] == "passed" else 1
    else:
        verify_manifest(args.output.resolve())
        print("Exact source, compiler, input and native-library pins passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
