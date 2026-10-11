# Heaptrack first-stage preflight

This directory contains only a fixed-package identity gate, one synthetic native
capture contract, and its offline validation. It does not contain a Flutter
launcher or a real workload sampler. It never installs/downloads packages.

## Frozen inputs and execution

CI must be Ubuntu 24.04 amd64 with the official Ubuntu packages:

- `heaptrack=1.5.0+dfsg1-2ubuntu3`
- `libheaptrack=1.5.0+dfsg1-2ubuntu3`
- The existing distribution C compiler/binutils, Python 3, gzip and zstd

The workflow owner installs the two exact packages through normally authenticated
APT and downloads those same two `.deb` archives into a new directory. No extra
APT source, PPA, source build or patched profiler is accepted. The runner checks
the installed package/source identity, official Ubuntu noble origin, APT SHA256
of each archive, and every installed package file against the verified archive.
It also records the actual recorder/interpreter/printer paths, versions and help.
APT's signed-index verification is supplied by the workflow's ordinary
`apt-get update`; the runner does not independently implement repository signing.

Run offline tests first:

```
python3 -m unittest discover -s tool/perf/heaptrack_preflight -p 'test_*.py' -v
```

Run the unique CI preflight:

```
python3 tool/perf/heaptrack_preflight/run_preflight.py \
  --output build/heaptrack-preflight --deb-dir build/heaptrack-packages
```

Output must be a new directory. There are no retries. An identity failure occurs
before the fixture starts. A fixture or profiler failure returns nonzero and
preserves evidence. A successful status is only `passed-synthetic-only`; the
manifest always states `realSamplingAllowedByThisResult: false`.

## Native contract

Exactly one profiled native fixture is permitted. Its normal path performs
23 explicitly authored allocator calls, below the 32-call bound. Four markers
make eight of those calls (one real malloc and free per marker). No stdio occurs
until authored work and cleanup finish. The fixture has no WLD, SDK or Flutter
dependency. It records pointer identities as integers before invalidation.

The fixture tests malloc/calloc, allocations live across cuts, free across cuts,
successful realloc, failed `realloc(p, SIZE_MAX)` preserving the original owner,
and Linux/glibc `realloc(p, 0)` freeing its old block. Requested fixture live-byte
totals at the four cuts are 320, 716, 1010 and 1558, each with two owned blocks.
Uncontrolled startup/system allocations are not assumed to be zero.

Each cut precedes a real allocation in a distinct exported noinline marker:
`q0_begin`, `q0_end`, `q7_begin`, `q7_end`. Identification requires the actual
ELF symbol PC range, recorded module load base, exact pointer and requested size;
size alone is insufficient. The parser checks every authored allocation/free
event, not just endpoint totals, so a missed transient pair also fails.

The current upstream 1.5.0 realloc wrapper records only a non-null result.
Therefore a missing zero-size-realloc free is a concrete anticipated failure,
not a reason to weaken this contract. The exact installed Ubuntu package must
demonstrate correct behavior. If it does not, this group ends here.

## Official cross-check and interpretation

Keep the complete raw-v3 stream, including its shutdown tail. For each marker,
copy only the complete prefix preceding that marker allocation event. Feed each
prefix into the unmodified official `heaptrack_interpret`, then use official
`heaptrack_print` with built-in/embedded suppressions disabled, no backtrace
merging, and the integer collapsed-stack `leaked` cost export. Compare its exact
byte sum and the interpreter's remaining-block count with the independent raw
accountant. Ordinary rounded display output and allocation-call totals are not
used as live bytes or live blocks.

In this context the profiler's label `leaked` means only “recorded allocations
still present at the end of this prefix.” It is not a leak verdict. Cuts are
recorded-event boundaries, not simultaneous frozen heaps. Unknown frees are
counted explicitly; a known duplicate live pointer, malformed/unknown format,
missing marker/free/tail or semantic mismatch fails. Tool warnings on either
stdout or stderr, including changes to RTLD_DEEPBIND, fail closed.

## Bounds and evidence

- Unique profiled native fixture: 10 seconds, at most 32 authored calls
- Compressed trace: 16 MiB; decoded trace: 64 MiB; record: 64 KiB
- Exactly four prefixes; at most 120 seconds interpretation plus printing per prefix
- Whole preflight: 650 seconds; command logs: 2 MiB each
- Child-created files: 64 MiB process limit; no core dumps

These smaller limits apply to the synthetic preflight, not a real application.
They do not change the historical product workload or any original test budget.

The runner starts each command in a fresh owned process group, keeps the leader
unreaped until cleanup, and sends bounded TERM then KILL to that owned group even
when its leader has already exited. After reaping it only probes, and sends no
further numeric-group signals. An unverified remaining group fails closed. The
offline orphan test temporarily makes only its own test process a child subreaper
so it can reap the synthetic orphan, and restores that process setting afterward.

Archive the entire output directory on success or failure, especially:

- `manifest.json`: identities, commands, limits, process count, verdict, hashes
- `fixture.jsonl`: native operation and semantic oracle
- `raw/`: complete compressed and decoded input
- `raw-accounting.json`: all authored events, cut identities and semantic failures
- `prefixes/`: four raw prefixes, official interpreted data and integer stack exports
- `official-comparisons.json`, `symbols.json`, and `logs/`

An invalid profiler semantic result still permits analysis of that same saved
capture for failure evidence. It never starts another profiled process. A raw
integrity failure stops earlier. Real Flutter/WLD work and the historical image
coverage failure are outside this gate and remain untouched.

## Primary references

- [Official Ubuntu noble package/version](https://packages.ubuntu.com/noble/amd64/heaptrack)
- [Upstream 1.5.0 raw launcher and offline interpreter invocation](https://raw.githubusercontent.com/KDE/heaptrack/v1.5.0/src/track/heaptrack.sh.cmake)
- [Raw recorder, serialized events and timestamp behavior](https://raw.githubusercontent.com/KDE/heaptrack/v1.5.0/src/track/libheaptrack.cpp)
- [Preload allocation/realloc/free order and RTLD_DEEPBIND behavior](https://raw.githubusercontent.com/KDE/heaptrack/v1.5.0/src/track/heaptrack_preload.cpp)
- [Official raw interpreter and pointer accounting](https://raw.githubusercontent.com/KDE/heaptrack/v1.5.0/src/interpret/heaptrack_interpret.cpp)
- [Printer integer export and suppressions](https://raw.githubusercontent.com/KDE/heaptrack/v1.5.0/src/analyze/print/heaptrack_print.cpp)
- [Raw-v3 sized-string reader](https://raw.githubusercontent.com/KDE/heaptrack/v1.5.0/src/util/linereader.h)
- [Version 1.5.0 and format 3 declarations](https://raw.githubusercontent.com/KDE/heaptrack/v1.5.0/CMakeLists.txt)

The Ubuntu package identity is pinned independently of the upstream tag. Its
actual contract result is required; upstream source inspection alone is not a
passing runtime test.
