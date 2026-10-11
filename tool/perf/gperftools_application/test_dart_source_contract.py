#!/usr/bin/env python3
"""Offline source/ABI contracts only. Never imports or invokes Dart/Flutter.

Use --root for an assembled tree. --baseline supplies unchanged original files
when reviewing the small overlay alone. This cannot prove Dart compilation or
real target entry; those remain mandatory gates in the one authorized CI pair.
"""
from __future__ import annotations

import argparse
import ctypes
import hashlib
import json
from pathlib import Path
import re
import unittest

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
BASELINE = ROOT
CONTRACTS = ROOT / "tool/perf/gperftools_application_contracts"
HARNESS = "integration_test/computer_memory_ownership_test.dart"
PROBE = "integration_test/support/memory_allocation_stack_probe.dart"
ORIGINAL_SHA = "3a9806165d2c5e025122a3118683259c4a42d54c682b7276ab57f5b87096e3d8"
HEADER_SHA = "48b55cb8c26cffe8a8fa1b9a4cf0195fcbb2693ae3fd5ca9b92f367ec5e09cd7"
BLOCK = re.compile(
    r"^[ \t]*// BEGIN bounded stack-attribution ([^\n]+)\n"
    r".*?^[ \t]*// END bounded stack-attribution \1\n",
    re.M | re.S,
)
NAMES = ["import", "lifetime", "initialization", "hello", "quiet cut", "stop"]


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def read(relative: str) -> bytes:
    path = ROOT / relative
    return (path if path.exists() else BASELINE / relative).read_bytes()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValueError(message)


def blocks(source: str) -> dict[str, re.Match]:
    found = list(BLOCK.finditer(source))
    require([m[1] for m in found] == NAMES, "Exactly six additive blocks required")
    require(digest(BLOCK.sub("", source).encode()) == ORIGINAL_SHA,
            "Original 5a161bf ownership harness changed outside additive blocks")
    return {m[1]: m for m in found}


def verify_harness(source: str) -> None:
    parts = blocks(source)
    quiet = parts["quiet cut"]
    require(source[:quiet.start()].endswith("          wrapper(),\n        );\n"),
            "Quiet hook must follow the original awaited, flushed gauge")
    require(source[quiet.end():].startswith("      }\n\n      Future<void> point("),
            "Quiet hook must be the last operation in original quiet()")
    require("if (phase == 'released' && (cycle == 0 || cycle == 7))" in quiet[0]
            and quiet[0].count("allocationStack.afterGauge(cycle, Timeline.now);") == 1,
            "Only released q0/q7 are allowed")
    initialization = parts["initialization"]
    require(source[:initialization.start()].endswith("    try {\n"),
            "Initialize inside original outer try")
    require(source[initialization.end():].startswith("      final scheduleBytes"),
            "Initialize before original schedule/hello/WLD")
    require(initialization[0].index("stackProbe = allocationStack;") <
            initialization[0].index("allocationStack.initialize();"),
            "Retain the initialized probe for every failure finally")
    require(initialization.start() < source.index("final hello = File(") <
            parts["hello"].start() < source.index("await waitForOwnershipReady(") <
            source.index("await inputs.computerInput()"), "Startup gate order changed")
    require(source[:parts["hello"].start()].endswith("          'startedUs': Timeline.now,\n")
            and "'stackAttribution': allocationStack.startup," in parts["hello"][0],
            "Hello extension must preserve original fields")
    stop = parts["stop"]
    require(source[:stop.start()].endswith(
        "      failureStack = stack.toString();\n    } finally {\n"),
        "Stop must enter the original outer finally before any original cleanup")
    require(source[stop.end():].startswith("      try {\n        journal?.stop();")
            and stop[0].count("stackProbe?.stopAndWriteEvidence();") == 1,
            "Stop must occur once before sampler/report finalization")


def verify_probe(source: str) -> None:
    require(not re.search(r"isLeaf\s*:\s*true", source), "FFI must not be leaf")
    require("HeapProfilerStart" not in source and "GetHeapProfile" not in source,
            "Probe must not start or extract extra profiles")
    require("Abi.current() != Abi.linuxX64" in source
            and "sizeOf<_QuietCut>() != 72" in source
            and "sizeOf<_QuietMetadata>() != 232" in source,
            "Restrict native layout to the audited Linux x86_64 ABI")
    require("Int32 Function(Int32, Uint64)" in source,
            "Native after-gauge ABI differs")
    require(source.count("_afterGauge(cycle, gaugeDartUs)") == 1,
            "Only one native after-gauge call site is allowed")
    start = source.index("void afterGauge(")
    end = source.index("Map<String, Object?> _nativeMetadata(")
    cut = source[start:end]
    require("cycle != (_attemptedCuts == 0 ? 0 : 7)" in cut
            and "_attemptedCuts >= 2" in cut, "Fixed two-slot cut budget required")
    require("Timeline.startSync(" in cut and "Timeline.finishSync();" in cut
            and "finally {" in cut, "Dart timeline bracket must always close")
    require("jsonEncode" not in cut and "File(" not in cut
            and "_nativeMetadata(" not in cut and "await " not in cut,
            "Do not encode, write, allocate metadata maps or yield around Dump")
    stop = source[source.index("void stopAndWriteEvidence()") :]
    require(stop.index("_stopInvoked = true;") < stop.index("final result = _stop();") <
            stop.index("_nativeMetadata(includeCuts: true)") < stop.index("jsonEncode(evidence)"),
            "Consume once and Stop before final evidence serialization")
    require("if (_stopInvoked) return;" in stop
            and source.count("final result = _stop();") == 1,
            "Stop FFI call must be one idempotent call site")
    require("File('$_outputPath/dart-probe.json')" in stop
            and "exclusive: true" in stop, "Use a fresh sibling sidecar")
    require(".close()" not in source and ".dispose()" not in source,
            "Do not unload the diagnostic helper during the workload")


def dart_fields(source: str, name: str) -> list[tuple[str, str]]:
    body = source.split(f"final class {name} extends Struct {{", 1)[1].split("\n}", 1)[0]
    return re.findall(r"@(\w+)\([^)]*\)\s+external (?:int|Array<_QuietCut>) (\w+);", body)


class SourceContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.harness = read(HARNESS).decode()
        cls.probe = read(PROBE).decode()

    def test_inverse_patch_reproduces_exact_original_harness(self):
        self.assertEqual(digest(BLOCK.sub("", self.harness).encode()), ORIGINAL_SHA)

    def test_harness_init_hello_quiet_and_finally_order(self):
        verify_harness(self.harness)

    def test_ffi_is_nonleaf_synchronous_bounded_and_stop_once(self):
        verify_probe(self.probe)

    def test_original_workload_supports_schedule_and_validator_are_frozen(self):
        manifest = json.loads((HERE / "harness_frozen_sources.json").read_text())
        for entry in manifest["unchanged"]:
            with self.subTest(path=entry["path"]):
                value = read(entry["path"])
                self.assertEqual(len(value), entry["bytes"])
                self.assertEqual(digest(value), entry["sha256"])

    def test_native_header_is_the_reviewed_abi(self):
        self.assertEqual(digest((CONTRACTS / "quiet_dump_bridge.h").read_bytes()), HEADER_SHA)

    def test_cut_fields_match_c_order_and_width(self):
        self.assertEqual(dart_fields(self.probe, "_QuietCut"), [
            ("Int32", "cycle"), ("Int32", "accepted"),
            ("Uint64", "gaugeDartUs"), ("Uint64", "enterNs"),
            ("Uint64", "dumpStartNs"), ("Uint64", "dumpEndNs"),
            ("Uint64", "ackEndNs"), ("Uint64", "exitNs"),
            ("Size", "mapsBeforeSize"), ("Size", "mapsAfterSize"),
        ])

    def test_metadata_fields_match_c_order_and_width(self):
        self.assertEqual(dart_fields(self.probe, "_QuietMetadata"), [
            *[("Uint32", field) for field in
              ("abi", "offline", "slotsUsed", "dumpCount", "stopCalls")],
            *[("Int32", field) for field in
              ("initialized", "failure", "stopRequested", "stopVerified", "cleanupFailure")],
            *[("Uint64", field) for field in
              ("observerPreallocatedBytes", "stopStartNs", "stopEndNs", "observerMapsBytes")],
            *[("Uint32", field) for field in
              ("observerHeldFds", "observerClosedFds", "observerFdCloseAttempts")],
            ("Int32", "observerFdCleanupFailure"), ("Array", "cuts"),
        ])

    def test_ctypes_documents_audited_struct_layout_without_c_execution(self):
        class Cut(ctypes.Structure):
            _fields_ = [("cycle", ctypes.c_int32), ("accepted", ctypes.c_int32)] + [
                (name, ctypes.c_uint64) for name in ("gauge", "enter", "dumpStart", "dumpEnd",
                                                   "ackEnd", "exit", "beforeSize", "afterSize")]
        class Metadata(ctypes.Structure):
            _fields_ = [(f"u{i}", ctypes.c_uint32) for i in range(5)] + [
                (f"i{i}", ctypes.c_int32) for i in range(5)] + [
                (f"n{i}", ctypes.c_uint64) for i in range(4)] + [
                (f"f{i}", ctypes.c_uint32) for i in range(3)] + [
                ("cleanup", ctypes.c_int32), ("cuts", Cut * 2)]
        self.assertEqual(ctypes.sizeof(Cut), 72)
        self.assertEqual(ctypes.sizeof(Metadata), 232)
        self.assertEqual(Metadata.cuts.offset, 88)

    def test_original_gauge_or_gc_mutation_is_rejected(self):
        for old, new in [("expect(gauges.length, 52);", "expect(gauges.length, 53);"),
                         ("await telemetry.measure();", "await telemetry.measure(extraGc: true);"),
                         ("cycle < 8", "cycle < 9")]:
            with self.subTest(change=old), self.assertRaises(ValueError):
                verify_harness(self.harness.replace(old, new, 1))

    def test_retained_or_final_dump_mutation_is_rejected(self):
        for old, new in [("phase == 'released'", "phase == 'retained'"),
                         ("cycle == 7", "cycle == 8")]:
            with self.subTest(change=old), self.assertRaises(ValueError):
                verify_harness(self.harness.replace(old, new, 1))

    def test_hook_moved_before_original_gauge_is_rejected(self):
        match = blocks(self.harness)["quiet cut"]
        block = match[0]
        changed = self.harness[:match.start()] + self.harness[match.end():]
        location = changed.index("        await gauge(\n          cycle == 8")
        changed = changed[:location] + block + changed[location:]
        with self.assertRaisesRegex(ValueError, "follow the original"):
            verify_harness(changed)

    def test_stop_moved_after_original_cleanup_is_rejected(self):
        match = blocks(self.harness)["stop"]
        block = match[0]
        changed = self.harness[:match.start()] + self.harness[match.end():]
        changed = changed.replace("        journal?.stop();\n", "        journal?.stop();\n" + block, 1)
        with self.assertRaisesRegex(ValueError, "outer finally"):
            verify_harness(changed)

    def test_leaf_or_extra_dump_call_is_rejected(self):
        for changed in [self.probe + "\n// isLeaf: true\n",
                        self.probe.replace("_afterGauge(cycle, gaugeDartUs)",
                                           "_afterGauge(cycle, gaugeDartUs) + _afterGauge(cycle, gaugeDartUs)")]:
            with self.assertRaises(ValueError):
                verify_probe(changed)

    def test_unbounded_cut_or_extra_stop_is_rejected(self):
        for changed in [self.probe.replace("_attemptedCuts >= 2", "_attemptedCuts >= 3"),
                        self.probe.replace("final result = _stop();", "final result = _stop();\nfinal result = _stop();")]:
            with self.assertRaises(ValueError):
                verify_probe(changed)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=ROOT)
    parser.add_argument("--baseline", type=Path)
    parser.add_argument("--contracts", type=Path)
    args, remaining = parser.parse_known_args()
    ROOT = args.root.resolve()
    BASELINE = args.baseline.resolve() if args.baseline else ROOT
    CONTRACTS = args.contracts.resolve() if args.contracts else ROOT / "tool/perf/gperftools_application_contracts"
    unittest.main(argv=[__file__, *remaining])
