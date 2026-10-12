# Third-party source and runtime notices

This repository contains the specifically authorized source subsets and generated
runtime artifacts below. Their inclusion does not create a new license grant or
change upstream ownership. No general upstream license was identified in the
private supplied source trees; these components are not relicensed under a license for
the original TerraForge code.

## TerraWasm

- Upstream: `Live-yum/TerraWasm`, base commit
  `e2c3c817b2b482a535763695d19945971e19e41c`.
- Distributed subset: `native/vendor/TerraWasm`; exact paths, byte counts and
  SHA-256 hashes are in its `SOURCE_MANIFEST.json`.
- The subset contains the C engine, headers, required embedded color/map/tile
  properties and item/NPC name tables, exports, build configuration and the
  original README. Native pointer-width, allocation-lifetime, zlib bridge and
  host build integration fixes are included. This is a patched source snapshot,
  not a claim of byte identity with the unmodified upstream commit.
- Generated artifacts: `web/engine/world.{js,wasm}` and
  `web/engine/player.{js,wasm}`. Their provenance and integrity hashes accompany
  the artifacts. Emscripten and zlib retain their respective upstream licenses.

## Viewer circuit rules

- Upstream: `Live-yan/viewer-app`, commit
  `366ebc57751cadfb077f968f4d5069028b3bf9a6`.
- Distributed subset: the exact 40-module closure under `vendor/viewer-circuit`.
  The trimmed `retrieved-source-manifest.json` retains the upstream Git blob IDs
  and sizes. Module bytes are unmodified.
- Generated artifacts: `assets/private/circuit_rules_native.js` and
  `web/engine/circuit_rules_web.js`. The historical `assets/private` directory
  name is retained for runtime compatibility; these listed files are approved
  for inclusion. `assets/private/circuit_rules.provenance.json` records source,
  adapters, host files, bundler, output sizes and SHA-256 hashes.
- Bundling uses esbuild 0.20.1 (MIT), pinned in `package-lock.json`. The source
  subset includes no dependency installation or unrelated viewer application.

## Other dependencies and excluded material

Flutter/Dart, flutter_js 0.8.7, JavaScriptCore, QuickJS and the other resolved
package dependencies retain their upstream licenses. Consult their distributed
license files and the application license registry for those terms.

Terraria names and embedded compatibility tables remain attributable to their
respective rights holders. No Terraria artwork atlases or Terraria executables, personal
world/player saves, private real-save fixtures, `.abcpack` archives, signing
material, credentials, logs or proof output are distributed in this repository.
Synthetic test fixtures are generated locally by the project scripts.

## Computerraria program and physical computer layout

- Upstream: [misprit7/computerraria](https://github.com/misprit7/computerraria),
  commit `0379d5b0d89dbb7fd4342b3afff9c3be5e1ab9d8`, MIT,
  Copyright (c) 2023 Xander Naumenko. Full permission notice is retained in
  `vendor/computerraria/LICENSE` and `test/fixtures/computerraria/LICENSE`.
- `test/fixtures/computerraria/pong.bin` is the 2,288-byte RV32I ROM program, SHA-256
  `d2a7d5a26eb168a55c80ae60b32205957d8f2ae215cbdce7c5d50acc2049946d`.
  The unchanged Pong source, driver sources, two host-only cfg guards, build
  script and per-file provenance are in `vendor/computerraria`.
- Physical clock/reset/ROM/RAM coordinates are verified against the pinned
  original WLD. The app enables this fixed layout only for its exact source
  hash and matching actual anchors, or a locally verified WLD export record.
- The application reads the world's native 64-by-48 monochrome PixelBox display.
  Mod-only color-display data is not part of the supported WLD format. No mod
  runtime, game textures or full world file is distributed.

## WireHead algorithm reference

The optional ordinary-PixelBox gate-wave pairing behavior references
[WireHead](https://github.com/misprit7/WireHead/tree/e6009d010ca54ff43d04b44697accc7115807b9c),
MIT © 2023 Xander Naumenko. The full notice is retained at
`vendor/wirehead/LICENSE` and bundled as `assets/computer/WIREHEAD_LICENSE.txt`. This is a bounded C implementation using physical WLD
networks, not an embedded mod runtime or a claim of complete WireHead parity.
