// Uses Dart-produced placement fragments, never a duplicate JS frame generator.
// Inputs are local-only proof artifacts from native_fusion_placement_test.dart.
import fs from 'node:fs';
import {createRequire} from 'node:module';
import assert from 'node:assert/strict';
const require = createRequire(import.meta.url);
const {createRegionBridge} = require('../web/terra_region.js');
const runtime = process.env.TERRA_WORLD_RUNTIME;
const directory = process.env.ABC_FUSION_PROOF_DIR;
if (!runtime || !directory) throw new Error('Set TERRA_WORLD_RUNTIME and ABC_FUSION_PROOF_DIR');
const factory = require(runtime);
const bridge = createRegionBridge(() => factory({wasmBinary: fs.readFileSync(runtime.replace(/\.js$/, '.wasm'))}));
const world = new Uint8Array(fs.readFileSync(`${directory}/source.wld`)), original = world.slice();
const cases = JSON.parse(fs.readFileSync(`${directory}/placements.json`, 'utf8'));
assert.ok(cases.length >= 3);
for (const value of cases) {
  const records = new Uint8Array(Buffer.from(value.records, 'base64'));
  const objects = value.objects ? new Uint8Array(Buffer.from(value.objects, 'base64')) : new Uint8Array();
  const {x, y, width, height} = value.request;
  const request = JSON.stringify(value.request);
  const result = await bridge.operation(world, 'stamp_tiles', request, records, objects);
  assert.deepEqual(await bridge.read(result, x, y, width, height), records, value.name);
  if (objects.length) {
    assert.deepEqual(await bridge.objects(result, x, y, width, height), objects, value.name);
    if (value.display) assert.deepEqual(objects.slice(-5), new Uint8Array([1, 0, 0, 1, 0]));
    const corrupt = objects.slice();
    new DataView(corrupt.buffer).setUint32(52, corrupt.length, true);
    await assert.rejects(() => bridge.operation(world, 'stamp_tiles', request, records, corrupt));
    assert.deepEqual(world, original, `${value.name} failure must preserve source`);
  }
  if (objects.length) {
    await assert.rejects(() => bridge.operation(result, 'stamp_tiles', request, records, objects));
  }
}
assert.deepEqual(world, original);
console.log(`PASS: ${cases.length} Dart-generated local metadata placements through WASM, exact tile/COB1 readback, all companion schemas, collision/malformed-payload rejection, immutable source`);
