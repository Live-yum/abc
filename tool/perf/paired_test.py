"""Fast false-pass, preservation, routing and immutable-pin contract checks."""
import copy
import json
from pathlib import Path
import subprocess
import tempfile
import signal
import sys
import textwrap
from types import SimpleNamespace
import unittest
from unittest import mock

from paired_contract import COMMON_HARNESS, OUT_OF_SCOPE, PINS, SUITES, diagnostic_changed, schedule
import paired_runner
from paired_validate import validate_session, verify_report_artifact, verify_protocol, validate


def session_fixture(suite="native"):
    snapshots = {}
    for role in PINS:
        snapshots[role] = {"source": {**PINS[role], "dirty": False},
                           "harness": dict(COMMON_HARNESS),
                           "machine": {"bootId": "same-boot", "cpuModel": "same-cpu"},
                           "toolchain": {"compiler": "same-compiler"},
                           "artifacts": {"build/native-perf/libabc_engine.so":
                                         {"sha256": ("a" if role == "baseline" else "b") * 64}},
                           "fixtures": {"public": {"sha256": "f" * 64}}}
    return {"schema": "abc.paired-performance.v1", "suite": suite, "pins": copy.deepcopy(PINS),
            "harnessCommit": PINS["candidate"]["commit"], "status": "completed",
            "workflowSource": {"commit": "c" * 40, "tree": "d" * 40, "dirty": False},
            "machine": snapshots["baseline"]["machine"], "sequence": schedule(),
            "preparation": {role: {"status": "passed", "snapshot": value}
                            for role, value in snapshots.items()},
            "attempts": [{**item, "status": "passed", "exitCode": 0,
                          "output": f"raw/{item['role']}/{item['slot']}",
                          "before": copy.deepcopy(snapshots[item["role"]]),
                          "after": copy.deepcopy(snapshots[item["role"]])}
                         for item in schedule()]}


class PairedContractTests(unittest.TestCase):
    def test_only_four_suites_and_three_balanced_pairs(self):
        self.assertEqual(set(SUITES), {"native", "wasm", "map-generation", "map-dart2js"})
        self.assertEqual([row["role"] for row in schedule()],
                         ["baseline", "candidate", "candidate", "baseline", "baseline", "candidate"])
        self.assertEqual(len({row["slot"] for row in schedule()}), 6)
        for pair in (1, 2, 3):
            self.assertEqual({row["role"] for row in schedule() if row["pair"] == pair}, set(PINS))

    def test_unrelated_later_push_does_not_retrigger(self):
        self.assertFalse(diagnostic_changed(["lib/application/workspace.dart", "README.md"]))
        self.assertFalse(diagnostic_changed(["tool/perf/compare.py", "tool/perf/paired_hidden/file.py"]))
        self.assertTrue(diagnostic_changed(["tool/perf/paired_runner.py"]))
        self.assertTrue(diagnostic_changed([".github/workflows/performance-paired.yml"]))

    def test_actual_workflow_gate_uses_push_before_instead_of_pr_base(self):
        text = (Path(__file__).resolve().parents[2] / ".github/workflows/performance-paired.yml").read_text()
        code = textwrap.dedent(text.split("python3 - <<'PY'\n", 1)[1].split("          PY", 1)[0])
        for changed, expected in [("tool/perf/paired_runner.py\n", "true"),
                                  ("test/ordinary_test.dart\n", "false")]:
            with tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                event = root / "event.json"
                event.write_text(json.dumps({"action": "synchronize", "before": "a" * 40,
                                             "pull_request": {"base": {"sha": "b" * 40}}}))
                output = root / "output"
                with mock.patch.dict("os.environ", {"GITHUB_EVENT_PATH": str(event),
                                                     "GITHUB_OUTPUT": str(output),
                                                     "GITHUB_EVENT_NAME": "pull_request"}), \
                        mock.patch.object(sys, "path", list(sys.path)), \
                        mock.patch("subprocess.run") as fetch, \
                        mock.patch("subprocess.check_output", return_value=changed) as diff:
                    exec(compile(code, "workflow-scope", "exec"), {})
                self.assertEqual(output.read_text(), "run=" + expected + "\n")
                self.assertEqual(fetch.call_args.args[0][-1], "a" * 40)
                self.assertEqual(diff.call_args.args[0], ["git", "diff", "--name-only", "a" * 40, "HEAD"])

    def test_original_cycles_timeouts_and_actual_entrypoints(self):
        self.assertEqual(SUITES, {"native": 1500, "wasm": 1500, "map-generation": 600, "map-dart2js": 900})
        for suite in ("map-generation", "map-dart2js"):
            self.assertIn("26", paired_runner.workload(suite)[1])
        self.assertIn("--expose-gc", paired_runner.workload("wasm")[1])
        self.assertIn("--concurrency=1", paired_runner.workload("native")[1])

    def test_environment_is_fixed_and_public_only(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / ".flutter-version").write_text("3.47.6\n")
            with mock.patch.dict("os.environ", {"ABC_PERF_WORLD": "private", "ABC_PRIVATE_PACK": "private"}):
                env = paired_runner.environment(root, "baseline")
            self.assertNotIn("ABC_PERF_WORLD", env)
            self.assertNotIn("ABC_PRIVATE_PACK", env)
            self.assertEqual(env["ABC_PERF_COMMIT"], PINS["baseline"]["commit"])
            self.assertEqual((env["ABC_PERF_CYCLES"], env["ABC_PERF_WARMUP"]), ("25", "5"))
            self.assertIn(str(root), env["TERRAFORGE_ENGINE_LIBRARY"])

    def test_clean_but_wrong_source_pin_is_rejected(self):
        with mock.patch.object(paired_runner, "command", side_effect=["f" * 40, PINS["baseline"]["tree"], ""]):
            with self.assertRaisesRegex(AssertionError, "Wrong product"):
                paired_runner.source(Path("unused"), PINS["baseline"])

    def test_different_product_binaries_are_allowed_but_drift_is_not(self):
        session = session_fixture()
        validate_session(session, "native")
        session["attempts"][2]["after"]["artifacts"] = {"unexpected": {"sha256": "e" * 64}}
        with self.assertRaisesRegex(AssertionError, "drift"):
            validate_session(session, "native")

    def test_missing_failed_duplicate_and_out_of_order_attempts_fail(self):
        for mutation in (
                lambda value: value["attempts"].pop(),
                lambda value: value["attempts"][0].update(status="failed", exitCode=1),
                lambda value: value["attempts"].__setitem__(1, copy.deepcopy(value["attempts"][0])),
                lambda value: value["attempts"].reverse()):
            value = session_fixture()
            mutation(value)
            with self.assertRaises(AssertionError):
                validate_session(value, "native")

    def test_changed_fixtures_toolchain_or_runner_fail(self):
        for key in ("fixtures", "toolchain", "machine"):
            value = session_fixture()
            value["preparation"]["candidate"]["snapshot"][key] = {"changed": True}
            with self.assertRaises(AssertionError):
                validate_session(value, "native")

    def test_actual_library_and_compiled_js_hashes_must_match(self):
        snapshot = session_fixture()["preparation"]["candidate"]["snapshot"]
        verify_report_artifact({"toolchain": {"nativeLibrarySha256": "b" * 64}}, snapshot, "native")
        with self.assertRaises(AssertionError):
            verify_report_artifact({"toolchain": {"nativeLibrarySha256": "a" * 64}}, snapshot, "native")
        snapshot = {"artifacts": {"build/perf/map-actions.js": {"sha256": "a" * 64}}}
        with self.assertRaises(AssertionError):
            verify_report_artifact({"toolchain": {"artifacts": [
                {"id": "compiled-map-benchmark", "sha256": "b" * 64}]}}, snapshot, "map-dart2js")

    def test_matching_but_shortened_protocol_is_rejected(self):
        report = {"suite": "native-actions", "buildMode": "flutter-test-debug-with-release-native-library",
                  "tier": "ci", "methodology": {"warmupCycles": 5, "measuredCycles": 25},
                  "operations": [{"phase": "cold"}, {"phase": "warm"}]}
        verify_protocol(report, "native")
        report["methodology"]["measuredCycles"] = 3
        with self.assertRaisesRegex(AssertionError, "Measured-cycle"):
            verify_protocol(report, "native")
        report["methodology"]["measuredCycles"] = 25
        report["operations"].pop(0)
        with self.assertRaisesRegex(AssertionError, "Cold/warm"):
            verify_protocol(report, "native")

    def test_failed_first_process_does_not_hide_or_retry_other_attempts(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            value = session_fixture()
            value.update(status="prepared", attempts=[])
            paired_runner.save(root / "paired-session.json", value)
            args = SimpleNamespace(output=root, suite="native", baseline=Path("base"), candidate=Path("cand"))
            def observed(path, role, suite):
                return copy.deepcopy(value["preparation"][role]["snapshot"])
            with mock.patch.object(paired_runner, "snapshot", side_effect=observed), \
                    mock.patch.object(paired_runner, "environment", return_value={}), \
                    mock.patch.object(paired_runner.subprocess, "run", side_effect=[
                        subprocess.CompletedProcess([], code) for code in [1, 0, 0, 0, 0, 0]]) as run:
                self.assertEqual(paired_runner.run(args), 1)
            self.assertEqual(run.call_count, 6)
            recorded = json.loads((root / "paired-session.json").read_text())
            self.assertEqual(recorded["status"], "failed")
            self.assertEqual(len(recorded["attempts"]), 6)
            self.assertEqual(len(list(root.glob("driver-*.log"))), 6)
            with self.assertRaisesRegex(AssertionError, "Never retry"):
                paired_runner.run(args)

    def test_timed_out_build_group_is_reaped_before_next_build(self):
        process = mock.Mock(pid=1234)
        process.wait.side_effect = [subprocess.TimeoutExpired(["compiler"], 1800),
                                    subprocess.TimeoutExpired(["compiler"], 15), 0]
        with mock.patch.object(paired_runner.subprocess, "Popen", return_value=process), \
                mock.patch.object(paired_runner.os, "killpg") as kill:
            with self.assertRaises(subprocess.TimeoutExpired):
                paired_runner.prepare_command(["compiler"], Path("unused"), {}, mock.Mock())
        self.assertEqual(kill.call_args_list, [mock.call(1234, signal.SIGTERM), mock.call(1234, signal.SIGKILL)])
        self.assertEqual(process.wait.call_count, 3)

    def test_missing_reports_create_explicit_invalid_limited_summary(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.assertEqual(validate(root, root / "candidate", "map-generation"), 1)
            summary = json.loads((root / "paired-summary.json").read_text())
            self.assertEqual(summary["diagnosticStatus"], "invalid")
            self.assertEqual(summary["overallAcceptance"], "unestablished")
            self.assertEqual(set(summary["otherSuites"]), set(OUT_OF_SCOPE))
            self.assertIn("uncompared", summary["newWorkloads"])

    def test_workflow_is_read_only_and_pins_both_products(self):
        text = (Path(__file__).resolve().parents[2] / ".github/workflows/performance-paired.yml").read_text()
        self.assertIn("contents: read", text)
        self.assertNotIn("contents: write", text)
        self.assertNotIn("actions: write", text)
        self.assertIn("cancel-in-progress: false", text)
        self.assertIn("diagnostic_changed(changed)", text)
        for pin in PINS.values():
            self.assertIn("ref: " + pin["commit"], text)
        self.assertEqual(text.count("persist-credentials: false"), 4)
        self.assertIn("if: always()", text)


if __name__ == "__main__":
    unittest.main()
