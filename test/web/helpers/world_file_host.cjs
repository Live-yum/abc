// Node-only adapter for testing the Web bridge against actual file-backed input.
'use strict';
const fs=require('node:fs'),os=require('node:os'),path=require('node:path'),vm=require('node:vm'),assert=require('node:assert/strict');
const {createWorldCircuitBridge}=require('../../../web/terra_world_circuit.js');
function createFileWorldOwner(loader,wasm){
 const directory=fs.mkdtempSync(path.join(os.tmpdir(),'abc-world-stream-'));let next=0,openFiles=0,peakOpenFiles=0,M;
 const storage={kind:'node-file',budget:{used:0,peak:0},async create(){
  const target=path.join(directory,String(++next)),fd=fs.openSync(target,'w+');let size=0,closed=false;openFiles++;peakOpenFiles=Math.max(peakOpenFiles,openFiles);
  return {get size(){return size;},async read(offset,length){assert.ok(length<=1024*1024);const bytes=new Uint8Array(length);assert.equal(fs.readSync(fd,bytes,0,length,offset),length);return bytes;},async write(offset,bytes){assert.ok(bytes.length<=1024*1024);assert.equal(fs.writeSync(fd,bytes,0,bytes.length,offset),bytes.length);size=Math.max(size,offset+bytes.length);},async snapshot(){fs.fsyncSync(fd);return fs.openAsBlob(target);},async close(){if(closed)return;closed=true;fs.closeSync(fd);fs.unlinkSync(target);openFiles--;}};
 }};
 const context=vm.createContext({console,WebAssembly,TextDecoder,TextEncoder,Uint8Array,ArrayBuffer,setTimeout,clearTimeout,URL,performance,window:{},document:{currentScript:{src:'http://localhost/world.js'}},location:{href:'http://localhost/'}});
 vm.runInContext(fs.readFileSync(loader,'utf8'),context,{filename:loader});
 const bridge=createWorldCircuitBridge(async()=>M=await context.TerraWorldWasmWeb({wasmBinary:fs.readFileSync(wasm)}),{createStorage:async()=>storage});
 return {bridge,get module(){return M;},get openFiles(){return openFiles;},get peakOpenFiles(){return peakOpenFiles;},cleanup(){fs.rmSync(directory,{recursive:true,force:true});}};
}
module.exports={createFileWorldOwner};
