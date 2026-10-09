// Node worker adapter for the actual browser worker bootstrap. No network I/O.
'use strict';
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const {Worker, isMainThread, parentPort, workerData} = require('node:worker_threads');
if (!isMainThread) {
  const base = 'http://local.invalid/';
  const root = workerData.root;
  const allowed = new Set(['terra_worker_rpc.js','terra_engine_worker.js','terra_engine.js','terra_world_circuit.js','terra_circuit.js','engine/world.js','engine/world.wasm','engine/player.js','engine/player.wasm']);
  const local = url => {
    const parsed = new URL(url, base), file = parsed.pathname.slice(1);
    if (parsed.origin !== new URL(base).origin || !allowed.has(file)) throw new Error('Only explicit local worker assets may load');
    return path.join(root, 'web', file);
  };
  let context;
  const scope = {
    console, URL, WebAssembly, TextEncoder, TextDecoder, Uint8Array, ArrayBuffer,
    setTimeout, clearTimeout, performance, WorkerGlobalScope: function(){},
    location:{href:base+'terra_engine_worker.js?owner='+workerData.owner},
    postMessage(data, transfers) { parentPort.postMessage(data, transfers); },
    importScripts(...urls) { for (const url of urls) vm.runInContext(fs.readFileSync(local(url),'utf8'), context, {filename:new URL(url,base).pathname}); },
    async fetch(url) { return new Response(fs.readFileSync(local(url)), {headers:{'Content-Type':'application/wasm'}}); },
  };
  scope.self = scope;
  context = vm.createContext(scope);
  if (workerData.direct) {
    const entries = {document:['terra_engine.js','createTerraDocumentBridge'],worldCircuit:['terra_world_circuit.js','createTerraWorldCircuitBridge'],circuit:['terra_circuit.js','createTerraCircuitBridge']};
    const [script,factory] = entries[workerData.owner];
    scope.importScripts(script);
    const bridge = scope[factory](async (kind='wld') => {
      const name = kind === 'plr' ? 'player' : 'world';
      scope.importScripts('engine/'+name+'.js');
      return scope.TerraWorldWasmWeb({wasmBinary:fs.readFileSync(local('engine/'+name+'.wasm'))});
    });
    // Direct bridge baseline runs in a separate worker, released before RPC tests.
    parentPort.on('message', async ({id,method,args}) => {
      try { parentPort.postMessage({id,ok:true,value:await bridge[method](...args)}); }
      catch(error) { parentPort.postMessage({id,ok:false,error:String(error)}); }
    });
  } else {
    scope.importScripts('terra_engine_worker.js');
    parentPort.on('message', data => scope.onmessage({data}));
  }
} else {
  function workerFactory({root=path.resolve(__dirname,'../../..'),direct=false}={}) {
    const threads = [], exits = [];
    function createWorker(owner) {
      const thread = new Worker(__filename, {workerData:{root,owner,direct}});
      const proxy = {postMessage:(data, transfers)=>thread.postMessage(data,transfers),terminate:()=>thread.terminate()};
      thread.on('message',data=>proxy.onmessage?.({data}));
      thread.on('error',error=>proxy.onerror?.(error));
      // An external termination/crash must reject pending calls, even without error.
      thread.on('exit',code=>proxy.onerror?.({message:'Worker exited '+code}));
      threads.push(thread); exits.push(new Promise(resolve=>thread.once('exit',resolve)));
      return proxy;
    }
    return {createWorker,threads,exits};
  }
  module.exports = {workerFactory};
}
