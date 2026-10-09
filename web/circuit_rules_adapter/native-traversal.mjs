// Original transport adapter. Traversal order and device rules remain in the
// pinned authoritative module; this file only marshals its C ABI buffers.
import { createNativeTraversal as retainedTraversal } from 'authoritative:native-traversal';

function request(op, args) {
  if (typeof globalThis.sendMessage !== 'function') throw new Error('Native circuit callback unavailable');
  const raw = globalThis.sendMessage('terraCircuitNative', JSON.stringify({ op, args }));
  const reply = typeof raw === 'string' ? JSON.parse(raw) : raw;
  if (!reply || !Number.isInteger(reply.status)) throw new Error('Invalid native circuit response');
  return reply;
}

export function supportsNativeTraversal() {
  try { const reply = request('abi', []); return reply.status === 0 && reply.abi === 1; }
  catch { return false; }
}

function transport() {
  // A traversal owns exactly two 64 KiB buffers and one 64-byte status buffer.
  // C allocations live in the native owner, never in this transport scratchpad.
  const heap = new Uint32Array((128 * 1024 + 256) / 4);
  let next = 16;
  const allocations = new Set();
  const words = (pointer, count) => Array.from(heap.subarray(pointer >>> 2, (pointer >>> 2) + count));
  const put = (pointer, values, maximum) => {
    if (!Array.isArray(values) || values.length > maximum || values.some(v => !Number.isInteger(v) || v < 0 || v > 0xffffffff)) {
      throw new Error('Invalid native circuit output words');
    }
    heap.set(values, pointer >>> 2);
  };
  const Module = { HEAPU32: heap,
    _terra_circuit_abi_version: () => { const r = request('abi', []); return r.status < 0 ? 0 : r.abi; },
    _terra_circuit_create: (width, height, maxCells, maxBytes, out) => {
      const r = request('create', [width, height, maxCells, maxBytes]);
      if (r.status >= 0) put(out, [r.handle], 1);
      return r.status;
    },
    _terra_circuit_load: (handle, data, count) => request('load', [handle, words(data, count * 4)]).status,
    _terra_circuit_patch: (handle, data, count) => request('patch', [handle, words(data, count * 4)]).status,
    _terra_circuit_compile: (handle, maxCells, out) => {
      const r = request('compile', [handle, maxCells]);
      if (r.status >= 0) put(out, [r.compiled], 1);
      return r.status;
    },
    _terra_circuit_begin: (handle, seeds, count, colour, flags, workLimit) =>
      request('begin', [handle, words(seeds, count * 2), colour, flags, workLimit]).status,
    _terra_circuit_step: (handle, maxNodes, events, capacity, meta) => {
      const r = request('step', [handle, maxNodes, capacity]);
      // The retained traversal reads processed/emitted even on a negative code.
      put(meta, r.meta || [0, 0, 0, 0], 4);
      put(events, r.events || [], capacity * 4);
      if (heap[(meta >>> 2) + 1] * 4 !== (r.events || []).length) throw new Error('Native event count mismatch');
      return r.status;
    },
    _terra_circuit_stats: (handle, out) => {
      const r = request('stats', [handle]);
      if (r.status >= 0) put(out, r.words, 16);
      return r.status;
    },
    _terra_circuit_cancel: handle => request('cancel', [handle]).status,
    _terra_circuit_close: handle => request('close', [handle]).status,
  };
  return { Module,
    malloc(bytes) {
      const pointer = next;
      next += (bytes + 7) & ~7;
      if (next > heap.byteLength) throw new RangeError('Circuit transport allocation limit');
      allocations.add(pointer);
      return pointer;
    },
    free(pointer) { allocations.delete(pointer); if (!allocations.size) next = 16; },
  };
}

export function createNativeTraversal(_tx, world, options) {
  if (!supportsNativeTraversal()) return null;
  return retainedTraversal(transport(), world, options);
}
