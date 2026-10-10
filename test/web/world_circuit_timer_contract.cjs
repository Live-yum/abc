// Actual WASM; expectations are exported by the independent Python FIFO oracle.
// Usage: node <this> world.js world.wasm <timer fixture directory>
'use strict';
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const crypto = require('node:crypto');
const assert = require('node:assert/strict');
const {createWorldCircuitBridge} = require('../../web/terra_world_circuit.js');

(async () => {
  const context = vm.createContext({console, WebAssembly, TextDecoder, TextEncoder,
    Uint8Array, ArrayBuffer, setTimeout, clearTimeout, URL, performance, window: {},
    document: {currentScript: {src: 'http://localhost/world.js'}},
    location: {href: 'http://localhost/'}});
  vm.runInContext(fs.readFileSync(process.argv[2], 'utf8'), context);
  let budget = 4096;
  const bridge = createWorldCircuitBridge(async () => {
    const module = await context.TerraWorldWasmWeb({wasmBinary: fs.readFileSync(process.argv[3])});
    const nativeStep = module._terra_circuit_world_step;
    // Exercise both work budgets against the actual exported WASM function.
    module._terra_circuit_world_step = (handle, _hostBudget, event) => nativeStep(handle, budget, event);
    return module;
  });
  const directory = process.argv[4];
  const manifest = JSON.parse(fs.readFileSync(path.join(directory, 'cases.json'), 'utf8'));
  assert.equal(manifest.reference, '8255d34616c780af12079425ac92a0a7aed87d71');
  let id;
  const command = (kind, fields = {}, points = []) => {
    const words = [2, kind, ...Array(14).fill(0)];
    const indexes = {x: 2, y: 3, width: 4, height: 5, stride: 6,
      mask: 7, count: 8, source_id: 11, flags: 12};
    for (const [key, value] of Object.entries(fields)) {
      assert.ok(key in indexes, key);
      words[indexes[key]] = value;
    }
    words[10] = points.length;
    return bridge.command(id, JSON.stringify(words), JSON.stringify(points.flat()));
  };
  const records = result => {
    const bytes = result.records;
    const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
    return Array.from({length: bytes.byteLength / 16}, (_, row) =>
      [0, 4, 8, 12].map(offset => view.getUint32(row * 16 + offset, true)));
  };
  const snapshot = async (expected, tick, label) => {
    const byRow = new Map();
    for (const [x, y] of expected) {
      if (!byRow.has(y)) byRow.set(y, []);
      byRow.get(y).push(x);
    }
    const actual = new Map();
    for (const [y, xs] of byRow) {
      const left = Math.min(...xs), right = Math.max(...xs);
      const result = await command(1, {x: left, y, width: right - left + 1, height: 1, stride: 1});
      assert.deepEqual(result.stats.slice(18, 20), [tick, 0], label + ' ticks');
      const rows = records(result);
      for (const x of xs) {
        const row = rows[x - left];
        actual.set(`${x},${y}`, [x, y, row[2] & 65535, row[3] & 65535, row[3] >>> 16]);
      }
    }
    assert.deepEqual(expected.map(([x, y]) => actual.get(`${x},${y}`)), expected, label);
    // Faulty 36-frame lamps are gate triggers, not ordinary on/off lamps.
    const lamps = expected.filter(row => row[2] === 419 && row[3] !== 36);
    if (lamps.length) {
      const result = await command(4, {}, lamps.map(([x, y]) => [x, y, 0, 0]));
      assert.deepEqual(records(result).map(row => row[2]), lamps.map(row => Number(row[3] === 18)), label + ' READ_LAMPS');
    }
  };
  let executed = 0;
  for (const spec of manifest.cases) {
    const filename = path.join(directory, spec.file);
    const bytes = fs.readFileSync(filename);
    const before = crypto.createHash('sha256').update(bytes).digest('hex');
    for (const streamed of [false, true]) for (const optimized of [0, 1]) for (budget of [1, 4096]) {
      const label = `${spec.name}/stream=${streamed}/mode=${optimized}/budget=${budget}`;
      const opened = streamed ? await bridge.openSource(new Blob([bytes])) : await bridge.open(bytes);
      id = opened.session;
      assert.equal(opened.sourceSha256, before, label + ' input hash');
      await command(10, {mask: optimized});
      await snapshot(spec.initial, 0, label + '/initial');
      for (const [index, step] of spec.steps.entries()) {
        await command(step.kind, step.fields);
        await snapshot(step.expected, step.ticks, label + `/step=${index}`);
      }
      const saved = await command(6, {source_id: 3});
      const savedBytes = streamed ? new Uint8Array(await saved.worldSource.blob.arrayBuffer()) : saved.world;
      await bridge.close(id);
      if (streamed) await bridge.releaseSource(saved.worldSource.token);
      id = (streamed ? await bridge.openSource(new Blob([savedBytes])) : await bridge.open(savedBytes)).session;
      await command(10, {mask: optimized});
      await snapshot(spec.reopened, 0, label + '/reopened');
      await command(3, {count: 300});
      await snapshot(spec.reopened, 300, label + '/no-restored-queue');
      await bridge.close(id);
      executed++;
    }
    assert.equal(crypto.createHash('sha256').update(fs.readFileSync(filename)).digest('hex'), before);
  }
  console.log(`PASS: actual Web WASM timer FIFO oracle, ${executed} retained/streamed OFF/ON budget1/4096 cases; periods, phase, repeated pulses, save/reopen, source hashes`);
})().catch(error => {console.error(error); process.exitCode = 1;});
