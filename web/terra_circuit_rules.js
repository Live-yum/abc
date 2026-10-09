/* Original JSON-only client. Rules and WASM execute in a dedicated owner. */
(function(root) {
  'use strict';
  const METHODS = new Set(['capabilities', 'catalog', 'editor.new', 'editor.open', 'editor.demo', 'editor.snapshot', 'editor.command', 'editor.close', 'simulation.command', 'simulation.cancel', 'simulation.reset', 'dispose', 'host.reset']);
  const INVALIDATES = new Set(['editor.new', 'editor.open', 'editor.demo', 'editor.close', 'simulation.cancel', 'simulation.reset']);
  const MAX_BYTES = 16 * 1024 * 1024, MAX_PENDING = 32;
  const failure = (code, message) => Object.assign(new Error(message), { code });
  function createCircuitRulesClient({ createWorker, timeoutMs = 60000 } = {}) {
    let worker = null, sequence = 0, generation = 1, queuedBytes = 0;
    const pending = new Map();
    function rejectPending(error) {
      for (const request of pending.values()) { clearTimeout(request.timer); request.reject(error); }
      pending.clear(); queuedBytes = 0;
    }
    function shutdown(error) {
      generation++;
      const old = worker; worker = null;
      if (old) { old.onmessage = old.onerror = old.onmessageerror = null; old.terminate(); }
      rejectPending(error);
    }
    function ensureWorker() {
      if (worker) return worker;
      const current = (createWorker || (() => new root.Worker(new URL('terra_circuit_rules_worker.js', root.document.baseURI))))();
      worker = current;
      current.onmessage = event => {
        if (worker !== current) return;
        const data = event.data;
        if (!data || data.generation !== generation || !Number.isSafeInteger(data.id)) return;
        const request = pending.get(data.id);
        if (!request) return;
        pending.delete(data.id); queuedBytes -= request.bytes; clearTimeout(request.timer);
        if (data.ok === true && typeof data.value === 'string' && data.value.length <= MAX_BYTES && new TextEncoder().encode(data.value).length <= MAX_BYTES) request.resolve(data.value);
        else request.reject(failure(typeof data.code === 'string' ? data.code : 'CIRCUIT_HOST', typeof data.error === 'string' ? data.error : 'Invalid circuit worker response'));
      };
      current.onerror = current.onmessageerror = () => {
        if (worker === current) shutdown(failure('COMPUTATION_OWNER_LOST', 'Circuit worker stopped; reopen the circuit document'));
      };
      return current;
    }
    function invoke(method, encodedArgs) {
      try {
        if (!METHODS.has(method)) throw failure('CIRCUIT_COMMAND', 'Unsupported circuit method');
        if (typeof encodedArgs !== 'string' || encodedArgs.length > MAX_BYTES) throw failure('CIRCUIT_LIMIT', 'Circuit request exceeds the byte limit');
        const bytes = new TextEncoder().encode(encodedArgs).length;
        if (bytes > MAX_BYTES) throw failure('CIRCUIT_LIMIT', 'Circuit request exceeds the byte limit');
        const args = JSON.parse(encodedArgs);
        if (!Array.isArray(args) || args.length > 8) throw failure('CIRCUIT_COMMAND', 'Circuit arguments must be an array');
        if (method === 'dispose' || method === 'host.reset') {
          if (args.length) throw failure('CIRCUIT_COMMAND', 'Owner reset/dispose takes no arguments');
          shutdown(failure('COMPUTATION_OWNER_LOST', method === 'host.reset' ? 'Circuit owner was reset' : 'Circuit owner was disposed'));
          return Promise.resolve('null');
        }
        if (INVALIDATES.has(method)) {
          generation++;
          rejectPending(failure('STALE_OPERATION', 'Circuit operation was superseded'));
        }
        if (pending.size >= MAX_PENDING || queuedBytes + bytes > MAX_BYTES * 2) throw failure('CIRCUIT_LIMIT', 'Circuit request queue is full');
        const current = ensureWorker(), id = ++sequence;
        return new Promise((resolve, reject) => {
          const timer = setTimeout(() => {
            if (pending.has(id)) shutdown(failure('COMPUTATION_OWNER_LOST', 'Circuit worker timed out; reopen the circuit document'));
          }, timeoutMs);
          pending.set(id, { resolve, reject, timer, bytes }); queuedBytes += bytes;
          try { current.postMessage({ id, generation, method, args: encodedArgs }); }
          catch (error) { shutdown(failure('COMPUTATION_OWNER_LOST', String(error))); }
        });
      } catch (error) { return Promise.reject(error); }
    }
    return Object.freeze({ invoke, dispose: () => invoke('dispose', '[]') });
  }
  root.terraCircuitRules = createCircuitRulesClient();
  if (typeof root.addEventListener === 'function') root.addEventListener('pagehide', () => root.terraCircuitRules.dispose());
  if (typeof module === 'object' && module.exports) module.exports = { createCircuitRulesClient };
})(globalThis);
