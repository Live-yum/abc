// Bounded file ownership and control contracts; synthetic bytes, no game assets.
'use strict';
const assert = require('node:assert/strict'), crypto = require('node:crypto');
const {createWorldCircuitBridge, SourceSha256} = require('../../web/terra_world_circuit.js');
const MiB = 1024 * 1024;
class VirtualBlob extends Blob {
 constructor(size, reader = (_,n) => new Uint8Array(n)) { super([]); this.virtualSize=size; this.reader=reader; this.slices=[]; }
 get size() { return this.virtualSize; }
 async arrayBuffer() { throw new Error('Whole source materialization is forbidden'); }
 slice(start=0,end=this.size) { const n=end-start; assert.ok(n<=MiB,'Every source slice must be <=1 MiB'); this.slices.push([start,n]); return new Blob([this.reader(start,n)]); }
}
function opfs() {
 const files=new Map(); let peakFiles=0, writes=0, maxWrite=0;
 const directory={
  async getFileHandle(name) {
   const state={size:0,writes:[],closed:false}; files.set(name,state);peakFiles=Math.max(peakFiles,files.size);
   function read(offset,n) { const bytes=new Uint8Array(n); for(const [at,data] of state.writes) { const first=Math.max(offset,at),last=Math.min(offset+n,at+data.length);if(last>first)bytes.set(data.subarray(first-at,last-at),first-offset); } return bytes; }
   return {
    async createSyncAccessHandle() { return {read(bytes,{at}) { bytes.set(read(at,bytes.length));return bytes.length; },write(bytes,{at}) { assert.ok(!state.closed);assert.ok(bytes.length<=MiB);writes++;maxWrite=Math.max(maxWrite,bytes.length);state.writes.push([at,bytes.slice()]);state.size=Math.max(state.size,at+bytes.length);return bytes.length; },flush(){},close(){state.closed=true;}}; },
    async getFile() { return new VirtualBlob(state.size,read); },
   };
  },
  async removeEntry(name) { assert.ok(files.has(name));files.delete(name); },
 };
 return {directory,files,get writes(){return writes;},get maxWrite(){return maxWrite;},get peakFiles(){return peakFiles;}};
}
function fakeModule(worldSize) {
 const memory=new ArrayBuffer(4*MiB),M={HEAPU8:new Uint8Array(memory),HEAPU32:new Uint32Array(memory),cancelCount:0,worldCloses:0,streamCloses:0,reads:[],vmState:42};
 let next=1024,streamEvents=[],events=[],stalled=false;
 M._tx_malloc=n=>{const p=next;next+=(n+7)&~7;assert.ok(next<memory.byteLength);return p;};M._tx_free=()=>{};
 const ready=(kind,count=0,reserved=1)=>[1,4,0,0,0,0,9,15200,15200,kind,count,reserved];
 const input=(id,offset,n)=>[1,1,id,offset,n,0,1,1,2,0,0,0];
 const output=(id,offset,bytes)=>{const p=M._tx_malloc(bytes.length);M.HEAPU8.set(bytes,p);return [1,2,id,offset,bytes.length,p,1,1,2,0,0,0];};
 M._terra_world_stream_open_begin=(id,size,p)=>{assert.equal(id,1);assert.equal(size,worldSize);M.HEAPU32[p/4]=11;streamEvents=[input(1,0,3),input(1,worldSize-3,3),ready(0)];return 0;};
 M._terra_world_stream_step=(id,units,p)=>{M.HEAPU32.set(streamEvents[0],p/4);return 0;};
 M._terra_world_stream_supply_source=(id,source,offset,p,n)=>{M.reads.push([source,offset,n]);streamEvents.shift();return 0;};
 M._terra_world_stream_adopt=(id,source,p)=>{assert.equal(source,1);M.HEAPU32[p/4]=42;return 0;};
 M._terra_world_stream_cancel=()=>0;M._terra_world_stream_close=()=>{M.streamCloses++;return 0;};M._terra_world_close=()=>{M.worldCloses++;return 0;};
 M._terra_circuit_world_begin=(w,s,t,n,b,p)=>{assert.equal(b,192*MiB);M.HEAPU32[p/4]=9;events=[output(2,200*MiB,new Uint8Array([8,9,10])),input(2,200*MiB,3),input(1,worldSize-3,3),...(t?[input(4,0,n)]:[]),ready(0)];return 0;};
 M._terra_circuit_world_step=(id,units,p)=>{if(stalled){M.vmState=99;M.HEAPU32.set([1,0,0,0,0,0,8,1,2,0,0,0],p/4);}else M.HEAPU32.set(events[0],p/4);return 0;};
 M._terra_circuit_world_supply=(id,source,offset,p,n)=>{if(source===2)assert.deepEqual([...M.HEAPU8.subarray(p,p+n)],[8,9,10]);M.reads.push([source,offset,n]);events.shift();return 0;};
 M._terra_circuit_world_ack=()=>{const event=events.shift();M.HEAPU8.fill(0,event[5],event[5]+event[4]);return 0;};
 M._terra_circuit_world_stats=(id,p)=>{const words=Array(24).fill(0);words[0]=1;words[2]=15200;words[3]=7200;words[16]=1000;words[17]=148797093;M.HEAPU32.set(words,p/4);return 0;};
 M._terra_circuit_world_cancel=()=>{M.cancelCount++;M.vmState=42;stalled=false;return 0;};
 M._terra_circuit_world_close=()=>0;
 M._terra_circuit_world_command=(id,p)=>{const words=M.HEAPU32.subarray(p/4,p/4+16);if(words[1]===6)events=[output(3,190*MiB,new Uint8Array([3,2,1])),output(5,0,new Uint8Array([9,8,7])),ready(6,190*MiB+3,3)];else if(words[1]===3)stalled=true;else events=[ready(words[1])];return 0;};
 return M;
}
const command=(bridge,id,kind)=>bridge.command(id,JSON.stringify([1,kind,0,0,kind===9?1:0,kind===9?1:0,1,0,1,0,0,kind===6?3:0,0,kind===6?5:0,0,0]),'[]');
(async()=>{
 for(const n of [0,1,55,56,63,64,65,1000,MiB+5]) { const bytes=crypto.randomBytes(n),hash=new SourceSha256();for(let i=0;i<n;i+=113)hash.update(bytes.subarray(i,i+113));assert.equal(hash.digest(),crypto.createHash('sha256').update(bytes).digest('hex')); }
 const disk=opfs(),prior=Object.getOwnPropertyDescriptor(globalThis,'navigator');Object.defineProperty(globalThis,'navigator',{configurable:true,value:{storage:{getDirectory:async()=>disk.directory}}});
 try {
  const size=129*MiB+7,world=new VirtualBlob(size),sidecar=new VirtualBlob(3),M=fakeModule(size),bridge=createWorldCircuitBridge(async()=>M);
  const result=await bridge.openSource(world,sidecar);
  assert.equal(result.world,null);assert.equal(result.sourceSha256.length,64);assert.equal(result.diagnostics.nativeBudgetBytes,192*MiB);assert.equal(result.diagnostics.nativePeakBytes,148797093);
  assert.equal(result.diagnostics.storageKind,'opfs');assert.equal(result.diagnostics.hostStorageBytes,0);assert.ok(result.diagnostics.sourceReadBytes>=size);assert.ok(result.diagnostics.maxReadBytes<=MiB);
  assert.ok(M.reads.some(([id,offset])=>id===1&&offset>128*MiB));assert.ok(M.reads.some(([id,offset])=>id===2&&offset===200*MiB));assert.ok(world.slices.every(([,n])=>n<=MiB));
  const saving=await command(bridge,result.session,6);assert.equal(saving.world,null);assert.equal(saving.twld,null);assert.equal(saving.worldSource.size,190*MiB+3);assert.equal(saving.twldSource.size,3);
  const pending=command(bridge,result.session,3),rejected=assert.rejects(pending,{code:'CIRCUIT_CANCELLED'});
  await new Promise(resolve=>setTimeout(resolve,0));assert.equal((await bridge.progress()).stage,'command');await bridge.cancelOperation();await rejected;assert.equal(M.vmState,42);assert.equal(M.cancelCount,1);
  await command(bridge,result.session,9);await bridge.close(result.session);assert.equal(disk.files.size,2,'Saved outputs outlive session close');assert.equal(M.worldCloses,1);assert.equal(M.streamCloses,1);
  assert.deepEqual([...new Uint8Array(await saving.worldSource.blob.slice(190*MiB,190*MiB+3).arrayBuffer())],[3,2,1]);
  await bridge.releaseSource(saving.worldSource.token);await bridge.releaseSource(saving.twldSource.token);assert.equal(disk.files.size,0,'Explicit release removes only owned outputs');
  const shortM=fakeModule(2*MiB),shortBridge=createWorldCircuitBridge(async()=>shortM),opening=shortBridge.openSource(new VirtualBlob(2*MiB),null),cancelled=assert.rejects(opening,{code:'CIRCUIT_CANCELLED'});
  await new Promise(resolve=>setTimeout(resolve,0));await shortBridge.cancelOperation();await cancelled;assert.equal(disk.files.size,0,'Cancelled imports close their scratch files');
  assert.ok(disk.maxWrite<=MiB);
  console.log('PASS: streamed >128MiB source, SHA256, <=1MiB reads, sparse OPFS writes, native192MiB budget, persistent paired outputs, progress, cancel rollback and cleanup');
 } finally { if(prior)Object.defineProperty(globalThis,'navigator',prior);else delete globalThis.navigator; }
})().catch(error=>{console.error(error);process.exitCode=1;});
