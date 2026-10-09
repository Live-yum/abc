// Lightweight observer contract only: no WASM module or benchmark is run.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import assert from 'node:assert/strict';
import {DiagnosticProbe} from './diagnostic_probe.mjs';
assert.equal(typeof global.gc, 'function');
const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'abc-rules-probe-test-'));
try {
  const directory = path.join(temporary, 'observations');
  const module = {HEAPU8: new Uint8Array(128), _tx_native_heap_used: () => 0, _tx_bridge_heap_used: () => 0};
  const bench = {modules: [module, module], owners: new Set()};
  const probe = new DiagnosticProbe(directory, bench);
  for (let cycle = -1; cycle < 2; cycle++) {
    probe.startCycle(cycle);
    probe.boundary('operation-before', 'test.operation', 'test-fixture');
    global.gc();
    await new Promise(resolve => setImmediate(resolve));
    probe.boundary('operation-after', 'test.operation', 'test-fixture');
    await probe.endCycle();
    assert.equal(probe.fd, null);
  }
  await probe.close();
  const records = fs.readdirSync(directory).flatMap(file => {
    const rows = fs.readFileSync(path.join(directory, file), 'utf8').trim().split('\n').map(JSON.parse);
    assert.equal(rows[0].event, 'cycle-start');
    assert.equal(rows.at(-1).event, 'cycle-end');
    assert.equal(new Set(rows.map(row => row.observedCycle)).size, 1);
    const before = rows.find(row => row.event === 'operation-before');
    const after = rows.find(row => row.event === 'operation-after');
    assert.ok(before.sampledMs <= after.observationStartMs);
    assert.equal(before.moduleCount, 1);
    assert.equal(before.wasmCapacityBytes, 128);
    assert.equal(before.nativeLiveBytes, 0);
    assert.ok(rows.at(-1).overhead.boundaryWallMs >= 0);
    return rows;
  });
  assert.ok(records.some(row => row.event === 'gc'), 'Explicit GC should produce observer records');
  for (const row of records.filter(row => row.event === 'gc')) {
    assert.ok(row.startMs >= 0 && row.durationMs >= 0 && row.deliveredMs >= row.startMs);
  }
  assert.equal(new Set(records.map(row => row.sequence)).size, records.length);
  console.log('PASS observer contract: 3 finite cycle files, complete boundaries, GC timestamps, no retained sample arrays');
} finally {
  fs.rmSync(temporary, {recursive: true, force: true});
}
