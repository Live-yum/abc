/* Original bounded owner protocol. A command is an atomic rules transaction;
 * cancellation drops queued work after the current transaction boundary. */
(function(root) {
  'use strict';
  const METHODS = new Set(['capabilities', 'catalog', 'editor.new', 'editor.open', 'editor.demo', 'editor.snapshot', 'editor.command', 'editor.close', 'simulation.command', 'simulation.cancel', 'simulation.reset']);
  const MAX_BYTES = 16 * 1024 * 1024, MAX_PENDING = 32;
  function installCircuitRulesWorker(scope, load, schedule = callback => setTimeout(callback, 0)) {
    let owner = null, loading = null, generation = 0, queuedBytes = 0, running = false, closed = false;
    const queue = [];
    const reply = (request, value) => scope.postMessage({ id: request.id, generation: request.generation, ...value });
    const reject = (request, code, error) => reply(request, { ok: false, code, error });
    async function drain() {
      if (running || closed || !queue.length) return;
      running = true;
      try {
        if (!owner) {
          owner = await (loading ||= Promise.resolve().then(load));
          if (closed) { owner.invoke('dispose', []); owner = null; return; }
        }
        const request = queue.shift();
        if (!request) return;
        queuedBytes -= request.bytes;
        if (request.generation !== generation) { reject(request, 'STALE_OPERATION', 'Circuit operation was superseded'); return; }
        try {
          const value = JSON.stringify(owner.invoke(request.method, request.decoded));
          if (typeof value !== 'string' || value.length > MAX_BYTES || new TextEncoder().encode(value).length > MAX_BYTES) throw Object.assign(new Error('Circuit reply exceeds the byte limit'), { code: 'CIRCUIT_LIMIT' });
          reply(request, { ok: true, value });
        } catch (error) { reject(request, error.code || 'CIRCUIT_COMMAND', String(error.message || error)); }
      } catch (error) {
        loading = null;
        for (const request of queue.splice(0)) reject(request, 'COMPUTATION_OWNER_LOST', String(error.message || error));
        queuedBytes = 0;
      } finally {
        running = false;
        if (queue.length && !closed) schedule(drain);
      }
    }
    scope.onmessage = ({ data }) => {
      if (closed || !data || !Number.isSafeInteger(data.id) || data.id < 1 || !Number.isSafeInteger(data.generation) || data.generation < 1) return;
      try {
        if (!METHODS.has(data.method)) throw Object.assign(new Error('Unsupported circuit method'), { code: 'CIRCUIT_COMMAND' });
        if (typeof data.args !== 'string' || data.args.length > MAX_BYTES) throw Object.assign(new Error('Circuit request exceeds the byte limit'), { code: 'CIRCUIT_LIMIT' });
        const bytes = new TextEncoder().encode(data.args).length;
        if (bytes > MAX_BYTES) throw Object.assign(new Error('Circuit request exceeds the byte limit'), { code: 'CIRCUIT_LIMIT' });
        const decoded = JSON.parse(data.args);
        if (!Array.isArray(decoded) || decoded.length > 8) throw Object.assign(new Error('Circuit arguments must be an array'), { code: 'CIRCUIT_COMMAND' });
        if (data.generation < generation) { reject(data, 'STALE_OPERATION', 'Circuit operation was superseded'); return; }
        if (data.generation > generation) {
          generation = data.generation;
          for (const request of queue.splice(0)) reject(request, 'STALE_OPERATION', 'Circuit operation was superseded');
          queuedBytes = 0;
        }
        if (queue.length >= MAX_PENDING || queuedBytes + bytes > MAX_BYTES * 2) throw Object.assign(new Error('Circuit request queue is full'), { code: 'CIRCUIT_LIMIT' });
        queue.push({ ...data, decoded, bytes }); queuedBytes += bytes;
        schedule(drain);
      } catch (error) { reject(data, error.code || 'CIRCUIT_COMMAND', String(error.message || error)); }
    };
    return { dispose() {
      closed = true;
      for (const request of queue.splice(0)) reject(request, 'COMPUTATION_OWNER_LOST', 'Circuit owner was disposed');
      queuedBytes = 0;
      owner?.invoke('dispose', []); owner = null;
      scope.onmessage = null;
    } };
  }
  async function load() {
    const base = new URL('engine/', root.location.href);
    root.importScripts(new URL('world.js', base).href, new URL('circuit_rules_web.js', base).href);
    const Module = await root.TerraWorldWasmWeb({ locateFile: name => new URL(name.endsWith('.wasm') ? 'world.wasm' : name, base).href });
    if (Module._terra_circuit_abi_version?.() !== 1) throw new Error('Verified circuit WASM ABI is unavailable');
    return root.createTerraCircuitRules(Module);
  }
  if (typeof module === 'object' && module.exports) module.exports = { installCircuitRulesWorker };
  else installCircuitRulesWorker(root, load);
})(globalThis);
