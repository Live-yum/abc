const fs=require('node:fs'),vm=require('node:vm'),{parentPort,workerData}=require('node:worker_threads');
globalThis.self=globalThis;
globalThis.postMessage=(data,transfer)=>parentPort.postMessage(data,transfer);
const {installMapWorker}=require('../../web/terra_map_worker.js');
installMapWorker(globalThis,()=>vm.runInThisContext(fs.readFileSync(workerData.compiled,'utf8'),{filename:workerData.compiled}));
parentPort.on('message',data=>globalThis.onmessage({data}));
