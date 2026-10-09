// Original synthetic-fixture regression; no user files or private resources.
// Usage: node test/web/world_export_smoke.cjs [repository] [synthetic-world.wld]
'use strict';
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const repository = path.resolve(process.argv[2] || path.join(__dirname, '../..'));
const fixturePath = process.argv[3] || path.join(repository, 'assets/qa/synthetic-objects.wld');
const fixture = fs.readFileSync(fixturePath);
const {createBridge} = require(path.join(repository, 'web/terra_engine.js'));

async function load() {
  const context = vm.createContext({console, WebAssembly, TextDecoder, TextEncoder,
    Uint8Array, ArrayBuffer, setTimeout, clearTimeout, URL, performance,
    window: {}, document: {currentScript: {src: 'http://localhost/world.js'}},
    location: {href: 'http://localhost/'}});
  vm.runInContext(fs.readFileSync(path.join(repository, 'web/engine/world.js'), 'utf8'), context);
  return context.TerraWorldWasmWeb({wasmBinary: fs.readFileSync(path.join(repository, 'web/engine/world.wasm'))});
}

(async () => {
  const bridge = createBridge(load);
  let opened = JSON.parse(await bridge.open(fixture, 'wld'));
  const baseline = opened.metadata;
  let handle = opened.handle;
  const inspect = async () => JSON.parse(await bridge.inspect(handle));
  assert.deepEqual(Buffer.from(await bridge.save(handle)), fixture);
  assert(baseline.chests.length > 0, 'The original synthetic fixture must contain a chest');
  const chests = JSON.parse(JSON.stringify(baseline.chests));
  const patch = {time: baseline.header.time + 0.5, worldName: baseline.header.worldName + ' export'};
  await bridge.mutate(handle, 'header_patch', JSON.stringify({patch}));
  // Exercise growth, shrinkage, UTF-8 byte lengths, and empty names.
  for (const name of ['A', 'ABC export test', '箱子回读测试', '']) {
    chests[0].name = name;
    await bridge.mutate(handle, 'replace_chests', JSON.stringify({chests}));
    const candidate = Buffer.from(await bridge.save(handle));
    assert(!candidate.equals(fixture));
    assert.deepEqual(Buffer.from(await bridge.save(handle)), candidate, 'Repeated export must be stable');
    await bridge.close(handle);
    opened = JSON.parse(await bridge.open(candidate, 'wld'));
    handle = opened.handle;
    const actual = await inspect();
    assert.deepEqual(actual.header, {...baseline.header, ...patch});
    assert.deepEqual(actual.chests, chests);
    assert.deepEqual(actual.bestiary, baseline.bestiary);
    assert.notDeepEqual(actual.format.positions, baseline.format.positions,
      'This regression must exercise legitimate shifted section offsets');
    const stripOffsets = format => ({...format, positions: format.positions.map(() => 0)});
    assert.deepEqual(stripOffsets(actual.format), stripOffsets(baseline.format));
    await assert.rejects(() => bridge.mutate(handle, 'header_patch', JSON.stringify({patch: {worldName: 123}})));
    assert.deepEqual(await inspect(), actual, 'Failed edit must retain the last valid candidate');
    assert.deepEqual(Buffer.from(await bridge.save(handle)), candidate);
    assert.deepEqual(fs.readFileSync(fixturePath), fixture, 'Source fixture must remain unchanged');
  }
  await bridge.mutate(handle, 'replace_chests', JSON.stringify({chests: baseline.chests}));
  await bridge.mutate(handle, 'header_patch', JSON.stringify({patch: {
    time: baseline.header.time, worldName: baseline.header.worldName,
  }}));
  assert.deepEqual(Buffer.from(await bridge.save(handle)), fixture);
  await bridge.close(handle);
  assert.deepEqual(fs.readFileSync(fixturePath), fixture);
  console.log('PASS: actual Web WASM variable-length header/chest exports, repeat-save stability, independent reopen, invalid-edit recovery, exact reversal, source preservation');
})().catch(error => { console.error(error); process.exitCode = 1; });
