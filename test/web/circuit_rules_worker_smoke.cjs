// Exercises the actual browser worker bootstrap in an isolated Node worker,
// with local importScripts/fetch adapters. It does not claim browser UI QA.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { Worker, isMainThread, parentPort, workerData } = require('node:worker_threads');

if (!isMainThread) {
  const files = new Map([
    ['/engine/world.js', workerData.runtime],
    ['/engine/world.wasm', workerData.runtime.replace(/\.js$/, '.wasm')],
    ['/engine/circuit_rules_web.js', path.join(workerData.root, 'web/engine/circuit_rules_web.js')],
  ]);
  let context;
  const scope = {
    console, URL, WebAssembly, TextEncoder, TextDecoder, Uint8Array, ArrayBuffer,
    setTimeout, clearTimeout, performance, WorkerGlobalScope: function() {},
    location: { href: 'http://local.invalid/terra_circuit_rules_worker.js' },
    postMessage(data) { parentPort.postMessage(data); },
    importScripts(...urls) {
      for (const url of urls) {
        const file = files.get(new URL(url).pathname);
        assert.ok(file, 'Worker may load only explicitly supplied local assets');
        vm.runInContext(fs.readFileSync(file, 'utf8'), context, { filename: path.basename(file) });
      }
    },
    async fetch(url) {
      const file = files.get(new URL(url).pathname);
      assert.ok(file, 'Worker may fetch only explicitly supplied local assets');
      return new Response(fs.readFileSync(file), { headers: { 'Content-Type': 'application/wasm' } });
    },
  };
  scope.self = scope;
  context = vm.createContext(scope);
  vm.runInContext(fs.readFileSync(path.join(workerData.root, 'web/terra_circuit_rules_worker.js'), 'utf8'), context);
  parentPort.on('message', data => scope.onmessage({ data }));
} else {
  const { createCircuitRulesClient } = require('../../web/terra_circuit_rules.js');
  (async () => {
    const runtime = process.env.TERRA_WORLD_RUNTIME;
    assert.ok(runtime, 'Set TERRA_WORLD_RUNTIME to a verified local world.js');
    const workers = [], exits = [];
    const client = createCircuitRulesClient({ createWorker() {
      const thread = new Worker(__filename, { workerData: { runtime: path.resolve(runtime), root: path.resolve(__dirname, '../..') } });
      const proxy = { postMessage: data => thread.postMessage(data), terminate: () => thread.terminate() };
      thread.on('message', data => proxy.onmessage?.({ data }));
      thread.on('error', error => { console.error(error.message); proxy.onerror?.(error); });
      workers.push(thread); exits.push(new Promise(resolve => thread.once('exit', resolve)));
      return proxy;
    } });
    const invoke = async (method, args = []) => JSON.parse(await client.invoke(method, JSON.stringify(args)));
    assert.equal((await invoke('capabilities')).available, true);
    const catalog = await invoke('catalog'); assert.equal(catalog.palette.length, 2776);
    const loaded = await invoke('editor.demo', ['devices']);
    let state = await invoke('simulation.command', [{ method: 'interact', args: [3, 3], debug: true }]);
    assert.equal(state.packet.native.backend, 'wasm');
    assert.equal(state.packet.native.fallback, false);
    assert.ok(state.packet.native.commandVisits > 0);
    assert.equal(state.packet.structureChanged, true);
    assert.notEqual(state.document, loaded.document);
    state = await invoke('simulation.reset'); assert.equal(state.document, loaded.document);
    const old = invoke('simulation.command', [{ method: 'step', args: [60] }]);
    const rejected = assert.rejects(old, { code: 'STALE_OPERATION' });
    await invoke('simulation.cancel'); await rejected;
    await invoke('editor.close'); await invoke('host.reset');
    await exits[0];
    assert.equal((await invoke('editor.new', ['Recreated owner'])).id, 1);
    assert.equal(workers.length, 2);
    await client.dispose(); await exits[1];
    console.log('PASS actual worker bootstrap: catalog, structural device event, WASM diagnostics, reset, cancel, close, terminate/recreate');
  })().catch(error => { console.error(error.message); process.exitCode = 1; });
}
