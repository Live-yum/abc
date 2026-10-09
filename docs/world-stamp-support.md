# Conservative fallback world stamping

This document describes the fallback Dart writer only. The primary application path now uses the authoritative region engine for complete layers and object companions; see [REGION_ENGINE.md](REGION_ENGINE.md). The fallback limits below do not describe the capabilities of that core-backed path.

The fallback pixel and fusion domain writer is an original, shared Dart implementation.
It accepts a serialized WLD and returns a separate candidate buffer. It never
modifies the input. The application must validate/reopen that candidate before
adopting it. No private palette tables or Wasm32 pointer APIs are used.

## Supported subset

| Feature | Support |
|---|---|
| World format | Releases 139 and 326 only, expected 7/11-section layouts |
| Ordinary blocks | Dirt 0, stone 1, grass 2, wood 30, if present and unframed |
| Background walls | IDs 0–4 (0 removes the wall) |
| Paint | 0–30 on supported nonempty layers |
| Transparent cell | Null cell skips both layers |
| Preserve one layer | Null block/wall preserves that layer and its paint |
| Clear foreground | Block -1 removes foreground; dirt is block 0 |
| Conflicts | Occupied requested layer rejects unless overwrite is explicit |
| Fusion import | Rectangular ordinary block/wall/paint extraction |
| RLE | Valid column-bounded runs split only where edited |
| Preservation | Unaffected records and all non-tile sections copied exactly |
| Chest/sign safety | Bounded full parsing; anchors within eight tiles reject |
| Furniture safety | Frame-important tile within eight tiles of target rejects |
| Entities | Any nonempty tile-entity section rejects |

This is not full fusion parity. Furniture, inventories, sign text and tile
entities cannot be transferred. Liquid, wiring, slopes, actuators, visibility
and fullbright flags cannot be edited. Source extraction rejects these special
states. Unknown formats, fields, section layouts, header bits, unsupported
materials, malformed streams, invalid bounds and excessive budgets fail closed.
Nearby chest/sign support is intentionally conservative. Distant object section
bytes are preserved, never interpreted and rewritten.

## Budgets and undo

Inputs and outputs are limited to 64 MiB; a stamp is limited to 1,048,576 cells.
Fusion history retains at most 50 snapshots within a conservative approximately
32 MiB accounting budget (48 bytes per cell plus list overhead). An individual
snapshot over this budget is not retained, so very large canvases may have no
undo. Current state and an in-progress stroke are separate from history.

## Evidence and limits

`test/world_stamp_test.dart` provides independently hand-encoded 139/326 section
fixtures, including long-RLE splitting, transparent preservation, conflicts,
malformed input, object proximity and fusion project undo/serialization.

`native/generate_world_fixture.py` creates an original full release-139 fixture.
`native/stamp_fixture.dart` applies real domain edits to it.
`native/stamp_readback.c` then independently decodes every tile using the supplied
engine, compares expected changes and untouched fields, and compares every
non-tile section byte-for-byte. This path passed for release 139. Release 326
currently has domain format-fixture coverage, not a full game-created fixture
compatibility claim. Production-world and in-game validation remain necessary.
