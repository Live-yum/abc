import assert from 'node:assert/strict';
import test from 'node:test';
import {WORLD_BYTES, WORLD_SHA, VERIFIED_LABEL, readyEvidence, enabledNode, installInstrumentation} from './browser_load_driver.mjs';

function fixture() {
  return {state: {file: {isFile: true, size: WORLD_BYTES}, legacyOpenCalls: 0, openSourceCalls: 1,
    openResult: {type: 'bridge-result', method: 'openSource', sourceSha256: WORLD_SHA,
      session: 1, stats: [2, ...Array(23).fill(0)]}},
  nodes: [{name: {value: VERIFIED_LABEL}, ignored: false, role: {value: 'StaticText'}},
    {name: {value: '关闭'}, ignored: false, role: {value: 'button'}, backendDOMNodeId: 4}]};
}

test('genuine-ready contract requires native File, source identity and completed application UI', () => {
  const {state, nodes} = fixture();
  assert.equal(readyEvidence(state, nodes), true);
  assert.equal(readyEvidence(state, nodes.slice(0, 1)), false);
  assert.equal(readyEvidence(state, nodes.slice(1)), false);
});

test('loaded Blob, preloaded byte route, wrong fixture, duplicate import cannot pass', () => {
  for (const mutate of [s => s.file.isFile = false, s => s.file.size--,
    s => s.legacyOpenCalls++, s => s.openSourceCalls++, s => s.openResult.sourceSha256 = '0'.repeat(64),
    s => s.openResult = null]) {
    const {state, nodes} = fixture();
    mutate(state);
    assert.equal(readyEvidence(state, nodes), false);
  }
});

test('a busy or ambiguous close control is not ready', () => {
  const {state, nodes} = fixture();
  assert.equal(enabledNode([...nodes, nodes[1]], '关闭'), null);
  nodes[1].properties = [{name: 'disabled', value: {value: true}}];
  assert.equal(readyEvidence(state, nodes), false);
});

test('frozen production-shaped bridge is forwarded without mutating, retaining or copying payloads', async t => {
  const keys = ['Worker', 'terraWorldCircuit', '__abcBrowserDiagnostic'];
  const saved = Object.fromEntries(keys.map(key => [key, Object.getOwnPropertyDescriptor(globalThis, key)]));
  t.after(() => { for (const key of keys) {
    if (saved[key]) Object.defineProperty(globalThis, key, saved[key]); else delete globalThis[key];
  } });
  let terminateCount = 0, sourceReceived;
  globalThis.Worker = class { addEventListener() {} terminate() { terminateCount++; } };
  const records = new Uint8Array([1, 2, 3]);
  const result = {session: 1, sourceSha256: WORLD_SHA, stats: [2, ...Array(23).fill(0)]};
  Object.defineProperty(result, 'records', {get() { throw new Error('Instrumentation must not touch payload'); }});
  const original = Object.freeze(Object.fromEntries(
    ['open', 'openSource', 'progress', 'command', 'close', 'cleanup', 'releaseSource', 'dispose'].map(method =>
      [method, async source => { if (method === 'openSource') sourceReceived = source; return result; }])));
  globalThis.terraWorldCircuit = original;
  const events = [];
  globalThis.__abcBrowserDiagnostic = value => events.push(JSON.parse(value));
  installInstrumentation();
  assert.equal(Object.isFrozen(original), true);
  assert.notEqual(globalThis.terraWorldCircuit, original);
  assert.equal(globalThis.terraWorldCircuit.releaseSource, original.releaseSource);
  const source = new File([records], 'small-test.wld');
  assert.equal(await globalThis.terraWorldCircuit.openSource(source), result);
  assert.equal(sourceReceived, source);
  const start = events.find(e => e.type === 'bridge-call' && e.method === 'openSource');
  assert.equal(start.file.isFile, true);
  assert.equal(start.file.size, 3);
  assert.equal(events.some(e => 'records' in e), false);
  const worker = new globalThis.Worker('http://127.0.0.1/terra_engine_worker.js?owner=worldCircuit');
  worker.terminate();
  assert.equal(terminateCount, 1);
  assert.equal(events.filter(e => e.type === 'world-worker-terminated').length, 1);
});
