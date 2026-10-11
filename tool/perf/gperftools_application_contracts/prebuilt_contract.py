"""Offline command and provenance contract; this module cannot launch Flutter.

Pinned Flutter's Linux prebuilt path skips building the application. Consequently
the explicit build command, original integration hello, and loaded ELF must all
be bound; a successful `drive` invocation alone is insufficient evidence.
These functions validate supplied evidence, not its acquisition. The actual CI
supervisor must obtain process/ELF identity using its retained owned-process fd.
"""

from __future__ import annotations

import hashlib
import re
from pathlib import PurePosixPath

BASE = "9d4cd5a0f9db03042a3986689fea374ba92d78b8"
SDK_COMMIT = "5fc346839b5d0eef006ed8404392afb4dfae428d"
SDK_VERSION = "3.47.6"
TARGET = "integration_test/computer_memory_ownership_test.dart"
DRIVER = "test_driver/ui_profile_driver.dart"
ARMS = ("probe-only", "product-with-ownership")


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValueError(message)


def absolute_path(value: str) -> str:
    require(isinstance(value, str) and value.startswith("/"), "Absolute path required")
    require(all(c.isprintable() for c in value), "Control characters in path")
    path = PurePosixPath(value)
    require(str(path) == value and ".." not in path.parts, "Canonical path required")
    return value


def sha(value: str, length: int) -> str:
    require(isinstance(value, str) and re.fullmatch(f"[0-9a-f]{{{length}}}", value) is not None,
            "Invalid pinned digest")
    return value


def commands(flutter: str, launcher: str, head: str, renderer: str) -> dict[str, list[str]]:
    """Return argv only. No shell, environment reads, subprocess or SDK calls."""
    absolute_path(flutter)
    absolute_path(launcher)
    sha(head, 40)
    require(isinstance(renderer, str) and 0 < len(renderer) <= 256
            and all(c.isprintable() for c in renderer), "Renderer identity missing or malformed")
    flags = [f"--target={TARGET}", "--dart-define=ABC_MEMORY_OWNERSHIP=true",
             f"--dart-define=PERF_COMMIT={head}", f"--dart-define=PERF_CHECKED_OUT_HEAD={head}",
             "--dart-define=PERF_WORKTREE_DIRTY=false",
             f"--dart-define=PERF_FLUTTER_VERSION={SDK_VERSION}",
             f"--dart-define=PERF_RENDERER={renderer}"]
    prefix = [flutter, "--no-version-check", "--suppress-analytics"]
    return {
        "build": prefix + ["build", "linux", "--profile", "--no-pub"] + flags,
        "drive": prefix + ["drive", "--no-pub", "--profile", "-d", "linux",
                           "--host-vmservice-port=0", f"--driver={DRIVER}",
                           f"--use-application-binary={launcher}"] + flags,
    }


def verify_commands(actual: dict, expected: dict, sdk_commit: str, sdk_version: str) -> None:
    require(sdk_commit == SDK_COMMIT and sdk_version == SDK_VERSION, "SDK pin differs")
    require(actual == expected and set(actual) == {"build", "drive"},
            "Explicit integration build/prebuilt drive command differs")


def clean_driver_environment(environment: dict[str, str]) -> dict[str, str]:
    """Do not expose environment contents in evidence; retain only this policy."""
    return {key: value for key, value in environment.items()
            if key not in {"LD_PRELOAD", "LD_AUDIT", "HEAPPROFILE", "HEAPPROFILESIGNAL"}
            and not key.startswith("HEAP_PROFILE_")}


def bind_source_target(source_bytes: bytes, expected_sha256: str) -> dict:
    """The exact compiled integration source, including its reviewed hook delta."""
    sha(expected_sha256, 64)
    actual = hashlib.sha256(source_bytes).hexdigest()
    require(actual == expected_sha256, "Integration target bytes differ from sealed source")
    # This is a source-integrity assertion, not proof of runtime entry.
    require(b"abc.memory-ownership-hello.v1" in source_bytes,
            "Original integration hello is absent from sealed target")
    return {"target": TARGET, "sha256": actual, "bytes": len(source_bytes),
            "runtimeEntryExecuted": False}


def bind_runtime_entry(hello: dict, *, arm: str, head: str, owned_pid: int,
                       loaded_executable: dict, built_executable: dict,
                       source_binding: dict) -> dict:
    """Only call with observed hello and fd-pinned loaded ELF identity.

    No timeout fallback to production main, alternate PID, SDK process or a
    second application is acceptable. This proves a bound integration handshake,
    not completed cycles, functional equivalence, profiling or performance.
    """
    require(arm in ARMS and type(owned_pid) is int and owned_pid > 0, "Invalid owned target")
    sha(head, 40)
    require(hello.get("schema") == "abc.memory-ownership-hello.v1"
            and hello.get("arm") == arm and hello.get("sourceCommit") == head
            and hello.get("baseProductCommit") == BASE
            and type(hello.get("hostPid")) is int and hello["hostPid"] == owned_pid
            and type(hello.get("startedUs")) is int and hello["startedUs"] >= 0,
            "Original integration hello does not bind this owned target")
    require(source_binding.get("target") == TARGET
            and type(source_binding.get("bytes")) is int and source_binding["bytes"] > 0,
            "Compiled integration source binding absent")
    sha(source_binding.get("sha256"), 64)
    require(set(built_executable) == {"sha256", "bytes"}
            and type(built_executable["bytes"]) is int and built_executable["bytes"] > 0,
            "Built target identity absent")
    sha(built_executable.get("sha256"), 64)
    require(loaded_executable == built_executable, "Loaded target differs from built integration ELF")
    return {"integrationHandshakeBound": True, "arm": arm, "hostPid": owned_pid,
            "sourceCommit": head, "target": TARGET,
            "targetSourceSha256": source_binding["sha256"],
            "executable": dict(built_executable), "workloadComplete": False}
