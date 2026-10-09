# Local resource catalogs

The public app includes original import and browsing code, not game databases,
textures, private viewer resources, or permission to redistribute those resources.
Use only resources you are authorized to access. Keep generated packs private.
The builder does not download anything, run source JavaScript, or modify its input.

## Build your pack

With Python 3.10+ and your authorized viewer resource checkout:

```sh
python3 tool/build_resource_pack.py /path/to/authorized/viewer /private/location/local.abcpack
```

The output path must not already exist. Use `--metadata-only` to omit PNGs.
Import the `.abcpack` through the app's local resource picker. A pack is portable
across native and web builds; it needs no account, network, credentials, or cache
server. Reimport a replacement when changing game version. Do not attach packs
to public issues, source commits, CI artifacts, or public releases.

The converter reads `infrastructure/assets/builtin-descriptor.json`, validates
compressed byte lengths and SHA256 hashes, bounds decompression, then reads
catalog families from the local `features/builtin-*/pages/resources/` directories.
It parses the achievement catalog's JSON literal without executing JavaScript.
Item metadata combines item-index and item details by original ID. Research rows
come from positive research counts. Compound tile/wall variant IDs stay intact.
No missing IDs are silently renumbered or synthesized.

The source version, descriptor SHA256, release SHA256, upstream manifest SHA256,
and source-object hashes are retained. These identify the supplied source; they
are not an independent authenticity signature or redistribution license.

### Optional player conversion profile

Supply `--conversion-profiles /private/verified-profiles.json` when you have
independently verified the exact target game's player loader. This adds the
private `player-conversion-profiles` family. The input is a row or array of rows:
`id` is the numeric save version; `schema` is 1; `gameVersion` must match the pack;
`sourceCommit` is the source's full 40-character commit; `sourceFiles` records
the inspected file paths and blob identities. `ranges` contains `hair`,
`skinVariant`, and `voiceVariant` rules, each with integer `minimum`, `maximum`,
`fallback`, and `behavior` (`clamp` or `resetAbove`). These values must describe
the verified loader, not guesses from texture counts. The input digest is saved
in pack provenance. Actual game-derived profiles remain private.

Conversion planning only recognizes current-format profiles paired with the
matching current game catalog. Older targets remain blocked without their own
historical gameplay data. Items, prefixes, stack sizes, buffs, hair dyes and
research names are checked against the target catalog; missing or incompatible
records block export rather than silently deleting content.

`PlayerConversion.prepare` clones the source and applies profile-backed style
normalization. `PlayerProjectionBackend.projectPlayer` uses temporary codec
handles to produce and validate target bytes without changing a live document.
The application must decode those bytes and call `reviewProjection`, review all
changes (including unknown-field loss), require explicit confirmation, and
check that the source has not changed before applying the result. Projecting
bytes by itself never grants permission to export or overwrite a save.

### Optional entity marker selectors

Supply `--entity-markers /private/verified-entities.json` to add named, frame-specific
entities without embedding game tables in this application. The JSON envelope is
`{gameVersion, sourceSha256, entries}`; each entry contains `id`, `name`, and
`selector`. The selector requires `tile_type` and `locate`, with optional
`frame_x`, `frame_y`, `frame_x_mod`, and `frame_y_mod`. Values are validated against
the engine's bounds and duplicate-selector rules. The declared source digest and
the input JSON digest are retained separately in provenance. No JavaScript runs.
Without this family, generic tile markers remain available and are labelled as
matching all variants; map-color variant IDs are never treated as entity frames.

### Optional editable world presets

`--world-rule-presets /private/verified-world-presets.json` imports literal
reference rules with envelope `{schema:1, gameVersion, sourceFiles, entries}`.
`sourceFiles` maps viewer-root-relative source paths to their actual SHA-256;
the builder rehashes those files. Each entry has `id`, `name`, `badge`,
`description`, optional `builtinMode`, and 1–128 ordered `rules` with
`where`, `patch`, and optional `limit`. Duplicate keys, IDs, unsafe paths,
unbounded or unknown rule fields are rejected. No source JavaScript executes.

Imported presets create editable named copies. A related core mode is only a
label: reference purification differs from the core fallback in five verified
source cases. Keep imported reference rules and core-generated rules distinct.
Missing provenance leaves this library unavailable without disabling the
independent core fallback. Private rule literals are not bundled with the app.

## Browser and editor API

- `ResourceStore.importPack(bytes)` validates a pack transactionally and returns
  an immutable store. Publish the new store to app state only after success.
- `store.catalog.byId('items', id)` returns a `CatalogEntry` with preserved fields.
  Item `maxStack`, `research`, `persistentId`, `eligiblePrefixes`, `rollablePrefixes`,
  and `prefixPool` are direct fields; detailed gameplay remains under `gameplay`.
- `catalog.search(family, query: text, category: category)` supports all records,
  multilingual names, IDs and internal names, plus exact category filtering.
- `store.iconBytes(entry)` retrieves only that entry's encoded PNG. No network
  fallback occurs; absent icons use a neutral placeholder.
- `CatalogBrowser` uses a bounded-height `ListView.builder`, not eager cards.
  Place it inside `Expanded` or a finite-height `SizedBox`. Visible icons decode
  at a small cache size; full sprite sheets are not expanded on catalog import.

Catalog families include items, tiles, walls, paints, prefixes, buffs, research,
achievements, bestiary, and supporting schemas such as tile-object-data,
player-texture-bindings, armor-sets, and map palettes when present in the source.
An imported catalog's absence must be shown explicitly; do not substitute guessed
prefix/research/stack limits for verified metadata. Numeric IDs and source game
version should be visible when selecting entries.

## ABCPACK1 format and security boundaries

This is a bounded uncompressed container, intentionally not ZIP:

1. Eight ASCII bytes `ABCPACK1`.
2. Little-endian unsigned 32-bit header length.
3. UTF-8 JSON header `{format:1, gameVersion, provenance, entries}`.
4. Concatenated, uncompressed member bytes, in manifest order.

Every entry has `path`, payload-relative `offset`, `bytes`, and lowercase `sha256`.
Paths may only match `catalog/[a-z][a-z0-9-]{0,63}.json` or
`images/<64 lowercase hex digits>.png`. PNG filename must equal its SHA256.
Offsets must be consecutive and unique; hidden gaps, overlap, duplicate paths,
trailing data, unknown versions, bad hashes, undeclared icon references,
non-PNG icons, and duplicate row IDs are rejected. No entry is written to the
filesystem, fetched from a URL, executed, or resolved as a host path.
ZIP, symlink, absolute path, backslash, drive, and parent-traversal inputs are not
supported. The Python builder additionally refuses source symlinks.

Limits: 256 MiB total pack, 8 MiB manifest, 64 MiB aggregate catalog JSON,
30,000 members, 50,000 rows per family, 150,000 rows total, 8 MiB per PNG,
8,192 pixels per dimension and 4,194,304 pixels per PNG. SHA256 provides integrity
against corruption; a malicious party can construct a different valid manifest.
Use packs from your own authorized resources, not untrusted downloads.

Synthetic tests validate parsing, ID preservation, multilingual/category search,
corruption rejection, unsafe paths, malformed manifests, image decode bounds,
caller-buffer isolation, and viewport virtualization for 10,000 catalog rows.
Private full-resource QA is performed outside the public repository; the output
and source content are never test fixtures in public source control.

## Stable RGB matching

`ResourceCatalog.stableColorCandidates(expectedVersion: ...)` reads only the
optional `stable-rgb` family produced from the descriptor's SHA256-checked
`rgb.stableCandidates` object. Generic map colors are never promoted into stable
materials. Each source tuple is `[kind,type,variant,paint,r,g,b,stableMarker]`;
kind 0 means tile, kind 1 means wall, and the stable marker must equal 1. The
builder preserves tuple order as the row ID because native tie-breaking depends
on that order. No colors or paint blends are recomputed or guessed by Dart.

The helper returns immutable maps with `rgb` (packed 0xRRGGBB), matcher `flags`
(bit 0 painted, bit 1 wall), `blockID`, `wallID`, `blockPaint`, `wallPaint`,
`version`, `variant`, and `id` (source ordinal). A tile ID of zero is valid Dirt;
use the wall flag to choose the layer, not a nonzero-ID test. Candidate flags
are color-matcher flags, not world tile flags.

The helper checks the requested game version, source order, ranges, stable
marker, and references to same-pack tile/wall/paint records. It currently rejects
nonzero map variants rather than inventing frame coordinates. Version 1.4.5.8's
source has 17,422 candidates: 261 stable tiles and 301 stable walls, each with
31 paint states (unpainted plus paint IDs 1–30), all variant zero. New game
versions require a corresponding authorized pack and source validation.

The optional historical `srgb` lookup binary is not required for the native
`match_colors` computation; it is a precomputed lookup acceleration structure.
