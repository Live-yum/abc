#!/usr/bin/env python3
"""Auxiliary observer; its timings MUST NOT enter frozen performance comparison.

Same source/open/lit/marked/save/close sequence as generate_native_map.py, but
retains the already-returned response and collects observers outside wall time.
Observer allocation, hashes, getrusage and journal writes can perturb later
operations. This is deliberately a separate schema and fresh-process group.
"""
import argparse
import ctypes as C
import hashlib
import json
import os
from pathlib import Path
import resource
import time

from mapgen_diagnostic_contract import ITERATIONS, REQUESTS


def fingerprint(data):
    return {"bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()}


def usage():
    value = resource.getrusage(resource.RUSAGE_SELF)
    return {"userSeconds": value.ru_utime, "systemSeconds": value.ru_stime,
            "minorFaults": value.ru_minflt, "majorFaults": value.ru_majflt,
            "voluntarySwitches": value.ru_nvcsw, "involuntarySwitches": value.ru_nivcsw}


def observation(cycle, kind, data, response, width, height, wall_ns, cpu_ns, before, after):
    # This function is called only after both clocks have stopped.
    parsed = json.loads(response.rstrip(b"\0"))
    return {"cycle": cycle, "operation": kind, "phase": "cold" if cycle == 0 else "warm",
            "wallMs": wall_ns / 1e6, "cpuMs": cpu_ns / 1e6,
            "usageDelta": {key: after[key] - before[key] for key in before},
            "output": {**fingerprint(data), "width": width, "height": height},
            "response": {**fingerprint(response), "json": parsed},
            "matches": {key: parsed.get(key) for key in
                        ("matched_tile_count", "matched_chest_count")}}


class Native:
    def __init__(self, library):
        self.lib = C.CDLL(str(library))
        u, p, up = C.c_uint32, C.c_void_p, C.POINTER(C.c_uint32)
        for name, signature in {
            "abc_world_open": [p, u, up], "abc_world_close": [u],
            "abc_world_operation": [u, C.c_char_p, C.c_char_p, p, u, up],
            "abc_world_map": [u, p, u, up, up, up],
            "abc_world_save": [u, p, u, up], "abc_error": [p, u, up],
        }.items():
            getattr(self.lib, name).argtypes = signature
            getattr(self.lib, name).restype = C.c_int32

    def check(self, status):
        if status:
            out, required = C.create_string_buffer(8192), C.c_uint32()
            self.lib.abc_error(out, len(out), C.byref(required))
            raise RuntimeError(f"Native status {status}: {out.value.decode(errors='replace')}")

    def read(self, function, *prefix):
        required = C.c_uint32()
        self.check(function(*prefix, None, 0, C.byref(required)))
        assert 0 < required.value <= 128 * 1024 * 1024, "Response exceeds contract"
        result = C.create_string_buffer(required.value)
        self.check(function(*prefix, result, len(result), C.byref(required)))
        return result.raw[:required.value]

    def generate(self, handle, operation, request):
        # Retain this response. A THIRD operation call would execute again after
        # the cached probe response is consumed and would change the workload.
        response = self.read(self.lib.abc_world_operation, handle, operation, request)
        size, width, height = C.c_uint32(), C.c_uint32(), C.c_uint32()
        self.check(self.lib.abc_world_map(handle, None, 0, C.byref(size), C.byref(width), C.byref(height)))
        assert 4 < size.value <= 128 * 1024 * 1024, "Invalid MAP length"
        out = C.create_string_buffer(size.value)
        self.check(self.lib.abc_world_map(handle, out, len(out), C.byref(size), C.byref(width), C.byref(height)))
        data = out.raw[:size.value]
        assert int.from_bytes(data[:4], "little") == 33083 and data[4:12] == b"relogic\x01", "Invalid MAP"
        return data, response, width.value, height.value


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("library", "input", "report"):
        parser.add_argument("--" + name, type=Path, required=True)
    args = parser.parse_args()
    assert not args.report.exists(), "Never replace evidence"
    source = args.input.read_bytes()
    native = Native(args.library)
    report = {"schema": "abc.mapgen-auxiliary.v1", "status": "running",
              "acceptanceEligible": False, "pid": os.getpid(),
              "runId": os.environ.get("ABC_PERF_RUN_ID"),
              "library": fingerprint(args.library.read_bytes()), "fixture": fingerprint(source),
              "iterations": ITERATIONS, "records": [], "sourcePreserved": False,
              "observerEffect": "Hash/JSON/resource observers and journal writes are outside wall time but can perturb subsequent calls; never pool with frozen reports."}
    args.report.parent.mkdir(parents=True, exist_ok=True)
    # Record actual load addresses to test address/layout hypotheses later.
    args.report.with_suffix(".maps.txt").write_text(Path("/proc/self/maps").read_text())
    journal = args.report.with_suffix(".cycles.jsonl")
    def save():
        args.report.write_text(json.dumps(report, indent=2) + "\n")
    save()
    try:
        with journal.open("x") as log:
            for cycle in range(ITERATIONS):
                handle = C.c_uint32()
                native.check(native.lib.abc_world_open(source, len(source), C.byref(handle)))
                try:
                    for kind, operation, request in REQUESTS:
                        before = usage()
                        cpu_start = time.process_time_ns()
                        start = time.perf_counter_ns()
                        data, response, width, height = native.generate(handle.value, operation, request)
                        elapsed = time.perf_counter_ns() - start
                        cpu_elapsed = time.process_time_ns() - cpu_start
                        after = usage()
                        row = observation(cycle, kind, data, response, width, height,
                                          elapsed, cpu_elapsed, before, after)
                        # Retain actual distinct synthetic outputs/responses as
                        # well as per-cycle hashes. No extra native API call.
                        for suffix, payload, key in ((".outputs", data, "output"),
                                                     (".responses", response, "response")):
                            directory = args.report.with_suffix(suffix)
                            directory.mkdir(exist_ok=True)
                            target = directory / (row[key]["sha256"] + ".bin")
                            if not target.exists():
                                target.write_bytes(payload)
                        report["records"].append(row)
                        log.write(json.dumps(row) + "\n")
                        log.flush()
                    assert native.read(native.lib.abc_world_save, handle.value) == source, "WLD changed"
                finally:
                    native.check(native.lib.abc_world_close(handle.value))
        assert args.input.read_bytes() == source, "Input file changed"
        report.update(status="passed", sourcePreserved=True)
        return 0
    except Exception as error:
        report.update(status="failed", error=f"{type(error).__name__}: {error}")
        return 1
    finally:
        report["processUsage"] = usage()
        save()


if __name__ == "__main__":
    raise SystemExit(main())
