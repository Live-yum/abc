// Original, offline synthetic regression. No game resources or user records.
// Usage: node --test test/web/online_resource_storage_smoke.cjs
'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const {test} = require('node:test');

const source = fs.readFileSync(path.join(__dirname, '../../web/online_resource_storage.js'), 'utf8');
const digest = 'a'.repeat(64);
const other = 'b'.repeat(64);
const stateLimit = 2 * 1024 * 1024;
const bytes = (...values) => Uint8Array.from(values);
const clone = value => value === undefined ? undefined : structuredClone(value);
const nextTurn = () => new Promise(resolve => setImmediate(resolve));

// A purpose-built IndexedDB test double: requests finish before transactions,
// write transactions serialize, and aborted transactions discard ALL writes.
// Explicit faults exercise storage denial, quota failure and commit interruption.
class SyntheticIndexedDB {
  records = new Map();
  connections = [];
  transactions = [];
  queue = [];
  initialized = false;
  fault = null;
  openError = null;
  blocked = false;
  active = null;
  holdNextWrite = false;
  held = null;

  open(name, version) {
    assert.equal(name, 'terraforge-online-resources-v1');
    assert.equal(version, 1);
    const request = {};
    const connection = {
      closed: false,
      createObjectStore: (store, options) => {
        assert.equal(store, 'resources');
        assert.equal(options.keyPath, 'key');
        this.initialized = true;
      },
      close() { this.closed = true; },
      transaction: (store, mode, options) => {
        assert.equal(store, 'resources');
        assert.equal(connection.closed, false);
        const tx = new SyntheticTransaction(this, mode, options);
        this.transactions.push(tx);
        this.queue.push(tx);
        this.start();
        return tx;
      },
    };
    this.connections.push(connection);
    setImmediate(() => {
      if (this.openError) {
        request.error = this.openError;
        request.onerror?.({target: request});
        return;
      }
      request.result = connection;
      if (!this.initialized) request.onupgradeneeded?.({target: request});
      if (this.blocked) request.onblocked?.({target: request});
      // A blocked open can still eventually succeed. Its connection must close.
      setImmediate(() => request.onsuccess?.({target: request}));
    });
    return request;
  }

  start() {
    if (this.active || !this.queue.length) return;
    this.active = this.queue.shift();
    const tx = this.active;
    setImmediate(() => {
      if (tx.finished) return;
      tx.records = new Map([...this.records].map(([key, value]) => [key, clone(value)]));
      tx.pump();
    });
  }

  finish(tx) {
    assert.equal(tx, this.active);
    this.active = null;
    this.start();
  }

  takeFault(phase, op, key) {
    const fault = this.fault;
    if (!fault || fault.phase !== phase || (fault.op && fault.op !== op) ||
        (fault.key && fault.key !== key)) return null;
    this.fault = null;
    return new Error(fault.message || 'Synthetic quota exceeded');
  }
}

class SyntheticTransaction {
  tasks = [];
  finished = false;
  records = null;
  error = null;

  constructor(backend, mode, options) {
    this.backend = backend;
    this.mode = mode;
    this.options = options;
  }

  objectStore(name) {
    assert.equal(name, 'resources');
    return {
      get: key => this.request('get', key, () => clone(this.records.get(key))),
      put: record => {
        assert.equal(this.mode, 'readwrite');
        const snapshot = clone(record);
        return this.request('put', record.key, () => {
          this.records.set(snapshot.key, snapshot);
          return snapshot.key;
        });
      },
      delete: key => {
        assert.equal(this.mode, 'readwrite');
        return this.request('delete', key, () => { this.records.delete(key); });
      },
      openCursor: () => {
        let keys;
        let position = 0;
        const cursor = () => {
          keys ||= [...this.records.keys()].sort();
          if (position >= keys.length) return null;
          const key = keys[position++];
          return {key, primaryKey: key, value: clone(this.records.get(key)),
            continue: () => this.request('cursor', key, cursor, request)};
        };
        const request = this.request('cursor', null, cursor);
        return request;
      },
    };
  }

  request(op, key, run, request = {}) {
    if (this.finished) throw new Error('TransactionInactiveError');
    const fault = this.backend.takeFault('schedule', op, key);
    if (fault) throw fault;
    this.tasks.push({op, key, run, request});
    return request;
  }

  pump() {
    if (this.finished) return;
    setImmediate(() => {
      if (this.finished) return;
      const task = this.tasks.shift();
      if (!task) { this.complete(); return; }
      const fault = this.backend.takeFault('request', task.op, task.key);
      if (fault) {
        task.request.error = fault;
        this.error = fault;
        this.onerror?.({target: task.request});
        this.abort();
        return;
      }
      try {
        task.request.result = task.run();
        task.request.onsuccess?.({target: task.request});
      } catch (error) {
        this.error = error;
        this.abort();
      }
      this.pump();
    });
  }

  complete() {
    if (this.backend.holdNextWrite && this.mode === 'readwrite') {
      this.backend.holdNextWrite = false;
      this.backend.held = () => { this.backend.held = null; this.complete(); };
      return;
    }
    const fault = this.backend.takeFault('complete');
    if (fault) { this.error = fault; this.abort(); return; }
    if (this.mode === 'readwrite') this.backend.records = this.records;
    this.finished = true;
    this.oncomplete?.({target: this});
    this.backend.finish(this);
  }

  abort() {
    if (this.finished) throw new Error('TransactionInactiveError');
    this.finished = true;
    setImmediate(() => {
      this.onabort?.({target: this});
      this.backend.finish(this);
    });
  }
}

function load(indexedDB = new SyntheticIndexedDB()) {
  const context = vm.createContext({indexedDB, Uint8Array, Blob, console});
  vm.runInContext(source, context, {filename: 'online_resource_storage.js'});
  return {api: context.terraOnlineResourceStorage, db: indexedDB};
}

test('binary values survive reloads, replace, list and remove without sharing buffers', async () => {
  const {api, db} = load();
  const input = bytes(0, 255, 2, 3);
  const pending = api.write('objects', digest, input);
  input.fill(99);
  await pending;
  const first = await api.read('objects', digest);
  assert.deepEqual(first, bytes(0, 255, 2, 3));
  first.fill(88);
  assert.deepEqual(await load(db).api.read('objects', digest), bytes(0, 255, 2, 3));

  for (const kind of ['images', 'packs', 'releases']) await api.write(kind, digest, bytes(1));
  for (const id of [`authority-${digest}-0`, `root-${digest}-1`,
    `staging-${digest}-${other}`, `installed-${digest}-${other}`,
    `active-${digest}`, `backup-${digest}`]) await api.write('state', id, bytes(2));
  await api.write('objects', other, bytes());
  const entries = JSON.parse(await load(db).api.list());
  assert.equal(entries.length, 11);
  assert.deepEqual(entries.find(item => item.kind === 'objects' && item.id === digest),
    {kind: 'objects', id: digest, bytes: 4});
  await api.write('objects', digest, bytes(5, 6));
  assert.deepEqual(await api.read('objects', digest), bytes(5, 6));
  await api.remove('objects', digest);
  await api.remove('objects', digest);
  assert.equal(await api.read('objects', digest), null);
  assert.equal(JSON.parse(await api.list()).length, 10);
  assert(db.connections.every(connection => connection.closed));
  assert(db.transactions.filter(tx => tx.mode === 'readwrite')
    .every(tx => tx.options.durability === 'strict'));
});

test('strict key and byte validation runs before storage access', async () => {
  const {api, db} = load();
  const invalid = [['unknown', digest], ['__proto__', digest], ['objects', '../escape'],
    ['objects', digest.toUpperCase()], ['objects', digest + '\n'],
    ['objects', digest + '\u2028'], ['objects', digest.slice(1)],
    ['objects', 123], ['state', digest], ['state', `active-${digest}\r`],
    ['state', `active-${digest}\u2029`], ['state', `authority-${digest}-2`],
    ['state', `staging-${digest}`], ['state', `installed-${digest}-${other}/extra`]];
  for (const [kind, id] of invalid) {
    await assert.rejects(api.read(kind, id), /Invalid online resource storage key/);
    await assert.rejects(api.write(kind, id, bytes(1)), /Invalid online resource storage key/);
    await assert.rejects(api.remove(kind, id), /Invalid online resource storage key/);
  }
  for (const value of [null, [1, 2], new ArrayBuffer(1), new DataView(new ArrayBuffer(1))]) {
    await assert.rejects(api.write('objects', digest, value), /Uint8Array/);
  }
  for (const namespace of [digest + '\n', '../escape', null, {toString: () => digest}]) {
    await assert.rejects(api.commitActive(namespace, bytes(1)), /Invalid online resource/);
  }
  await assert.rejects(api.write('state', `active-${digest}`, new Uint8Array(stateLimit + 1)), /size limit/);
  await assert.rejects(api.commitActive(digest, new Uint8Array(stateLimit + 1)), /size limit/);
  class OversizedBytes extends Uint8Array { get byteLength() { return 256 * 1024 * 1024 + 1; } }
  await assert.rejects(api.write('objects', digest, new OversizedBytes(1)), /size limit/);
  assert.equal(db.connections.length, 0);
  await api.commitActive(digest, new Uint8Array(stateLimit));
  assert.equal((await api.read('state', `active-${digest}`)).length, stateLimit);
});

test('activation retains exactly the predecessor and serializes concurrent commits', async () => {
  const {api, db} = load();
  const active = `active-${digest}`;
  const backup = `backup-${digest}`;
  await api.commitActive(digest, bytes(1));
  assert.deepEqual(await api.read('state', active), bytes(1));
  assert.equal(await api.read('state', backup), null);
  await api.commitActive(digest, bytes(2));
  assert.deepEqual(await api.read('state', backup), bytes(1));
  const input = bytes(3);
  const pending = api.commitActive(digest, input);
  input[0] = 99;
  await Promise.all([pending, load(db).api.commitActive(digest, bytes(4))]);
  assert.deepEqual(await api.read('state', active), bytes(4));
  assert.deepEqual(await api.read('state', backup), bytes(3));
  await api.commitActive(other, bytes(8));
  assert.deepEqual(await api.read('state', active), bytes(4));
  assert.deepEqual(await api.read('state', `active-${other}`), bytes(8));
});

test('quota failures and interruptions roll back both active and backup', async () => {
  const {api, db} = load();
  const active = `active-${digest}`;
  const backup = `backup-${digest}`;
  await api.commitActive(digest, bytes(1));
  await api.commitActive(digest, bytes(2));
  for (const fault of [
    {phase: 'request', op: 'get', key: `state/${active}`},
    {phase: 'request', op: 'put', key: `state/${backup}`},
    {phase: 'request', op: 'put', key: `state/${active}`},
    {phase: 'schedule', op: 'put', key: `state/${active}`},
    {phase: 'complete'},
  ]) {
    db.fault = fault;
    await assert.rejects(api.commitActive(digest, bytes(3)), /Synthetic quota exceeded/);
    assert.deepEqual(await load(db).api.read('state', active), bytes(2));
    assert.deepEqual(await load(db).api.read('state', backup), bytes(1));
  }
  await api.commitActive(digest, bytes(4));
  assert.deepEqual(await api.read('state', active), bytes(4));
  assert.deepEqual(await api.read('state', backup), bytes(2));
  assert(db.connections.every(connection => connection.closed));
});

test('writes resolve only after the durable transaction completes', async () => {
  const {api, db} = load();
  db.holdNextWrite = true;
  let resolved = false;
  const pending = api.write('objects', digest, bytes(7)).then(() => { resolved = true; });
  for (let attempts = 0; !db.held && attempts < 20; attempts++) await nextTurn();
  assert(db.held, 'The synthetic transaction reached its commit boundary');
  assert.equal(resolved, false);
  assert.equal(db.records.size, 0);
  db.held();
  await pending;
  assert.equal(resolved, true);
  assert.deepEqual(await api.read('objects', digest), bytes(7));
});

test('corrupt records fail closed without replacing an existing active value', async () => {
  const {api, db} = load();
  await api.commitActive(digest, bytes(1));
  await api.commitActive(digest, bytes(2));
  const activeKey = `state/active-${digest}`;
  db.records.set(activeKey, {key: activeKey, blob: bytes(99)});
  await assert.rejects(api.read('state', `active-${digest}`), /corrupted/);
  await assert.rejects(api.list(), /corrupted/);
  await assert.rejects(api.commitActive(digest, bytes(3)), /corrupted/);
  assert.deepEqual(db.records.get(activeKey).blob, bytes(99));
  assert.deepEqual(await api.read('state', `backup-${digest}`), bytes(1));
  db.records.set(activeKey, {key: activeKey, blob: new Blob([new Uint8Array(stateLimit + 1)])});
  await assert.rejects(api.read('state', `active-${digest}`), /size limit/);
  await assert.rejects(api.list(), /size limit/);
  await assert.rejects(api.commitActive(digest, bytes(3)), /size limit/);
  db.records.set(activeKey, {key: `state/active-${other}`, blob: new Blob([bytes(1)])});
  await assert.rejects(api.read('state', `active-${digest}`), /corrupted/);
  await assert.rejects(api.list(), /corrupted/);
  db.records.clear();
  db.records.set('objects/../escape', {key: 'objects/../escape', blob: new Blob([bytes(1)])});
  await assert.rejects(api.list(), /Invalid online resource record key/);
});

test('failed writes and deletes preserve existing bytes and remain retryable', async () => {
  const {api, db} = load();
  await api.write('objects', digest, bytes(1));
  db.fault = {phase: 'complete'};
  await assert.rejects(api.write('objects', digest, bytes(2)), /quota/);
  assert.deepEqual(await api.read('objects', digest), bytes(1));
  db.fault = {phase: 'request', op: 'delete'};
  await assert.rejects(api.remove('objects', digest), /quota/);
  assert.deepEqual(await api.read('objects', digest), bytes(1));
  await api.remove('objects', digest);
  assert.equal(await api.read('objects', digest), null);
});

test('unavailable, denied and blocked IndexedDB never fall back to memory', async () => {
  for (const missing of [undefined, null]) {
    const context = vm.createContext({indexedDB: missing, Uint8Array, Blob});
    vm.runInContext(source, context);
    const api = context.terraOnlineResourceStorage;
    for (const action of [() => api.read('objects', digest), () => api.list(),
      () => api.write('objects', digest, bytes(1)), () => api.remove('objects', digest),
      () => api.commitActive(digest, bytes(1))]) await assert.rejects(action(), /unavailable/);
  }
  const {api, db} = load();
  db.openError = new Error('Synthetic access denied');
  await assert.rejects(api.write('objects', digest, bytes(1)), /access denied/);
  assert.equal(db.records.size, 0);
  db.openError = null;
  db.blocked = true;
  await assert.rejects(api.commitActive(digest, bytes(1)), /Close other TerraForge tabs/);
  await nextTurn();
  assert.equal(db.connections.at(-1).closed, true);
  assert.equal(db.records.size, 0);
  db.blocked = false;
  await api.write('objects', digest, bytes(2));
  assert.deepEqual(await api.read('objects', digest), bytes(2));
});
