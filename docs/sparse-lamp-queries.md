# Sparse lamp queries

Cold, uncached `READ_LAMPS` queries use the existing 64-column checkpoints to avoid replaying complete intervals that contain no requested points. At a completed-column boundary, the query restores the next point's checkpoint only when it is strictly ahead of the next sequential column. It immediately exhausts the current work budget and yields, so the host can cancel before the next source read. Points retain their original output index, including unsorted requests and duplicates. Cached lamp reads and the indexed `PIXELS` display path already avoid this replay; this change makes no claim about steady-state Pong display FPS.

This is an equivalent query optimization in both circuit modes. It does not change the user's PixelBox optimization setting. The complete input is still parsed and validated during import; source identity and hashing remain unchanged. Viewport, lamp writes, triggers, physical VM execution, save scans and unsupported legacy-world checks retain their existing paths.

## Reproducible differential contract

After building the native library, run:

```sh
python3 tool/test_sparse_lamp_queries.py \
  --library build/native-release/libabc_engine.so \
  --compare-sequential --expect-checkpoint-jump \
  --output build/sparse-lamp-query-contract.json
```

The CI native job runs this command. The runner copies the current native source into a temporary directory and substitutes only `cx_query_step` with the checked-in sequential driver in `native/fixtures/sparse-lamp-sequential-query.inc`, then builds a separate Release oracle library. That driver is frozen from the verified v8 source; its attribution and source hash are recorded in the fixture. The product has no test oracle or slower query mode. A fresh checkout needs only Python, CMake, a C compiler and zlib; no previous binary or external world is needed.

The candidate and oracle run in separate processes against original synthetic format fixtures. Exact output comparisons cover unsorted points, repeated coordinates, multiple rows in one column, points within one checkpoint, boundaries, standard/general gates, routed wire frontiers, retained and streamed sources, and work budgets 1, 7 and 4096. RLE and individual-record encodings must agree. The test also covers invalid bounds/reserved fields, cached rereads, writes, physical triggers, viewport results, save/reopen and a synthetic version-1 legacy file that parses but rejects circuit simulation.

Candidate-specific checks require an actual skip within fewer than 400 work=1 steps and exercise cancellation before the jump, after restoration, during a pending source read, and before result acknowledgement. Pending events remain stable until supplied/acknowledged, stale supply is rejected after cancellation, state counters are preserved and a fresh command succeeds. Builds exposing allocation counters must return to zero after close.

## Public full-world measurements

The original public Computerraria WLD is 405,983,441 bytes, SHA-256 `55d0a24bd1f56d622003dbd30d52555e7d06d6d1bcacfc22ae506f2db5240c33`. The exact initialization request is `(2853,1236), (15140,4249), (2853,4287), (2854,4287)` in that order.

A same-configuration native Release comparison observed:

| Query-only measurement | Frozen sequential engine | Checkpoint query |
| --- | ---: | ---: |
| Columns replayed | 12,325 | 76 |
| Source READ requests | 388 | 3 |
| Source READ bytes | 405,811,366 | 2,213,188 |
| Bounded engine calls through the Python test host | 125,573 | 736 |
| Query wall time | 3.402 s | 0.0197 s |

This is one local query measurement through Python/ctypes into the native engine. It includes that host's dispatch overhead and is not a Flutter/browser load-time result. The column reduction is not an end-to-end time percentage. Both builds use GCC 14.2.0, Release `-O3 -DNDEBUG` and `ABC_PERF_COUNTERS=ON`. All four output records and all 24 world-stat words match exactly, including live/peak allocations and physical counters.

The candidate's full native ON acceptance also passes the original WLD's 48 physical CPU signatures, the ROM negative control, all 23 input probes, moving Pong with its changing physical RAM trace, idle mode switching, complete save/reopen and subsequent physical execution. Its complete deterministic projection matches the previously verified v8 run, including identical saved WLD, RAM and display hashes. The test uses public program fixtures; no host-side CPU interpreter is substituted.

Both Web engine profiles were rebuilt with pinned Emscripten 5.0.7. The full Node WASM ON acceptance, including actual compound RPC, also passes and exactly matches v8's complete deterministic projection. The candidate's Native/Web same-mode projection agrees. These tests verify the physical engine and protocol, not browser scheduling or UI timing. Native allocations, Web bridge storage and open owned files all return to zero. The source-closure, cumulative-patch replay and generated-artifact provenance checks pass.
