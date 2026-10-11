# Fixed gperftools synthetic preflight

This is a separate, bounded candidate contract, not a product sampler. It keeps
Heaptrack's rejected 503-byte result and all original Flutter/WLD evidence intact.
No success here authorizes another run, a real-map launch, a version change, a
profiler patch, a larger buffer, or a production/Release action.

The candidate replaces the allocator with full tcmalloc. Its requested-byte
allocation stacks cannot reconcile the original glibc +72.729 MiB result. Neither
success nor failure is evidence of a product leak or absence of leaks. Native/host
limited accounting and the image-coverage failure retain their original scope.

## Narrow index-selector correction after the first CI run

Run 38146022836 at head 97b7dbe stopped before package identity completion and
before any profiled fixture/application invocation. Its APT index list begins
with the official runner's unrelated Microsoft noble/main index. The previous
selector asserted Ubuntu identity after matching only component/suite/architecture,
so that unrelated row caused a false stop. The failed run remains unchanged.

This revision selects the already-verified fixed Ubuntu Repo-URI plus Sourcesentry
and requested package component first, requires exactly one candidate, and then
checks Trusted, Origin, Label, Release/Suite/Codename, architecture, target kind,
MetaKey and index-file directory. Microsoft or an unknown source cannot stand in
for Ubuntu, a claimed Ubuntu label cannot select another repository, malformed
selected rows still fail, and duplicate fixed candidates still fail. No APT source,
trust root, permissions, package version, profiler/fixture logic or budget changed.

apt-index-targets-97b7dbe.txt is the complete, unmodified 4730-byte stdout from that
failed run, SHA256 61ecf219759260f992be493fbfed4b5d22098b72b9bb87131bf62251b161145c.
It retains all five original stanzas, in order: Microsoft main followed by Ubuntu
main, universe, restricted and multiverse. Tests and the frozen source manifest
bind those exact bytes. Negative cases cover Microsoft-only output, spoofed labels,
partial/forged source tuples, duplicate candidates, unknown sources and each
selected Ubuntu identity field. This fixture is recorded evidence, not authority.

## Fixed official distribution identity

Ubuntu 24.04 Noble, amd64 process; source package google-perftools 2.15-3build1:

| Binary package | Version | Binary architecture | Component | Required member |
|---|---|---|---|---|
| libgoogle-perftools4t64 | 2.15-3build1 | amd64 | main | /usr/lib/x86_64-linux-gnu/libtcmalloc.so.4.5.16 |
| libgoogle-perftools-dev | 2.15-3build1 | amd64 | main | /usr/include/gperftools/heap-profiler.h |
| google-perftools | 2.15-3build1 | all | universe | /usr/bin/google-pprof |

The all-architecture analyst is supplied by the amd64 universe Packages index.
The main and universe indexes are independently bound to the same fixed Ubuntu
source stanza. Minimal tcmalloc is not accepted. The normal linker input is the
verified full library file, not a guessed SONAME. LD_PRELOAD uses that same
absolute regular file, and dlsym/dladdr verify that both malloc and HeapProfilerDump
are provided by exactly that file before authored allocations begin.

Official package references:

- [Noble source package](https://packages.ubuntu.com/source/noble/google-perftools)
- [Runtime file list](https://packages.ubuntu.com/noble/amd64/libgoogle-perftools4t64/filelist)
- [Developer file list](https://packages.ubuntu.com/noble/amd64/libgoogle-perftools-dev/filelist)
- [Developer main component](https://packages.ubuntu.com/noble/amd64/libgoogle-perftools-dev/download)
- [Analyst package/version/component/architecture](https://packages.ubuntu.com/search?keywords=google-perftools)
- [Noble google-pprof manual and providing package](https://manpages.ubuntu.com/manpages/noble/man1/google-pprof.1.html)

The exact analyst path is also verified from the official [Noble Debian packaging
archive](https://archive.ubuntu.com/ubuntu/pool/main/g/google-perftools/google-perftools_2.15-3build1.debian.tar.xz):
debian/rules line 16 renames usr/bin/pprof to google-pprof, and
debian/google-perftools.install line 1 includes usr/bin. The archive is 8916 bytes;
its SHA256 306e1fd0b9a9deb96312cadbd87a1211fb0b09d10a67ab2bafef76a0deb8aba4
matches the [official source descriptor](https://archive.ubuntu.com/ubuntu/pool/main/g/google-perftools/google-perftools_2.15-3build1.dsc).
This read-only source check is not a verification of future CI binary bytes;
the installed/archive byte gate remains mandatory.

The gate retains the previously reviewed mirror/source/keyring protections:

- No changes to APT sources, trust roots, installed trust permissions or security
  settings. Ordinary authenticated workflow APT update/install/download only;
  HTTP/HTTPS redirects and insecure/weak/downgrade overrides remain prohibited.
- Only fixed mirror+file:/etc/apt/apt-mirrors.txt and fixed Ubuntu Deb822 source.
  O_NOFOLLOW, descriptor walking, ordinary file checks, bounded reads and stable
  identity checks remain. Mirror/source ancestors remain root-owned and protected.
- Only the fixed /usr/share/keyrings/ubuntu-archive-keyring.gpg may use the official
  runner bootstrap's observed writable /usr/share tree. Its path types, metadata,
  package owner, installed ubuntu-keyring identity and installed MD5 byte match
  are recorded. MD5 here is bootstrap consistency, not independent authentication.
- Three approved archive identities must match APT SHA256 metadata, version,
  binary/source package, architecture, component, mirror and authenticated index.
  Every installed /usr regular member available in each verified archive is hashed
  against extracted bytes before using the required tools/header/library.
- The runner never installs or downloads. The workflow supplies those three
  archives and its bounded download log. The CLI is guarded to GitHub CI.

## Independent oracle and explicit fixture changes

Original logical owner sizes remain exactly:

| Cut | Live owner bytes | Blocks | Cumulative author allocations | Cumulative requested bytes |
|---|---:|---:|---:|---:|
| q0.begin | 320 | 2 | 2 | 320 |
| q0.end | 716 | 2 | 5 | 1539 |
| q7.begin | 1010 | 2 | 6 | 2140 |
| q7.end | 1558 | 2 | 8 | 3698 |
| cleanup | 0 | 0 | 8 | 3698 |

The 15 original logical malloc-family calls are unchanged. The eight Heaptrack
marker malloc/free calls are absent in this new fixture. Instead, the same four
quiet cuts call synchronous HeapProfilerDump immediately after copying static
owner-state data. One final cleanup dump is followed by HeapProfilerStop, before
stdio and process teardown, preventing an exit dump from masquerading as a cut.
Exactly five numbered files and matching ordered dump reasons are required.

Each of the eight successful allocation sites now has a distinct noinline,
exported wrapper. This changes stack labels, not the logical sizes/lifetimes.
Fixed non-PIE ELF text extents make attribution exact; nearest-symbol guesses
are forbidden. The fixture emits operation pointers only after it stops profiling,
using integer identities captured while valid. Content preservation, calloc zero
initialization, failed SIZE_MAX realloc with ENOMEM, 503-byte realloc(p,0) returning
NULL, original owner state at every cut and final empty ownership are mandatory.
JSON operations are independently replayed against a separate authored schedule.

The separate Python oracle explicitly requires one cumulative allocation at each
successful allocation/reallocation site. It never learns expected counters from
profiler output. In particular the zero-size site must retain cumulative 1/503
while its live values are 0 after q0.begin. Omitting both its allocation and free
therefore fails even if all live totals happen to match.

All upstream source references below are pinned to the official gperftools-2.15
commit 365060c4213a48adb27f63d5dfad41b3dfbdd62e:

- [tcmalloc.cc L1597–1640](https://github.com/gperftools/gperftools/blob/365060c4213a48adb27f63d5dfad41b3dfbdd62e/src/tcmalloc.cc#L1597): moved realloc invokes New(new,size) then Delete(old); same-address success invokes Delete(old) then New(old,size). Failed allocation returns before either hook. Both successful paths create exactly one new requested-size allocation.
- [tcmalloc.cc L2015–2030](https://github.com/gperftools/gperftools/blob/365060c4213a48adb27f63d5dfad41b3dfbdd62e/src/tcmalloc.cc#L2015): non-NULL pointer with new size zero invokes Delete, frees and returns NULL.
- [heap-profile-table.cc L208–231](https://github.com/gperftools/gperftools/blob/365060c4213a48adb27f63d5dfad41b3dfbdd62e/src/heap-profile-table.cc#L208): allocation counters use requested bytes; frees use the stored request size.
- [heap-profiler.cc](https://github.com/gperftools/gperftools/blob/365060c4213a48adb27f63d5dfad41b3dfbdd62e/src/heap-profiler.cc): four automatic interval flags are zero; Dump holds the profiler lock through write/close. No GetHeapProfile is used, because it performs an ordinary 1 MiB malloc. HEAPPROFILE starts profiling during target startup, including allocations crossing the first boundary. HEAPPROFILESIGNAL is absent, cleanup is 0 with a new isolated prefix, and all mmap modes are 0.

The expected failed SIZE_MAX allocation is not exempted from diagnostic checks.
The fixed [OOM path](https://github.com/gperftools/gperftools/blob/365060c4213a48adb27f63d5dfad41b3dfbdd62e/src/tcmalloc.cc#L1216)
returns NULL with ENOMEM without an error log; [configure.ac L653–660](https://github.com/gperftools/gperftools/blob/365060c4213a48adb27f63d5dfad41b3dfbdd62e/configure.ac#L653)
disables large-allocation reporting by default, and Noble packaging does not
change that setting. [base/logging.h L198–207](https://github.com/gperftools/gperftools/blob/365060c4213a48adb27f63d5dfad41b3dfbdd62e/src/base/logging.h#L198)
emits RAW_VLOG's pattern without a prefix and adds a newline; the exact Dump
announcement checked by the runner comes from heap-profiler.cc's
Dumping heap profile to %s (%s) format. Warnings/errors remain failures.

This synchronous cut is a snapshot of hooks already recorded in this single-thread
fixture; it is not an atomic global suspension facility for a future application.
Profiler-internal guarded allocations, direct mmap/private pools/GPU resources
and retaining-owner graphs are outside this contract.

## Completeness, symbols and independent official integer analysis

Every .heap file must be a complete newline-terminated ASCII heapprofile with
well-formed buckets and complete executable maps, below the actual upstream
1 MiB buffer capacity. All four bucket sums must equal all four header integers:
live objects, live bytes, cumulative objects, cumulative bytes. This is necessary
because upstream FillOrderedProfile may omit tail buckets to preserve maps when
its fixed buffer fills. A live-only check would miss omitted freed buckets.
Malformed lines, missing mappings, unknown necessary author stacks, missing exact
symbol extents, duplicate stacks, negative/overflow counters and any mismatch stop
the preflight. It never enlarges or patches the upstream buffer.

Every file-backed executable mapping is retained with SHA256, inode and ELF build
ID, along with the fixture binary, source, symbols and all five maps. The profile
format deliberately reports device 00:00, so that synthetic device field is not
misrepresented as identity evidence. Kernel vdso/vsyscall maps are retained in the
original text; required author frames must resolve to the exact fixture ELF.
Runtime frames need not all have function names and are not assigned product owners.

For all five dumps, the unchanged official google-pprof is invoked separately with
--raw --inuse_space and --raw --inuse_objects. Both whole-profile exact integer
totals and every required authored-site value must match independently parsed
heap data and the oracle. No top-N, focus, ignore, rounded MB, sampled-profile
scaling, or filtered display totals are used.

Official --raw is **text symbols followed by packed 64-bit little-endian records**,
not text heap rows. pprof_raw.py validates the binary identity, symbol section,
exact five-word header, every count/depth/PC record, bounds and full EOF. It keeps
zero values and sums duplicate stacks with integer arithmetic. A clean EOF is the
actual local writer's terminator; a partial word/record fails. Since that format
has no record count, EOF alone cannot detect deletion of whole final records; the
independent original heap totals and required authored historical-stack presence
supply the relevant cross-check. We do not claim every incidental runtime stack is
unchanged: upstream intentionally adjusts caller PCs and drops allocator frames.

Relevant pinned [pprof source](https://github.com/gperftools/gperftools/blob/365060c4213a48adb27f63d5dfad41b3dfbdd62e/src/pprof):

- PrintProfileData L1117–1163 writes all nonempty stack keys, including zero counts;
  PrintSymbolizedProfile L1166–1206 writes text symbols followed by binary records.
- ReadHeapProfile L4177 accepts zero counts; L4215–4218 calls AddEntries unconditionally.
  AddEntries L3304–3316 calls AddEntry L3292–3299, which retains keys even for zero.
  Thus every historically allocated author stack, including 503 bytes and final
  zero-live stacks, must still be present and officially symbolized.
- FixCallerAddresses L3934–3958 keeps the first PC and subtracts one from callers;
  RemoveUninterestingFrames L2959–3105 removes allocator frames and merges stacks.
  A required author wrapper may not disappear or remain unresolved.
- --version reports the script's own literal version 2.0, not the release version
  2.15. Package/source/installed byte identity is the version gate; --help verifies
  required raw/in-use flags.

## Bounds and execution

Inherited bounds: one profiled target, <=10 seconds, <=32 authored operations;
this fixture uses 15. Original 16 MiB trace budget becomes an aggregate profile
budget, with a stricter <1 MiB per actual upstream dump. Record bound remains
64 KiB; analysis files and child RLIMIT_FSIZE remain 64 MiB, command logs 2 MiB,
whole preflight 650 seconds. Each of the five analyses has at most 120 seconds
for both integer modes together and shares the same whole-preflight deadline.
No core dumps. Offline tests and the C stub are not profiler evidence.

Each command starts in its own process group. The leader remains unreaped while
TERM then KILL are sent only to that owned group; cleanup is verified afterward,
without signaling a potentially reused PID after reaping. Timeout and output caps
are checked during execution and again after fast exits. Compiler, package tools,
analyst and Python driver receive a clean environment without preload/profile
variables. Only the single native target receives the explicit profiler variables.

Offline checks (no APT, profiler, Flutter, Dart or WLD):

```
python3 -m unittest discover -s tool/perf/gperftools_preflight -p 'test_*.py' -v
cc -std=c11 -O2 -g -Wall -Wextra -Werror \
  -fno-builtin-malloc -fno-builtin-free -fno-builtin-calloc -fno-builtin-realloc \
  -fno-pie -no-pie -fno-optimize-sibling-calls -rdynamic -DGPERFTOOLS_OFFLINE \
  tool/perf/gperftools_preflight/native_contract.c -o /tmp/gperftools-offline
```

The offline define stubs the profiler API only. The normal CI reader rejects its
metadata; it cannot make a profiler contract pass. CI alone runs the ordinary
build linked to the verified full library:

```
python3 tool/perf/gperftools_preflight/run_preflight.py \
  --output build/gperftools-preflight --deb-dir build/gperftools-packages \
  --apt-download-log build/gperftools-preflight-evidence/apt-download.log
```

The output directory must be new. source-manifest.json freezes the reviewed source
files before the CLI runs. The runtime manifest preserves every command, package
provenance, owned-group cleanup, binary/module/source hashes, captured profiles,
fixture JSON, accounting and official comparisons. A failure remains failed-closed;
no retry or promotion to real sampling is implemented. Publication belongs to the
separate authorized publisher after review of this frozen source manifest.
