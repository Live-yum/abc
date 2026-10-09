# Capability and public evidence matrix

Snapshot: 2026-10-09 UTC. “Implemented” identifies a reachable code path with
bounded evidence, not complete upstream parity or target-device certification.
This document publishes only source-level capabilities, public synthetic tests,
the public Computerraria world and public CI results. Additional local real-input
validation exists; its private sample details and measurements are not disclosed
here. Personal saves, private validation reports, resource atlases, game binaries
and credentials are excluded from the public deliverable.

The current implementation is **WLD only**. Companion-file parsing, remapping,
paired import/export and pairing records are removed. OFF keeps game-rule
PixelBox crossings; ON uses the documented WireHead-style group-pair rule to
operate the public world's 3,072 monochrome pixels. OFF executes the physical
CPU but does not display Pong in this world. Neither path substitutes a host CPU
interpreter. The latest query optimization preserves both modes' behavior.

| Prototype area | Implemented locally | Evidence | Remaining work / limitation |
|---|---|---|---|
| World archive/viewer | Actual WLD import, metadata, map PNG, pan/zoom/coordinates, persistent styled item/entity markers with frame selectors, bounded viewport wire/liquid overlays, separate export | Public synthetic Native/Web contracts and earlier synthetic browser flows; additional real-input validation remains local | Overlay data covers the explicitly loaded viewport, at most 262,144 cells; final UI browser pass, target-device and in-game validation remain |
| Binary exploration MAP | Legacy 135–319 and chunked 315 decode, grayscale exploration-light preview, bounded light/paint edits, undo/redo, checked export and WLD-generated MAP; native isolate/Web worker ownership | Public synthetic protocol fixtures and owner/lifecycle contracts; see [MAP support](MAP_FORMAT.md) | No user-supplied/materialized real exploration MAP has been validated. Generated fully explored MAPs do not prove original exploration progress or game palette fidelity; browser/device interaction remains unverified |
| World edits | Typed searchable progression/time/weather/basic header properties, spawn, chest slot/name/prefix editing, organize/clear and catalog-backed reforge; transactional candidate validation and undo/redo | Public synthetic Native/WASM header/chest edits and saved candidate/reopen; Workspace original preservation and exact undo/redo | Unknown/structural and unsupported version-specific fields remain read-only; exhaustive historical section fixtures remain |
| Pixel workshop | Image decode budgets, drawing/fill/erase, grouped undo, PNG/project, authoritative RGB mapping | Domain/widget tests; actual core matching and safe pixel-write contracts | Matching resources must be imported; rendered appearance does not reproduce every game shader or paint effect |
| Player laboratory | PLR open/create, stats/colors, inventory/equipment/loadouts, slot copy/paste and confirmed scoped best-prefix batches, buffs, research/Journey; reviewed version projection | Native/Web PLR round trips; native application conversion confirmation, stale-source rejection and undo | Only imported verified target profiles can be used; historical downgrade profiles incomplete; all-version in-game validation absent |
| Circuit laboratory | Authoritative retained JavaScript editor/rules, 2,776 palette entries, 15 demos, properties/styles, clipboard transforms, bounded route/network preview-confirm-cancel, actual native traversal and Web worker; separate whole-world TCW trigger/step/run/save plus complete Computerraria WLD, physical Pong ROM/input/display, WLD export/resume and default-off optimization | 15-demo source/Web/native-transport parity: 1,180 packets and 12 structural changes; real embedded-native replay of a bounded 244-case corpus; 10 Web lifecycle tests; whole-world Native/Web timer/save/reopen; final pure-WLD Native/Node OFF/ON acceptance and Node ON continuation passed: OFF physical CPU, ON real monochrome Pong; one fresh process per backend/mode | Plans are limited to 60,000 cells and use unchanged reference routing/topology. OFF's game-rule PixelBoxes do not display Pong in this WLD. Exact a561 pure-WLD Chrome loads passed in three fresh processes; fresh ON Pong, UP/DOWN controls and a 3,072-pixel screenshot/native replay match are verified. A separate reset crashed Chrome with Error 9, and close retained WASM capacity; replacement-worker repair still requires browser verification. Node ON continuation is separately verified. Other current circuit-editor browser flows, Android/iOS/macOS complete-world execution and complete game behavior remain unverified |
| Fusion canvas | All-layer region records, eight grouped continuous brushes, original-atlas static preview, complete object copy/paste, catalog-backed furniture placement/variants and display contents; 18 companion-bearing tile families / 11 tile-entity schemas | Public synthetic Native/Web placement and payload read-back, collision/stale-source rejection and exact undo; TCW command-8 tile/COB1 extraction matches across Native/WASM | Structural edits require verified geometry and complete objects. Unknown supports/frames/alternates stay blocked. Neighbor framing, paint, lighting and dynamic appearance remain approximate; browser interaction for this batch remains unverified |
| World generation | Source-verified options/schema, submit/poll/cancel/retry routes, bounded forms and uncertain-submission guard | In-process HTTP/schema/UI contracts | No verified portable initial MEMBER login, supported live session or actual options/job/result validation |
| Write into world | Pixel→region→WLD merge, Dirt0, wall/foreground/clear modes, bounds/collision checks, original retained; separate validated complete-object insertion | Native/Web byte-level layer preservation and application read-back/undo | Arbitrary framed structural replacement remains blocked; every reference switch/mapping combination has not been compared |
| Save center | Persistent binary vault/history/trash, source-verified authenticated private downloads and multipart uploads, generated WLD upload preview, recommendation likes/ticket-download/count receipts/transfers, durable adoption and account/service-scoped recovery journals | Native vault recovery and application history; synthetic reference HTTP, durable adoption, cancellation, retry/account-isolation and reachable UI contracts | Supported initial account login and live transfers remain unmet. Optional player equipment preview generation is not provided; backend new uploads require a WeChat-linked MEMBER. No permanent purge |
| Encyclopedias/achievements | Imported catalog search/icons; typed bestiary counts/toggles/known unlock; numeric/boolean achievement editing, verified catalog creation and known-condition batch completion | Domain/widget/application tests and native bestiary read-back/undo; encrypted BSON reopen | Catalog contents external; unknown achievements and composite NPC trackers are retained without guessing rules |
| Mapping rules | Manual tile/wall mappings, reviewed atomic environment-rule conversion in Fusion, whole-world typed where/patch/limit rules, four core biome modes, 23 imported editable original presets, persistent named/default scheme libraries, authoritative stable RGB candidates/filters | Native/WASM whole-world candidates/read-back/undo and stale-preview rejection; provenance-bound preset import, independent editable clone and named-library persistence tests | Imported literal presets are distinct from the four opaque native biome modes; matching labels do not prove equal conversion semantics. Broad historical and all-environment comparison remain |
| Account/system | Source-verified profile nickname/avatar editor, explicit avatar loading, bounded remote-help viewer, manifest-pinned online resource installer with native/IndexedDB cache, atomic activation/recovery and revocation guards | Synthetic account/help/UI contracts, resource HTTP/integrity/storage/recovery tests and fake-fetch/IndexedDB contracts | No supported portable initial login or live service/content validation. Help is sanitized plain text, not full rich-text rendering. Online normalization omits unverified supplemental catalogs/atlases/profiles; offline cache knows only the last durable revocation state |
| Web computation ownership | Dedicated workers for WLD/PLR document operations, generated MAP, TCW and legacy traversal, alongside separate region/rules/MAP owners; bounded serialized RPC with transfer, timeout/cancel/dispose and stale-handle rejection | Worker lifecycle contracts and actual WASM bootstrap through Node workers; see [ownership contract](web-computation-workers.md) | Node event-loop and direct-WASM evidence does not establish real browser frames, Flutter UI smoothness or target-device performance |

## Public full-world loading evidence

For the original 405,983,441-byte public Computerraria WLD, three fresh
standalone Native C processes per variant reduced median load/compile time from
17.654 to 9.664 seconds. This earlier isolated optimization preserves compiled
topology and uses no persistent compiled cache. It does not measure Flutter or
browser readiness, and OS page cache was uncontrolled.

The subsequent identified C-hash host build measured Native imports of
12.695 / 12.983 seconds in OFF/ON and Node WASM imports of 17.907 / 17.449 seconds.
These are one process per backend and mode. The old/new deterministic state
projections and saved-WLD reopen match, and owned engine/storage/file counts
return to zero. They are host-specific observations, not statistical speedup
claims or UI timings. See the [public artifact-bound host comparison](evidence/host-wld-regression-2026-10-09.json).

The final sparse lamp-query candidate uses existing checkpoints to skip columns
with no requested point. The four initialization anchors replay 76 columns
instead of 12,325; one Native query-only comparison measured 3.402 seconds versus
0.0197 seconds, with identical output records and all physical-state statistics.
The Native and Node ON full CPU/Pong/save/reopen projections match the prior
version. A checked-in sequential oracle and bounded cancellation contracts make
this reproducible from a clean checkout. This is neither total browser loading
time nor a steady-state display FPS improvement. See [the method](sparse-lamp-queries.md)
and [public query evidence](evidence/sparse-lamp-query-2026-10-09.json).

## Public browser baseline and remaining repair checks

The exact a5612b4 CI release artifact loaded the public WLD in three fresh cloud
Chrome processes. Hash start to final monochrome initialization took
41.050 / 41.944 / 38.646 seconds. It excludes the chooser and is not the first
presented frame. The owned Chrome process-tree PSS peaks were
680.816 / 689.459 / 690.667 MiB, with at most a 268.285 MiB increase over the
corresponding baseline. Renderer RSS and WASM capacity overlap those measurements
and must not be added to them.

Fresh ON Pong and UP/DOWN input worked. All 3,072 binary pixels in one paused
25,728-pulse screenshot match an independent physical native replay. This is
correctness evidence, not FPS. A separate reset crashed Chrome with Error 9;
OOM was not established as its cause. Close freed active engine allocations and
scratch storage but retained the old worker's WASM capacity. The new safe worker
retirement, output-release retries and reset/cancellation guards require fresh
browser validation on the final artifact. See the [public browser evidence](evidence/browser-pure-wld-baseline-2026-10-09.json).

## Public CI and synthetic UI performance

At head 9bb73baeaeacd296ccdd64c58753f449d1398cde, all five functional platform
jobs passed, including Web, Android, Linux, macOS and unsigned iOS compilation.
The Flutter test job reported 672 passed and 32 skipped. All eight new Workspace
output-release/cancellation cases actually executed and passed. Of the skipped
cases, 18 ran in the same-head Native job. Ten external-resource cases and one
VM-service-specific lifecycle case were not executed in that campaign; three
opt-in performance suites have separate jobs. Final source changes still require
their own exact-head CI. Local Workspace compiler exits are retained as failed
attempts, not reclassified as successful runs.

The a5612b4 general performance campaign completed five independent Linux
profile processes, each with two warmup and eight measured lifecycles, covering
152 UI operation kinds and 102 controller variants on public synthetic inputs.
With llvmpipe, measured raster-work medians were 24.316–25.423 ms and p95 values
41.425–43.902 ms. These are real FrameTiming durations, not inferred FPS. The
reported display refresh was zero, so device refresh calibration is unavailable.
After-close RSS ranged 721.5–800.4 MiB and requested-GC Dart heaps 38.7–43.4 MiB.
The harness retains growing raw measurements; these samples alone establish
neither a leak nor long-term memory stability. See the [public five-process evidence](evidence/general-ui-baseline-2026-10-09.json).

That first campaign had no selected comparison baseline and remained
**inconclusive** for regression acceptance despite successful workloads. New
performance runs explicitly select the verified a5612b4 run, validate run/report
identity, and retain environmental mismatches or failures. Headless zero-refresh
reports do not establish target-device fluency. Android/iOS/macOS runtime,
signed distribution, physical-device performance and in-game read-back remain
unverified by compile-only results.

## Remaining migration boundaries

- Live account access, portable initial login, real cloud transfers and generation jobs need a supported backend session and live validation. Synthetic HTTP contracts do not establish those outcomes.
- Catalogs, textures and supported target profiles remain external inputs. The public repository does not redistribute game artwork or personal saves.
- Historical format coverage, unknown structural fields, neighbor framing, lighting and complete game wiring behavior remain bounded as listed above.
- A fresh browser pass for every editor, actual OS file chooser/share behavior, real exploration MAP progress and physical-device performance remain separate acceptance layers.
- The PR remains draft and unmerged. Public source authorization does not create an upstream license grant. Original attribution and exact source/runtime closures remain in the third-party notices and integrity manifests.

Read-only reference pins: viewer 366ebc57751cadfb077f968f4d5069028b3bf9a6 and
TerraWasm e2c3c817b2b482a535763695d19945971e19e41c, plus documented local patches.
See [third-party notices](../THIRD_PARTY_NOTICES.md), [platform build scope](platform-builds.md)
and the public contracts linked in the table. Native/WASM read-back, actual
browser interaction, target-device operation and in-game compatibility are
separate forms of evidence.
