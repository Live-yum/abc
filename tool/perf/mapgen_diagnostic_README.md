# Additional MAP generation causal diagnostic

This is a prepared, separately triggered experiment for the existing same-runner MAP
generation regression. It is not current-head product acceptance. It preserves
the previous observations and leaves the other five environment-mismatched
suites inconclusive and new workloads uncompared. Do not pool these results
with the original paired run or pool auxiliary observations with frozen reports.

## Static findings and falsifiable questions

The baseline and candidate MAP implementation, marker/parser code, synthetic
fixture generator and `generate_native_map.py` are byte-identical. The compiled
native inputs that changed are the SHA facade additions in `abc_engine.c/.h`
and the sparse query implementation in `terra_circuit_query.c`. The changed
`native_contract.c` test is not compiled into `libabc_engine.so`.

No concrete uninitialized-data defect was found in the marked call path:

- `native/vendor/TerraWasm/src/terra_ops.c:245` clears each marker and assigns
  `icon_id=-1`, `frame_x=frame_y=-1`. The fixed request sets type 1, magenta,
  radius 2; omitted `locate` is zero and default line width is 3.
- `terra_map.c:1132` selects legacy active-tile recoloring. Radius and line width
  do not add circles or alter its workload. `terra_markers.c:40` returns without
  entity scanning because no entity selector is enabled.
- The omitted trailing field of the aggregate at `terra_map.c:1917` is zero by
  C aggregate-initialization rules; the following loop sets the paint count to
  one. It is not an indeterminate field.
- Fresh worlds (`terra_api.c:387`), decoded tiles (`terra_wld.c:831`), strip
  buffers (`terra_map.c:831`), color-cache count (`:1489`), chunk tables (`:1742`)
  and per-chunk compression hash heads (`:191`) are initialized before use.
- The 512x256 checkerboard generator produces 65,536 active type-1 tiles and no
  chests. The expected marked response is `matched_tile_count=65536`,
  `matched_chest_count=0`, width 512, height 256 and `file_written=false`.
  These are static expectations, not newly observed runtime results.
- `terra_ops.c:642` already returns counts, dimensions and `map_bytes`.
  The original harness discards this response and hashes only the final lit
  output. `terra_api.c:1180` serves the second probe/copy operation call from an
  exact response cache; a third operation call would regenerate, so the probe
  retains the original response instead of invoking the operation again.

Every cycle opens a new world, runs lit followed by marked, checks source-save
preservation and closes it. “Warm” is later process cycles, not a reused world.
The cold median and p95 each describe the same single sample. The original
observed slow candidate marked process was slow across all 26 cycles; the new
diagnostic never drops that observation or any new slow sample.

The four variants test which changed compiled input follows the slowdown:

| Variant | Source identity | Change from A |
| --- | --- | --- |
| A | a5612b474fc8dc50d41b3bc6b87234d30ba97e02 | None |
| A_SHA | A plus a recorded patch and distinct local derived commit | Candidate `native/abc_engine.c` and `.h` |
| A_QUERY | A plus a recorded patch and distinct local derived commit | Candidate `native/vendor/TerraWasm/src/terra_circuit_query.c` |
| B | cddd936f95d31b14a76503e13ffc89173110a057 | Full candidate product |

The full expected trees are fixed in `mapgen_diagnostic_contract.py`. Derived
trees were calculated from A's tracked Git blobs with only the named B blobs
substituted. At runtime the script checks those trees and creates deterministic
local commits with A as parent. It records base pin, patch, changed paths, tree,
derived commit and file hashes. It never calls a remote write or publishes the
derived commits.

Possible outcomes:

1. SHA-only follows B: inspect the newly linked hash object and moved functions,
   tables and sections. MAP does not call SHA, so do not claim SHA computation
   consumed the measured time.
2. Query-only follows B: inspect that object and its link-layout effects. The
   measured MAP path does not call the circuit query operation.
3. Only B follows the slowdown: inspect the combined layout interaction and
   actual compile/link archives before attributing a cause.
4. Counts or output bytes differ: investigate determinism or workload changes
   before explaining a timing-only regression. Equal output does not prove
   identical internal allocation/fallback work.
5. No repeat separates: the original regression remains unexplained. Compare
   process addresses, CPU versus wall time, faults and context switches. Do not
   interpret this as a fix or proof of equivalence.

## Protocol and evidence

All four products build sequentially on one Linux job before measurement. Each
group uses the fixed order below, chosen before observing new results:

`A, A_SHA, A_QUERY, B; B, A_QUERY, A_SHA, A; A_SHA, A, B, A_QUERY`.

There are two separate groups, each with three independent processes per
variant, 12 processes per group, 24 total:

- `raw/frozen`: the exact original `generate_native_map.py` and `run_ci_suite.py`
  at their verified SHA-256 hashes, with 26 cycles (one cold, 25 warm). The
  original comparator is unchanged and compares A against each other variant
  using only these reports. Real derived commits appear in derived reports.
- `raw/auxiliary`: a clearly labeled observer with a different report schema.
  It uses the same open/lit/marked/save/close sequence and fixed requests. Each
  operation records wall and process CPU time, user/system CPU, minor/major
  faults, voluntary/involuntary context switches, output size/hash, original
  response size/hash/full small JSON, API-provided counts and dimensions.
  Hashing, response parsing and all journaling happen after the wall timer.
  Their allocations, resource calls and writes can affect subsequent calls;
  auxiliary timing is therefore ineligible for frozen comparison.

The auxiliary process preserves an append-only cycle journal and a final report,
actual distinct MAP/response bytes addressed by hash, and `/proc/self/maps` for
actual library addresses. It consumes the existing two-call native response;
there is no extra generating operation. On errors it retains the partial report
and journal. The validator refuses incomplete, failed or reordered evidence and
checks the expected marked counts without deleting mismatches.

For every variant, `variants/<name>/` retains:

- actual `libabc_engine.so`, all compiled `.o` and `.a` files;
- `compile_commands.json`, all `flags.make`, `link.txt`, `build.make`, CMake
  cache, linker map and the full verbose configure/build commands and logs;
- symbol table, ELF layout and disassembly;
- original/derived source identity, exact patch and artifact hashes.

The C build remains Release with `ABC_PERF_COUNTERS=ON`. Additional options
export compile commands and a GNU linker map, and verbose mode records actual
commands. These are explicitly recorded diagnostic build options. No product
source, optimization threshold, frozen harness or comparator is modified.
All libraries are separate builds; original A/B builds are not substituted
with cached earlier binaries. The experiment needs CMake, GCC/binutils, zlib
development headers and Python. Node, Dart, Flutter and Emscripten are unused.

The session records workflow commit/tree, all harness bytes and their archives,
CPU/kernel/image/boot/runner identity, compiler/linker/libc/CMake/Python versions,
the selected build environment variables and the fixed synthetic fixture hash.
Before/after snapshots bind each process to its exact source and loaded library.
The archived auxiliary source is the executed source. No personal input or
private fixture environment is inherited.

## Running after review

The new `.github/workflows/performance-mapgen-diagnostic.yml` runs on a same-repo
PR when this workflow or its Python diagnostic files change, and also supports
`workflow_dispatch`. Its first PR addition can run without merging into the
default branch. A five-minute scope job checks the actual synchronize event's
`before` to head diff, rather than the cumulative PR diff: later unrelated
pushes skip the heavy job. README-only edits do not retrigger it. Publication
must therefore be coordinated before pushing, since the first relevant PR push
starts this additional experiment.
It uses the repository's existing pinned official checkout/upload actions,
`contents: read`, no persisted checkout credentials, and no automatic
cancellation. It does not modify an existing workflow or gate.

The scope job cap is 5 minutes and the measurement job cap is 60 minutes (65
minutes sequential CI ceiling). Setup is capped at 10 minutes, lightweight tests at
2 minutes, final validation at 10 minutes, upload at 5 minutes. All builds and
measurements share a 30-minute wall budget; individual build commands are
capped at the lesser of 1,800 seconds or remaining budget. A fresh measured
process starts only if its full 600-second timeout plus 30-second cleanup
reserve fits. An exhausted budget records remaining slots as unstarted, fails
validation and preserves earlier evidence. It does not pretend to complete
the required three repeats. A stuck outer driver is not killed independently
of its child; the frozen driver owns timeout/reaping. An incomplete child
record stops all later timed processes. A hard job cancellation or infrastructure
loss can still interrupt artifact upload.

The previous paired MAP job observed six measurement sections of roughly
0.26–0.31 seconds each. Its per-pin setup/build sections included unrelated
Flutter/Node preparation, so they are not a reliable runtime estimate for this
C-only four-build workflow. The limits above are ceilings, not predicted cost.

For local preparation checks only:

```sh
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tool/perf -p 'mapgen_diagnostic_test.py' -v
```

After explicit execution approval, the workflow supplies clean fixed checkouts
and calls `mapgen_diagnostic_runner.py prepare`, then `run`, followed by
`mapgen_diagnostic_validate.py`. Each invocation uses fresh work/evidence
directories; retries may never overwrite old attempts. Artifact uploads include
only the evidence directory, not cloned worktrees or their Git databases.

Only lightweight logic, synthetic Git identity tests and YAML/shell checks were
run while preparing this patch. No product build, native benchmark, GitHub
write or workflow dispatch was performed.
