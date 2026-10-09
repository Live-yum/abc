/* Bounded RPC for isolated document, whole-world circuit, and traversal owners.
 * A lost owner is never replayed: callers must explicitly reopen their source.
 * Only copied input buffers are transferred, preserving the caller's originals. */
(function(root) {
  'use strict';
  const MiB = 1024 * 1024, MAX_PENDING = 16, MAX_DOCUMENTS = 32, MAX_QUEUED_BYTES = 96 * MiB;
  const MAX_RESPONSE_BYTES = 160 * MiB, DEFAULT_TIMEOUT = 120000;
  const METHODS = Object.freeze({
    document: ['open', 'createPlayer', 'projectPlayer', 'inspect', 'mutate', 'save', 'preview', 'generateMap', 'close'],
    worldCircuit: ['open', 'command', 'close'],
    circuit: ['propagate'],
  });
  const fail = (code, message) => Object.assign(new Error(message), {code});
  const invalid = message => { throw fail('WORKER_INPUT', message); };
  const ownerLost = message => fail('COMPUTATION_OWNER_LOST', message + '; explicitly reopen the source before continuing');
  function string(value, max) {
    if (typeof value !== 'string' || value.length > max || new TextEncoder().encode(value).length > max) invalid('Text exceeds worker input budget');
    return value.length * 2;
  }
  function bytes(value, max, optional = false) {
    if (optional && value == null) return 0;
    if (!(value instanceof Uint8Array) || (!optional && !value.length) || value.length > max) invalid('Bytes exceed worker input budget');
    return value.byteLength;
  }
  function handle(value) { if (!Number.isSafeInteger(value) || value < 1) invalid('Invalid computation handle'); }
  function validate(owner, method, args) {
    if (!Object.hasOwn(METHODS, owner) || !METHODS[owner].includes(method)) invalid('Unknown worker method');
    if (!Array.isArray(args)) invalid('Worker arguments must be an array');
    const counts = owner === 'document' ? {open:2, createPlayer:1, projectPlayer:1, inspect:1, mutate:3, save:1, preview:1, generateMap:2, close:1} : owner === 'worldCircuit' ? {open:2, command:3, close:1} : {propagate:6};
    if (args.length !== counts[method]) invalid('Invalid worker argument count');
    let size = 64;
    if (owner === 'document') {
      if (method === 'open') {
        if (!['wld', 'plr'].includes(args[1])) invalid('Only WLD and PLR files are supported');
        size += bytes(args[0], (args[1] === 'wld' ? 64 : 2) * MiB);
      } else if (method === 'createPlayer') size += string(args[0], 400);
      else if (method === 'projectPlayer') size += string(args[0], 4 * MiB);
      else {
        handle(args[0]);
        if (method === 'mutate') {
          if (!['player_patch','patch','header_patch','world_patch','replace_chests','replace_bestiary'].includes(args[1])) invalid('Unsupported document mutation');
          size += string(args[2], 8 * MiB);
        }
        if (method === 'generateMap') size += string(args[1], 8 * MiB);
      }
    } else if (owner === 'worldCircuit') {
      if (method === 'open') size += bytes(args[0], 64 * MiB) + bytes(args[1], 16 * MiB, true);
      else {
        handle(args[0]);
        if (method === 'command') size += string(args[1], 1024) + string(args[2], 4 * MiB);
      }
    } else {
      const [width,height,json,x,y,colour] = args;
      if (![width,height,x,y,colour].every(Number.isInteger) || width<1 || height<1 || width>256 || height>256 || x<0 || y<0 || x>=width || y>=height || colour<0 || colour>3) invalid('Invalid traversal geometry');
      size += string(json, 4 * MiB);
    }
    return size;
  }
  function measure(value, depth = 0, state = {nodes:0}) {
    if (++state.nodes > 300000 || depth > 8) invalid('Worker response exceeds structure budget');
    if (value == null || typeof value === 'boolean' || typeof value === 'number') return 8;
    if (typeof value === 'string') return string(value, 8 * MiB);
    if (value instanceof Uint8Array) return value.byteLength;
    if (typeof value !== 'object') invalid('Invalid worker response');
    let size = 0;
    for (const child of Object.values(value)) { size += measure(child, depth + 1, state); if (size > MAX_RESPONSE_BYTES) invalid('Worker response exceeds byte budget'); }
    return size;
  }
  function validateResult(owner, method, value) {
    if (measure(value) > MAX_RESPONSE_BYTES) invalid('Worker response exceeds byte budget');
    if (owner === 'document') {
      if (['open','createPlayer','inspect'].includes(method)) string(value, 8 * MiB);
      else if (['save','projectPlayer','generateMap'].includes(method)) bytes(value, (method === 'generateMap' ? 128 : method === 'projectPlayer' ? 2 : 64) * MiB);
      else if (method === 'preview') bytes(value, 16 * MiB, true);
      else if (value != null) invalid('Invalid document completion response');
    } else if (owner === 'circuit') string(value, 4 * MiB);
    else if (method === 'close') { if (value != null) invalid('Invalid circuit completion response'); }
    else {
      if (!value || typeof value !== 'object' || !Array.isArray(value.stats) || value.stats.length !== 24 || value.stats.some(v => !Number.isInteger(v) || v < 0 || v > 0xffffffff)) invalid('Invalid circuit response');
      handle(value.session);
      for (const field of ['resultKind','resultCount','reserved']) if (!Number.isInteger(value[field]) || value[field] < 0 || value[field] > 0xffffffff) invalid('Invalid circuit result field');
      bytes(value.records, 8 * MiB, true);
      for (const field of ['world','twld','objects']) bytes(value[field], (field === 'objects' ? 4 : field === 'twld' ? 16 : 64) * MiB, true);
    }
  }
  function transfers(value, result = [], seen = new Set()) {
    if (value instanceof Uint8Array) {
      if (!seen.has(value.buffer)) { seen.add(value.buffer); result.push(value.buffer); }
    } else if (value && typeof value === 'object') for (const child of Object.values(value)) transfers(child, result, seen);
    return result;
  }
  function createClient(owner, {createWorker, timeoutMs = DEFAULT_TIMEOUT} = {}) {
    if (!Object.hasOwn(METHODS, owner)) invalid('Unknown worker owner');
    if (!Number.isInteger(timeoutMs) || timeoutMs < 1 || timeoutMs > 600000) invalid('Invalid worker timeout');
    let worker = null, generation = 1, sequence = 0, nextHandle = 1, queuedBytes = 0, active = null;
    const pending = new Map(), handles = new Map();
    function shutdown(error) {
      generation++;
      const old = worker; worker = null; active = null; handles.clear();
      if (old) { old.onmessage = old.onerror = old.onmessageerror = null; try { old.terminate(); } catch (_) {} }
      for (const request of pending.values()) { clearTimeout(request.timer); request.reject(error); }
      pending.clear(); queuedBytes = 0;
    }
    function ensureWorker() {
      if (worker) return worker;
      if (!createWorker && (typeof root.Worker !== 'function' || !root.document)) throw ownerLost('Dedicated Web Workers are unavailable');
      const current = createWorker ? createWorker(owner) : new root.Worker(new URL('terra_engine_worker.js?owner=' + owner, root.document.baseURI));
      worker = current;
      current.onmessage = event => {
        if (worker !== current) return;
        const data = event.data;
        if (!data || data.generation !== generation) return;
        const request = pending.get(data.id);
        if (!request || active !== request) return;
        if (data.ok !== true && data.ok !== false) { shutdown(ownerLost('Invalid worker response')); return; }
        pending.delete(data.id); queuedBytes -= request.bytes; clearTimeout(request.timer); active = null;
        if (data.ok === false) request.reject(fail(typeof data.code === 'string' ? data.code.slice(0,80) : 'WORKER_ENGINE', typeof data.error === 'string' ? data.error.slice(0,2048) : 'Worker operation failed'));
        else {
          try {
            validateResult(owner, request.method, data.value);
            let value = data.value;
            if ((owner === 'document' && ['open','createPlayer'].includes(request.method)) || (owner === 'worldCircuit' && request.method === 'open')) {
              const model = owner === 'document' ? JSON.parse(value) : value;
              const native = model[owner === 'document' ? 'handle' : 'session']; handle(native);
              const publicHandle = nextHandle++;
              if (!Number.isSafeInteger(publicHandle)) throw ownerLost('Computation handle space exhausted');
              handles.set(publicHandle, {native, generation, closing:false});
              model[owner === 'document' ? 'handle' : 'session'] = publicHandle;
              value = owner === 'document' ? JSON.stringify(model) : model;
            } else if (owner === 'worldCircuit' && request.method === 'command') {
              if (!value || value.session !== request.args[0]) invalid('Mismatched circuit result');
              value.session = request.publicHandle;
            }
            if (request.method === 'close') handles.delete(request.publicHandle);
            request.resolve(value);
          } catch (error) { request.reject(error); shutdown(ownerLost('Invalid worker result')); return; }
        }
        dispatch();
      };
      current.onerror = current.onmessageerror = () => { if (worker === current) shutdown(ownerLost('Computation worker stopped')); };
      return current;
    }
    function dispatch() {
      if (active || !pending.size) return;
      const request = pending.values().next().value;
      try {
        const current = ensureWorker(); active = request;
        current.postMessage({id:request.id, generation, method:request.method, args:request.args}, transfers(request.args));
      } catch (_) { shutdown(ownerLost('Could not send the computation request')); }
    }
    function invoke(method, input) {
      try {
        const size = validate(owner, method, input);
        if (pending.size >= MAX_PENDING || queuedBytes + size > MAX_QUEUED_BYTES) throw fail('WORKER_LIMIT', 'Computation request queue is full');
        if (owner === 'document' && ['open','createPlayer'].includes(method) &&
            handles.size + [...pending.values()].filter(request => ['open','createPlayer'].includes(request.method)).length >= MAX_DOCUMENTS) {
          throw fail('WORKER_LIMIT', 'Close a document before opening another');
        }
        const args = input.slice(); let publicHandle;
        if ((owner === 'document' && !['open','createPlayer','projectPlayer'].includes(method)) || (owner === 'worldCircuit' && method !== 'open')) {
          publicHandle = args[0]; const entry = handles.get(publicHandle);
          if (!entry || entry.generation !== generation || entry.closing) {
            // Cleanup after a lost owner must not prevent an explicit reopen.
            // Never forward a stale close to a new owner's reused native handle.
            if (method === 'close') return Promise.resolve();
            throw fail('STALE_HANDLE', 'Computation handle is closed or belongs to a lost owner; reopen the source');
          }
          args[0] = entry.native;
          if (method === 'close') entry.closing = true;
        }
        // Snapshot now, before queueing; never transfer an application-owned buffer.
        for (let i=0;i<args.length;i++) if (args[i] instanceof Uint8Array) args[i] = Uint8Array.from(args[i]);
        const id = ++sequence;
        if (!Number.isSafeInteger(id)) throw fail('WORKER_LIMIT', 'Computation request identity space exhausted');
        return new Promise((resolve,reject) => {
          const request = {id, method, args, publicHandle, bytes:size, resolve, reject};
          request.timer = setTimeout(() => { if (pending.has(id)) shutdown(ownerLost('Computation worker timed out')); }, timeoutMs);
          pending.set(id, request); queuedBytes += size; dispatch();
        });
      } catch (error) { return Promise.reject(error); }
    }
    const client = {};
    for (const method of METHODS[owner]) client[method] = (...args) => invoke(method, args);
    // Cancellation is owner-wide: an interrupted mutation is never retried.
    for (const method of ['reset','cancel','dispose']) client[method] = () => { shutdown(ownerLost('Computation owner was ' + method)); return Promise.resolve(); };
    return Object.freeze(client);
  }
  function installHost(owner, bridge, scope = root) {
    if (!Object.hasOwn(METHODS, owner)) invalid('Unknown worker owner');
    let generation = null, lastId = 0, count = 0, queuedBytes = 0, queue = Promise.resolve();
    const documents = new Set();
    const reply = (data, payload) => scope.postMessage({id:data.id, generation:data.generation, ...payload}, payload.ok ? transfers(payload.value) : []);
    scope.onmessage = ({data}) => {
      let size;
      try {
        if (!data || !Number.isSafeInteger(data.id) || data.id < 1 || data.id <= lastId || !Number.isSafeInteger(data.generation) || data.generation < 1) invalid('Invalid worker request identity');
        if (generation !== null && data.generation !== generation) invalid('Stale worker generation');
        size = validate(owner, data.method, data.args);
        if (count >= MAX_PENDING || queuedBytes + size > MAX_QUEUED_BYTES) throw fail('WORKER_LIMIT', 'Worker queue is full');
        generation = data.generation; lastId = data.id; count++; queuedBytes += size;
      } catch (error) { if (data) reply(data, {ok:false, code:error.code || 'WORKER_INPUT', error:String(error.message || error).slice(0,2048)}); return; }
      const run = queue.then(async () => {
        try {
          if (owner === 'document' && ['open','createPlayer'].includes(data.method) && documents.size >= MAX_DOCUMENTS) throw fail('WORKER_LIMIT', 'Worker document limit reached');
          const value = await bridge[data.method](...data.args);
          if (owner === 'document' && ['open','createPlayer'].includes(data.method)) documents.add(JSON.parse(value).handle);
          if (owner === 'document' && data.method === 'close') documents.delete(data.args[0]);
          validateResult(owner, data.method, value);
          reply(data, {ok:true, value});
        } catch (error) { reply(data, {ok:false, code:error.code || 'WORKER_ENGINE', error:String(error.message || error).slice(0,2048)}); }
        finally { count--; queuedBytes -= size; }
      });
      queue = run.catch(() => {});
    };
  }
  root.TerraWorkerRPC = Object.freeze({createClient, installHost});
  if (typeof module === 'object' && module.exports) module.exports = {createClient, installHost};
})(globalThis);
