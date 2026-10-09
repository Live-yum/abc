const { test } = require('node:test');
const assert = require('node:assert/strict');
const { createCircuitRulesClient } = require('../../web/terra_circuit_rules.js');
const { installCircuitRulesWorker } = require('../../web/terra_circuit_rules_worker.js');

const flush = () => new Promise(resolve => setTimeout(resolve, 5));
function harness(load) {
  const callbacks = [], calls = [], replies = [];
  let termination = 0;
  const scope = { postMessage(data) { replies.push(data); queueMicrotask(() => worker.onmessage?.({ data })); } };
  const owner = installCircuitRulesWorker(scope, load || (() => ({ invoke(method, args) { calls.push([method, args]); return { method, args }; } })), callback => callbacks.push(callback));
  const worker = { postMessage(data) { scope.onmessage({ data }); }, terminate() { termination++; owner.dispose(); } };
  const client = createCircuitRulesClient({ createWorker: () => worker });
  return { client, worker, scope, calls, replies, callbacks, termination: () => termination,
    async drain() { while (callbacks.length) { await callbacks.shift()(); await flush(); } } };
}

test('whitelist and JSON/UTF-8 limits reject before dispatch', async () => {
  let created = 0;
  const client = createCircuitRulesClient({ createWorker() { created++; throw new Error('unexpected'); } });
  await assert.rejects(client.invoke('constructor', '[]'), { code: 'CIRCUIT_COMMAND' });
  await assert.rejects(client.invoke('editor.command', '{}'), { code: 'CIRCUIT_COMMAND' });
  await assert.rejects(client.invoke('editor.open', JSON.stringify(['字'.repeat(6 * 1024 * 1024)])), { code: 'CIRCUIT_LIMIT' });
  assert.equal(created, 0);
});

test('cancel invalidates queued simulation and stale replies', async () => {
  const h = harness();
  const stale = h.client.invoke('simulation.command', '[{"method":"step","args":[60]}]');
  const rejected = assert.rejects(stale, { code: 'STALE_OPERATION' });
  const cancel = h.client.invoke('simulation.cancel', '[]');
  h.worker.onmessage({ data: { id: 1, generation: 1, ok: true, value: '"stale"' } });
  await h.drain(); await rejected;
  assert.equal(JSON.parse(await cancel).method, 'simulation.cancel');
  assert.deepEqual(h.calls, [['simulation.cancel', []]]);
  await h.client.dispose();
});

test('newer editor drops old edit; close releases owner on page lifecycle', async () => {
  const h = harness();
  const pending = h.client.invoke('editor.command', '[{"method":"undo","args":[]}]');
  const rejected = assert.rejects(pending, { code: 'STALE_OPERATION' });
  const opened = h.client.invoke('editor.new', '["new"]');
  await h.drain(); await rejected; await opened;
  const closing = h.client.invoke('editor.close', '[]'); await h.drain(); await closing;
  await h.client.dispose();
  assert.equal(h.termination(), 1);
  assert.deepEqual(h.calls.map(row => row[0]), ['editor.new', 'editor.close', 'dispose']);
});

test('worker load failure rejects work and permits explicit retry', async () => {
  let attempt = 0;
  const h = harness(() => { if (++attempt === 1) throw new Error('missing private engine'); return { invoke: () => null }; });
  const pending = h.client.invoke('catalog', '[]');
  const rejected = assert.rejects(pending, /missing private engine/);
  await h.drain(); await rejected;
  const retry = h.client.invoke('capabilities', '[]'); await h.drain(); assert.equal(await retry, 'null');
  await h.client.dispose();
});

test('one failed startup rejects its queued batch without implicit reloads', async () => {
  let attempts = 0;
  const h = harness(() => { attempts++; throw new Error('missing private engine'); });
  const rejected = Array.from({ length: 3 }, () => assert.rejects(h.client.invoke('catalog', '[]'), /missing private engine/));
  await h.drain(); await Promise.all(rejected);
  assert.equal(attempts, 1);
  await h.client.dispose();
});

test('dispose while loading releases a late owner and emits no stale result', async () => {
  let resolveLoad, disposed = 0;
  const h = harness(() => new Promise(resolve => { resolveLoad = resolve; }));
  const pending = h.client.invoke('catalog', '[]');
  const rejected = assert.rejects(pending, { code: 'COMPUTATION_OWNER_LOST' });
  const draining = h.callbacks.shift()(); await flush();
  await h.client.dispose();
  resolveLoad({ invoke(method) { if (method === 'dispose') disposed++; } });
  await draining; await rejected;
  assert.equal(disposed, 1);
  assert.equal(h.replies.some(reply => reply.ok), false);
});

test('bounded queue rejects overflow and termination rejects outstanding work', async () => {
  const h = harness();
  const pending = Array.from({ length: 32 }, () => assert.rejects(h.client.invoke('catalog', '[]'), { code: 'COMPUTATION_OWNER_LOST' }));
  await assert.rejects(h.client.invoke('catalog', '[]'), { code: 'CIRCUIT_LIMIT' });
  await h.client.dispose(); await Promise.all(pending);
  assert.equal(h.termination(), 1);
});

test('timeout terminates owner; late replies cannot attach to a new owner', async () => {
  const workers = [];
  const client = createCircuitRulesClient({ timeoutMs: 10, createWorker() {
    const worker = { postMessage() {}, terminate() { this.terminated = true; } }; workers.push(worker); return worker;
  } });
  await assert.rejects(client.invoke('catalog', '[]'), /timed out/);
  assert.equal(workers[0].terminated, true);
  const request = client.invoke('capabilities', '[]');
  assert.equal(workers.length, 2);
  workers[1].onmessage({ data: { id: 2, generation: 2, ok: true, value: '{"available":true}' } });
  assert.equal(JSON.parse(await request).available, true);
  await client.dispose();
});

test('worker rejects direct unsupported and stale commands without invoking rules', async () => {
  const h = harness();
  h.scope.onmessage({ data: { id: 99, generation: 4, method: 'constructor', args: '[]' } });
  h.scope.onmessage({ data: { id: 100, generation: 4, method: 'catalog', args: '[]' } });
  h.scope.onmessage({ data: { id: 101, generation: 3, method: 'editor.new', args: '[]' } });
  await h.drain();
  assert.equal(h.replies.find(row => row.id === 99).code, 'CIRCUIT_COMMAND');
  assert.equal(h.replies.find(row => row.id === 101).code, 'STALE_OPERATION');
  assert.deepEqual(h.calls, [['catalog', []]]);
  await h.client.dispose();
});

test('host.reset terminates only circuit owner and is never sent to rules', async () => {
  const sentinel = globalThis.terraWorldCircuit = { existingWorld: 42 };
  const h = harness();
  const pending = h.client.invoke('catalog', '[]');
  const rejected = assert.rejects(pending, { code: 'COMPUTATION_OWNER_LOST' });
  assert.equal(await h.client.invoke('host.reset', '[]'), 'null');
  await rejected;
  assert.equal(h.termination(), 1);
  assert.equal(h.calls.some(row => row[0] === 'host.reset'), false);
  assert.equal(globalThis.terraWorldCircuit, sentinel);
  await assert.rejects(h.client.invoke('host.reset', '[1]'), { code: 'CIRCUIT_COMMAND' });
  delete globalThis.terraWorldCircuit;
});
