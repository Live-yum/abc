/* TerraForge's original binary IndexedDB vault. Never uses localStorage. */
(() => {
  'use strict';
  const MAX = 128 * 1024 * 1024;
  const validId = id => typeof id === 'string' && /^[A-Za-z0-9][A-Za-z0-9_-]{0,95}$/.test(id);
  function validate(entry) {
    if (!entry || !validId(entry.id) || !Number.isSafeInteger(entry.size) ||
        entry.size < 0 || entry.size > MAX || !/^[a-f0-9]{64}$/.test(entry.sha256) ||
        typeof entry.name !== 'string' || !entry.name.length || entry.name.length > 255 ||
        /[/\\\x00-\x1f]/.test(entry.name) || typeof entry.kind !== 'string' ||
        !entry.kind.length || entry.kind.length > 64 || /[\x00-\x1f]/.test(entry.kind) ||
        typeof entry.modified !== 'string' || !Number.isFinite(Date.parse(entry.modified))) {
      throw new Error('Invalid vault record');
    }
  }
  async function verify(entry, bytes) {
    validate(entry);
    if (!(bytes instanceof Uint8Array) || bytes.byteLength !== entry.size || bytes.byteLength > MAX) {
      throw new Error('Vault size mismatch');
    }
    const hash = Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256', bytes)),
      byte => byte.toString(16).padStart(2, '0')).join('');
    if (hash !== entry.sha256) throw new Error('Vault SHA-256 mismatch');
  }
  function open() {
    return new Promise((resolve, reject) => {
      if (!globalThis.indexedDB) { reject(new Error('Browser storage is unavailable')); return; }
      let blocked = false;
      const request = indexedDB.open('terraforge-vault-v1', 1);
      request.onupgradeneeded = () => request.result.createObjectStore('records', {keyPath: 'id'});
      request.onerror = () => reject(request.error || new Error('Browser storage access denied'));
      request.onblocked = () => {
        blocked = true;
        reject(new Error('Close other TerraForge tabs to unlock storage'));
      };
      request.onsuccess = () => {
        if (blocked) { request.result.close(); return; }
        request.result.onversionchange = () => request.result.close();
        resolve(request.result);
      };
    });
  }
  async function transaction(mode, operation) {
    const db = await open();
    try {
      return await new Promise((resolve, reject) => {
        const tx = db.transaction('records', mode);
        let result;
        tx.oncomplete = () => resolve(result);
        tx.onerror = () => reject(tx.error || new Error('Browser storage transaction failed'));
        tx.onabort = () => reject(tx.error || new Error('Browser storage denied or quota exceeded'));
        try {
          const request = operation(tx.objectStore('records'));
          request.onsuccess = () => { result = request.result; };
        } catch (error) { tx.abort(); reject(error); }
      });
    } finally { db.close(); }
  }
  async function unpack(record) {
    if (!record) throw new Error('Vault record not found');
    const entry = JSON.parse(record.metadata);
    validate(entry);
    if (record.id !== entry.id || !(record.blob instanceof Blob) || record.blob.size !== entry.size) {
      throw new Error('Vault record is incomplete or corrupted');
    }
    const bytes = new Uint8Array(await record.blob.arrayBuffer());
    await verify(entry, bytes);
    return {metadata: JSON.stringify(entry), bytes};
  }
  globalThis.terraVault = Object.freeze({
    async list() {
      const records = await transaction('readonly', store => store.getAll());
      const entries = [];
      for (const record of records) entries.push(JSON.parse((await unpack(record)).metadata));
      return JSON.stringify(entries);
    },
    async put(metadata, input) {
      const entry = JSON.parse(metadata);
      validate(entry);
      if (!(input instanceof Uint8Array) || input.byteLength > MAX || input.byteLength !== entry.size) {
        throw new Error('Vault size mismatch');
      }
      const bytes = new Uint8Array(input); // Do not retain a mutable WASM/Dart buffer.
      await verify(entry, bytes);
      // Explicit metadata whitelist prevents source paths or extra fields persisting.
      const safe = {id: entry.id, name: entry.name, kind: entry.kind, sha256: entry.sha256,
        size: entry.size, modified: entry.modified};
      await transaction('readwrite', store => store.add({id: entry.id,
        metadata: JSON.stringify(safe), blob: new Blob([bytes], {type: 'application/octet-stream'})}));
      await unpack(await transaction('readonly', store => store.get(entry.id)));
    },
    async read(id) {
      if (!validId(id)) throw new Error('Invalid vault identifier');
      return unpack(await transaction('readonly', store => store.get(id)));
    },
    async remove(id) {
      if (!validId(id)) throw new Error('Invalid vault identifier');
      await transaction('readwrite', store => store.delete(id));
    }
  });
})();
