# Standalone Native loading memory

`native_load_only.c` and `native_load_peak.py` measure loading of the complete
pinned public Computerraria WLD. The report is explicitly labelled
`standaloneNativeLoad`: it measures a small C host and the Native engine, not
the Flutter application, Dart heap, browser, textures, or raster buffers. It
is independent of the complete Native correctness and Flutter profile gates
described in [COMPUTERRARIA.md](COMPUTERRARIA.md).

The workload hashes the WLD, streams it, compiles the circuit, reads and
validates the physical 64×48 monochrome display at (6485, 800), constructs its
12,288-byte RGBA buffer, and closes the session. It does not clock the CPU, load or run
Pong, edit the source files, or export a world. Public input hashes, geometry,
and display coordinates are intentionally pinned; input, library, executable,
and output paths are command-line parameters. Reports contain no input paths
or command line. No personal save is accepted as an alternative fixture.

## Build and run on Linux

Use a freshly rebuilt Release `libabc_engine.so` from the WLD-only engine
with `circuitWorldAbiVersion` 2, a C compiler, OpenSSL development
headers/libcrypto, and Python 3. The four-argument circuit begin API requires
the new library; the host rejects an older circuit ABI before opening inputs.
The separate engine facade ABI remains version 1. Build before starting a measured run. Run
large benchmark, browser/profile, and compiler workloads sequentially.

```sh
cmake -S native -B build/native-wld-only -DCMAKE_BUILD_TYPE=Release
cmake --build build/native-wld-only --target abc_engine -j2
mkdir -p build/native-load
cc -std=c11 -O2 -Wall -Wextra -Werror -I native tool/perf/native_load_only.c \
  -L build/native-wld-only -labc_engine -lcrypto -ldl \
  -o build/native-load/native_load_only

python3 tool/perf/native_load_peak.py \
  --host build/native-load/native_load_only \
  --library build/native-wld-only/libabc_engine.so \
  --wld build/computerraria/inputs/computerraria.wld \
  --output build/native-load/run-1 --run-id run-1
```

Adjust the paths to the locally verified build and public input download.
The host verifies that the library actually bound at runtime is the file the
sampler fingerprints. The sampler refuses an existing output directory. For
repeats, run the same command sequentially with new output directories and run
IDs. Each invocation starts a fresh process. It never clears filesystem caches
or changes machine settings. The default timeout is 180 seconds; `--timeout`
can select 1–1200 seconds. Only its direct child is terminated on a timeout.

Each output directory retains `report.json`, `events.jsonl`, `samples.csv`,
`stderr.txt`, and a private-to-the-run `scratch.bin`. The scratch file is created
exclusively and existing files are never truncated. Do not publish the scratch
file or original WLD. The input is opened read-only. The generated report and samples contain public fixture
identity and measurements; the tool does not upload anything.

## Read the numbers

The supervisor reads only its own child's Linux `/proc/PID/status`, targeting
10 ms intervals, and `/proc/PID/smaps_rollup`, targeting 100 ms intervals.
`--rss-ms` and `--detail-ms` make these intervals explicit. The report retains
sample counts and the largest observed interval. PSS/USS unavailability is
recorded rather than replaced with zero. Short phases may have no OS sample.

The host records phase timestamps and Linux `getrusage` RSS high-water marks.
The report keeps `ru_maxrss` and observed `VmHWM` separately; their larger
recorded value is a conservative recorded peak, not a guarantee that sampling
captures every transient. Small differences can occur between Linux accounting
interfaces. Early `ru_maxrss` can retain pre-exec launcher accounting, so use
the sampled current RSS for baseline measurements.

PSS apportions shared pages; USS is private clean plus private dirty memory.
Shared RSS is not uniquely owned memory. PSS/USS maxima are sampled lower
bounds and may occur at different times from the RSS maximum. No memory from
the Python supervisor or compiler is added to the child's RSS.

Circuit `active_bytes` and `peak_bytes` are separate actual engine counters.
They omit host, decoder, loaded-library, allocator, and mapped-page overhead.
The 192 MiB circuit budget is not a process RSS limit. Counters are null before
the circuit exists and after close; a successful close alone does not prove
zero outstanding allocations. Engine phases are observed after bounded calls,
not at every allocation instruction.

## Measurement identity and publication

Reports use schema `abc.standaloneNativeLoad.v2`, circuit ABI 2, and
`load_scope: wld-only-mono64x48`. They are valid only when the process exits
successfully, verifies the pinned WLD hash, finishes all 15,200 circuit columns,
validates all 3,072 mono pixels, records zero clock pulses and ticks, and closes
the session. The pinned WLD is 405,983,441 bytes, SHA-256
`55d0a24bd1f56d622003dbd30d52555e7d06d6d1bcacfc22ae506f2db5240c33`.

[The WLD-only three-run summary](../../docs/evidence/standalone-native-load-2026-10-09.json)
records conservative RSS peaks of 143.711, 143.801 and 143.797 MiB, with loading
times of 17.124, 17.809 and 17.654 seconds. All three sampled RSS maxima occurred
in `compile.intern`; the largest retained circuit allocation counter was
145,729,418 bytes. All runs validated the full WLD, initialized only the mono
display, recorded zero clock pulses/ticks, and exited successfully.

These were sequential fresh-process runs of this exact packaged host and the
rebuilt ABI 2 engine, with 10 ms RSS and 100 ms PSS/USS target intervals. The
largest observed RSS sampling gap was 24.199 ms. Raw reports, events, samples,
source and binary fingerprints are retained separately; the public summary
records their hashes. The earlier prototype summary used a different workload
and was replaced by these actual measurements. The results describe the
standalone Native load workload; the full Flutter application's memory requires
its separate profile measurement.
