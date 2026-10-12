#!/usr/bin/env python3
"""Compare the same bounded synthetic reader contract against frozen and current code."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent
REFERENCE = "9d4cd5a0f9db03042a3986689fea374ba92d78b8"
REFERENCE_MANIFEST = "8fe9e685b4e49e344ffcb12b3483bff7570db313511647f082bd471c74fb5d5a"
PASS = re.compile(
    r"PASS differential digest [0-9a-f]{16}; 98 full compile sessions / "
    r"196 viewport queries, 4 compile cancel sessions, 40 edge cases\n"
)


def require(condition, message):
    if not condition:
        raise ValueError(message)


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def relative(path):
    return os.path.relpath(Path(path).resolve(), ROOT)


def identity(path):
    return {"path": relative(path), "bytes": path.stat().st_size, "sha256": sha(path)}


def source_identity(source):
    manifest = source / "SOURCE_MANIFEST.json"
    records = json.loads(manifest.read_text())["files"]
    expected = {record["path"] for record in records} | {"SOURCE_MANIFEST.json"}
    actual = {str(path.relative_to(source)) for path in source.rglob("*") if path.is_file()}
    require(actual == expected, "Vendor source closure differs from its manifest")
    for record in records:
        path = source / record["path"]
        require(not path.is_symlink() and path.resolve().is_relative_to(source),
                "Vendor source must be a regular file within its closure")
        require(path.stat().st_size == record["bytes"] and sha(path) == record["sha256"],
                "Vendor source hash mismatch: " + record["path"])
    return {"manifest": identity(manifest), "filesVerified": len(records),
            "readerSources": [identity(source / "src" / name) for name in (
                "terra_circuit_compile.c", "terra_circuit_world.c",
                "terra_circuit_world_internal.h")]}


def web_objects(source, build):
    """Select only the exact WLD target's source-derived objects, never a build glob."""
    cache = (build / "CMakeCache.txt").read_text()
    for item in ("CMAKE_BUILD_TYPE:STRING=Release", "TERRAWASM_FEATURE_SET:STRING=wld",
                 "CMAKE_HOME_DIRECTORY:INTERNAL=" + str(source)):
        require(item in cache.splitlines(), "Unexpected Web build cache: " + item)
    text = (source / "CMakeLists.txt").read_text()
    names = []
    for group in ("COMMON_SOURCES", "WLD_SOURCES"):
        match = re.search(r"set\(" + group + r"\s+(.*?)\n\)", text, re.S)
        require(match is not None, "Missing source group: " + group)
        names.extend(re.findall(r'"\$\{SRC_DIR\}/([^"]+\.c)"', match.group(1)))
    require(names and len(names) == len(set(names)), "Invalid WLD source list")
    target = build / "CMakeFiles/terrax_world_wasm_web.dir"
    objects = sorted(target.rglob("*.o"))
    by_name = {}
    for path in objects:
        by_name.setdefault(path.name, []).append(path)
    expected = {name + ".o" for name in names} | {"abc_region.c.o"}
    require(set(by_name) == expected and all(len(items) == 1 for items in by_name.values()),
            "Web target object set differs from WLD sources plus its abc_region wrapper")
    flags = (target / "flags.make").read_text()
    normalized = flags.replace(str(source), "${SOURCE}").replace(
        str(source.parent.parent), "${HOST}")
    selected = [by_name[name + ".o"][0] for name in names]
    return selected, normalized, {
        "selectedObjects": [identity(path) for path in selected],
        "excludedHostObjects": [identity(by_name["abc_region.c.o"][0])],
        "compileFlags": normalized,
        "sourceCMake": identity(source / "CMakeLists.txt"),
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mode", choices=("release", "sanitized", "wasm"), required=True)
    parser.add_argument("--reference-source", type=Path, required=True)
    parser.add_argument("--candidate-source", type=Path, required=True)
    parser.add_argument("--reference-archive", type=Path)
    parser.add_argument("--candidate-archive", type=Path)
    parser.add_argument("--reference-web-build", type=Path)
    parser.add_argument("--candidate-web-build", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    report = {"schema": "abc.batched-reader-regression.v1", "mode": args.mode,
              "referenceCommit": REFERENCE, "status": "running", "commands": [],
              "products": {}, "harness": identity(ROOT / "native/circuit_batched_reader_contract.c"),
              "scope": "Synthetic reader/session behavior; no whole-map or performance run"}
    if args.mode == "sanitized":
        report["sanitizerEnvironment"] = {name: os.environ.get(name, "")
                                          for name in ("ASAN_OPTIONS", "UBSAN_OPTIONS")}

    def save():
        (output / "report.json").write_text(json.dumps(report, indent=2) + "\n")

    def run(argv):
        argv = [str(item) for item in argv]
        try:
            process = subprocess.run(argv, cwd=ROOT, capture_output=True, text=True, timeout=120)
        except subprocess.TimeoutExpired as error:
            def decoded(value):
                return value.decode("utf-8", errors="replace") if isinstance(value, bytes) else (value or "")
            report["commands"].append({"argv": argv, "exitCode": None, "status": "timed_out",
                                       "timeoutSeconds": 120, "stdout": decoded(error.stdout),
                                       "stderr": decoded(error.stderr)})
            save()
            raise
        report["commands"].append({"argv": argv, "exitCode": process.returncode,
                                   "stdout": process.stdout, "stderr": process.stderr})
        save()
        require(process.returncode == 0, "Command failed: " + " ".join(argv))
        return process.stdout

    try:
        compiler = "emcc" if args.mode == "wasm" else "cc"
        report["compiler"] = run([compiler, "--version"]).splitlines()[0]
        if args.mode == "wasm":
            require(run(["emcc", "-dumpversion"]).strip() == "5.0.7",
                    "The Web regression requires Emscripten 5.0.7")
            report["node"] = run(["node", "--version"]).strip()
        probe = output / "linker_wrap_probe.c"
        probe.write_text("""#include "terra_circuit_world_internal.h"
#include <assert.h>
#include <stdio.h>
static TxWorld world;
static unsigned gets, errors;
TxWorld* __wrap_tx_get_world(uint32_t id){++gets;return id==123?&world:NULL;}
extern void __real_tx_set_error(const char*,const char*);
void __wrap_tx_set_error(const char*a,const char*b){++errors;__real_tx_set_error(a,b);}
int main(void){
    uint32_t handle=42;world.version=279;
    assert(terra_circuit_world_begin(123,8,8*1024*1024,&handle)==TCW_FORMAT);
    assert(gets==1&&handle==0);
    assert(cx_fail(NULL,TCW_FORMAT,"batched-reader linker probe")==TCW_FORMAT);
    assert(errors==1);
    puts("PASS production linker wrappers");return 0;
}
""")
        report["linkerWrapProbe"] = identity(probe)
        results = []
        previous_flags = None
        for name in ("reference", "candidate"):
            source = getattr(args, name + "_source").resolve()
            info = source_identity(source)
            report["products"][name] = info
            if name == "reference":
                require(info["manifest"]["sha256"] == REFERENCE_MANIFEST,
                        "Reference is not the frozen 9d4 vendor manifest")
            flags = ["-std=gnu17", "-UNDEBUG", "-DTERRAX_STATIC"]
            if args.mode == "wasm":
                build_arg = getattr(args, name + "_web_build")
                require(build_arg is not None, "Both Web build directories are required")
                objects, normalized, provenance = web_objects(source, build_arg.resolve())
                info["webObjects"] = provenance
                if previous_flags is not None:
                    require(normalized == previous_flags,
                            "Reference and candidate Web object compile flags differ")
                previous_flags = normalized
                archive = output / (name + "-web.a")
                run(["emar", "rcs", relative(archive)] + [relative(path) for path in objects])
                flags += ["-O3", "-flto", "-sUSE_ZLIB=1", "-sENVIRONMENT=node",
                          "-sEXIT_RUNTIME=1", "-sALLOW_MEMORY_GROWTH=1",
                          "-sINITIAL_MEMORY=67108864", "-sMAXIMUM_MEMORY=268435456"]
                executable = output / (name + ".cjs")
            else:
                archive_arg = getattr(args, name + "_archive")
                require(archive_arg is not None, "Both native static archives are required")
                archive = archive_arg.resolve()
                flags += (["-O1", "-g", "-fsanitize=address,undefined",
                           "-fno-omit-frame-pointer"] if args.mode == "sanitized" else ["-O2"])
                executable = output / name
            info["archive"] = identity(archive)
            command = [compiler] + flags + [
                "-I", relative(source / "include"), "-I", relative(source / "src"),
                "native/circuit_batched_reader_contract.c", relative(archive),
                "-Wl,--wrap=tx_get_world,--wrap=tx_set_error", "-lm"]
            if args.mode != "wasm":
                command.append("-lz")
            probe_executable = output / (name + ("-wrap.cjs" if args.mode == "wasm" else "-wrap"))
            probe_command = [relative(probe) if part == "native/circuit_batched_reader_contract.c" else part
                             for part in command]
            run(probe_command + ["-o", relative(probe_executable)])
            probe_result = run((["node"] if args.mode == "wasm" else []) + [relative(probe_executable)])
            require(probe_result == "PASS production linker wrappers\n",
                    name + " did not prove both production linker wrap paths")
            info["productionWrapProbePassed"] = True
            run(command + ["-o", relative(executable)])
            result = run((["node"] if args.mode == "wasm" else []) + [relative(executable)])
            require(PASS.fullmatch(result) is not None,
                    name + " did not emit the complete expected contract result")
            info["result"] = result
            results.append(result)
        require(results[0] == results[1], "Reference and candidate behavior digests differ")
        report["status"] = "passed"
        report["exactOutputMatch"] = True
        print(args.mode + ": exact baseline/candidate match\n" + results[0], end="")
        return 0
    except (OSError, ValueError, subprocess.TimeoutExpired) as error:
        report["status"] = "failed"
        report["error"] = str(error)
        print(str(error), file=sys.stderr)
        return 1
    finally:
        save()


if __name__ == "__main__":
    sys.exit(main())

