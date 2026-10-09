// Production hash routing/ownership contracts. Native SHA calls are faked with
// node:crypto here; the unchanged C algorithm has its own real ABI contracts.
'use strict';
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const {createWorldCircuitBridge} = require('../../web/terra_world_circuit.js');
const MiB = 1024 * 1024;
const reference = bytes => crypto.createHash('sha256').update(bytes).digest('hex');
const names = ['create', 'update', 'final', 'destroy'].map(n => '_terra_sha256_' + n);
const pattern = n => Uint8Array.from({length:n}, (_, i) => (i * 31 + 7) & 255);

class RangedBlob extends Blob {
 constructor(bytes, read) { super([bytes]); this.read = read; this.ranges = []; this.sha256 = '0'.repeat(64); }
 async arrayBuffer() { throw new Error('Whole source reads are forbidden'); }
 slice(start, end) {
  assert.ok(end - start <= MiB); this.ranges.push([start, end - start]);
  this.read?.(start, end - start); return super.slice(start, end);
 }
}
function storage() {
 const files = new Set();
 const disk = {kind:'test', budget:{used:0, peak:0}, files, async create() {
  let size = 0; const chunks = [];
  const file = {get size() { return size; },
   async read(offset, length) {
    disk.beforeRead?.(offset, length);
    assert.ok(length <= MiB); const result = new Uint8Array(length);
    for (const [at, bytes] of chunks) {
     const first = Math.max(offset, at), last = Math.min(offset + length, at + bytes.length);
     if (first < last) result.set(bytes.subarray(first - at, last - at), first - offset);
    }
    return result;
   },
   async write(offset, bytes) { chunks.push([offset, bytes.slice()]); size = Math.max(size, offset + bytes.length); },
   async snapshot() { const parts = []; for (let at = 0; at < size; at += MiB) parts.push(await this.read(at, Math.min(MiB, size - at))); return new Blob(parts); },
   async close() { files.delete(file); },
  }; files.add(file); return file;
 }}; return disk;
}
function fakeModule(output = new Uint8Array(), native = true, fault = {}) {
 let memory = new ArrayBuffer(8 * MiB), next = 2 * MiB, sequence = 0, events = [];
 const M = {HEAPU8:new Uint8Array(memory), HEAPU32:new Uint32Array(memory)};
 const owned = new Map(), contexts = new Map();
 const stats = {create:0, update:0, final:0, destroy:0, hashAllocations:0, maxUpdate:0, bytes:0, pointers:new Set(), begin:0};
 const grow = () => { const replacement = new ArrayBuffer(memory.byteLength + 65536); new Uint8Array(replacement).set(M.HEAPU8); memory = replacement; M.HEAPU8 = new Uint8Array(memory); M.HEAPU32 = new Uint32Array(memory); };
 M.HEAPU8.set(new TextEncoder().encode('{"circuitWorldAbiVersion":2}'), 32); M._terra_build_info_json = () => 32;
 M._tx_malloc = length => {
  if (length === MiB + 36) { stats.hashAllocations++; if (fault.allocation) return 0; }
  const p = next; next += (length + 7) & ~7; assert.ok(next < memory.byteLength); owned.set(p, length); return p;
 };
 M._tx_free = p => { const length = owned.get(p); assert.ok(owned.delete(p), 'Every allocation is released exactly once'); if (fault.free && length === MiB + 36) throw fault.free; };
 const ready = (kind, count = 0) => [2,4,0,0,0,0,0,0,0,kind,count,0];
 M._terra_world_stream_open_begin = (id, size, p) => { stats.begin++; M.HEAPU32[p >>> 2] = 3; return 0; };
 M._terra_world_stream_step = (id, work, p) => { M.HEAPU32.set([1,4,0,0,0,0,0,0,0,0,0,0], p >>> 2); return 0; };
 M._terra_world_stream_adopt = (id, source, p) => { M.HEAPU32[p >>> 2] = 42; return 0; };
 for (const n of ['supply_source', 'cancel', 'close']) M['_terra_world_stream_' + n] = () => 0;
 M._terra_world_close = () => 0;
 M._terra_circuit_world_begin = (world, scratch, budget, p) => { M.HEAPU32[p >>> 2] = 9; events = [ready(0)]; return 0; };
 M._terra_circuit_world_step = (id, work, p) => {
  const event = events[0]; if (event[1] === 2) M.HEAPU8.set(output.subarray(event[3], event[3] + event[4]), 256);
  M.HEAPU32.set(event, p >>> 2); return 0;
 };
 M._terra_circuit_world_ack = () => { events.shift(); return 0; };
 M._terra_circuit_world_stats = (id, p) => { M.HEAPU32.fill(0, p >>> 2, (p >>> 2) + 24); return 0; };
 for (const n of ['supply', 'cancel', 'close']) M['_terra_circuit_world_' + n] = () => 0;
 M._terra_circuit_world_command = (id, p) => {
  const kind = M.HEAPU32[(p >>> 2) + 1]; events = [];
  if (kind === 6) for (let at = 0; at < output.length; at += MiB) events.push([2,2,3,at,Math.min(MiB, output.length - at),256,0,0,0,0,0,0]);
  events.push(ready(kind, kind === 6 ? output.length : 0)); return 0;
 };
 if (native) {
  M._terra_sha256_create = p => {
   stats.create++; if (fault.grow) grow(); M.HEAPU32[p >>> 2] = 0;
   if (fault.zeroHandle) return 0;
   if (fault.create && !fault.createOwnsHandle) return fault.create;
   const h = ++sequence; contexts.set(h, crypto.createHash('sha256')); M.HEAPU32[p >>> 2] = h; return fault.create || 0;
  };
  M._terra_sha256_update = (h, p, length) => {
   stats.update++; assert.ok(contexts.has(h)); assert.ok(length <= MiB); stats.maxUpdate = Math.max(stats.maxUpdate, length); stats.bytes += length; stats.pointers.add(p);
   if (fault.update) return fault.update;
   contexts.get(h).update(M.HEAPU8.subarray(p, p + length)); if (fault.grow) grow(); fault.afterUpdate?.(); return 0;
  };
  M._terra_sha256_final = (h, p) => {
   stats.final++; if (fault.final) return fault.final;
   const digest = contexts.get(h).digest(); if (fault.grow) grow(); M.HEAPU8.set(digest, p); return 0;
  };
  M._terra_sha256_destroy = h => { stats.destroy++; assert.ok(contexts.delete(h)); return fault.destroy || 0; };
 }
 return {M, owned, contexts, stats};
}
function host(bytes, output, native = true, fault = {}) {
 const fake = fakeModule(output, native, fault), disk = storage();
 const bridge = createWorldCircuitBridge(async () => fake.M, {createStorage:async () => disk});
 const source = new RangedBlob(bytes, fault.read);
 return {...fake, disk, bridge, source};
}
const save = (bridge, id) => bridge.command(id, JSON.stringify([2,6,0,0,0,0,0,0,0,0,0,3,0,0,0,0]), '[]');
const clean = h => { assert.equal(h.owned.size, 0); assert.equal(h.contexts.size, 0); assert.equal(h.disk.files.size, 0); };

(async () => {
 const sizes = [0,1,3,55,56,57,63,64,65,119,120,127,128,129,MiB-1,MiB,MiB+13];
 for (const native of [false, true]) for (const n of sizes) {
  const output = n === 3 ? new TextEncoder().encode('abc') : pattern(n), bytes = n ? output : new Uint8Array([1]);
  const h = host(bytes, output, native, {grow:native && n === MiB+13});
  const opened = await h.bridge.openSource(h.source);
  assert.equal(opened.sourceSha256, reference(bytes)); assert.notEqual(opened.sourceSha256, h.source.sha256);
  assert.equal(opened.diagnostics.sourceReadBytes, bytes.length); assert.equal(opened.diagnostics.sourceReadRequests, Math.ceil(bytes.length / MiB));
  assert.equal(opened.diagnostics.maxReadBytes, Math.min(bytes.length, MiB));
  if (native) assert.equal(h.stats.pointers.size, 1, 'Source hashing reuses one input allocation');
  const saved = await save(h.bridge, opened.session); assert.equal(saved.worldSource.sha256, reference(output));
  assert.equal(saved.worldSource.size, n); assert.equal(saved.worldSource.token, 1);
  if (native) { assert.equal(h.stats.create, 2); assert.equal(h.stats.destroy, 2); assert.equal(h.stats.hashAllocations, 2); assert.equal(h.stats.bytes, bytes.length + n); }
  else assert.equal(h.stats.hashAllocations, 0);
  await h.bridge.close(opened.session); await h.bridge.releaseSource(saved.worldSource.token); clean(h);
 }
 for (const missing of names) {
  const h = host(new Uint8Array([1])); delete h.M[missing];
  await assert.rejects(h.bridge.openSource(h.source), /Incomplete streaming SHA-256 API/);
  assert.equal(h.source.ranges.length, 0); assert.equal(h.stats.begin, 0); clean(h);
 }
 const malformed = host(new Uint8Array([1]));
 for (const name of names) malformed.M[name] = null;
 await assert.rejects(malformed.bridge.openSource(malformed.source), /Incomplete streaming SHA-256 API/); clean(malformed);
 for (const fault of [{allocation:true}, {zeroHandle:true}, {create:6}, {create:6, createOwnsHandle:true}, {update:6}, {final:6}, {destroy:6}, {free:new Error('Synthetic hash free failure')}]) {
  const h = host(new Uint8Array([1,2,3]), undefined, true, fault);
  await assert.rejects(h.bridge.openSource(h.source), /hash allocation failed|Missing streaming SHA-256 context|World decoder status 6|hash free failure/);
  assert.equal(h.stats.begin, 0); clean(h);
 }
 const primary = new Error('Original ranged read failure');
 const h = host(pattern(MiB+3), undefined, true, {read:at => { if (at) throw primary; }, destroy:6, free:new Error('Secondary free failure')});
 await assert.rejects(h.bridge.openSource(h.source), error => error === primary); assert.equal(h.stats.destroy, 1); clean(h);
 for (const native of [false, true]) {
  const cancelled = host(pattern(MiB+3), undefined, native);
  cancelled.source.read = at => { if (at) cancelled.bridge.cancelOperation(); };
  await assert.rejects(cancelled.bridge.openSource(cancelled.source), {code:'CIRCUIT_CANCELLED'}); clean(cancelled);
 }
 const cancelled = host(new Uint8Array([1]), undefined, true, {afterUpdate:() => cancelled.bridge.cancelOperation(), destroy:6});
 await assert.rejects(cancelled.bridge.openSource(cancelled.source), {code:'CIRCUIT_CANCELLED'});
 assert.equal(cancelled.stats.final, 0); assert.equal(cancelled.stats.destroy, 1); clean(cancelled);
 for (const native of [false, true]) {
  const output = pattern(MiB+9), h = host(new Uint8Array([1,2,3]), output, native);
  const opened = await h.bridge.openSource(h.source), outputError = new Error('Original output hash read failure');
  h.disk.beforeRead = () => { throw outputError; };
  await assert.rejects(save(h.bridge, opened.session), error => error === outputError);
  assert.equal(h.disk.files.size, 1, 'Failed output hash never retains an unpublished file');
  h.disk.beforeRead = () => h.bridge.cancelOperation();
  await assert.rejects(save(h.bridge, opened.session), {code:'CIRCUIT_CANCELLED'});
  assert.equal(h.disk.files.size, 1, 'Cancelled output hash never retains an unpublished file');
  h.disk.beforeRead = null;
  const saved = await save(h.bridge, opened.session);
  assert.equal(saved.worldSource.token, 1, 'Hash failures and cancellation cannot publish a lease');
  assert.equal(saved.worldSource.sha256, reference(output));
  if (native) { assert.equal(h.stats.create, 4); assert.equal(h.stats.destroy, 4); }
  await h.bridge.close(opened.session); await h.bridge.releaseSource(saved.worldSource.token); clean(h);
 }
 console.log('PASS: production C-hash routing, legacy fallback, SHA boundaries, binary digest, heap growth, bounded reuse, all-or-none API, failures, cancellation and ownership');
})().catch(error => { console.error(error); process.exitCode = 1; });
