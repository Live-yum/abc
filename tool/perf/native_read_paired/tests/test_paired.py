import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from types import SimpleNamespace
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import paired


def valid_report(variant="A"):
    stats = [0] * 24
    for index, value in zip((0, 2, 3, 10, 12), (2, 15200, 7200, 72939714, 13641575)):
        stats[index] = value
    return {
        "status": "passed", "variant": variant, "quietMilliseconds": 1200,
        "nativeCounterAvailable": True, "nativeLiveBytesAfterClose": 0,
        "originalStatUnchanged": True,
        "cycles": [{
            "cycle": cycle, "sourceSha256": paired.WORLD_SHA, "openStats": stats[:],
            "openFlags": 0, "closedNativeLiveBytes": 0, "closedHandleRejected": True,
            "timings": {"openMicroseconds": cycle * 1000000,
                        "actualQuietMicroseconds": 1200000},
            "correctness": {
                "pongSha256": paired.PONG_SHA,
                "cpu": {"signature": [0] * 47 + [0x600dc0de]},
                "pongFrames": [{"clocks": n * 128, "ramSha256": str(n),
                                "displaySha256": str(n)} for n in range(1, 13)],
            },
        } for cycle in range(1, 9)],
        "cancellation": {"error": "World circuit operation cancelled",
                         "reopenedSourceSha256": paired.WORLD_SHA,
                         "reopenedStats": stats[:]},
    }


class PinsAndReports(unittest.TestCase):
    def test_pin_detects_same_size_mutation(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "input"
            path.write_bytes(b"original")
            pin = paired.pin(path)
            paired.verify_pin(pin)
            path.write_bytes(b"modified")
            with self.assertRaisesRegex(ValueError, "Pinned file changed"):
                paired.verify_pin(pin)

    def test_unpinned_import_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name in paired.SOURCES:
                path = root / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text("import 'dart:io';\n")
            paired.validate_imports(root)
            (root / paired.BINDING).write_text("import 'new_product_helper.dart';\n")
            with self.assertRaisesRegex(ValueError, "Unpinned product source"):
                paired.validate_imports(root)

    def test_complete_report_passes(self):
        self.assertEqual([], paired.validate_report(valid_report(), "A"))

    def test_missing_warm_cycle_fails(self):
        report = valid_report()
        report["cycles"].pop(4)
        self.assertIn("must retain all eight ordered cycles", paired.validate_report(report, "A"))

    def test_quiet_and_native_leak_fail_separately(self):
        report = valid_report()
        report["cycles"][2]["timings"]["actualQuietMicroseconds"] = 1199999
        report["cycles"][7]["closedNativeLiveBytes"] = 16
        errors = paired.validate_report(report, "A")
        self.assertIn("quiet interval was shortened", errors)
        self.assertIn("native allocations remain after cycle", errors)

    def test_halted_cpu_or_static_display_cannot_pass(self):
        report = valid_report()
        for frame in report["cycles"][0]["correctness"]["pongFrames"]:
            frame["ramSha256"] = "constant"
            frame["displaySha256"] = "constant"
        errors = paired.validate_report(report, "A")
        self.assertIn("Pong physical RAM does not change", errors)
        self.assertIn("Pong physical display does not change", errors)

    def test_cancellation_is_required_and_graph_checked(self):
        report = valid_report()
        report["cancellation"]["reopenedStats"][10] -= 1
        self.assertIn("cancellation recovery graph differs", paired.validate_report(report, "A"))

    def test_wrong_identity_or_variant_fails(self):
        report = valid_report()
        report["cycles"][0]["sourceSha256"] = "0" * 64
        errors = paired.validate_report(report, "B")
        self.assertIn("source hash mismatch", errors)
        self.assertIn("worker protocol/variant mismatch", errors)

    def test_unavailable_counters_must_be_null_not_zero(self):
        report = valid_report()
        report["nativeCounterAvailable"] = False
        report["nativeLiveBytesAfterClose"] = None
        for cycle in report["cycles"]:
            cycle["closedNativeLiveBytes"] = None
        self.assertEqual([], paired.validate_report(report, "A"))
        report["cycles"][2]["closedNativeLiveBytes"] = 0
        self.assertIn("unavailable native counter must remain null", paired.validate_report(report, "A"))

    def test_summary_keeps_all_samples_and_reports_different_outcome(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            programs = root / "programs.json"
            paired.write_json(programs, {"main": {"checks": [
                {"expected": x} for x in valid_report()["cycles"][0]["correctness"]["cpu"]["signature"]]}})
            paired.write_json(root / "manifest.json", {
                "scope": "test", "nativeBuild": {}, "programs": {"path": str(programs)}})
            for slot, variant in enumerate(paired.ORDER, 1):
                run = root / "raw" / f"{slot:02d}-{variant}"
                report = valid_report(variant)
                if slot == 3:
                    report["cycles"][6]["correctness"]["cpu"]["signature"][0] = 1
                paired.write_json(run / "report.json", report)
                paired.write_json(run / "execution.json", {"status": "passed"})
                samples = [{"cycle": cycle, "phase": "closedQuiet", "kind": "boundary",
                            "memory": {metric: cycle for metric in paired.MEMORY_METRICS}}
                           for cycle in range(1, 9)]
                (run / "os-samples.jsonl").write_text("".join(json.dumps(s) + "\n" for s in samples))
            result = paired.summarize(root)
            self.assertEqual("failed", result["status"])
            self.assertEqual(6, len(result["processes"]))
            self.assertEqual(3, result["arms"]["B"]["processColdOpenMs"]["count"])
            self.assertTrue(any("physical/hash/graph outcomes differ" in e for e in result["errors"]))
            self.assertTrue(any("independent CPU expectations mismatch" in e for e in result["errors"]))
            self.assertEqual([None] * 8, result["processes"][0]["phaseObservedMs"]["hash"])

    def test_complete_orders_and_correct_pairing(self):
        self.assertEqual(list("ABBAAB"), paired.ORDER)
        self.assertEqual([(0, 1), (3, 2), (4, 5)], paired.paired_slots(list("ABBAAB")))
        self.assertEqual([(1, 0), (2, 3), (5, 4)], paired.paired_slots(list("BAABBA")))
        for invalid in [list("BAAB"), list("BAABBB"), list("AAABBB")]:
            with self.assertRaisesRegex(ValueError, "complete fixed"):
                paired.validate_order(invalid)

    def test_reverse_summary_uses_all_six_prespecified_pairs(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            programs = root / "programs.json"
            paired.write_json(programs, {"main": {"checks": [
                {"expected": x} for x in valid_report()["cycles"][0]["correctness"]["cpu"]["signature"]]}})
            paired.write_json(root / "manifest.json", {
                "scope": "test", "nativeBuild": {}, "programs": {"path": str(programs)}, "order": list("BAABBA")})
            for slot, variant in enumerate("BAABBA", 1):
                run = root / "raw" / f"{slot:02d}-{variant}"
                report = valid_report(variant)
                for cycle in report["cycles"]:
                    cycle["timings"]["openMicroseconds"] += slot * 1000
                paired.write_json(run / "report.json", report)
                paired.write_json(run / "execution.json", {"status": "passed"})
                samples = [{"cycle": c, "phase": "closedQuiet", "kind": "boundary",
                            "memory": {metric: c for metric in paired.MEMORY_METRICS}} for c in range(1, 9)]
                (run / "os-samples.jsonl").write_text("".join(json.dumps(s) + "\n" for s in samples))
            result = paired.summarize(root)
            self.assertEqual("passed", result["status"])
            self.assertEqual([(2, 1), (3, 4), (6, 5)], [
                (p["A_slot"], p["B_slot"]) for p in result["pairedComparisons"]])
            self.assertEqual([-1, 1, -1], [p["cold_B_minus_A_ms"] for p in result["pairedComparisons"]])
            self.assertEqual(6, len(result["processes"]))

    def test_incomplete_summary_does_not_invent_unlaunched_samples(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            programs = root / "programs.json"
            paired.write_json(programs, {"main": {"checks": [{"expected": 1}]}})
            paired.write_json(root / "manifest.json", {
                "scope": "test", "nativeBuild": {}, "programs": {"path": str(programs)}})
            run = root / "raw/01-A"
            paired.write_json(run / "execution.json", {"status": "failed", "exitCode": -9})
            paired.write_json(run / "report.json", {"status": "running", "cycles": []})
            result = paired.summarize(root)
            self.assertEqual("failed", result["status"])
            self.assertEqual("incomplete", result["completeness"])
            self.assertEqual(1, len(result["processes"]))
            self.assertEqual(5, len(result["notRunSlots"]))
            self.assertEqual([], result["pairedComparisons"])
            self.assertIsNone(result["arms"]["B"]["processColdOpenMs"])


class ReadOnlySamplerAndRunner(unittest.TestCase):
    def test_first_failure_stops_after_one_launch_and_hashes_source(self):
        for failure in ["failed", "timeout"]:
            with self.subTest(failure=failure), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                world = root / "world"
                world.write_bytes(b"original fixture remains unchanged")
                manifest = {
                    "world": paired.pin(world), "library": {"path": "/unused-library"},
                    "pong": {"path": "/unused-pong"}, "programs": {"path": "/unused-programs"},
                    "pubCache": str(root / "pub-cache"),
                }
                paired.write_json(root / "manifest.json", manifest)
                paired.write_json(root / "build.json", {
                    "status": "passed", "manifestSha256": paired.digest(root / "manifest.json"),
                    "executables": {"A": {"path": "/unused-A"}, "B": {"path": "/unused-B"}},
                    "packagePins": {},
                })
                def failed_worker(command, run, env, timeout):
                    run.mkdir()
                    (run / "report.json").write_text('{"status":"running","cycles":[]}')
                    (run / "stdout.jsonl").write_text("partial evidence\n")
                    return {"status": failure, "exitCode": -9, "shellEquivalentExitCode": 137}
                with patch.object(paired, "verify_manifest", return_value=manifest), \
                     patch.object(paired, "verify_pin"), \
                     patch.object(paired, "run_process", side_effect=failed_worker) as worker, \
                     patch.object(paired, "summarize", return_value={"status": "failed"}):
                    self.assertEqual(1, paired.run(SimpleNamespace(output=root, timeout_seconds=600)))
                    self.assertEqual(1, worker.call_count)
                session = paired.load_json(root / "session.json")
                self.assertEqual("failed", session["status"])
                self.assertEqual("incomplete", session["completeness"])
                self.assertEqual(1, len(session["processes"]))
                self.assertEqual(1, session["stoppedAfterSlot"])
                self.assertEqual("passed", session["sourceVerificationAfter"]["status"])
                self.assertEqual(manifest["world"]["sha256"], session["originalSourceSha256After"])
                self.assertEqual(["01-A"], sorted(path.name for path in (root / "raw").iterdir()))
                self.assertEqual("partial evidence\n", (root / "raw/01-A/stdout.jsonl").read_text())

    def test_proc_fields_keep_non_atomic_rss_and_hwm_separate(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            process = root / "123"
            (process / "fd").mkdir(parents=True)
            (process / "fd" / "0").touch()
            (process / "status").write_text("VmRSS:\t400 kB\nVmHWM:\t900 kB\nThreads:\t7\n")
            (process / "smaps_rollup").write_text(
                "Rss: 410 kB\nPss: 350 kB\nPrivate_Clean: 100 kB\nPrivate_Dirty: 200 kB\nPrivate_Hugetlb: 8 kB\n")
            sample = paired.proc_sample(123, root)
            self.assertEqual(400 * 1024, sample["statusRssBytes"])
            self.assertEqual(900 * 1024, sample["statusHwmBytes"])
            self.assertEqual(410 * 1024, sample["smapsRssBytes"])
            self.assertEqual(350 * 1024, sample["smapsPssBytes"])
            self.assertEqual(308 * 1024, sample["smapsUssBytes"])
            self.assertEqual((1, 7), (sample["fdCount"], sample["threadCount"]))

    def test_missing_smaps_is_not_zero_memory(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "123").mkdir()
            (root / "123/status").write_text("VmRSS: 1 kB\n")
            result = paired.proc_sample(123, root)
            self.assertNotIn("smapsUssBytes", result)
            self.assertIn("smapsError", result)
            self.assertIsNone(paired.proc_sample(124, root))

    def test_failed_worker_raw_and_exit_code_retained(self):
        with tempfile.TemporaryDirectory() as directory:
            run = Path(directory) / "run"
            code = "import sys; print('raw evidence', flush=True); sys.stderr.write('failure\\n'); sys.exit(17)"
            outcome = paired.run_process([sys.executable, "-c", code], run, dict(os.environ), 5, .01)
            self.assertEqual(("failed", 17), (outcome["status"], outcome["exitCode"]))
            self.assertEqual("raw evidence\n", (run / "stdout.jsonl").read_text())
            self.assertEqual("failure\n", (run / "stderr.log").read_text())
            with self.assertRaises(FileExistsError):
                paired.run_process([sys.executable, "-c", "pass"], run, dict(os.environ), 5)

    def test_timeout_is_retained_and_process_terminated(self):
        with tempfile.TemporaryDirectory() as directory:
            run = Path(directory) / "run"
            code = "import time; print('partial evidence', flush=True); time.sleep(30)"
            outcome = paired.run_process([sys.executable, "-c", code], run, dict(os.environ), .15, .01)
            self.assertEqual("timeout", outcome["status"])
            self.assertIn("partial evidence", (run / "stdout.jsonl").read_text())
            self.assertIsNotNone(outcome["exitCode"])

    def test_boundary_acknowledgment_precedes_worker_resume(self):
        with tempfile.TemporaryDirectory() as directory:
            run = Path(directory) / "run"
            code = (
                "import sys,json; print(json.dumps({'event':'boundary','phase':'closedQuiet','cycle':3}), flush=True); "
                "assert sys.stdin.readline() == 'ack\\n'; print('resumed-after-ack', flush=True)"
            )
            result = paired.run_process([sys.executable, "-c", code], run, dict(os.environ), 5, .01)
            self.assertEqual("passed", result["status"])
            samples = [json.loads(line) for line in (run / "os-samples.jsonl").read_text().splitlines()]
            boundaries = [s for s in samples if s["kind"] == "boundary"]
            self.assertEqual([(3, "closedQuiet")], [(s["cycle"], s["phase"]) for s in boundaries])
            self.assertIsNotNone(boundaries[0]["memory"])
            self.assertIn("resumed-after-ack", (run / "stdout.jsonl").read_text())

    def test_signal_exit_keeps_signal_and_shell_equivalent(self):
        with tempfile.TemporaryDirectory() as directory:
            run = Path(directory) / "run"
            code = "import os,signal; print('before kill', flush=True); os.kill(os.getpid(), signal.SIGKILL)"
            result = paired.run_process([sys.executable, "-c", code], run, dict(os.environ), 5, .01)
            self.assertEqual(-9, result["exitCode"])
            self.assertEqual(137, result["shellEquivalentExitCode"])
            self.assertIn("before kill", (run / "stdout.jsonl").read_text())


if __name__ == "__main__":
    unittest.main()
