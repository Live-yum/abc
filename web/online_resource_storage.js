/* TerraForge's original durable online-resource store. No volatile fallback. */
(() => {
  'use strict';
  const DATABASE = 'terraforge-online-resources-v1';
  const STORE = 'resources';
  const VALUE_LIMIT = 256 * 1024 * 1024;
  const STATE_LIMIT = 2 * 1024 * 1024;
  const KINDS = new Set(['objects', 'images', 'releases', 'packs', 'state']);
  const DIGEST = /^[a-f0-9]{64}$/;
  const STATE = /^(?:(?:authority|root)-[a-f0-9]{64}-[01]|(?:staging|installed)-[a-f0-9]{64}-[a-f0-9]{64}|(?:active|backup)-[a-f0-9]{64})$/;

  function keyFor(kind, id) {
    // Comparing the entire match also rejects trailing newline characters,
    // which JavaScript's $ anchor alone accepts.
    const pattern = kind === 'state' ? STATE : DIGEST;
    if (!KINDS.has(kind) || typeof id !== 'string' || id.length > 139 ||
        pattern.exec(id)?.[0] !== id) {
      throw new Error('Invalid online resource storage key');
    }
    return `${kind}/${id}`;
  }

  function validateSize(kind, size) {
    if (!Number.isSafeInteger(size) || size < 0 ||
        size > (kind === 'state' ? STATE_LIMIT : VALUE_LIMIT)) {
      throw new Error('Online resource exceeds the storage size limit');
    }
  }

  function snapshot(kind, input) {
    if (!(input instanceof Uint8Array)) {
      throw new Error('Online resource bytes must be a Uint8Array');
    }
    validateSize(kind, input.byteLength);
    // Blob copies the caller's mutable buffer before the first asynchronous step.
    return new Blob([input], {type: 'application/octet-stream'});
  }

  function entryFor(record, expectedKey) {
    if (!record || typeof record.key !== 'string' || record.key !== expectedKey ||
        !(record.blob instanceof Blob)) {
      throw new Error('Online resource record is incomplete or corrupted');
    }
    const parts = record.key.split('/');
    if (parts.length !== 2 || keyFor(parts[0], parts[1]) !== record.key) {
      throw new Error('Invalid online resource record key');
    }
    validateSize(parts[0], record.blob.size);
    return {kind: parts[0], id: parts[1], bytes: record.blob.size};
  }

  function open() {
    return new Promise((resolve, reject) => {
      if (!globalThis.indexedDB) {
        reject(new Error('Browser resource storage is unavailable'));
        return;
      }
      let failed = false;
      const request = indexedDB.open(DATABASE, 1);
      request.onupgradeneeded = () => {
        request.result.createObjectStore(STORE, {keyPath: 'key'});
      };
      request.onerror = () => reject(request.error || new Error('Browser resource storage access denied'));
      request.onblocked = () => {
        failed = true;
        reject(new Error('Close other TerraForge tabs to unlock resource storage'));
      };
      request.onsuccess = () => {
        const db = request.result;
        if (failed) { db.close(); return; }
        db.onversionchange = () => db.close();
        resolve(db);
      };
    });
  }

  async function transaction(mode, operation) {
    const db = await open();
    try {
      return await new Promise((resolve, reject) => {
        // Request strict durability for writes where supported by IndexedDB.
        const tx = mode === 'readwrite'
          ? db.transaction(STORE, mode, {durability: 'strict'})
          : db.transaction(STORE, mode);
        let result;
        let failure;
        tx.oncomplete = () => failure ? reject(failure) : resolve(result);
        tx.onerror = event => {
          failure ||= tx.error || event.target?.error || new Error('Browser resource storage transaction failed');
        };
        tx.onabort = () => reject(failure || tx.error || new Error('Browser resource storage denied or quota exceeded'));
        const guard = action => () => {
          try {
            action();
          } catch (error) {
            failure = error;
            try { tx.abort(); } catch (_) { reject(error); }
          }
        };
        guard(() => operation(tx.objectStore(STORE), value => { result = value; }, guard))();
      });
    } finally {
      db.close();
    }
  }

  globalThis.terraOnlineResourceStorage = Object.freeze({
    async read(kind, id) {
      const key = keyFor(kind, id);
      const record = await transaction('readonly', (store, done) => {
        const request = store.get(key);
        request.onsuccess = () => done(request.result);
      });
      if (record === undefined) return null;
      const entry = entryFor(record, key);
      const bytes = new Uint8Array(await record.blob.arrayBuffer());
      if (bytes.byteLength !== entry.bytes) throw new Error('Online resource size mismatch');
      return bytes;
    },

    async write(kind, id, input) {
      const key = keyFor(kind, id);
      const blob = snapshot(kind, input);
      await transaction('readwrite', store => { store.put({key, blob}); });
    },

    async remove(kind, id) {
      const key = keyFor(kind, id);
      await transaction('readwrite', store => { store.delete(key); });
    },

    async list() {
      const entries = await transaction('readonly', (store, done, guard) => {
        const result = [];
        const request = store.openCursor();
        request.onsuccess = guard(() => {
          const cursor = request.result;
          if (!cursor) { done(result); return; }
          result.push(entryFor(cursor.value, cursor.primaryKey));
          cursor.continue();
        });
      });
      return JSON.stringify(entries);
    },

    async commitActive(namespace, input) {
      if (typeof namespace !== 'string') throw new Error('Invalid online resource namespace');
      const activeKey = keyFor('state', `active-${namespace}`);
      const backupKey = keyFor('state', `backup-${namespace}`);
      const blob = snapshot('state', input);
      // Read and both writes share one transaction. A quota error, interrupted
      // write, or invalid predecessor rolls back active AND backup together.
      await transaction('readwrite', (store, done, guard) => {
        const request = store.get(activeKey);
        request.onsuccess = guard(() => {
          const previous = request.result;
          if (previous !== undefined) {
            entryFor(previous, activeKey);
            store.put({key: backupKey, blob: previous.blob});
          }
          store.put({key: activeKey, blob});
        });
      });
    },
  });
})();
