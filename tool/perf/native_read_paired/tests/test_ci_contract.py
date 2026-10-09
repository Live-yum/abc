import copy
import hashlib
import json
from pathlib import Path
import sys
import tempfile
import unittest

HERE = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(HERE))
import finalize
import paired
import verify_sources


class Provenance(unittest.TestCase):
    def test_rebuilt_shared_library_requires_exact_fixed_source_and_flags(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            sources = {}
            for name in paired.SOURCES:
                path = root / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(name)
                sources[name] = paired.digest(path)
            artifact = {"sha256": "this-ci-library", "bytes": 123}
            provenance = {
                "source": {"commit": paired.BASE_COMMIT, "dirty": False},
                "artifacts": {"libabc_engine.so": artifact},
                "sourceFilesSha256": sources,
                "cmake": {"ABC_PERF_COUNTERS": "OFF", "CMAKE_BUILD_TYPE": "Profile",
                          "CMAKE_GENERATOR": "Ninja", "CMAKE_C_COMPILER": "/usr/bin/clang"},
                "effectiveCompileFlags": {name: "-O3 -DNDEBUG -fPIC" for name in
                    ("abc_world_circuit.c.o", "terra_circuit_vm.c.o", "terra_circuit_world.c.o")},
            }
            paired.validate_native_provenance(provenance, artifact, root)
            for field, value in [("ABC_PERF_COUNTERS", "ON"), ("CMAKE_BUILD_TYPE", "Debug")]:
                changed = copy.deepcopy(provenance)
                changed["cmake"][field] = value
                with self.assertRaisesRegex(ValueError, "Profile with counters OFF"):
                    paired.validate_native_provenance(changed, artifact, root)
            changed = copy.deepcopy(provenance)
            changed["effectiveCompileFlags"]["terra_circuit_vm.c.o"] = "-O0"
            with self.assertRaisesRegex(ValueError, "optimized native flags"):
                paired.validate_native_provenance(changed, artifact, root)
            changed = copy.deepcopy(provenance)
            changed["artifacts"]["libabc_engine.so"]["sha256"] = "other-library"
            with self.assertRaisesRegex(ValueError, "artifact identity mismatch"):
                paired.validate_native_provenance(changed, artifact, root)

    def test_committed_candidate_is_exact_reviewed_binding(self):
        self.assertEqual(paired.CANDIDATE_SHA, paired.digest(HERE / "candidate_binding.dart.txt"))

    def test_manifest_catches_same_size_source_change(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            manifest = root / "tool/perf/native_read_paired/source-manifest.json"
            manifest.parent.mkdir(parents=True)
            source = root / "runner.py"
            source.write_bytes(b"before")
            manifest.write_text(json.dumps({"files": [{"path": "runner.py", "bytes": 6,
                "sha256": hashlib.sha256(b"before").hexdigest()}]}))
            self.assertEqual(1, verify_sources.verify(root))
            source.write_bytes(b"after!")
            with self.assertRaisesRegex(ValueError, "pin mismatch"):
                verify_sources.verify(root)


class ArtifactPolicy(unittest.TestCase):
    def test_interrupted_eight_cycle_report_remains_incomplete_and_no_inputs_uploaded(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            raw = root / "state/raw/01-B"
            raw.mkdir(parents=True)
            (raw / "report.json").write_text(json.dumps({"status": "running", "cycles": list(range(8))}))
            (raw / "stdout.jsonl").write_text('{"phase":"cancelled"}\n')
            (root / "state/session.json").write_text('{"status":"running","processes":[]}')
            (root / "state/manifest.json").write_text('{"order":["B","A","A","B","B","A"],"cycles":8}')
            (root / "inputs").mkdir()
            (root / "inputs/computerraria.wld").write_bytes(b"not uploadable")
            (root / "state/A").mkdir()
            (root / "state/A/benchmark").write_bytes(b"not uploadable")
            (root / "logs").mkdir()
            (root / "logs/private.bin").write_bytes(b"not uploadable")
            result = finalize.collect(root, {"MEASUREMENT_OUTCOME": "cancelled"})
            self.assertEqual("failed-incomplete", result["status"])
            self.assertTrue((root / "evidence/raw/01-B/report.json").exists())
            self.assertFalse(any(p.name in {"computerraria.wld", "benchmark", "private.bin"}
                                 for p in (root / "evidence").rglob("*")))
            self.assertFalse((raw / "execution.json").exists())

    def test_workflow_is_isolated_read_only_and_always_collects(self):
        root = HERE.parents[2]
        workflow = (root / ".github/workflows/native-read-paired-diagnostic.yml").read_text()
        self.assertIn("contents: read", workflow)
        self.assertNotIn("contents: write", workflow)
        self.assertNotIn("pull_request:", workflow)
        self.assertIn("branches: [codex/native-read-paired-diagnostic-1dac]", workflow)
        self.assertIn("ref: " + paired.BASE_COMMIT, workflow)
        self.assertEqual(1, workflow.count("paired.py build --output"))
        self.assertEqual(1, workflow.count("cmake --build"))
        self.assertIn("--order BAABBA", workflow)
        self.assertIn("--timeout-seconds 600", workflow)
        self.assertGreaterEqual(workflow.count("if: always()"), 3)
        self.assertNotIn("base64", workflow)
        self.assertNotIn("cancel-in-progress: true", workflow)


if __name__ == "__main__":
    unittest.main()
