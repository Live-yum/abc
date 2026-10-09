// Fault-injected ownership contracts; no WASM or full-world input is loaded.
'use strict';
const assert = require('node:assert/strict');
const {createWorldCircuitBridge} = require('../../web/terra_world_circuit.js');
const {createClient,installHost} = require('../../web/terra_worker_rpc.js');
const input = new Blob(['world']);
const command = kind => JSON.stringify([2,kind,0,0,0,0,0,0,0,0,0,kind===6?3:0,0,0,0,0]);
function harness() {
 const counts={circuit:0,world:0,task:0,begin:0}, fail={circuit:0,world:0,task:0,compile:0,create:0,file:0};
 const files=[], active=new Set(), allocated=new Set(), live={circuit:false,world:false,task:false};
 const storage={kind:'test',budget:{used:0,peak:0},async create() {
  if(fail.create-- > 0) throw new Error('create failed');
  let bytes=new Uint8Array();
  const file={fail:fail.file,attempts:0,closed:0,get size(){return bytes.length;},async read(offset,length){return bytes.slice(offset,offset+length);},
   async write(offset,value){const copy=new Uint8Array(Math.max(bytes.length,offset+value.length));copy.set(bytes);copy.set(value,offset);bytes=copy;},
   async snapshot(){return new Blob([bytes]);},async close(){
    file.attempts++; if(file.fail-- > 0) throw new Error('remove failed');
    assert.equal(file.closed++,0,'Acknowledged files must not close twice');active.delete(file);
   }}; fail.file=0;files.push(file);active.add(file);return file;
 }};
 const M={HEAPU8:new Uint8Array(65536)}; M.HEAPU32=new Uint32Array(M.HEAPU8.buffer);let next=1024,events=[];
 M.HEAPU8.set(new TextEncoder().encode('{"circuitWorldAbiVersion":2}'),32);M._terra_build_info_json=()=>32;
 M._tx_malloc=size=>{const p=next;next+=(size+7)&~7;assert.ok(next<65536);allocated.add(p);return p;};
 M._tx_free=p=>assert.ok(allocated.delete(p),'Host allocation cannot be freed twice');
 const ready=kind=>[2,4,0,0,0,0,0,0,0,kind,kind===6?3:0,0];
 M._terra_world_stream_open_begin=(source,size,out)=>{counts.begin++;live.task=true;M.HEAPU32[out>>>2]=3;return 0;};
 M._terra_world_stream_step=(task,work,event)=>{M.HEAPU32.set([1,4,0,0,0,0,0,0,0,0,0,0],event>>>2);return 0;};
 M._terra_world_stream_adopt=(task,source,out)=>{live.world=true;M.HEAPU32[out>>>2]=42;return 0;};
 M._terra_world_stream_supply_source=M._terra_world_stream_cancel=()=>0;
 M._terra_world_stream_close=()=>{counts.task++;assert.equal(live.task,true);if(fail.task-- > 0)return 6;live.task=false;return 0;};
 M._terra_world_close=()=>{counts.world++;assert.equal(live.circuit,false,'Circuit must release its world first');assert.equal(live.task,false,'Task must release adopted world references first');assert.equal(live.world,true);if(fail.world-- > 0)return 6;live.world=false;return 0;};
 M._terra_circuit_world_begin=(world,scratch,budget,out)=>{live.circuit=true;M.HEAPU32[out>>>2]=9;events=[[2,2,2,0,3,256,0,0,0,0,0,0],ready(0)];return 0;};
 M._terra_circuit_world_step=(handle,work,event)=>{if(fail.compile-- > 0)throw new Error('compile failed');M.HEAPU8.set([4,5,6],256);M.HEAPU32.set(events[0],event>>>2);return 0;};
 M._terra_circuit_world_ack=()=>{events.shift();return 0;};
 M._terra_circuit_world_stats=(handle,out)=>{M.HEAPU32.fill(0,out>>>2,(out>>>2)+24);M.HEAPU32[out>>>2]=2;M.HEAPU32[(out>>>2)+16]=123;return 0;};
 M._terra_circuit_world_command=(handle,words)=>{assert.equal(live.circuit,true);const kind=M.HEAPU32[(words>>>2)+1];events=kind===6?[[2,2,3,0,3,256,0,0,0,0,0,0],ready(kind)]:[ready(kind)];return 0;};
 M._terra_circuit_world_supply=M._terra_circuit_world_cancel=()=>0;
 M._terra_circuit_world_close=()=>{counts.circuit++;assert.equal(live.circuit,true);if(fail.circuit-- > 0)return -2;live.circuit=false;return 0;};
 const bridge=createWorldCircuitBridge(async()=>M,{createStorage:async()=>storage});
 return {bridge,M,counts,fail,files,active,allocated,live};
}
function rpc(bridge) {
 const workers=[];
 const client=createClient('worldCircuit',{createWorker(){
  const worker={terminated:false};const scope={postMessage(data){queueMicrotask(()=>worker.onmessage?.({data}));}};
  installHost('worldCircuit',bridge,scope);worker.postMessage=data=>queueMicrotask(()=>scope.onmessage({data}));worker.terminate=()=>{worker.terminated=true;};workers.push(worker);return worker;
 }});return {client,workers};
}
const clean=h=>{assert.equal(h.active.size,0);assert.equal(h.allocated.size,0);assert.deepEqual(h.live,{circuit:false,world:false,task:false});};
function opfs(acquireFailureAt=0,removeFailureAt=0,removeFailures=0) {
 const files=new Map(),all=[];
 const directory={async getFileHandle(name) {
  const state={index:all.length+1,closed:0,size:0};all.push(state);files.set(name,state);
  return {async createSyncAccessHandle() {
   if(state.index===acquireFailureAt)throw new Error('access failed');
   return {close(){assert.equal(state.closed++,0,'Sync access handle closes once across removal retries');},flush(){},
    write(bytes,{at}){state.size=Math.max(state.size,at+bytes.length);return bytes.length;},read(bytes){return bytes.length;}};
  },async getFile(){return new Blob([new Uint8Array(state.size)]);}};
 },async removeEntry(name){const state=files.get(name);assert.ok(state);if(state.index===removeFailureAt&&removeFailures-- > 0)throw new Error('OPFS remove failed');files.delete(name);}};
 return {directory,files,all};
}
(async()=>{
 for(const fault of ['circuit','world','file']) {
  const h=harness(),opened=await h.bridge.openSource(input);h.fail[fault]=1;if(fault==='file')h.files[0].fail=1;
  await assert.rejects(h.bridge.close(opened.session),/status|remove failed/);
  await assert.rejects(h.bridge.command(opened.session,command(3),'[]'),/session is closed/);
  assert.equal(h.active.size,1,'Failed teardown retains backing file ownership');
  if(fault==='circuit'){assert.equal(h.counts.world,0);assert.equal(h.files[0].attempts,0);}
  if(fault==='world')assert.equal(h.files[0].attempts,0);
  await h.bridge.close(opened.session);await h.bridge.close(opened.session);clean(h);
  assert.equal(h.counts.circuit,fault==='circuit'?2:1);assert.equal(h.counts.world,fault==='world'?2:1);
  assert.equal(h.files[0].closed,1);assert.equal((await h.bridge.progress()).diagnostics.storageBytes,0);
 }
 // Reopen retries retained cleanup before allocating or importing anything.
 const blocked=harness(),opened=await blocked.bridge.openSource(input);blocked.files[0].fail=3;
 await assert.rejects(blocked.bridge.close(opened.session),/remove failed/);
 await assert.rejects(blocked.bridge.openSource(input),/remove failed/);assert.equal(blocked.counts.begin,1);assert.equal(blocked.files.length,1);
 await assert.rejects(blocked.bridge.cleanup(),/remove failed/);await blocked.bridge.cleanup();clean(blocked);
 const reopened=await blocked.bridge.openSource(input);await blocked.bridge.close(reopened.session);clean(blocked);

 // Failed import retains every unfinished native dependency and retries only it.
 for(const fault of ['circuit','world','task','file']) {
  const h=harness();h.fail.compile=fault==='task'?0:1;
  h.fail[fault]=2;await assert.rejects(h.bridge.openSource(input),/compile failed|World decoder status/);
  assert.equal(h.active.size,1);const begin=h.counts.begin;
  // The first failure already retried task close during failed-import cleanup.
  if(fault!=='task')await assert.rejects(h.bridge.openSource(input),/status|remove failed/);
  assert.equal(h.counts.begin,begin,'Reopen may not cross unfinished import cleanup');
  await h.bridge.cleanup();clean(h);
  const next=await h.bridge.openSource(input);await h.bridge.close(next.session);clean(h);
 }
 const cancelled=harness();cancelled.fail.file=1;
 const cancellingInput=new class extends Blob {slice(...args){cancelled.bridge.cancelOperation();return super.slice(...args);}}(['world']);
 const importing=cancelled.bridge.openSource(cancellingInput);
 await assert.rejects(importing,{code:'CIRCUIT_CANCELLED'});assert.equal(cancelled.active.size,1);await cancelled.bridge.cleanup();clean(cancelled);

 // Multiple files are cleaned independently; only failed records remain.
 const files=harness(),fileSession=await files.bridge.openSource(input);
 const saved=await files.bridge.command(fileSession.session,command(6),'[]');assert.equal(files.active.size,2);
 await assert.rejects(files.bridge.cleanup(),/Close the existing/);
 await files.bridge.close(fileSession.session);assert.equal(files.active.size,1,'Completed export belongs to its lease after close');
 files.files[1].fail=1;await assert.rejects(files.bridge.releaseSource(saved.worldSource.token),/remove failed/);assert.equal(files.active.size,1);
 await files.bridge.cleanup();assert.equal(files.active.size,1,'Idle cleanup never drops exports');
 await files.bridge.releaseSource(saved.worldSource.token);clean(files);assert.equal(files.files[1].closed,1);

 // Through the real RPC host, failed close cannot retire or become a local no-op.
 const integrated=harness(),transport=rpc(integrated.bridge),session=await transport.client.openSource(input);integrated.files[0].fail=1;
 await assert.rejects(transport.client.close(session.session),/remove failed/);assert.equal(transport.workers[0].terminated,false);
 await transport.client.close(session.session);assert.equal(transport.workers[0].terminated,true);clean(integrated);
 const noHandle=harness(),idle=rpc(noHandle.bridge);noHandle.fail.compile=1;noHandle.fail.circuit=1;
 await assert.rejects(idle.client.openSource(input),/compile failed/);assert.equal(idle.workers[0].terminated,false);assert.equal(noHandle.live.circuit,true);
 await idle.client.cleanup();assert.equal(idle.workers[0].terminated,true);clean(noHandle);

 // Releasing the last old export cannot abandon failed-import scratch.
 const lease=harness(),leaseRpc=rpc(lease.bridge),first=await leaseRpc.client.openSource(input);
 const output=await leaseRpc.client.command(first.session,command(6),'[]');await leaseRpc.client.close(first.session);
 lease.fail.compile=1;lease.fail.circuit=2;await assert.rejects(leaseRpc.client.openSource(input),/compile failed/);
 await assert.rejects(leaseRpc.client.releaseSource(output.worldSource.token),/status/);assert.equal(leaseRpc.workers[0].terminated,false);
 await leaseRpc.client.releaseSource(output.worldSource.token);assert.equal(leaseRpc.workers[0].terminated,true);clean(lease);
 const priorNavigator=Object.getOwnPropertyDescriptor(globalThis,'navigator');
 try {
  for(const [acquireAt,removeAt,failures] of [[0,1,1],[1,1,2],[2,2,2],[0,2,1]]) {
   const disk=opfs(acquireAt,removeAt,failures),native=harness();
   Object.defineProperty(globalThis,'navigator',{configurable:true,value:{storage:{getDirectory:async()=>disk.directory}}});
   const bridge=createWorldCircuitBridge(async()=>native.M);
   if(acquireAt||removeAt===1)await assert.rejects(bridge.openSource(input),/access failed|OPFS remove failed/);
   else {const opened=await bridge.openSource(input);await assert.rejects(bridge.close(opened.session),/OPFS remove failed/);}
   assert.equal(disk.files.size,1,'Probe and failed access acquisition retain retryable file ownership');
   await bridge.cleanup();assert.equal(disk.files.size,0);clean(native);
  }
 } finally {if(priorNavigator)Object.defineProperty(globalThis,'navigator',priorNavigator);else delete globalThis.navigator;}
 console.log('PASS: retryable VM/world/task/file cleanup, failed/cancelled import ownership, blocked reopen, export leases, exact-once frees and acknowledged RPC retirement');
})().catch(error=>{console.error(error);process.exitCode=1;});
