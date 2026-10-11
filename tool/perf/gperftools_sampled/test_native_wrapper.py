#!/usr/bin/env python3
"""Offline adapter tests. Build and run only an explicitly synthetic provider.

No official allocator/profiler is linked or loaded. No SDK, app, product, CI,
network, launcher, or sampler execution. An official-header compile-only check
is a separate command; it must not be described as official runtime validation.
"""
from __future__ import annotations

import errno
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent
RAW_LIMIT = 1024 * 1024
PENDING = "q0.sample.heap.pending"
FINAL = "q0.sample.heap"
FIXTURE = (
    b"heap profile:      1:      64 [     1:      64] @ heap_v2/524288\n"
    b"     1:       64 [     1:       64] @ 0x1001\n"
    b"\nMAPPED_LIBRARIES:\n"
    b"00001000-00002000 r-xp 00000000 00:00 1 /offline/synthetic-provider\n"
)
STUB_HEADER = """// TEST ONLY. API-shaped stub, not an official header or runtime.
#include <string>
class MallocExtension {
 public:
  virtual ~MallocExtension() = default;
  static MallocExtension* instance();
  virtual void GetHeapSample(std::string*) = 0;
};
"""


def clean_environment():
    # Only child compiler/stub-process environments are constructed here.
    # The adapter itself never mutates the target environment.
    prefixes = ("LD_", "HEAP", "TCMALLOC", "CPUPROFILE", "MALLOC", "ABC_")
    return {k: v for k, v in os.environ.items() if not k.startswith(prefixes)}


def run(command, *, env=None):
    return subprocess.run(command, check=True, capture_output=True, text=True,
                          timeout=20, env=clean_environment() if env is None else env)


class NativeSampleWrapperTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.build_tmp = tempfile.TemporaryDirectory(prefix="abc-sampled-stub-build-")
        cls.build = Path(cls.build_tmp.name)
        include = cls.build / "gperftools"
        include.mkdir()
        (include / "malloc_extension.h").write_text(STUB_HEADER)
        cls.binary = cls.build / "offline-stub"
        compiler = shutil.which("c++") or "c++"
        run([compiler, "-std=c++17", "-O2", "-Wall", "-Wextra", "-Werror",
             "-I", str(cls.build), "-I", str(ROOT), str(ROOT / "sample_wrapper.cc"),
             str(ROOT / "native_wrapper_stub_test.cc"),
             *[f"-Wl,--wrap={name}" for name in
               ("openat", "write", "close", "fsync", "renameat2", "clock_gettime")],
             "-o", str(cls.binary)])
        # Confirm the exported interface can be consumed by C without C++ types.
        source = cls.build / "c-abi.c"
        source.write_text('#include "sample_wrapper.h"\n'
                          'int main(void) { struct abc_sample_context c = {0}; '
                          'return (int)c.initialized; }\n')
        run([shutil.which("cc") or "cc", "-std=c11", "-Wall", "-Wextra", "-Werror",
             "-I", str(ROOT), "-c", str(source), "-o", str(cls.build / "c-abi.o")])

    @classmethod
    def tearDownClass(cls):
        cls.build_tmp.cleanup()

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="abc-sampled-stub-case-")
        self.directory = Path(self.tmp.name)
        self.directory.chmod(0o700)

    def tearDown(self):
        self.tmp.cleanup()

    def case(self, scenario="success", env_changes=None):
        env = clean_environment()
        env.update(ABC_SAMPLED_DIAGNOSTIC="1", TCMALLOC_SAMPLE_PARAMETER="524288")
        for key, value in (env_changes or {}).items():
            if value is None:
                env.pop(key, None)
            else:
                env[key] = value
        result = json.loads(run([str(self.binary), scenario, str(self.directory)], env=env).stdout)
        self.assertTrue(result["offline"])
        self.assertFalse(result["officialRuntimeInvoked"])
        self.assertEqual(result["abi"], 1)
        self.assertEqual(result["status"], result["recordedStatus"])
        self.assertEqual((result["repeated"], result["reinitialized"]), (5, 5))
        self.assertLessEqual(result["sampleCalls"], 1)
        self.assertEqual(result["apiCalls"], result["sampleCalls"])
        self.assertEqual(result["closeAttempts"], result["closeCalls"])
        self.assertLessEqual(result["writeCalls"], 1)
        self.assertLessEqual(result["closeCalls"], 1)
        self.assertTrue(result["directoryStillOpen"])
        self.assertTrue(result["envUnchanged"])
        return result

    def test_complete_bytes_new_empty_writer_timing_and_exclusive_publication(self):
        r = self.case()
        self.assertEqual((r["initialized"], r["status"], r["accepted"], r["published"]), (0, 0, 1, 1))
        self.assertEqual((r["apiCalls"], r["providerChecks"], r["emptyWriter"]), (1, 2, 1))
        self.assertEqual((r["returnedBytes"], r["writtenBytes"]), (len(FIXTURE), len(FIXTURE)))
        self.assertEqual((r["openCalls"], r["writeCalls"], r["syncCalls"], r["closed"]), (1, 1, 1, 1))
        self.assertEqual((self.directory / FINAL).read_bytes(), FIXTURE)
        self.assertEqual(stat.S_IMODE((self.directory / FINAL).stat().st_mode), 0o600)
        self.assertFalse((self.directory / PENDING).exists())
        times = [r[k] for k in ("hookStartNs", "apiStartNs", "apiEndNs", "hookEndNs")]
        self.assertEqual(times, sorted(times))
        self.assertEqual(r["apiElapsedNs"], r["apiEndNs"] - r["apiStartNs"])

    def test_disabled_by_default_never_calls_provider_or_creates_output(self):
        r = self.case(env_changes={"ABC_SAMPLED_DIAGNOSTIC": None})
        self.assertEqual((r["initialized"], r["status"], r["apiCalls"], r["guardCalls"]), (1, 1, 0, 0))
        self.assertEqual(list(self.directory.iterdir()), [])

    def test_enable_must_be_exact(self):
        for value in ("0", "true", "01", "1 ", ""):
            with self.subTest(value=value):
                self.assertEqual(self.case(env_changes={"ABC_SAMPLED_DIAGNOSTIC": value})["status"], 1)

    def test_parameter_must_be_exact_fixed_startup_value(self):
        for value in (None, "0", "1", "524287", "+524288", "0524288", "524288 "):
            with self.subTest(value=value):
                r = self.case(env_changes={"TCMALLOC_SAMPLE_PARAMETER": value})
                self.assertEqual((r["status"], r["apiCalls"], r["guardCalls"]), (3, 0, 0))

    def test_full_profiler_environment_is_rejected_without_mutation(self):
        for key in ("HEAPPROFILE", "HEAPPROFILESIGNAL", "HEAPCHECK", "HEAP_PROFILE_TIME_INTERVAL"):
            with self.subTest(key=key):
                r = self.case(env_changes={key: "0"})
                self.assertEqual((r["status"], r["apiCalls"]), (3, 0))

    def test_consumed_full_profiler_prefix_marker_is_also_rejected(self):
        # gperftools 2.15 may OR 0x80 into the value's first byte after consuming
        # HEAPPROFILE. Reject its presence; do not interpret or normalize it.
        marked = os.fsdecode(bytes([ord("/") | 0x80]) + b"offline/heap")
        r = self.case(env_changes={"HEAPPROFILE": marked})
        self.assertEqual((r["status"], r["apiCalls"], r["guardCalls"]), (3, 0, 0))

    def test_invalid_configuration_is_inert(self):
        for scenario in ("wrong-directory-identity", "missing-guard", "wrong-abi"):
            with self.subTest(scenario=scenario):
                r = self.case(scenario)
                self.assertEqual((r["status"], r["apiCalls"], r["guardCalls"]), (2, 0, 0))

    def test_non_private_directory_is_rejected(self):
        self.directory.chmod(0o755)
        self.assertEqual(self.case()["status"], 2)

    def test_directory_identity_rechecked_before_call(self):
        r = self.case("directory-changed")
        self.assertEqual((r["status"], r["apiCalls"]), (13, 0))

    def test_only_q0_and_one_attempt(self):
        r = self.case("wrong-cut")
        self.assertEqual((r["status"], r["apiCalls"], r["guardCalls"]), (6, 0, 0))

    def test_wrong_provider_is_never_called(self):
        r = self.case("wrong-provider")
        self.assertEqual((r["status"], r["instanceCalls"], r["apiCalls"]), (4, 0, 0))

    def test_provider_change_fails_without_output(self):
        r = self.case("provider-changed")
        self.assertEqual((r["status"], r["apiCalls"], r["providerChecks"], r["openCalls"]), (4, 1, 2, 0))

    def test_null_provider_has_no_sample_call(self):
        r = self.case("null-provider")
        self.assertEqual((r["status"], r["instanceCalls"], r["apiCalls"]), (4, 1, 0))

    def test_cpp_exceptions_do_not_cross_c_abi(self):
        for scenario, expected, calls in (("exception", 8, 1), ("bad-alloc", 9, 1),
                                          ("provider-throw", 8, 0), ("instance-throw", 8, 0)):
            with self.subTest(scenario=scenario):
                r = self.case(scenario)
                self.assertEqual((r["status"], r["apiCalls"], r["apiReturned"], r["openCalls"]),
                                 (expected, calls, 0, 0))

    def test_partial_exception_preserves_size_but_never_publishes(self):
        r = self.case("partial-exception")
        self.assertEqual((r["status"], r["returnedBytes"], r["apiReturned"], r["published"]),
                         (8, len(FIXTURE), 0, 0))
        self.assertGreater(r["apiEndNs"], r["apiStartNs"])

    def test_empty_fails_before_output(self):
        r = self.case("empty")
        self.assertEqual((r["status"], r["apiReturned"], r["openCalls"]), (10, 1, 0))

    def test_nul_bytes_preserved_for_offline_parser_rejection(self):
        r = self.case("nul")
        self.assertEqual((r["status"], r["accepted"], r["returnedBytes"]), (0, 1, len(FIXTURE) + 1))
        self.assertEqual((self.directory / FINAL).read_bytes(), FIXTURE + b"\0")

    def test_raw_bound_is_strict_and_oversize_is_never_truncated(self):
        for scenario, size in (("at-limit", RAW_LIMIT), ("over-limit", RAW_LIMIT + 7)):
            with self.subTest(scenario=scenario):
                r = self.case(scenario)
                self.assertEqual((r["status"], r["returnedBytes"], r["writtenBytes"], r["openCalls"]),
                                 (11, size, 0, 0))
        self.assertEqual(list(self.directory.iterdir()), [])

    def test_transport_accepts_under_limit_without_claiming_format_validity(self):
        r = self.case("under-limit")
        self.assertEqual((r["status"], r["returnedBytes"]), (0, RAW_LIMIT - 1))
        self.assertEqual((self.directory / FINAL).read_bytes(), b"x" * (RAW_LIMIT - 1))

    def test_clock_errors_fail_without_publication(self):
        for scenario in ("zero-clock", "clock-failure", "backwards-clock"):
            with self.subTest(scenario=scenario):
                r = self.case(scenario)
                self.assertEqual((r["status"], r["published"]), (7, 0))

    def test_slow_api_fails_after_return_without_output(self):
        r = self.case("slow-api")
        self.assertEqual((r["status"], r["apiCalls"], r["apiReturned"], r["openCalls"]), (12, 1, 1, 0))
        self.assertGreater(r["apiElapsedNs"], 10_000_000_000)

    def test_slow_write_closes_but_retains_unpublished_pending(self):
        r = self.case("slow-write")
        self.assertEqual((r["status"], r["closed"], r["published"]), (12, 1, 0))
        self.assertEqual((self.directory / PENDING).read_bytes(), FIXTURE)
        self.assertFalse((self.directory / FINAL).exists())

    def test_final_timeout_retains_published_flag_but_rejects_diagnostic(self):
        r = self.case("slow-finish")
        self.assertEqual((r["status"], r["published"], r["accepted"]), (12, 1, 0))

    def test_open_failure_is_not_retried(self):
        r = self.case("open-failure")
        self.assertEqual((r["status"], r["openCalls"], r["writeCalls"], r["closeCalls"]), (13, 1, 0, 0))

    def test_short_write_eintr_and_enospc_never_publish_or_retry(self):
        for scenario in ("short-write", "write-eintr", "write-failure"):
            with self.subTest(scenario=scenario):
                r = self.case(scenario)
                self.assertEqual((r["status"], r["writeCalls"], r["closed"], r["published"]), (14, 1, 1, 0))
                self.assertFalse((self.directory / FINAL).exists())
                (self.directory / PENDING).unlink()

    def test_sync_failure_closes_once_without_publication(self):
        r = self.case("sync-failure")
        self.assertEqual((r["status"], r["syncCalls"], r["closeCalls"], r["published"]), (15, 1, 1, 0))

    def test_close_failure_never_retries_or_publishes(self):
        r = self.case("close-failure")
        self.assertEqual((r["status"], r["closeCalls"], r["closed"], r["cleanupErrno"], r["published"]),
                         (16, 1, 0, errno.EINTR, 0))

    def test_cleanup_error_does_not_replace_primary_short_write(self):
        r = self.case("short-and-close")
        self.assertEqual((r["status"], r["ioErrno"], r["cleanupErrno"], r["closeCalls"]),
                         (14, errno.EIO, errno.EINTR, 1))

    def test_publish_failure_retains_complete_pending(self):
        r = self.case("publish-failure")
        self.assertEqual((r["status"], r["publishCalls"], r["closed"], r["published"]), (17, 1, 1, 0))
        self.assertEqual((self.directory / PENDING).read_bytes(), FIXTURE)

    def test_preexisting_pending_is_not_reused_or_overwritten(self):
        pending = self.directory / PENDING
        pending.write_bytes(b"prior evidence")
        r = self.case()
        self.assertEqual((r["status"], r["writeCalls"]), (13, 0))
        self.assertEqual(pending.read_bytes(), b"prior evidence")

    def test_preexisting_final_is_not_replaced(self):
        final = self.directory / FINAL
        final.write_bytes(b"prior final")
        r = self.case()
        self.assertEqual((r["status"], r["published"], r["ioErrno"]), (17, 0, errno.EEXIST))
        self.assertEqual(final.read_bytes(), b"prior final")
        self.assertEqual((self.directory / PENDING).read_bytes(), FIXTURE)

    def test_symlink_pending_is_not_followed(self):
        target = self.directory / "untouched"
        target.write_bytes(b"keep me")
        (self.directory / PENDING).symlink_to(target)
        r = self.case()
        self.assertEqual((r["status"], r["writeCalls"]), (13, 0))
        self.assertEqual(target.read_bytes(), b"keep me")


if __name__ == "__main__":
    unittest.main()
