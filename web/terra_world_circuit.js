/* Whole-world VM owner. Large sources remain immutable Blob/File handles;
 * scratch and staged outputs use worker-owned random-access OPFS files. */
(function(root) {
'use strict';
const MiB = 1024 * 1024, MAX_SOURCE = 0x7fffffff, NATIVE_BUDGET = 192 * MiB;
const SMALL_WORLD = 64 * MiB, SMALL_TWLD = 16 * MiB, MEMORY_STORAGE = 64 * MiB;
const pause = () => new Promise(resolve => setTimeout(resolve, 0));
const now = () => root.performance?.now() ?? Date.now();
const blob = value => typeof root.Blob === 'function' && value instanceof root.Blob;
const range = (offset, length, size = MAX_SOURCE) => {
 if (!Number.isSafeInteger(offset) || !Number.isSafeInteger(length) || offset < 0 || length < 0 || length > MiB || offset + length > size) throw new Error('Invalid circuit source range');
};

// The fallback is explicitly for small inputs, and has a shared page budget.
// No write ever reallocates or copies the entire accumulated scratch file.
function memoryStorage() {
 const pageSize = 65536, budget = {used:0, peak:0};
 return {
  kind:'memory', budget,
  async create() {
   let size = 0, closed = false; const pages = new Map();
   return {
    get size() { return size; },
    async read(offset, length) {
     range(offset, length, size); const result = new Uint8Array(length);
     for (let at = 0; at < length;) { const index = Math.floor((offset + at) / pageSize), start = (offset + at) % pageSize, n = Math.min(length - at, pageSize - start); const page = pages.get(index); if (page) result.set(page.subarray(start, start + n), at); at += n; }
     return result;
    },
    async write(offset, bytes) {
     if (closed) throw new Error('Circuit storage is closed'); range(offset, bytes.length);
     for (let at = 0; at < bytes.length;) { const index = Math.floor((offset + at) / pageSize), start = (offset + at) % pageSize, n = Math.min(bytes.length - at, pageSize - start); let page = pages.get(index);
      if (!page) { if (budget.used + pageSize > MEMORY_STORAGE) throw new Error('Small-world scratch budget exceeded; persistent browser storage is required'); page = new Uint8Array(pageSize); pages.set(index, page); budget.used += pageSize; budget.peak = Math.max(budget.peak, budget.used); }
      page.set(bytes.subarray(at, at + n), start); at += n;
     }
     size = Math.max(size, offset + bytes.length);
    },
    async snapshot() { const parts = []; for (let at = 0; at < size; at += pageSize) parts.push(await this.read(at, Math.min(pageSize, size - at))); return new root.Blob(parts); },
    async close() { if (closed) return; closed = true; budget.used -= pages.size * pageSize; pages.clear(); size = 0; },
   };
  },
 };
}
async function persistentStorage() {
 const directory = await root.navigator?.storage?.getDirectory?.();
 if (!directory) throw new Error('OPFS is unavailable');
 let sequence = 0;
 const prefix = 'terra-circuit-' + (root.crypto?.randomUUID?.() || Date.now().toString(36) + '-' + Math.random().toString(36).slice(2));
 return {
  kind:'opfs', budget:{used:0, peak:0},
  async create() {
   const name = prefix + '-' + (++sequence), file = await directory.getFileHandle(name, {create:true});
   let access;
   try { access = await file.createSyncAccessHandle(); } catch (error) { await directory.removeEntry(name); throw error; }
   let closed = false, size = 0;
   return {
    get size() { return size; },
    async read(offset, length) { range(offset, length, size); const result = new Uint8Array(length); if (access.read(result, {at:offset}) !== length) throw new Error('Truncated circuit scratch read'); return result; },
    async write(offset, bytes) { range(offset, bytes.length); if (access.write(bytes, {at:offset}) !== bytes.length) throw new Error('Incomplete circuit scratch write'); size = Math.max(size, offset + bytes.length); },
    async snapshot() { access.flush(); return file.getFile(); },
    async close() { if (closed) return; closed = true; access.close(); await directory.removeEntry(name); },
   };
  },
 };
}
// Incremental SHA-256 identifies pinned source data without a whole-file buffer.
// Hashing does not confer authorization. Buffers are one 1-MiB input and 64 words.
class SourceSha256 {
 constructor() { this.h = new Int32Array([0x6a09e667,0xbb67ae85,0x3c6ef372,0xa54ff53a,0x510e527f,0x9b05688c,0x1f83d9ab,0x5be0cd19]); this.block = new Uint8Array(64); this.words = new Int32Array(64); this.used = 0; this.length = 0; }
 compress(bytes, offset = 0) {
  const w = this.words, view = new DataView(bytes.buffer, bytes.byteOffset + offset, 64), r = (x,n) => (x >>> n) | (x << (32-n));
  for (let i=0;i<16;i++) w[i] = view.getInt32(i*4, false);
  for (let i=16;i<64;i++) { const a=w[i-15],b=w[i-2]; w[i]=(w[i-16]+(r(a,7)^r(a,18)^(a>>>3))+w[i-7]+(r(b,17)^r(b,19)^(b>>>10)))|0; }
  let [a,b,c,d,e,f,g,h] = this.h;
  for (let i=0;i<64;i++) { const t1=(h+(r(e,6)^r(e,11)^r(e,25))+((e&f)^(~e&g))+SourceSha256.k[i]+w[i])|0, t2=((r(a,2)^r(a,13)^r(a,22))+((a&b)^(a&c)^(b&c)))|0; h=g;g=f;f=e;e=(d+t1)|0;d=c;c=b;b=a;a=(t1+t2)|0; }
  const result=[a,b,c,d,e,f,g,h]; for(let i=0;i<8;i++) this.h[i]=(this.h[i]+result[i])|0;
 }
 update(bytes) {
  this.length += bytes.length; let offset=0;
  if(this.used) { const n=Math.min(64-this.used,bytes.length); this.block.set(bytes.subarray(0,n),this.used); this.used+=n;offset=n; if(this.used===64){this.compress(this.block);this.used=0;} }
  while(offset+64<=bytes.length){this.compress(bytes,offset);offset+=64;}
  if(offset<bytes.length){this.block.set(bytes.subarray(offset),0);this.used=bytes.length-offset;}
 }
 digest() {
  this.block[this.used++]=0x80;
  if(this.used>56){this.block.fill(0,this.used);this.compress(this.block);this.used=0;}
  this.block.fill(0,this.used,56);const d=new DataView(this.block.buffer);d.setUint32(56,Math.floor(this.length/0x20000000),false);d.setUint32(60,(this.length*8)>>>0,false);this.compress(this.block);
  return Array.from(this.h,v=>(v>>>0).toString(16).padStart(8,'0')).join('');
 }
}
SourceSha256.k = new Int32Array([0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2]);
function createWorldCircuitBridge(loadModule, options = {}) {
 let promise, queue = Promise.resolve(), session = null, operation = null, exportedSequence = 0;
 const exported = new Map();
 let progressState = {stage:'idle', phase:0, completed:0, total:0, nativeBudgetBytes:NATIVE_BUDGET, nativeActiveBytes:0, nativePeakBytes:0, sourceReadBytes:0, sourceReadRequests:0, scratchReadBytes:0, scratchWriteBytes:0, maxReadBytes:0, maxWriteBytes:0, storageBytes:0, hostStorageBytes:0, hostStoragePeakBytes:0, wasmHeapBytes:0, storageKind:'none'};
 const worldCheck = status => { if (status !== 0) throw new Error('World decoder status ' + status); return status; };
 const check = status => { if (status < 0) throw new Error('World circuit engine status ' + status); return status; };
 const serial = fn => { const pending = queue.then(fn); queue = pending.catch(() => {}); return pending; };
 const cancelled = () => { if (operation?.cancelled) throw Object.assign(new Error('World circuit operation cancelled'), {code:'CIRCUIT_CANCELLED'}); };
 function refreshMemory(M, storage, stats) {
  progressState.wasmHeapBytes = M.HEAPU8.length;
  if (storage) { progressState.storageKind = storage.kind; progressState.hostStorageBytes = storage.budget?.used || 0; progressState.hostStoragePeakBytes = storage.budget?.peak || 0; }
  if (stats) { progressState.nativeActiveBytes = stats[16]; progressState.nativePeakBytes = stats[17]; }
 }
 async function cooperate() { await pause(); cancelled(); }
 function source(value) {
  const size = blob(value) ? value.size : value?.byteLength;
  if (!Number.isSafeInteger(size) || size < 1 || size > MAX_SOURCE) throw new Error('World input exceeds streaming source limit');
  if (!blob(value) && !(value instanceof Uint8Array)) throw new Error('Expected immutable File/Blob or small byte source');
  return {size, async read(offset, length) { range(offset, length, size); return blob(value) ? new Uint8Array(await value.slice(offset, offset + length).arrayBuffer()) : value.subarray(offset, offset + length); }};
 }
 async function readSource(files, id, offset, length) {
  const owner = files.get(id); if (!owner) throw new Error('Missing circuit input');
  range(offset, length, owner.size); const bytes = await owner.read(offset, length); cancelled();
  if (bytes.length !== length) throw new Error('Truncated circuit input');
  progressState.maxReadBytes = Math.max(progressState.maxReadBytes, length);
  if (id === 1 || id === 4) { progressState.sourceReadBytes += length; progressState.sourceReadRequests++; } else progressState.scratchReadBytes += length;
  return bytes;
 }
 async function hashSource(files, id, M, storage, stage = 'hash') {
  const owner = files.get(id); if (!owner) throw new Error('Missing circuit hash source');
  progressState.stage = stage; progressState.phase = id; progressState.completed = 0; progressState.total = owner.size;
  const digest = new SourceSha256();
  for (let offset = 0; offset < owner.size; offset += MiB) {
   const bytes = await readSource(files, id, offset, Math.min(MiB, owner.size - offset));
   digest.update(bytes); progressState.completed = offset + bytes.length; refreshMemory(M, storage); await cooperate();
  }
  cancelled(); return digest.digest();
 }
 function buildInfo(M) {
  const p = M._terra_build_info_json?.(); if (!p) throw new Error('Missing circuit build identity');
  let end = p; while (end < M.HEAPU8.length && end - p < 65536 && M.HEAPU8[end]) end++;
  if (end === M.HEAPU8.length || end - p === 65536) throw new Error('Invalid circuit build identity');
  return JSON.parse(new TextDecoder().decode(M.HEAPU8.subarray(p, end)));
 }
 function validateObjects(bytes, maxBytes, maxObjects) {
  if (bytes.length < 32 || bytes.length > maxBytes) throw new Error('Invalid circuit object companion size');
  const d = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength), word = at => d.getUint32(at, true), count = word(12);
  if (word(0) !== 0x31424f43 || word(4) !== 1 || word(16) !== bytes.length || count > maxObjects || word(28) !== 0) throw new Error('Invalid circuit COB1 companion');
  let at = 32;
  for (let i = 0; i < count; i++) { if (at + 32 > bytes.length) throw new Error('Truncated circuit object'); const section = word(at), kind = word(at + 4), length = word(at + 20);
   if (![2,3,5].includes(section) || (section !== 5 && kind !== 0) || (section === 5 && kind > 10) || word(at + 16) > 65535 || word(at + 24) !== 0 || word(at + 28) !== 0 || at + 32 + length > bytes.length) throw new Error('Invalid circuit object record'); at += 32 + length;
  }
  if (at !== bytes.length) throw new Error('Trailing circuit object data');
 }
 async function materialize(file, limit) {
  if (file.size > limit) throw new Error('Circuit output exceeds byte API budget; use the source API');
  const result = new Uint8Array(file.size); for (let offset = 0; offset < file.size; offset += MiB) result.set(await file.read(offset, Math.min(MiB, file.size - offset)), offset); return result;
 }
 async function chooseStorage(large) {
  if (options.createStorage) return options.createStorage();
  try { const storage = await persistentStorage(); const probe = await storage.create(); await probe.close(); return storage; }
  catch (error) { if (large) throw new Error('Full-world import requires writable OPFS browser storage: ' + error.message); return memoryStorage(); }
 }
 async function disposeFiles(files) {
  const errors = []; for (const [id, file] of files) if (id !== 1 && id !== 4) { try { await file.close(); } catch (error) { errors.push(error); } }
  files.clear(); if (errors.length) throw errors[0];
 }
 async function openImpl(world, twld, streaming) {
  if (session) throw new Error('Close the existing world circuit first');
  if (streaming && (!blob(world) || (twld != null && !blob(twld)))) throw new Error('Streaming import requires File/Blob sources');
  if (!streaming && (!(world instanceof Uint8Array) || !world.length || world.length > SMALL_WORLD || (twld?.length || 0) > SMALL_TWLD)) throw new Error('World byte input exceeds host budget; use File/Blob import');
  const worldSource = source(world), twldSource = twld && (blob(twld) ? twld.size : twld.length) ? source(twld) : null;
  const M = await (promise ??= loadModule());
  for (const n of ['begin','step','supply','ack','command','stats','cancel','close']) if (typeof M['_terra_circuit_world_' + n] !== 'function') throw new Error('World circuit ABI missing ' + n);
  const storage = await chooseStorage(worldSource.size > SMALL_WORLD || (twldSource?.size || 0) > SMALL_TWLD), files = new Map([[1,worldSource]]);
  if (twldSource) files.set(4, twldSource);
  progressState = {...progressState, stage:'open', phase:0, completed:0, total:0, sourceReadBytes:0, sourceReadRequests:0, scratchReadBytes:0, scratchWriteBytes:0, maxReadBytes:0, maxWriteBytes:0, storageBytes:0, nativeActiveBytes:0, nativePeakBytes:0};
  const out = M._tx_malloc(4), event = M._tx_malloc(48); let handle = 0, w = 0, task = 0, input = 0, adopted = false, sourceSha256, twldSourceSha256 = null;
  try {
   if (!out || !event) throw new Error('Circuit allocation failed');
   files.set(2, await storage.create()); cancelled();
   // Caller metadata, including any sha256 property, is never an import proof.
   sourceSha256 = await hashSource(files, 1, M, storage);
   if (twldSource) twldSourceSha256 = await hashSource(files, 4, M, storage);
   progressState.stage='open'; progressState.phase=0; progressState.completed=0; progressState.total=0;
   if (streaming) {
    for (const n of ['open_begin','step','supply_source','adopt','cancel','close']) if (typeof M['_terra_world_stream_' + n] !== 'function') throw new Error('World streaming ABI missing ' + n);
    M.HEAPU32[out >>> 2] = 0; worldCheck(M._terra_world_stream_open_begin(1, worldSource.size, out)); task = M.HEAPU32[out >>> 2];
    for (let batches = 0;;) {
     cancelled(); worldCheck(M._terra_world_stream_step(task, 64, event)); const e = Array.from(M.HEAPU32.subarray(event >>> 2, (event >>> 2) + 12));
     if (e[0] !== 1) throw new Error('Unsupported world stream ABI');
     progressState.completed = e[8]; progressState.total = e[9]; refreshMemory(M, storage);
     if (e[1] === 4) break;
     if (e[1] === 1) { if (e[2] !== 1) throw new Error('Unexpected world input source'); const bytes = await readSource(files, e[2], e[3], e[4]), p = M._tx_malloc(bytes.length);
      try { if (!p) throw new Error('Circuit allocation failed'); M.HEAPU8.set(bytes, p); worldCheck(M._terra_world_stream_supply_source(task, e[2], e[3], p, bytes.length)); } finally { if (p) M._tx_free(p); }
     } else if (e[1] !== 0) throw new Error('Unexpected world stream event');
     if (++batches % 8 === 0) await cooperate();
    }
    worldCheck(M._terra_world_stream_adopt(task, 1, out)); w = M.HEAPU32[out >>> 2]; adopted = true; worldCheck(M._terra_world_stream_close(task)); task = 0;
   } else {
    input = M._tx_malloc(world.length); if (!input) throw new Error('Circuit allocation failed'); M.HEAPU8.set(world, input);
    task = M._terra_world_open_begin(input, world.length); if (!task) throw new Error('Cannot begin world decode'); let status;
    do { cancelled(); status = M._terra_world_open_step(task, 64); if (status === 10) await cooperate(); } while (status === 10);
    worldCheck(status); worldCheck(M._terra_world_open_finish(task, out)); w = M.HEAPU32[out >>> 2]; M._terra_world_task_close(task); task = 0;
    M._tx_free(input); input = 0;
   }
   cancelled(); check(M._terra_circuit_world_begin(w, 2, twldSource ? 4 : 0, twldSource?.size || 0, NATIVE_BUDGET, out)); handle = M.HEAPU32[out >>> 2];
   session = {M, handle, world:w, files, storage, streaming, sourceSha256, twldSourceSha256, hasTwld:!!twldSource}; progressState.stage = 'compile';
   return await pump();
  } catch (error) {
   if (handle) M._terra_circuit_world_close(handle); if (w) M._terra_world_close(w); session = null;
   try { await disposeFiles(files); } catch (_) {} progressState.stage = error.code === 'CIRCUIT_CANCELLED' ? 'cancelled' : 'error'; throw error;
  } finally {
   if (task) { if (streaming) { if (!adopted) M._terra_world_stream_cancel(task); M._terra_world_stream_close(task); } else { M._terra_world_open_cancel(task); M._terra_world_task_close(task); } }
   if (out) M._tx_free(out); if (event) M._tx_free(event); if (input) M._tx_free(input); operation = null; refreshMemory(M, storage);
  }
 }
 async function prepareExport(files, id, name, M, storage) {
  const file = files.get(id), sha256 = await hashSource(files, id, M, storage, 'hash-output');
  const value = await file.snapshot(); cancelled();
  if (!blob(value) || value.size !== file.size) throw new Error('Invalid circuit output snapshot');
  return {blob:value, name, size:file.size, sha256};
 }
 function publishExport(file, prepared) {
  const token = ++exportedSequence; exported.set(token, file); return {...prepared, token};
 }
 async function pump(command) {
  const kindExpected = command?.[1] || 0, save = kindExpected === 6, fragments = kindExpected === 7 || kindExpected === 8, withObjects = kindExpected === 8 && command[12] === 1;
  const recordSize = fragments ? 32 : 16, recordLimit = fragments ? command[8] : kindExpected === 9 ? 65536 : 8 * MiB / 16;
  const {M,handle,files,storage,streaming} = session, event = M._tx_malloc(48), stats = M._tx_malloc(96);
  const chunks = []; let resultBytes = 0, batches = 0, yieldedAt = now(), resultKind = 0, resultCount = 0, reserved = 0, objectBytes = 0;
  const hostStagesUs = {coreStepUs:0, yieldWaitUs:0, resultCopyUs:0};
  try {
   if (!event || !stats) throw new Error('Circuit allocation failed');
   for (;;) {
    cancelled(); const stepAt = now(); check(M._terra_circuit_world_step(handle, 4096, event)); hostStagesUs.coreStepUs += (now() - stepAt) * 1000; const e = Array.from(M.HEAPU32.subarray(event >>> 2, (event >>> 2) + 12));
    const [abi,kind,id,offset,length,pointer] = e; if (abi !== 1) throw new Error('Unsupported circuit ABI');
    progressState.phase = e[6]; progressState.completed = e[7]; progressState.total = e[8];
    if (kind === 4) { resultKind = e[9]; resultCount = e[10]; reserved = e[11];
     if ((kindExpected === 10 && (reserved & 2) !== (command[7] ? 2 : 0)) || resultKind !== kindExpected || (kindExpected === 8 && resultCount * 32 !== resultBytes) || (kindExpected === 7 && resultCount < resultBytes / 32)) throw new Error('Incomplete circuit result'); break;
    }
    range(offset, length);
    if (kind === 1) {
     const bytes = await readSource(files, id, offset, length), p = M._tx_malloc(length);
     try { if (!p && length) throw new Error('Circuit allocation failed'); M.HEAPU8.set(bytes, p); check(M._terra_circuit_world_supply(handle, id, offset, p, length)); } finally { if (p) M._tx_free(p); }
    } else if (kind === 2 || kind === 3) {
     if ((!pointer && length) || pointer + length > M.HEAPU8.length) throw new Error('Invalid circuit output');
     if (kind === 2) {
      if (id === 6) { if (!withObjects || offset !== objectBytes || length > 65536 || offset + length > command[4]) throw new Error('Invalid circuit companion output'); objectBytes += length; }
      else if (id !== 2 && !(save && (id === 3 || id === 5))) throw new Error('Unexpected circuit output source');
      const target = files.get(id); if (!target || !target.write) throw new Error('Invalid circuit target');
      // The borrowed Wasm view remains valid until ack; storage consumes it now.
      const priorSize = target.size; await target.write(offset, M.HEAPU8.subarray(pointer, pointer + length)); cancelled();
      progressState.storageBytes += target.size - priorSize; progressState.scratchWriteBytes += length; progressState.maxWriteBytes = Math.max(progressState.maxWriteBytes, length);
     } else {
      if (e[9] !== kindExpected || length !== e[10] * recordSize || resultBytes + length > recordLimit * recordSize) throw new Error('Circuit query exceeds host budget'); const copyAt = now(); chunks.push(M.HEAPU8.slice(pointer, pointer + length)); hostStagesUs.resultCopyUs += (now() - copyAt) * 1000; resultBytes += length;
     }
     check(M._terra_circuit_world_ack(handle));
    } else if (kind !== 0) throw new Error('Unknown circuit event');
    if (++batches % 128 === 0 || now() - yieldedAt >= 16) { check(M._terra_circuit_world_stats(handle, stats)); refreshMemory(M, storage, Array.from(M.HEAPU32.subarray(stats >>> 2, (stats >>> 2) + 24))); const yieldAt = now(); await cooperate(); hostStagesUs.yieldWaitUs += (now() - yieldAt) * 1000; yieldedAt = now(); }
   }
   const copyAt = now(); // Each chunk already owns the required borrowed-WASM copy made before ack.
   const records = chunks.length === 1 ? chunks[0] : new Uint8Array(resultBytes); let at = 0; if (chunks.length !== 1) for (const chunk of chunks) { records.set(chunk, at); at += chunk.length; } hostStagesUs.resultCopyUs += (now() - copyAt) * 1000;
   const objects = withObjects ? await materialize(files.get(6), command[4]) : null; if (objects) validateObjects(objects, command[4], command[5]);
   check(M._terra_circuit_world_stats(handle, stats)); const statWords = Array.from(M.HEAPU32.subarray(stats >>> 2, (stats >>> 2) + 24)); refreshMemory(M, storage, statWords);
   let world = null, twld = null, worldSource = null, twldSource = null;
   if (save) {
    if (files.get(3).size !== resultCount || (session.hasTwld && files.get(5).size !== reserved)) throw new Error('Incomplete circuit saved files');
    if (streaming) {
     // Prepare both digests before publishing either lease. Until publication,
     // the session still owns both files and cleans them together on failure.
     const preparedWorld = await prepareExport(files, 3, 'circuit.wld', M, storage);
     const preparedTwld = session.hasTwld ? await prepareExport(files, 5, 'circuit.twld', M, storage) : null;
     cancelled(); worldSource = publishExport(files.get(3), preparedWorld);
     if (preparedTwld) twldSource = publishExport(files.get(5), preparedTwld);
     files.delete(3); files.delete(5);
    } else { world = await materialize(files.get(3), SMALL_WORLD); if (session.hasTwld) twld = await materialize(files.get(5), SMALL_TWLD); }
   }
   progressState.stage = 'ready'; return {hostStagesUs, session:handle, resultKind, resultCount, reserved, objects, stats:statWords, records, world, twld, worldSource, twldSource, sourceSha256:session.sourceSha256, twldSourceSha256:session.twldSourceSha256, diagnostics:{...progressState}};
  } finally { if (event) M._tx_free(event); if (stats) M._tx_free(stats); }
 }
 function command(id, json, recordsJson) { return serial(() => commandImpl(id, json, recordsJson)); }
 async function commandImpl(id, json, recordsJson, preserveOperation = false) {
  const commandAt = now();
  if (!session || id !== session.handle) throw new Error('Circuit session is closed');
  const words = JSON.parse(json), records = JSON.parse(recordsJson), {M,handle,files,storage} = session;
  if (!Array.isArray(words) || !Array.isArray(records) || words.length !== 16 || words[0] !== 1 || words[1] < 1 || words[1] > 10 || words[9] !== 0 || words[14] !== 0 || words[15] !== 0 || records.length !== words[10] * 4 || records.length > 65536 * 4 || [...words,...records].some(v => !Number.isInteger(v) || v < 0 || v > 0xffffffff)) throw new Error('Invalid circuit command');
  if (words[1] === 10 && (words[7] > 1 || records.length || words[12] !== 0)) throw new Error('Invalid circuit optimization mode');
  if (words[1] === 10 && buildInfo(M).circuitWorldOptimization !== 1) throw new Error('Circuit optimization is unavailable in this engine');
  if (words[1] === 9 && (records.length || !words[4] || !words[5] || words[4] * words[5] > 65536 || words[12] !== 0)) throw new Error('Invalid circuit pixel query');
  if (words[1] === 7 || words[1] === 8) {
   if (words[8] < 1 || words[8] > 32768) throw new Error('Circuit fragments are limited to 32768 records'); const info = buildInfo(M);
   if (words[1] === 7) { for (let i = 0; i < records.length; i += 4) { const shape = records[i+2], w = (shape >>> 16) & 255, h = shape >>> 24;
    if (records[i] > 65535 || !w || !h || (shape & 255) >= w || ((shape >>> 8) & 255) >= h || records[i+3] > 17) throw new Error('Invalid circuit object geometry');
    if (records[i+3] !== 0 && info.circuitWorldFragmentSupports !== 1) throw new Error('Circuit placement supports are unavailable'); }
   } else { if (records.length || words[12] > 1 || (words[12] === 1 && (words[13] !== 6 || words[4] < 32 || words[4] > 4 * MiB || words[5] < 1 || words[5] > 32768)) || (words[12] === 0 && words[13] !== 0)) throw new Error('Invalid circuit companion extraction'); if (words[12] === 1 && info.circuitWorldFragmentObjects !== 1) throw new Error('Circuit object companions are unavailable'); }
  }
  const p = M._tx_malloc(64), r = M._tx_malloc(Math.max(4, records.length * 4)); if (!preserveOperation) operation = {cancelled:false}; progressState.stage = words[1] === 6 ? 'save' : 'command';
  const replace = async id => { const old = files.get(id); if (old) { progressState.storageBytes -= old.size; await old.close(); } files.set(id, await storage.create()); };
  try {
   if (!p || !r) throw new Error('Circuit allocation failed'); M.HEAPU32.set(records, r >>> 2); words[9] = r; M.HEAPU32.set(words, p >>> 2);
   if (words[1] === 6) { await replace(3); if (session.hasTwld) await replace(5); } if (words[1] === 8) await replace(6);
   cancelled(); check(M._terra_circuit_world_command(handle, p)); const result = await pump(words); result.hostStagesUs.commandWallUs = (now() - commandAt) * 1000; return result;
  } catch (error) {
   M._terra_circuit_world_cancel(handle);
   if (words[1] === 6) for (const outputId of [3,5]) {
    const file = files.get(outputId); if (!file) continue;
    const size = file.size;
    try { await file.close(); files.delete(outputId); progressState.storageBytes = Math.max(0, progressState.storageBytes - size); } catch (_) { /* close() can retry retained cleanup. */ }
   }
   progressState.stage = error.code === 'CIRCUIT_CANCELLED' ? 'cancelled' : 'error'; throw error;
  }
  finally { if (p) M._tx_free(p); if (r) M._tx_free(r); if (!preserveOperation) operation = null; refreshMemory(M, storage); }
 }
 function computerFrame(id, clockJson, pixelsJson) { return serial(async () => {
  const clockWords = JSON.parse(clockJson), pixels = JSON.parse(pixelsJson);
  const expectedClock = [1,2,3194,153,1,1,1,8,128,0,0,0,0,0,0,0];
  const monitor = pixels?.[2] === 6485 ? [6485,800,64,48] : [7371,1002,176,96];
  const expectedPixels = [1,9,...monitor,1,0,0,0,0,0,0,0,0,0];
  if (!Array.isArray(clockWords) || clockWords.length !== 16 || !Number.isInteger(clockWords[8]) || clockWords[8] < 32 || clockWords[8] > 128 || clockWords.some((v,i) => i !== 8 && v !== expectedClock[i]) || !Array.isArray(pixels) || pixels.length !== 16 || pixels.some((v,i) => v !== expectedPixels[i])) throw new Error('Invalid physical computer frame');
  operation = {cancelled:false}; const started = now();
  try {
   const clock = await commandImpl(id, clockJson, '[]', true);
   try {
    cancelled(); const display = await commandImpl(id, pixelsJson, '[]', true);
    return {clock, display, displayError:null, hostStagesUs:{commandWallUs:(now()-started)*1000}};
   } catch (error) {
    // The accepted physical clock cannot be replayed if the read fails.
    return {clock, display:null, displayError:String(error.message || error).slice(0,2048), hostStagesUs:{commandWallUs:(now()-started)*1000}};
   }
  } finally { operation = null; }
 }); }
 function close(id) { return serial(async () => {
  if (!session || id !== session.handle) return; const current = session; session = null;
  try { try { check(current.M._terra_circuit_world_close(current.handle)); } finally { worldCheck(current.M._terra_world_close(current.world)); } }
  finally { for (const [sourceId,file] of current.files) if (sourceId !== 1 && sourceId !== 4) progressState.storageBytes -= file.size; await disposeFiles(current.files); progressState.stage = 'closed'; progressState.nativeActiveBytes = 0; refreshMemory(current.M, current.storage); }
 }); }
 function releaseSource(token) { return serial(async () => { const file = exported.get(token); if (!file) return; const size = file.size; await file.close(); exported.delete(token); progressState.storageBytes = Math.max(0, progressState.storageBytes - size); }); }
 const open = (world,twld,streaming) => serial(async () => { operation={cancelled:false}; try { return await openImpl(world,twld,streaming); } finally { operation=null; } });
 return {open:(world,twld) => open(world,twld,false), openSource:(world,twld) => open(world,twld,true), command, computerFrame, close, releaseSource,
  progress:async () => ({...progressState, diagnostics:{...progressState}}), cancelOperation:async () => { if (operation) operation.cancelled = true; },
 };
}
root.createTerraWorldCircuitBridge = createWorldCircuitBridge;
if (root.document) { root.terraWorldCircuit = root.TerraWorkerRPC.createClient('worldCircuit'); root.addEventListener?.('pagehide', () => root.terraWorldCircuit.dispose()); }
if (typeof module === 'object' && module.exports) module.exports = {createWorldCircuitBridge, SourceSha256};
})(globalThis);
