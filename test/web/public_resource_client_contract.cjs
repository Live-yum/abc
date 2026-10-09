'use strict';
const assert = require('node:assert/strict');
const path = require('node:path');
const compiled = process.argv[2];
if (!compiled) throw new Error('Pass the locally compiled Dart fixture path');
globalThis.self = globalThis;
let calls = 0;
globalThis.fetch = async (url, options) => {
  calls++;
  assert.equal(options.method, 'GET');
  assert.equal(options.credentials, 'omit');
  assert.equal(options.cache, 'no-store');
  assert.equal(options.redirect, 'error');
  assert(options.signal instanceof AbortSignal);
  assert(!Object.keys(options.headers).some(k => /^(authorization|cookie)$/i.test(k)));
  if (url === 'https://resource.example.test/hang') {
    return new Promise((resolve, reject) => {
      const abort = () => reject(new Error('Synthetic abort'));
      if (options.signal.aborted) abort();
      else options.signal.addEventListener('abort', abort, {once: true});
    });
  }
  assert.equal(url, 'https://resource.example.test/fixture');
  let part = 0;
  return {status: 200, headers: {get: key => key === 'content-length' ? '3' : null}, body: {
    getReader: () => ({read: async () => part++ === 0
      ? {done: false, value: new Uint8Array([1, 2, 3])} : {done: true},
    cancel: async () => {}, releaseLock() {}}),
  }};
};
process.on('exit', () => assert.equal(calls, 2));
require(path.resolve(compiled));
