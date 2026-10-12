# Batched circuit reader: bounded Native loading improvement

The streamed circuit compiler now binds its existing read window once per bounded decode block instead of temporarily rebinding the world for each RLE record. The original decoder still runs for every record. Original validation, cursor/error ordering, work accounting, timer ordering and READ/yield/cancel boundaries remain unchanged. This adds no heap allocation, retained cache or scratch I/O.

## Local evidence

One pre-registered BAABBA sequence used six fresh processes, each loading, querying and closing the same original public Computerraria WLD twice. All twelve observations were retained. The input is 405,983,441 bytes, pinned in the adjacent JSON. Every load was preceded by hashing, so “first” means first in a new process, not cold disk. Engine limit: 192 MiB; work: 4096; aggregate deadline: 600 seconds; actual elapsed: 125.313 seconds. No ROM/program execution or save is included.

Baseline is exact `9d4cd5a0f9db03042a3986689fea374ba92d78b8`; candidate changes only the three source files identified in [the complete measurements](BATCHED_READER_PROFILE.json). Both use direct GCC 14.2.0 builds with the same flags derived from the pinned CMake configuration. These are not formal Flutter or Web builds. The JSON records the exact source/binary/controller/pins and original-report SHA-256 identities. Its `product` A/B identifies the actual baseline/candidate library; `load.mode` is A for both because both disable internal diagnostic hooks and callback clocks.

| Process | Variant | First wall / CPU (s) | Reopen wall / CPU (s) |
|---|---|---|---|
| 1 | B | 9.403375952 / 9.396990467 | 9.417219972 / 9.415470695 |
| 2 | A | 9.810287178 / 9.806643073 | 9.924518883 / 9.916572271 |
| 3 | A | 9.553342446 / 9.550904058 | 10.427072960 / 10.425377462 |
| 4 | B | 9.268884713 / 9.268112983 | 9.383786119 / 9.382911615 |
| 5 | B | 8.979620206 / 8.978868607 | 9.190054503 / 9.187864844 |
| 6 | A | 9.458287511 / 9.457486759 | 9.732707252 / 9.731702171 |

Adjacent pairs are B1/A2, B4/A3, B5/A6. First-load wall improvements are 4.147801%, 2.977573%, 5.060824%; median **4.147801%**. Reopen improvements are 5.111572%, 10.005558%, 5.575558%; median **5.575558%**. All pairs improve and both class medians exceed the fixed 3% adoption threshold. The single 2.977573% pair is retained; the threshold applies to each class median, not every pair. Both raw CPU median gates pass.

Absolute wall medians are **9.553342446 → 9.268884713 seconds** for first load and **9.924518883 → 9.383786119 seconds** for reopen. The ratio of those medians is a different statistic from the median of adjacent paired improvements above.

All 24 engine stats, 162,939 step calls, eight I/O count/byte ledgers, query hashes and FD restoration match across all twelve loads. The input is unmodified. Independent review verified the raw values, host/source/library pins and that only the compile/world vendor objects differ.

## Memory and correctness limits

Engine active/peak allocation is identical: **120.825739 / 138.978525 MiB**. Every cycle restores FD counts 3 → 5 → 3. Absolute candidate ready/closed RSS/PSS/USS medians are 0.054688 MiB higher; adjacent pair signs are mixed, so no consistent candidate-specific OS-memory regression was demonstrated. Both variants retain exactly **2.058594 MiB** more RSS/PSS/USS after the second close than at that cycle’s baseline. This does not solve or explain previously observed long-run Flutter memory growth.

All 36 baseline/ready/closed boundaries are in the JSON. They are point samples, not continuous peaks. `ru_maxrss` is cumulative over the entire process, including work outside load timing. All six reopen smaps RSS readings exceed their separately read HWM by 0.054688–0.304688 MiB. Both original readings remain intact; their precise discrepancy is unresolved and they must not be treated as one interchangeable exact peak. Closed engine allocation is unavailable/null after handle destruction, not measured zero.

The independent differential exercises 98 complete compiles, 196 viewport queries across both optimization modes, four interrupted compiles and forty edge cases. It covers rich tile properties, timers absent/present/dense, budgets 1/4096, 31/32-byte readiness, actual 1 MiB input tails, malformed/truncated records, RLE bounds, metadata aliases and restoration after external boundaries. Release and ASan/UBSan match digest `4fb5af0d3cede802`. Six existing Native contracts pass in both build modes. Local LeakSanitizer was unavailable under ptrace; no leak-check pass is claimed.

Formal CMake/WASM/Flutter and target-device validation remain separate. This local comparison establishes a bounded Native loading improvement on one input and host; it does not establish Flutter loading speed, true-device frame rate, complete game semantics, or absence of leaks. Previous failed performance and memory acceptance remain unchanged.
