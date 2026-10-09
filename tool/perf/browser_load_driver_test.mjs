import assert from 'node:assert/strict';
import test from 'node:test';
import {spawnSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';
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

// Synthetic cycle contracts: never starts Chrome or invokes a real product.
import {CYCLE_LIMITS, clickGeometry, displayNode, summarizeDisplay, commandKind, installCycleInstrumentation,
  newCycleState, observeCycleEvent, releaseWindow, releaseWindowComplete, ownershipSnapshot, quietCloseEvidence, cycleReadyEvidence, closedEvidence, optimizationNode, checked, uiPulses} from './browser_load_cycles.mjs';

function physicalDisplay(lit = [[0, 20], [0, 21], [31, 25]], session = 1) {
  const records = new Uint8Array(64 * 48 * 16), view = new DataView(records.buffer);
  const keys = new Set(lit.map(([x, y]) => `${x},${y}`));
  for (let y = 0; y < 48; y++) for (let x = 0; x < 64; x++) {
    const offset = (y * 64 + x) * 16;
    view.setUint32(offset, 6485 + x, true); view.setUint32(offset + 4, 800 + y, true);
    view.setUint32(offset + 8, 445, true); view.setInt16(offset + 12, keys.has(`${x},${y}`) ? 18 : 0, true);
  }
  // Actual C PIXELS READY/DONE envelope has resultCount=0; the 3072 records
  // arrive through separate RESULT events and are collected by the JS bridge.
  return {session, records, resultKind: 9, resultCount: 0, reserved: 14};
}
const clockWords = pulses => [2, 2, 3194, 153, 1, 1, 1, 8, pulses, 0, 0, 0, 0, 0, 0, 0];
const pixelsWords = [2, 9, 6485, 800, 64, 48, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0];
const inputWords = direction => [2, 2, direction === 'up' ? 6516 : 6517,
  direction === 'up' ? 851 : 866, 1, 1, 1, direction === 'up' ? 9 : 5, 1, 0, 0, 0, 0, 0, 0, 0];

function acceptedOpen(state, session = 1, callId = 1, workerId = 1) {
  observeCycleEvent(state, {type: 'world-worker-created', workerId});
  observeCycleEvent(state, {type: 'bridge-call', method: 'openSource', callId,
    file: {isFile: true, size: WORLD_BYTES}});
  observeCycleEvent(state, {type: 'bridge-result', method: 'openSource', callId,
    session, sourceSha256: WORLD_SHA, stats: [2, ...Array(23).fill(0)], reserved: 4});
}
function acceptedClose(state, session = 1, callId = 2, workerId = 1) {
  observeCycleEvent(state, {type: 'bridge-call', method: 'close', callId, requestSession: session});
  observeCycleEvent(state, {type: 'world-worker-terminated', workerId});
  observeCycleEvent(state, {type: 'bridge-result', method: 'close', callId});
}

test('monitor summaries retain validated actual output count and fingerprints, never full pixels', () => {
  const result = physicalDisplay(), before = result.records.slice();
  const summary = summarizeDisplay(result);
  assert.equal(summary.litCount, 3); assert.equal(summary.interiorLitCount, 1);
  assert.equal(summary.leftPaddleCenter, 20.5); assert.equal(summary.pixelCount, 3072);
  assert.equal(summary.recordBytes, 49152); assert.deepEqual(result.records, before);
  assert.equal('records' in summary, false); assert.equal('pixels' in summary, false);
  const moved = summarizeDisplay(physicalDisplay([[0, 18], [0, 19], [31, 25]]));
  assert.notEqual(summary.pixelHash, moved.pixelHash);
  assert.equal(moved.leftPaddleCenter, 18.5);
  assert.equal(summarizeDisplay(physicalDisplay([])).leftPaddleCenter, null);
  assert.ok(JSON.stringify(summary).length < 450);
});

test('monitor evidence rejects wrong shape, duplicate coordinate, wrong tile and invalid frames', () => {
  for (const change of [r => r.resultKind = 1,
    r => r.records = r.records.subarray(16),
    r => new DataView(r.records.buffer).setUint32(16, 6485, true),
    r => new DataView(r.records.buffer).setUint32(0, 6484, true),
    r => new DataView(r.records.buffer).setUint32(8, 1, true),
    r => new DataView(r.records.buffer).setInt16(12, 36, true),
    r => new DataView(r.records.buffer).setInt16(14, 18, true)]) {
    const row = physicalDisplay(); change(row); assert.throws(() => summarizeDisplay(row));
  }
});

test('physical input/clock recognition requires exact ABI wiring rather than any trigger', () => {
  assert.equal(commandKind(clockWords(128)), 'clock');
  assert.equal(commandKind(inputWords('up')), 'up'); assert.equal(commandKind(inputWords('down')), 'down');
  assert.equal(commandKind(pixelsWords), 'display');
  for (const index of [2, 3, 4, 5, 6, 7, 9, 10, 11, 12, 13, 14, 15]) {
    const words = inputWords('up'); words[index]++; assert.notEqual(commandKind(words), 'up');
  }
  assert.notEqual(commandKind(clockWords(129)), 'clock');
});

test('reset replacement balances actual owners and public sessions across repeated closes', () => {
  const state = newCycleState(); acceptedOpen(state); acceptedClose(state);
  assert.equal(closedEvidence(state), true);
  acceptedOpen(state, 2, 3, 2); assert.equal(closedEvidence(state), false);
  acceptedClose(state, 2, 4, 2); assert.equal(closedEvidence(state), true);
  assert.deepEqual([...state.allSessions], [1, 2]);
  assert.equal(state.workerCreated, 2); assert.equal(state.workerTerminated, 2);
  assert.equal(state.errors.length, 0);
});

test('stale handles, missing ACK, reused IDs and owner recreation cannot pass close', () => {
  const stale = newCycleState(); acceptedOpen(stale); acceptedClose(stale);
  observeCycleEvent(stale, {type: 'bridge-call', method: 'command', callId: 5, requestSession: 1, words: clockWords(128)});
  assert.equal(closedEvidence(stale), false); assert.match(stale.errors[0].message, /stale/);
  const unacked = newCycleState(); acceptedOpen(unacked);
  observeCycleEvent(unacked, {type: 'world-worker-terminated', workerId: 1});
  assert.equal(closedEvidence(unacked), false);
  const reused = newCycleState(); acceptedOpen(reused); acceptedClose(reused); acceptedOpen(reused, 1, 3, 2);
  assert.match(reused.errors[0].message, /reused/);
  const recreated = newCycleState(); acceptedOpen(recreated); acceptedClose(recreated);
  observeCycleEvent(recreated, {type: 'world-worker-created', workerId: 2});
  assert.equal(closedEvidence(recreated), false);
});

test('compound live frames record real clock/display ACKs and fail incomplete display', () => {
  const state = newCycleState(); acceptedOpen(state);
  observeCycleEvent(state, {type: 'bridge-call', method: 'computerFrame', callId: 2,
    requestSession: 1, words: clockWords(128), pixelWords: pixelsWords});
  observeCycleEvent(state, {type: 'bridge-result', method: 'computerFrame', callId: 2,
    clock: {session: 1}, display: {session: 1}, monitor: summarizeDisplay(physicalDisplay()), hostMonoNs: 10});
  assert.equal(state.clockPulses, 128); assert.equal(state.display.session, 1); assert.equal(state.displayCount, 1);
  observeCycleEvent(state, {type: 'bridge-call', method: 'command', callId: 3,
    requestSession: 1, words: inputWords('down')});
  observeCycleEvent(state, {type: 'bridge-result', method: 'command', callId: 3, session: 1, hostMonoNs: 11});
  assert.deepEqual(state.inputAcks.down, [{callId: 3, atPulses: 128, hostMonoNs: 11}]);
  observeCycleEvent(state, {type: 'bridge-call', method: 'computerFrame', callId: 4,
    requestSession: 1, words: clockWords(128), pixelWords: pixelsWords});
  observeCycleEvent(state, {type: 'bridge-result', method: 'computerFrame', callId: 4,
    clock: {session: 1}, display: null, displayError: 'display failed'});
  assert.equal(state.clockPulses, 256); assert.match(state.errors[0].message, /display/);
});

test('optimization requires unambiguous readable initial OFF and explicit ON state', () => {
  const node = {ignored: false, name: {value: '电路优化\n默认关闭。'}, role: {value: 'switch'},
    properties: [{name: 'checked', value: {value: 'false'}}]};
  assert.equal(optimizationNode([node]), node); assert.equal(checked(node), false);
  assert.equal(optimizationNode([node, node]), null);
  assert.equal(checked({...node, properties: []}), null);
  assert.equal(uiPulses([{ignored: false, name: {value: '已执行 5120 个物理时钟脉冲 · 当前模式实测 0.0 Hz'}}]), 5120);
  assert.equal(uiPulses([]), null);
});

test('cycle instrumentation forwards immutable compound results and observes real DOM events passively', async t => {
  const keys = ['Worker', 'terraWorldCircuit', '__abcBrowserDiagnostic', 'addEventListener'];
  const saved = Object.fromEntries(keys.map(key => [key, Object.getOwnPropertyDescriptor(globalThis, key)]));
  t.after(() => { for (const key of keys) {
    if (saved[key]) Object.defineProperty(globalThis, key, saved[key]); else delete globalThis[key];
  } });
  const listeners = {}, events = [];
  globalThis.addEventListener = (type, listener) => { listeners[type] = listener; };
  globalThis.Worker = class { addEventListener() {} terminate() {} };
  globalThis.__abcBrowserDiagnostic = value => events.push(JSON.parse(value));
  const display = physicalDisplay(), compound = {clock: {session: 1}, display, displayError: null};
  let received;
  const plain = {session: 1};
  Object.defineProperty(plain, 'records', {get() { throw new Error('Must not inspect unrelated records'); }});
  const original = Object.freeze(Object.fromEntries(['open', 'openSource', 'progress', 'command', 'computerFrame',
    'close', 'cleanup', 'releaseSource'].map(method => [method, async (...args) => {
      received = args; return method === 'computerFrame' ? compound : plain;
    }])));
  globalThis.terraWorldCircuit = original;
  installCycleInstrumentation(summarizeDisplay);
  assert.equal(await globalThis.terraWorldCircuit.command(1, JSON.stringify(clockWords(128)), '[]'), plain);
  assert.equal(await globalThis.terraWorldCircuit.computerFrame(1, JSON.stringify(clockWords(128)), JSON.stringify(pixelsWords)), compound);
  assert.equal(received[0], 1); assert.equal(compound.display, display);
  const observation = events.find(e => e.method === 'computerFrame' && e.type === 'bridge-result');
  assert.equal(observation.monitor.litCount, 3); assert.equal('records' in observation.display, false);
  listeners.keydown({type: 'keydown', key: 'ArrowUp', code: 'ArrowUp', isTrusted: true,
    repeat: false, timeStamp: 10, target: {tagName: 'FLT-GLASS-PANE'}});
  assert.deepEqual(events.find(e => e.type === 'dom-key-event').key, 'ArrowUp');
  assert.equal(events.find(e => e.type === 'dom-key-event').isTrusted, true);
  assert.equal(CYCLE_LIMITS.cycles, 3); assert.equal(CYCLE_LIMITS.afterCloseMs, 20000);
  assert.equal(CYCLE_LIMITS.bootBatches * CYCLE_LIMITS.bootBatchPulses, 5120);
});


test('current import readiness cannot reuse prior open result across reset or a new cycle', () => {
  const state = newCycleState(); acceptedOpen(state);
  const nodes = fixture().nodes.concat([{name: {value: '重置'}, ignored: false, role: {value: 'button'}}]);
  assert.equal(cycleReadyEvidence(state, nodes, 1), true);
  observeCycleEvent(state, {type: 'bridge-call', method: 'openSource', callId: 2,
    file: {isFile: true, size: WORLD_BYTES}});
  assert.equal(cycleReadyEvidence(state, nodes, 2), false);
  assert.equal(cycleReadyEvidence(state, nodes, 1), false);
});

test('reset close acknowledgement cannot satisfy the following ordinary close', () => {
  const state = newCycleState(); acceptedOpen(state); acceptedClose(state);
  acceptedOpen(state, 2, 3, 2);
  observeCycleEvent(state, {type: 'bridge-call', method: 'close', callId: 4, requestSession: 2});
  observeCycleEvent(state, {type: 'world-worker-terminated', workerId: 2});
  assert.equal(state.closeAcks, 1); assert.equal(closedEvidence(state), false);
  observeCycleEvent(state, {type: 'bridge-result', method: 'close', callId: 2});
  assert.equal(closedEvidence(state), false); assert.match(state.errors[0].message, /Unmatched/);
});

test('stale display result after reset is attributed and fails instead of proving current pixels', () => {
  const state = newCycleState(); acceptedOpen(state); acceptedClose(state); acceptedOpen(state, 2, 3, 2);
  observeCycleEvent(state, {type: 'bridge-call', method: 'command', callId: 4, requestSession: 2, words: pixelsWords});
  observeCycleEvent(state, {type: 'bridge-result', method: 'command', callId: 4, session: 1,
    monitor: summarizeDisplay(physicalDisplay())});
  assert.match(state.errors[0].message, /stale or mismatched/);
  assert.notEqual(state.display.session, 2);
});


test('release proof must observe a fresh sensor-free interval even when polling overshoots old thresholds', () => {
  const state = newCycleState();
  state.clockPulses = 1024; // A delayed poll already passed release+128 and release+256.
  const drained = releaseWindow(state, 'down');
  assert.equal(releaseWindowComplete(state, 'down', drained), false);
  state.clockPulses = 1152;
  state.inputAcks.down.push({callId: 9});
  assert.equal(releaseWindowComplete(state, 'down', drained), false);
  state.inputAcks.down.pop();
  assert.equal(releaseWindowComplete(state, 'down', drained), true);
});

test('balanced transient worker or session activity during after-close tail still fails quiet ownership', () => {
  const state = newCycleState(); acceptedOpen(state); acceptedClose(state);
  const snapshot = ownershipSnapshot(state);
  assert.equal(quietCloseEvidence(state, snapshot), true);
  observeCycleEvent(state, {type: 'world-worker-created', workerId: 2});
  observeCycleEvent(state, {type: 'world-worker-terminated', workerId: 2});
  assert.equal(closedEvidence(state), true);
  assert.equal(quietCloseEvidence(state, snapshot), false);
  const clean = newCycleState(); acceptedOpen(clean); acceptedClose(clean);
  const prior = ownershipSnapshot(clean); acceptedOpen(clean, 2, 3, 2); acceptedClose(clean, 2, 4, 2);
  assert.equal(closedEvidence(clean), true); assert.equal(quietCloseEvidence(clean, prior), false);
});


test('UI reveal uses bounded wheel motion and rejects missing geometry before clicking', () => {
  const viewport = {width: 1440, height: 1100};
  assert.equal(clickGeometry([100, 100, 300, 100, 300, 200, 100, 200], viewport).visible, true);
  const below = clickGeometry([100, 2000, 300, 2000, 300, 2100, 100, 2100], viewport);
  assert.equal(below.visible, false); assert.equal(below.wheelY, 700);
  assert.equal(below.wheelX, 0);
  const above = clickGeometry([100, -2000, 300, -2000, 300, -1900, 100, -1900], viewport);
  assert.equal(above.wheelY, -700);
  assert.throws(() => clickGeometry([], viewport));
  assert.throws(() => clickGeometry(Array(8).fill(0), viewport));
  assert.equal(CYCLE_LIMITS.revealAttempts, 12);
});


test('CLI selects baseline or explicit cycle mode and rejects non-owned URL before any CDP access', () => {
  const script = fileURLToPath(new URL('./browser_load_driver.mjs', import.meta.url));
  for (const mode of [[], ['--cycles=3']]) {
    const result = spawnSync(process.execPath, [script, '1', 'https://example.invalid/', '/tmp/fixture', '/tmp/evidence', ...mode],
      {encoding: 'utf8', timeout: 3000});
    assert.equal(result.status, 1);
    assert.match(result.stderr, /owned loopback/);
    assert.doesNotMatch(result.stderr, /Unsettled top-level await/);
  }
  const result = spawnSync(process.execPath, [script, '1', 'https://example.invalid/', '/tmp/fixture', '/tmp/evidence', '--cycles=4'],
    {encoding: 'utf8', timeout: 3000});
  assert.equal(result.status, 1); assert.match(result.stderr, /explicit --cycles=3/);
});


test('actual PIXELS DONE count zero coexists with 3072 independently validated RESULT records', () => {
  // Native producer: native/vendor/TerraWasm/src/terra_circuit_world.c:221-222
  // clears the final envelope, assigning result_count only for SAVE/FRAGMENTS/EXTRACT.
  // Web bridge: web/terra_world_circuit.js pump collects RESULT record bytes,
  // then separately copies READY/DONE resultCount. Product decode checks kind/bytes.
  const result = physicalDisplay();
  assert.equal(result.resultKind, 9); assert.equal(result.resultCount, 0);
  assert.equal(result.records.byteLength, 3072 * 16);
  const summary = summarizeDisplay(result);
  assert.equal(summary.pixelCount, 3072); assert.equal(summary.litCount, 3);
});

test('malformed monitor observation retains scalar shape and forwards original result without pixel buffers', async t => {
  const keys = ['Worker', 'terraWorldCircuit', '__abcBrowserDiagnostic', 'addEventListener'];
  const saved = Object.fromEntries(keys.map(key => [key, Object.getOwnPropertyDescriptor(globalThis, key)]));
  t.after(() => { for (const key of keys) {
    if (saved[key]) Object.defineProperty(globalThis, key, saved[key]); else delete globalThis[key];
  } });
  const events = [];
  globalThis.addEventListener = () => {};
  globalThis.Worker = class { addEventListener() {} terminate() {} };
  globalThis.__abcBrowserDiagnostic = value => events.push(JSON.parse(value));
  const malformed = physicalDisplay(); malformed.records = malformed.records.subarray(16);
  const compound = {clock: {session: 1}, display: malformed, displayError: null};
  globalThis.terraWorldCircuit = Object.freeze(Object.fromEntries(['open', 'openSource', 'progress', 'command',
    'computerFrame', 'close', 'cleanup', 'releaseSource'].map(method => [method,
      async () => method === 'computerFrame' ? compound : malformed])));
  installCycleInstrumentation(summarizeDisplay);
  assert.equal(await globalThis.terraWorldCircuit.command(1, JSON.stringify(pixelsWords), '[]'), malformed);
  assert.equal(await globalThis.terraWorldCircuit.computerFrame(1, JSON.stringify(clockWords(128)), JSON.stringify(pixelsWords)), compound);
  const errors = events.filter(e => e.type === 'observation-error');
  assert.equal(errors.length, 2);
  for (const error of errors) {
    assert.match(error.message, /shape mismatch/);
    assert.deepEqual(error.resultShape, {resultKind: 9, resultCount: 0,
      recordsConstructor: 'Uint8Array', recordsByteLength: 49136});
    assert.equal('records' in error, false); assert.equal('records' in error.resultShape, false);
    assert.ok(JSON.stringify(error).length < 600);
  }
});


// Reduced from run37969035697 failure-accessibility.json. Keep actual role,
// focusability, label and parent/child structure; omit unrelated Chrome fields.
function observedMonitorAX() {
  return [
    {nodeId: '541', ignored: false, role: {type: 'role', value: 'button'},
      name: {type: 'computedString', value: '黑白显示器，显示实际物理像素状态'},
      properties: [{name: 'focusable', value: {type: 'booleanOrUndefined', value: true}}],
      childIds: ['3474'], backendDOMNodeId: 541},
    {nodeId: '3474', ignored: false, role: {type: 'internalRole', value: 'StaticText'},
      name: {type: 'computedString', value: '黑白显示器，显示实际物理像素状态'},
      properties: [], parentId: '541', childIds: ['-1000012662'], backendDOMNodeId: 3474},
    {nodeId: '-1000012662', ignored: false, role: {type: 'internalRole', value: 'InlineTextBox'},
      name: {type: 'computedString', value: '黑白显示器，显示实际物理像素状态'},
      properties: [], parentId: '3474', childIds: []},
  ];
}

test('actual Flutter merged monitor button is selected despite same-label text descendants', () => {
  const nodes = observedMonitorAX();
  assert.equal(displayNode(nodes), nodes[0]);
  assert.equal(displayNode(nodes).backendDOMNodeId, 541);
  assert.equal(displayNode(nodes.slice(1)), null);
});

test('monitor image roles remain supported without selecting static label text', () => {
  for (const role of ['image', 'img']) {
    const nodes = observedMonitorAX(); nodes[0].role.value = role;
    assert.equal(displayNode(nodes), nodes[0]);
  }
});

test('disabled, ignored and non-exact monitor labels cannot be focus-click targets', () => {
  for (const change of [node => node.properties.push({name: 'disabled', value: {type: 'boolean', value: true}}),
    node => node.ignored = true,
    node => node.name.value += ' unrelated']) {
    const nodes = observedMonitorAX(); change(nodes[0]);
    assert.equal(displayNode(nodes), null);
  }
});

test('multiple actionable exact-label monitors fail closed even across button/image roles', () => {
  for (const role of ['button', 'image', 'img']) {
    const nodes = observedMonitorAX();
    const extra = structuredClone(nodes[0]); extra.nodeId = '999'; extra.backendDOMNodeId = 999;
    extra.role.value = role; nodes.push(extra);
    assert.equal(displayNode(nodes), null);
  }
});
