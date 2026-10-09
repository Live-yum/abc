# Region and pixel integration

Original host adapters invoke the separately supplied authoritative core. Native
calls execute only in the existing singleton engine worker. Close the ordinary
world document before these one-shot operations and reopen the candidate/original
afterward. Web uses an isolated module instance in a dedicated worker. No live engine handle escapes.

## Interface

- `readRegion(world,x,y,width,height)` returns full column-major 32-byte cells.
- `readRegionObjects(...)` returns a COB1 companion; incomplete/unsupported object
  footprints fail. Regions without objects return a 32-byte empty COB1 header.
- `replaceRegion(world,x,y,width,height,records)` replaces all tile layers exactly,
  including deletion and wire/liquid clearing. Existing framed objects retain
  their active state, type, frames and shape. Cosmetic layers may change. Object
  metadata sections stay intact; structural changes fail before returning output.
- `regionOperation(world,'stamp_tiles',request,records:...,objects:...)` performs
  a sparse overlay, preserving unrelated existing layers and metadata. It does
  not erase: wires are ORed and absent block/wall/liquid layers are skipped.
- `writeIndexedPixels(world,x,y,width,height,maps,indices)` is a safe original
  adapter: core-read the target records, merge only requested layers, then invoke
  core-backed exact replacement. It never routes UI edits through the legacy
  primitive that resets an entire cell. Mode0 clears foreground only; mode1
  writes foreground including Dirt ID0; mode2 writes wall only; mode3 skips;
  mode4 writes both. Unrequested blocks/walls, liquids, wires, slopes, actuators,
  and coatings remain. Foreground modes1/4 apply the requested inactive flag.
  Framed palette materials and structural furniture collisions reject.
  Requires nonnegative, fully in-bounds placement with at most 262144 cells.


`AdvancedRegionDocument.stampRequest(x,y)` produces the request. Source IDs are
world=1, 32-byte records=2, COB1 companion=3. A complete furniture paste must
include its companion. Occupied framed targets are rejected. TXCI is the engine's
colour-index format; it is not the COB1 furniture metadata or region document.
The original editor JSON schema is `abc-region`, version 1 (base64 records/COB1).

## Supported matrix

| Operation | Support and rejection |
| --- | --- |
| Tile read | Modern sectioned WLD accepted by core; every block/wall/frame/paint/liquid/wire/slope/actuator/invisibility/fullbright layer |
| Region replacement | Writable modern core versions; exact ordinary layer replacement; future read-only and legacy unsectioned worlds rejected |
| Object companion | WLD 88–326; chests/dressers, signs, and the core's 11 tile-entity registrations; complete recognised footprints and existing metadata required |
| Object insertion | Original core stamp validation checks destination version, IDs, complete frame records and metadata; occupied/split objects rejected |
| Version-dependent layers | Shimmer/invisible/fullbright reject below WLD269; IDs must fit target world's type table |
| Furniture structural editing | Rejected by region replacement; use complete validated overlay at an unoccupied destination |
| RGBA/indexed pixel write | Resolved 12-byte palette + uint16 indices, safe layer merge; palette index0 transparent; source bytes remain unchanged on failure |

Tile records are eight little-endian uint32 values: relative x/y,
`type | flags<<16`, signed16 frameX/frameY, wall + tile/wall paints,
liquid amount/type + shape + wire mask, two zero reserved words. Flags bits0–6:
active, actuator, inactive, invisible block/wall, fullbright block/wall.

Palette records: RGBA bytes, little-endian uint16 tile and wall IDs, byte tile
paint, wall paint, mode, inactive. Modes: 0 foreground clear, 1 tile, 2 wall, 3 skip,
4 tile+wall. Palette 1–65536 entries, image dimensions 1–16384, index count must
match the image. Native matching/world validation remains authoritative.

Host limits: region read/replacement 262144 cells; clipboard 32MiB records;
object payload 4MiB/32768 objects; history 32MiB. The Web bridge caps world input
at 64MiB. WASM allocation limits can reject large combined input/output memory.
This adapter returns complete bytes; it does not claim a constant-memory host.

## Regression commands

Generate fixtures with `native/generate_world_fixture.py` and
`native/generate_region_object_fixture.py`; both are original synthetic data.
Run `native/region_smoke.dart`, `native/region_objects_smoke.dart` with
`TERRAFORGE_ENGINE_LIBRARY`, and `tool/test_web_region.mjs` with
`TERRA_WORLD_RUNTIME`, `TERRA_WLD_FIXTURE`, `TERRA_OBJECT_FIXTURE`.

Checks cover all-layer readback, exact erasure, indexed pixel output, immutable
input, error cleanup, named chest/nonempty inventory, sign text and a tile entity
copy/paste, cosmetic edits with byte-identical COB1 preservation, incomplete
selection, occupied destination and structural-change rejection.

## Authoritative colour matching

`matchColors(queryRgb,candidateRgb,candidateFlags,flags:...)` uses core pixel ABI1,
with up to 65536 RGB queries/candidates per call. Candidate bits: painted=1,
wall=2. Query bits: require unpainted=1, require wall=2, prefer wall=4,
require tile=8, require painted=16. Contradictory filters fail. Returned values
are candidate indexes, with UINT32_MAX for no eligible candidate. No guessed
material IDs. Ties prefer shorter RGB distance, unpainted, preferred wall, then
input order. RGBA importers must skip transparent pixels explicitly and pass
opaque RGBs to this matcher before constructing a resolved palette.
