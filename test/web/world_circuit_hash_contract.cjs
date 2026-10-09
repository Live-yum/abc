// Small synthetic ownership contracts for verified input and output pair hashes.
'use strict';
const assert=require('node:assert/strict'),crypto=require('node:crypto');
const {createWorldCircuitBridge}=require('../../web/terra_world_circuit.js');
const MiB=1024*1024,hash=bytes=>crypto.createHash('sha256').update(bytes).digest('hex');
class RangedBlob extends Blob {
 constructor(bytes){super([bytes]);this.ranges=[];this.sha256='0'.repeat(64);}
 async arrayBuffer(){throw new Error('Whole File/Blob reads are forbidden');}
 slice(start,end){assert.ok(end-start<=MiB);this.ranges.push([start,end-start]);return super.slice(start,end);}
}
function memoryDisk(){
 let next=0,failId=0,cancelId=0,onCancel;const files=new Map(),readLengths=[];
 return {kind:'test-file',budget:{used:0,peak:0},files,readLengths,
  failRead(id){failId=id;},cancelRead(id,callback){cancelId=id;onCancel=callback;},
  async create(){const id=++next;let size=0,closed=false;const pages=[];const file={id,get size(){return size;},
   async write(offset,bytes){assert.ok(bytes.length<=MiB);pages.push([offset,bytes.slice()]);size=Math.max(size,offset+bytes.length);},
   async read(offset,n){assert.ok(!closed);assert.ok(n<=MiB);readLengths.push(n);if(id===failId)throw new Error('Synthetic output hash read failure');if(id===cancelId){cancelId=0;onCancel();}const out=new Uint8Array(n);for(const [at,bytes]of pages){const first=Math.max(offset,at),last=Math.min(offset+n,at+bytes.length);if(first<last)out.set(bytes.subarray(first-at,last-at),first-offset);}return out;},
   async snapshot(){const parts=[];for(let at=0;at<size;at+=MiB)parts.push(await this.read(at,Math.min(MiB,size-at)));return new Blob(parts);},
   async close(){closed=true;files.delete(id);},
  };files.set(id,file);return file;},
 };
}
function moduleFor(worldBytes,sidecarBytes,outWorld,outTwld){
 const heap=new ArrayBuffer(16*MiB),M={HEAPU8:new Uint8Array(heap),HEAPU32:new Uint32Array(heap),cancelCount:0};let next=4096,events=[],stream=[];
 M._tx_malloc=n=>{const p=next;next+=(n+7)&~7;assert.ok(next<heap.byteLength);return p;};M._tx_free=()=>{};
 const ready=(kind,count=0,reserved=1)=>[1,4,0,0,0,0,0,0,0,kind,count,reserved];
 const write=(id,offset,bytes)=>{const p=M._tx_malloc(bytes.length);M.HEAPU8.set(bytes,p);return[1,2,id,offset,bytes.length,p,0,0,0,6,0,0];};
 M._terra_world_stream_open_begin=(id,size,p)=>{assert.equal(size,worldBytes.length);M.HEAPU32[p/4]=3;stream=[ready(0)];return 0;};M._terra_world_stream_step=(id,n,p)=>{M.HEAPU32.set(stream[0],p/4);return 0;};M._terra_world_stream_supply_source=()=>0;M._terra_world_stream_adopt=(id,src,p)=>{M.HEAPU32[p/4]=42;return 0;};M._terra_world_stream_cancel=()=>0;M._terra_world_stream_close=()=>0;M._terra_world_close=()=>0;
 M._terra_circuit_world_begin=(w,s,t,length,b,p)=>{assert.equal(length,sidecarBytes?.length||0);M.HEAPU32[p/4]=9;events=[ready(0)];return 0;};M._terra_circuit_world_step=(id,n,p)=>{M.HEAPU32.set(events[0],p/4);return 0;};M._terra_circuit_world_supply=()=>0;M._terra_circuit_world_ack=()=>{events.shift();return 0;};M._terra_circuit_world_stats=(id,p)=>{M.HEAPU32.set(Array(24).fill(0),p/4);return 0;};M._terra_circuit_world_cancel=()=>{M.cancelCount++;return 0;};M._terra_circuit_world_close=()=>0;
 M._terra_circuit_world_command=(id,p)=>{const kind=M.HEAPU32[p/4+1];events=[];if(kind===6){for(let at=0;at<outWorld.length;at+=MiB)events.push(write(3,at,outWorld.subarray(at,at+MiB)));if(sidecarBytes)events.push(write(5,0,outTwld));events.push(ready(6,outWorld.length,sidecarBytes?outTwld.length:0));}else events=[ready(kind)];return 0;};
 return M;
}
const save=(bridge,id)=>bridge.command(id,JSON.stringify([1,6,0,0,0,0,0,0,0,0,0,3,0,5,0,0]),'[]');
(async()=>{
 const worldBytes=new Uint8Array([1,2,3,4]),sidecarBytes=new Uint8Array([31,139,8,0,9,7,3]),outWorld=new Uint8Array(MiB+19).fill(53),outTwld=new Uint8Array([31,139,8,0,2,4,8]);outWorld[MiB+18]=199;
 const disk=memoryDisk(),M=moduleFor(worldBytes,sidecarBytes,outWorld,outTwld),bridge=createWorldCircuitBridge(async()=>M,{createStorage:async()=>disk}),world=new RangedBlob(worldBytes),sidecar=new RangedBlob(sidecarBytes);
 const opened=await bridge.openSource(world,sidecar);assert.equal(opened.sourceSha256,hash(worldBytes));assert.equal(opened.twldSourceSha256,hash(sidecarBytes));assert.notEqual(opened.sourceSha256,world.sha256);assert.notEqual(opened.twldSourceSha256,sidecar.sha256);assert.ok(sidecar.ranges.length>0,'Companion bytes are independently read and hashed');
 // Scratch is file1; failed pair is files2/3. Failure in the second hash must
 // retire the already-hashed WLD too, before either lease can escape.
 disk.failRead(3);await assert.rejects(()=>save(bridge,opened.session),/output hash read failure/);assert.equal(disk.files.size,1,'Failed pair hash removes both unpublished outputs');
 disk.failRead(0);disk.cancelRead(4,()=>bridge.cancelOperation());await assert.rejects(()=>save(bridge,opened.session),{code:'CIRCUIT_CANCELLED'});assert.equal(disk.files.size,1,'Cancelled output hash removes both unpublished outputs');
 const saved=await save(bridge,opened.session);assert.equal(saved.twldSourceSha256,hash(sidecarBytes),'Result retains actual original companion identity');assert.equal(saved.worldSource.sha256,hash(outWorld));assert.equal(saved.twldSource.sha256,hash(outTwld));assert.notEqual(saved.twldSource.sha256,saved.twldSourceSha256,'Output digest describes the saved companion bytes');assert.equal(saved.worldSource.token,1,'Failed/cancelled pair hashes never publish a lease');assert.equal(saved.twldSource.token,2);
 await bridge.close(opened.session);assert.equal(disk.files.size,2);assert.equal(hash(new Uint8Array(await saved.worldSource.blob.arrayBuffer())),saved.worldSource.sha256,'Saved WLD hash survives session close');assert.equal(hash(new Uint8Array(await saved.twldSource.blob.arrayBuffer())),saved.twldSource.sha256,'Saved TWLD hash survives session close');await bridge.releaseSource(saved.worldSource.token);await bridge.releaseSource(saved.twldSource.token);assert.equal(disk.files.size,0);assert.ok(disk.readLengths.every(n=>n<=MiB));assert.equal(M.cancelCount,2);
 const brokenDisk=memoryDisk(),brokenM=moduleFor(worldBytes,sidecarBytes,outWorld,outTwld),brokenBridge=createWorldCircuitBridge(async()=>brokenM,{createStorage:async()=>brokenDisk}),brokenCompanion=new RangedBlob(sidecarBytes);brokenCompanion.slice=()=>{throw new Error('Synthetic companion hash failure');};await assert.rejects(()=>brokenBridge.openSource(new RangedBlob(worldBytes),brokenCompanion),/companion hash failure/);assert.equal(brokenDisk.files.size,0,'Input companion hash failure releases partial import owners');
 const soloDisk=memoryDisk(),solo=moduleFor(worldBytes,null,outWorld,outTwld),soloBridge=createWorldCircuitBridge(async()=>solo,{createStorage:async()=>soloDisk}),unpaired=await soloBridge.openSource(new RangedBlob(worldBytes),null);assert.equal(unpaired.twldSourceSha256,null);await soloBridge.close(unpaired.session);
 console.log('PASS: actual input pair hashes, untrusted hash claims ignored, bounded saved pair hashing, atomic lease publication, cancellation/error cleanup and post-close verification');
})().catch(error=>{console.error(error);process.exitCode=1;});
