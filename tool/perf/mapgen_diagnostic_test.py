"""Lightweight contracts only: no native compilation or benchmark invocation."""
import copy
import ctypes as C
import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import textwrap
import time
from types import SimpleNamespace
import unittest
from unittest.mock import patch

import mapgen_diagnostic_contract as contract
import mapgen_diagnostic_probe as probe
import mapgen_diagnostic_runner as runner
import mapgen_diagnostic_validate as validator


def session():
    machine = {"bootId": "one-boot"}
    value = {"schema": "abc.mapgen-factorial.v1", "status": "completed", "pins": contract.PINS,
             "harness": contract.HARNESS, "groups": list(contract.GROUPS), "sequence": contract.schedule(),
             "overallAcceptance": "unestablished", "machine": machine, "variants": {}, "attempts": []}
    for number, (name, (base, paths)) in enumerate(contract.VARIANTS.items()):
        source = {"commit": contract.PINS[base]["commit"] if not paths else str(number) * 40,
                  "tree": contract.TREES[name], "dirty": False}
        identity = {"base": contract.PINS[base], "changedPaths": list(paths), "source": source,
                    "kind": "derived-local-commit" if paths else "original-pin"}
        snapshot = {"source": source, "machine": machine, "fixture": contract.FIXTURE,
                    "library": {"bytes": 123, "sha256": "a" * 64}}
        value["variants"][name] = {"identity": identity, "snapshot": snapshot, "status": "passed"}
    for group in contract.GROUPS:
        for entry in contract.schedule():
            snapshot = value["variants"][entry["variant"]]["snapshot"]
            value["attempts"].append({**entry, "group": group, "status": "passed", "exitCode": 0,
                "before": copy.deepcopy(snapshot), "after": copy.deepcopy(snapshot),
                "output": f"raw/{group}/{entry['slot']}"})
    return value


def auxiliary():
    snapshot = session()["variants"]["A"]["snapshot"]
    value = {"schema": "abc.mapgen-auxiliary.v1", "status": "passed", "acceptanceEligible": False,
             "sourcePreserved": True, "fixture": contract.FIXTURE, "library": snapshot["library"],
             "iterations": 26, "records": []}
    for cycle in range(26):
        for kind in ("lit", "marked"):
            response = {"status": "ok", "width": 512, "height": 256, "map_bytes": 20, "file_written": False}
            if kind == "marked":
                response.update(contract.EXPECTED_MATCHES)
            value["records"].append(probe.observation(cycle, kind, b"x" * 20,
                json.dumps(response).encode() + b"\0", 512, 256, 3_000_000, 2_000_000,
                {"minorFaults": 1}, {"minorFaults": 2}))
    return value, snapshot


class Contracts(unittest.TestCase):
    def test_predeclared_sequence_has_three_independent_slots_per_variant(self):
        self.assertEqual(contract.ORDER, ("A", "A_SHA", "A_QUERY", "B", "B", "A_QUERY", "A_SHA", "A", "A_SHA", "A", "B", "A_QUERY"))
        self.assertTrue(all(contract.ORDER.count(name) == 3 for name in contract.VARIANTS))
        self.assertEqual(len({row["slot"] for row in contract.schedule()}), 12)

    def test_complete_two_groups_pass(self):
        validator.validate_session(session())

    def test_missing_failed_reordered_or_pooled_attempt_rejected(self):
        for modification in (lambda s: s["attempts"].pop(),
                             lambda s: s["attempts"][0].update(status="failed"),
                             lambda s: s["attempts"].reverse(),
                             lambda s: s["attempts"][12].update(group="frozen")):
            value = session()
            modification(value)
            with self.assertRaises(AssertionError):
                validator.validate_session(value)

    def test_derived_pin_masquerade_and_wrong_tree_rejected(self):
        for changes in ({"commit": contract.PINS["A"]["commit"]}, {"tree": "f" * 40}, {"dirty": True}):
            value = session()
            value["variants"]["A_SHA"]["identity"]["source"].update(changes)
            with self.assertRaises(AssertionError):
                validator.validate_session(value)

    def test_binary_drift_rejected(self):
        value = session()
        value["attempts"][0]["after"]["library"]["sha256"] = "b" * 64
        with self.assertRaises(AssertionError):
            validator.validate_session(value)

    def test_auxiliary_schema_counts_and_all_cycles(self):
        report, snapshot = auxiliary()
        validator.validate_auxiliary(report, snapshot)
        self.assertEqual(report["records"][1]["matches"], contract.EXPECTED_MATCHES)
        self.assertEqual(report["records"][0]["response"]["bytes"], len(json.dumps(report["records"][0]["response"]["json"]).encode()) + 1)

    def test_missing_cycle_wrong_count_and_wrong_schema_rejected(self):
        for modification in (lambda r: r["records"].pop(),
                             lambda r: r["records"][1]["matches"].update(matched_tile_count=65535),
                             lambda r: r.update(schema="abc.performance.v1"),
                             lambda r: r.update(acceptanceEligible=True)):
            report, snapshot = auxiliary()
            modification(report)
            with self.assertRaises(AssertionError):
                validator.validate_auxiliary(report, snapshot)

    def test_no_slow_sample_removed(self):
        report, snapshot = auxiliary()
        report["records"][13]["wallMs"] = 6000
        validator.validate_auxiliary(report, snapshot)
        self.assertEqual(len(report["records"]), 52)
        self.assertEqual(report["records"][13]["wallMs"], 6000)

    def test_probe_keeps_existing_operation_response_without_reexecution(self):
        instance = object.__new__(probe.Native)
        data = (33083).to_bytes(4, "little") + b"relogic\x01" + b"abc"
        response = b'{"status":"ok"}\0'
        calls = []
        def operation(handle, name, request, out, capacity, required):
            calls.append((name, request, capacity))
            required._obj.value = len(response)
            if out is not None:
                C.memmove(out, response, len(response))
            return 0
        def map_output(handle, out, capacity, size, width, height):
            size._obj.value, width._obj.value, height._obj.value = len(data), 512, 256
            if out is not None:
                C.memmove(out, data, len(data))
            return 0
        instance.lib = SimpleNamespace(abc_world_operation=operation, abc_world_map=map_output)
        result = instance.generate(1, b"render_lit_map", b"{}")
        self.assertEqual(result, (data, response, 512, 256))
        self.assertEqual(len(calls), 2)  # probe and cached copy, never a third call

    def test_resource_and_response_observers_run_after_timer(self):
        text = Path(probe.__file__).read_text()
        measured = text.split("start = time.perf_counter_ns()", 1)[1].split("elapsed = time.perf_counter_ns() - start", 1)[0]
        self.assertIn("native.generate", measured)
        self.assertNotIn("observation(", measured)
        self.assertNotIn("usage()", measured)
        self.assertNotIn("hashlib", measured)

    def test_private_fixture_environment_cleared_and_real_commit_used(self):
        with patch.dict(runner.os.environ, {"ABC_PRIVATE_PACK": "secret", "ABC_PERF_WORLD": "save"}):
            env = runner.environment("1" * 40)
        self.assertNotIn("ABC_PRIVATE_PACK", env)
        self.assertNotIn("ABC_PERF_WORLD", env)
        self.assertEqual(env["ABC_PERF_COMMIT"], "1" * 40)

    def test_timeout_reaps_group_and_preserves_failed_command(self):
        process = unittest.mock.Mock(pid=1234, returncode=-9)
        process.wait.side_effect = [subprocess.TimeoutExpired("fake", 1), subprocess.TimeoutExpired("fake", 15), -9]
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "failure.log"
            with patch.object(runner.subprocess, "Popen", return_value=process), patch.object(runner.os, "killpg") as kill:
                result = runner.execute(["fake"], Path(directory), {}, path, 1)
            self.assertEqual(result["status"], "timeout")
            self.assertEqual(kill.call_args_list, [unittest.mock.call(1234, signal.SIGTERM), unittest.mock.call(1234, signal.SIGKILL)])
            self.assertEqual(json.loads(path.with_suffix(".command.json").read_text())["status"], "timeout")
            with self.assertRaises(AssertionError):
                runner.execute(["fake"], Path(directory), {}, path, 1)

    def test_archiving_copies_binary_objects_commands_and_map(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            build = root / "build/native-perf"
            build.mkdir(parents=True)
            for name in ("libabc_engine.so", "terra_map.c.o", "flags.make", "link.txt", "compile_commands.json", "abc_engine.map", "irrelevant.txt"):
                (build / name).write_text(name)
            archived = runner.archive_build(root, root / "archive")
            self.assertEqual(len(archived), 6)
            self.assertNotIn("irrelevant.txt", archived)
            self.assertEqual(archived["libabc_engine.so"]["sha256"], hashlib.sha256(b"libabc_engine.so").hexdigest())

    def test_actual_git_derived_identity_is_clean_and_not_the_base(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            a, b = root / "A", root / "B"
            a.mkdir()
            runner.command(["git", "init", "-q"], a)
            paths = contract.VARIANTS["A_SHA"][1] + contract.VARIANTS["A_QUERY"][1]
            for name in paths:
                target = a / name
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_text("base\n")
            runner.command(["git", "add", "."], a)
            runner.command(["git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-qm", "fixture"], a)
            runner.command(["git", "clone", "-q", str(a), str(b)])
            for name in paths:
                (b / name).write_text("candidate\n")
            runner.command(["git", "add", "."], b)
            runner.command(["git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-qm", "fixture"], b)
            pins = {name: {"commit": runner.command(["git", "rev-parse", "HEAD"], path),
                           "tree": runner.command(["git", "rev-parse", "HEAD^{tree}"], path)}
                    for name, path in (("A", a), ("B", b))}
            env = dict(os.environ, GIT_INDEX_FILE=str(root / "expected.index"))
            runner.command(["git", "read-tree", "HEAD"], a, env)
            for name in contract.VARIANTS["A_SHA"][1]:
                blob = runner.command(["git", "hash-object", "-w", str(b / name)], a)
                runner.command(["git", "update-index", "--cacheinfo", f"100644,{blob},{name}"], a, env)
            tree = runner.command(["git", "write-tree"], a, env)
            evidence = root / "evidence"
            evidence.mkdir()
            with patch.dict(runner.PINS, pins, clear=True), patch.dict(runner.HARNESS, {}, clear=True), patch.dict(runner.TREES, {"A_SHA": tree}, clear=True):
                result = runner.derive(root / "derived", a, b, "A_SHA", evidence)
            self.assertNotEqual(result["source"]["commit"], pins["A"]["commit"])
            self.assertEqual(result["source"]["tree"], tree)
            self.assertFalse(result["source"]["dirty"])
            self.assertEqual((root / "derived" / contract.VARIANTS["A_QUERY"][1][0]).read_text(), "base\n")
            self.assertIn("native/abc_engine.c", (evidence / "variant.patch").read_text())

    def test_exhausted_budget_records_all_unstarted_slots_without_processes(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            state = session()
            state.update(status="prepared", attempts=[], toolchain={}, diagnosticHarness={}, deadlineEpochSeconds=time.time() - 1)
            runner.save(root / "session.json", state)
            args = SimpleNamespace(output=root, work=root / "work", workflow_root=root)
            with patch.object(runner, "machine", return_value=state["machine"]), patch.object(runner, "toolchain", return_value={}), patch.object(runner, "execute") as execute:
                self.assertEqual(runner.run(args), 1)
                execute.assert_not_called()
            result = json.loads((root / "session.json").read_text())
            self.assertEqual(len(result["attempts"]), 24)
            self.assertTrue(all(row["status"] == "unstarted" for row in result["attempts"]))

    def test_unfinished_driver_blocks_later_heavy_work_without_outer_timeout(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            state = session()
            state.update(status="prepared", attempts=[], toolchain={}, diagnosticHarness={}, deadlineEpochSeconds=time.time() + 10000)
            runner.save(root / "session.json", state)
            args = SimpleNamespace(output=root, work=root / "work", workflow_root=root)
            snapshot = state["variants"]["A"]["snapshot"]
            with patch.object(runner, "machine", return_value=state["machine"]), patch.object(runner, "toolchain", return_value={}), patch.object(runner, "snapshot", return_value=snapshot), patch.object(runner, "execute", return_value={"status": "failed", "exitCode": 1}) as execute:
                self.assertEqual(runner.run(args), 1)
                execute.assert_called_once()
                self.assertIsNone(execute.call_args.args[-1])
            result = json.loads((root / "session.json").read_text())
            self.assertEqual(result["attempts"][0]["status"], "failed")
            self.assertTrue(all(row["status"] == "unstarted" for row in result["attempts"][1:]))

    def test_workflow_is_scoped_read_only_and_retains_running_evidence(self):
        workflow = Path(__file__).resolve().parents[2] / ".github/workflows/performance-mapgen-diagnostic.yml"
        text = workflow.read_text()
        self.assertIn("workflow_dispatch:", text)
        self.assertIn("pull_request:", text)
        self.assertIn("needs.scope.outputs.run == 'true'", text)
        self.assertIn("contents: read", text)
        self.assertNotIn("contents: write", text)
        self.assertIn("cancel-in-progress: false", text)
        self.assertEqual(text.count("persist-credentials: false"), 4)
        self.assertIn("timeout-minutes: 60", text)
        self.assertNotIn("continue-on-error", text)
        self.assertNotIn("strategy:", text)
        self.assertIn("if: always()", text)

    def test_only_own_source_or_workflow_retriggers(self):
        for path in ("tool/perf/mapgen_diagnostic_probe.py", ".github/workflows/performance-mapgen-diagnostic.yml"):
            self.assertTrue(contract.diagnostic_changed([path]))
        self.assertFalse(contract.diagnostic_changed(["test/widget_test.dart", "tool/perf/paired_runner.py", "tool/perf/mapgen_diagnostic_README.md"]))

    def test_real_scope_code_uses_push_before_and_skips_unrelated_changes(self):
        workflow = Path(__file__).resolve().parents[2] / ".github/workflows/performance-mapgen-diagnostic.yml"
        code = textwrap.dedent(workflow.read_text().split("python3 - <<'PY'\n", 1)[1].split("\n          PY", 1)[0])
        for action, changed, expected in (("opened", "tool/perf/mapgen_diagnostic_probe.py\n", "true"),
                                          ("synchronize", "test/widget_test.dart\n", "false"),
                                          ("synchronize", "tool/perf/mapgen_diagnostic_probe.py\n", "true")):
            with tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                event = root / "event.json"
                event.write_text(json.dumps({"action": action, "before": "a" * 40,
                                             "pull_request": {"base": {"sha": "b" * 40}}}))
                output = root / "output"
                env = {"GITHUB_EVENT_PATH": str(event), "GITHUB_EVENT_NAME": "pull_request", "GITHUB_OUTPUT": str(output)}
                with patch.dict(os.environ, env), patch.object(subprocess, "run"), patch.object(subprocess, "check_output", return_value=changed) as diff:
                    exec(compile(code, "workflow-scope", "exec"), {})
                self.assertEqual(output.read_text(), f"run={expected}\n")
                self.assertEqual(diff.call_args.args[0][-2], ("a" if action == "synchronize" else "b") * 40)


if __name__ == "__main__":
    unittest.main()
