# Third-party source and runtime notices

This repository contains the specifically authorized source subsets and generated
runtime artifacts below. Their inclusion does not create a new license grant or
change upstream ownership. No general upstream license was identified in the
supplied source trees; these components are not relicensed under a license for
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
respective rights holders. No Terraria artwork atlases, game programs, personal
world/player saves, private real-save fixtures, `.abcpack` archives, signing
material, credentials, logs or proof output are distributed in this repository.
Synthetic test fixtures are generated locally by the project scripts.
