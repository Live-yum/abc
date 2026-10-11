"""Offline evidence fixtures only; none execute a Flutter integration entry."""
import copy
import hashlib
import unittest

from prebuilt_contract import (ARMS, BASE, SDK_COMMIT, SDK_VERSION, TARGET,
    bind_runtime_entry, bind_source_target, clean_driver_environment,
    commands, verify_commands)


class PrebuiltContractTests(unittest.TestCase):
    def setUp(self):
        self.head = "1" * 40
        self.expected = commands("/opt/flutter/bin/flutter", "/tmp/owned/launcher", self.head, "llvmpipe")
        raw = b"synthetic offline source: abc.memory-ownership-hello.v1"
        self.source = bind_source_target(raw, hashlib.sha256(raw).hexdigest())
        self.binary = {"bytes": 1234, "sha256": "2" * 64}
        self.hello = {"schema": "abc.memory-ownership-hello.v1", "arm": ARMS[0],
                      "sourceCommit": self.head, "baseProductCommit": BASE,
                      "hostPid": 42, "startedUs": 100}

    def bind(self, hello=None, **overrides):
        args = dict(arm=ARMS[0], head=self.head, owned_pid=42,
                    loaded_executable=self.binary, built_executable=self.binary,
                    source_binding=self.source)
        args.update(overrides)
        return bind_runtime_entry(self.hello if hello is None else hello, **args)

    def test_explicit_build_and_prebuilt_drive_preserve_original_target(self):
        verify_commands(self.expected, self.expected, SDK_COMMIT, SDK_VERSION)
        for argv in self.expected.values():
            self.assertEqual(argv.count("--target=" + TARGET), 1)
            self.assertIn("--dart-define=ABC_MEMORY_OWNERSHIP=true", argv)
        self.assertIn("build", self.expected["build"])
        self.assertIn("--use-application-binary=/tmp/owned/launcher", self.expected["drive"])
        self.assertFalse(self.source["runtimeEntryExecuted"])

    def test_ignored_drive_target_does_not_excuse_wrong_explicit_build(self):
        bad = copy.deepcopy(self.expected)
        bad["build"][bad["build"].index("--target=" + TARGET)] = "--target=lib/main.dart"
        with self.assertRaises(ValueError):
            verify_commands(bad, self.expected, SDK_COMMIT, SDK_VERSION)

    def test_missing_build_or_changed_defines_sdk_or_launcher_fail(self):
        for key in ("build", "drive"):
            bad = copy.deepcopy(self.expected)
            bad[key].append("--dart-define=ABC_MEMORY_OWNERSHIP=false")
            with self.assertRaises(ValueError):
                verify_commands(bad, self.expected, SDK_COMMIT, SDK_VERSION)
        for commit, version in [("0"*40, SDK_VERSION), (SDK_COMMIT, "unknown")]:
            with self.assertRaises(ValueError):
                verify_commands(self.expected, self.expected, commit, version)
        with self.assertRaises(ValueError):
            verify_commands({"drive": self.expected["drive"]}, self.expected, SDK_COMMIT, SDK_VERSION)

    def test_loader_and_profiler_variables_only_removed_from_driver_copy(self):
        original = {"LD_PRELOAD": "/bad.so", "LD_AUDIT": "/bad-audit.so", "HEAPPROFILE": "/bad",
                    "HEAPPROFILESIGNAL": "12", "HEAP_PROFILE_TIME_INTERVAL": "1",
                    "DISPLAY": ":99", "MEMORY_OWNER_ARM": "probe-only", "FLUTTER_ENGINE_SWITCH_1": "x"}
        kept = clean_driver_environment(original)
        self.assertEqual(set(kept), {"DISPLAY", "MEMORY_OWNER_ARM", "FLUTTER_ENGINE_SWITCH_1"})
        self.assertIn("LD_PRELOAD", original)

    def test_hello_and_loaded_elf_bind_but_do_not_prove_completed_work(self):
        result = self.bind()
        self.assertTrue(result["integrationHandshakeBound"])
        self.assertFalse(result["workloadComplete"])

    def test_wrong_or_missing_runtime_entry_fields_fail(self):
        for key, value in [("schema", "production.main"), ("arm", ARMS[1]), ("hostPid", 43),
                           ("hostPid", True), ("sourceCommit", "3"*40),
                           ("baseProductCommit", "4"*40), ("startedUs", -1)]:
            with self.subTest(key=key, value=value):
                bad = {**self.hello, key: value}
                with self.assertRaises(ValueError): self.bind(bad)
        with self.assertRaises(ValueError): self.bind({})

    def test_sdk_or_other_process_elf_cannot_satisfy_target_gate(self):
        for loaded in [{"sha256": "3"*64, "bytes": 1234}, {"sha256": "2"*64, "bytes": 1235}, {}]:
            with self.assertRaises(ValueError): self.bind(loaded_executable=loaded)

    def test_unsealed_source_and_production_target_fail(self):
        with self.assertRaises(ValueError): bind_source_target(b"wrong", "0"*64)
        with self.assertRaises(ValueError): bind_source_target(b"main", hashlib.sha256(b"main").hexdigest())
        with self.assertRaises(ValueError): self.bind(source_binding={**self.source, "target": "lib/main.dart"})

    def test_bad_paths_and_renderer_are_never_shell_commands(self):
        for path in ["flutter", "/opt/../flutter", "/tmp/launcher\nextra", "/tmp//launcher"]:
            with self.assertRaises(ValueError): commands(path, "/tmp/launcher", self.head, "llvmpipe")
        with self.assertRaises(ValueError): commands("/opt/flutter", "/tmp/launcher", self.head, "bad\nvalue")


if __name__ == "__main__":
    unittest.main()
