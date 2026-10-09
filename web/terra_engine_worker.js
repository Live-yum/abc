/* Each Worker has one independent WASM owner. Save data stays on the device. */
'use strict';
importScripts('terra_worker_rpc.js');
const owner = new URL(self.location.href).searchParams.get('owner');
const entries = {
  document: ['terra_engine.js', 'createTerraDocumentBridge'],
  worldCircuit: ['terra_world_circuit.js', 'createTerraWorldCircuitBridge'],
  circuit: ['terra_circuit.js', 'createTerraCircuitBridge'],
};
if (!Object.hasOwn(entries, owner)) throw new Error('Unknown computation owner');
const [script, factory] = entries[owner];
importScripts(script);
async function loadModule(kind = 'wld') {
  const name = kind === 'plr' ? 'player' : 'world';
  const base = new URL('engine/', self.location.href);
  importScripts(new URL(name + '.js', base).href);
  const create = self.TerraWorldWasmWeb;
  if (typeof create !== 'function') throw new Error('Missing verified engine factory');
  return create({locateFile:file => new URL(file.endsWith('.wasm') ? name + '.wasm' : file, base).href});
}
TerraWorkerRPC.installHost(owner, self[factory](loadModule));
