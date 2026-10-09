# Approved online resources

The Flutter resource installer implements the public browser contract in the
provided viewer source: `infrastructure/assets/{authority,protocol,transport,
resource-manager,install-recovery,platform-store}.mjs`. It uses original Dart
adapters and synthetic fixtures. No game assets or credentials are included.

Configure `TERRAFORGE_RESOURCE_ORIGIN` explicitly with a trusted HTTPS API base.
There is no live-service default, automatic network check, account login, or
WeChat `download-link` flow. The application reaches the installer from
资料图鉴 → 线上资源. Initialization restores local verified data without a request.

## Protocol and trust

1. Read `/viewer/resources/approval-state`, validate the canonical state digest,
   authority ID, stable channel, exact decimal sequence and cumulative sorted
   revocations. Persist two approval records and the authority root before use.
2. Fetch `/viewer/resources/file?path=releases/<sha>.json&manifestSha256=<sha>`.
   The approval pins the complete manifest SHA-256 and game version.
3. Fetch its objects through the same `file` endpoint, always with that manifest
   digest. Check the wire digest and exact size before bounded gzip decoding;
   validate decoded size, CRC, JSON shape, row counts and binary headers.
4. Download manifest-listed catalog icons, checking their digest, exact size,
   PNG signature, IHDR and declared dimensions. Re-read persisted bytes before
   activation. No archive is extracted onto the filesystem.
5. Re-read approval immediately before atomically replacing the active pointer.
   A failed or paused attempt leaves the prior active pack unchanged. Revocation
   or a failed authority write makes held online-resource consumers unusable.

The endpoint is the trust anchor. State hashes establish integrity and identity,
not an independent publisher signature. Offline restoration enforces the last
durable approval and revocations; it cannot discover later server revocations
without a user-initiated check. Transient authority-write failures can be retried
with a valid non-replayed state. A corrupt high-water ledger fails closed.

HTTP requests omit account credentials, disable redirects, and have a 30-second
deadline and streamed byte cap. JSON control documents are bounded to 1 MiB
(approval) and 2 MiB (manifest); object and decoded sizes are capped at 128 MiB.
The same bounded Dart gzip decoder is used on native and Web. Existing locked
`archive` 4.3.0 is promoted to a direct dependency; no dependency version changed.
Web uses a small public-only fetch client with `credentials: omit`, including
same-origin requests; `http`'s default BrowserClient would use `same-origin`.

## Normalization is a distinct format

The server manifest is not an ABCPACK1. The installer creates a separate
`ABCPACK1-public-v1` normalization, then validates it with `ResourceStore`.
Its provenance records the exact manifest, authority and endpoint. It does not
grant rights to redistribute the downloaded data.

- Manifest row families retain their source IDs and fields.
- `item-index` enriches existing `items` by original ID and provides `research`
  rows only when a positive source research count exists.
- `rgb.stableCandidates` supplies `stable-rgb` in source order. Ordinary color
  candidates are never promoted to stable candidates or silently remapped.
- Icon references are created only from verified manifest texture entries.
- Achievements, tile/wall atlases and frame flags, conversion profiles, entity
  markers and world-rule presets remain absent. Those need separately verified
  supplemental sources. Item metadata and image dimensions cannot supply them.

Delivery packs and image ZIP bundles are optional transfer accelerators. This
implementation downloads individual manifest objects and required icons from
the public file endpoint instead. It verifies all non-ZIP manifest objects on
installation, but does not claim a complete viewer delivery-pack cache or import
unsupported supplemental catalogs.

ABCPACK1 limits remain 256 MiB total, 64 MiB catalog metadata, 8 MiB header,
30,000 entries, 50,000 rows per family and 150,000 rows overall. PNGs are capped
at 8 MiB encoded, 8,192 pixels per dimension and 4,194,304 decoded pixels.

## Storage, interruption and recovery

Native storage uses app-private files, a process queue plus OS file lock,
flushed temporary writes, and atomic renames. Paths are generated from validated
keys; symlinks are rejected. Browser storage uses IndexedDB with transactional
active/backup replacement and no volatile fallback. Normalized packs use the
`.abcpack` suffix on disk, separate from server delivery archives.

Every object checkpoint is durable. On restart, incomplete valid stages become
paused. Resumption rehashes existing content; checkpoint counts are never proof
of integrity. At most two stages, totaling 32 MiB of physically retained source
data, are recoverable for seven days. Other stages become abandoned. A canceled
HTTP body is restarted; verified complete objects are reused.

The cache has a 512 MiB application limit. Installation and explicit 清理未使用缓存
collect unreferenced content while preserving all active/backup closures and
recoverable stages across authority namespaces. Approval/root records are never
removed. Cleanup plans all preservation first and stops on unreadable active or
backup records. A cache/quota error preserves the prior active version. This is
an application byte budget, not a promise of available disk space or OS quota.

## Verification

Original offline tests cover normalized IDs/research/stable colors/icons,
offline restoration, object-hash mismatch, bounded gzip and CRC errors,
cancellation and retry, high-water replay/equivocation, cumulative revocations,
revocation immediately before activation, persistence failure, active/backup
preservation, public HTTP request shape, streaming limits, timeout, native
symlink refusal and IndexedDB transaction rollback. Widget tests exercise the
configured/unconfigured panel and Workspace revocation withdrawal.

Run `flutter test --no-pub test/online_resource_service_test.dart
test/online_resource_transport_test.dart test/online_resource_storage_native_test.dart
test/online_resources_panel_test.dart`, plus
`node test/web/online_resource_storage_smoke.cjs`. No live HTTP, account,
production asset download, deployment or asset redistribution was performed.

The browser fetch contract also runs without a browser or network:
`dart compile js -o build/public_resource_client_contract.js
test/web/public_resource_client_contract.dart`, then
`node test/web/public_resource_client_contract.cjs
build/public_resource_client_contract.js`. Its fake fetch checks credentials
omission, redirect/cache options, streamed bytes and cancellation.

## Opt-in performance workload

`test/performance/online_resources_test.dart` writes the common measurements
schema when `ABC_RESOURCE_PERF_REPORT` is set. It measures synthetic transport,
actual gzip/hash/CRC and catalog validation, normalization, native file staging
and atomic activation, offline restoration, cache reuse, cancellation/resume,
corruption rejection, failed-commit preservation/retry, revocation and cleanup.
It also records process RSS after each disposed service cycle. Inner storage
samples are included in installer totals and must not be added to them.

Use `ABC_PERF_TIER=ci|local|soak`, `ABC_PERF_CYCLES` (at least 3),
`ABC_PERF_WARMUP` (at least 1), and optional `ABC_RESOURCE_PERF_ROWS` and
`ABC_RESOURCE_PERF_ICONS`. Default catalog sizes are 128/4,096/8,192 items and
16/128/256 distinct 1×1 PNGs, respectively. All tiers use original data.
These results measure catalog and native-storage
costs; they are not production-network latency, full texture decoding, browser
IndexedDB latency, Flutter frame rate or real-device acceptance.
