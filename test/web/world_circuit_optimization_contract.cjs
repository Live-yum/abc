// Host ownership and queue contracts for the optional native generation stamps.
// This fake proves transport/state handling only; actual equivalence is checked
// by computerraria_file_acceptance against both newly built artifact modes.
'use strict';
const assert=require('node:assert/strict');
const {createWorldCircuitBridge}=require('../../web/terra_world_circuit.js');
function fakeModule(){
 const heap=new ArrayBuffer(8*1024*1024),M={HEAPU8:new Uint8Array(heap),HEAPU32:new Uint32Array(heap),mode:false,state:18,commands:[],opened:0,closed:0,release:false,omitModeAck:false};
 let next=4096,kind=0,query=false,busy=false,currentWords=[];
 M._tx_malloc=n=>{const p=next;next+=(n+7)&~7;return p;};M._tx_free=()=>{};
 const info=new TextEncoder().encode(JSON.stringify({circuitWorldAbiVersion:2,circuitWorldWireHeadPixels:1,circuitWorldOptimization:1}));M.HEAPU8.set(info,32);M._terra_build_info_json=()=>32;
 M._terra_world_open_begin=()=>1;M._terra_world_open_step=()=>0;M._terra_world_open_finish=(t,p)=>{M.HEAPU32[p/4]=42;return 0;};M._terra_world_task_close=()=>0;M._terra_world_close=()=>0;
 M._terra_circuit_world_begin=(w,s,b,p)=>{M.opened++;M.HEAPU32[p/4]=9;return 0;};
 M._terra_circuit_world_step=(id,work,p)=>{
  const reserved=4|(M.mode&&!M.omitModeAck?10:0);
  if(busy&&!M.release){M.HEAPU32.set([2,0,0,0,0,0,8,0,1,0,0,0],p/4);return 0;}
  if(busy){busy=false;M.state^=18;}
  if(query){
   const count=M.emptyPixels?0:M.fullPixels?currentWords[4]*currentWords[5]:1,data=M._tx_malloc(count*16);M.lastPixels=data;M.outputCount=count;
   for(let i=0;i<count;i++)M.HEAPU32.set([currentWords[2]+Math.floor(i/currentWords[5]),currentWords[3]+i%currentWords[5],445,M.state],data/4+i*4);
   M.HEAPU32.set([2,3,0,0,count*16,data,0,0,0,kind,count,0],p/4);
  } else M.HEAPU32.set([2,4,0,0,0,0,0,0,0,kind,kind===9?M.outputCount:0,reserved],p/4);return 0;
 };
 M._terra_circuit_world_stats=(id,p)=>{M.HEAPU32.set([2,0,1024,768,...Array(20).fill(0)],p/4);if(M.afterCommandStats&&kind===2)M.afterCommandStats();return 0;};
 M._terra_circuit_world_command=(id,p)=>{const w=Array.from(M.HEAPU32.subarray(p/4,p/4+16));currentWords=w;kind=w[1];M.commands.push(kind);if(kind===2)M.state^=18;if(kind===9&&M.failRead)return -1;if(kind===10){assert.equal(busy,false,'Mode changes reach native only while idle');if(w[7]===1&&M.unsupportedTopology)return -7;M.mode=w[7]===1;}if(kind===3){busy=true;M.release=false;}query=kind===9;return 0;};
 M._terra_circuit_world_ack=()=>{query=false;return 0;};M._terra_circuit_world_supply=()=>0;M._terra_circuit_world_cancel=()=>{busy=false;return 0;};M._terra_circuit_world_close=()=>{M.closed++;return 0;};
 return M;
}
function words(kind,mask=0){return [2,kind,kind===9?37:0,kind===9?19:0,kind===9?1:0,kind===9?1:0,1,mask,0,0,0,0,0,0,0,0];}
(async()=>{
 const obsolete=fakeModule();obsolete.HEAPU8.fill(0,32,200);obsolete.HEAPU8.set(new TextEncoder().encode('{"circuitWorldAbiVersion":1}'),32);
 const obsoleteBridge=createWorldCircuitBridge(async()=>obsolete);
 await assert.rejects(()=>obsoleteBridge.open(new Uint8Array([1])),/ABI 2 is required/);
 await assert.rejects(()=>obsoleteBridge.openSource(new Blob([new Uint8Array([1])])),/ABI 2 is required/);
 assert.equal(obsolete.opened,0,'An incompatible begin signature must never be called');
 const M=fakeModule(),bridge=createWorldCircuitBridge(async()=>M),opened=await bridge.open(new Uint8Array([1])),id=opened.session;
 const command=(kind,mask=0)=>bridge.command(id,JSON.stringify(words(kind,mask)),'[]');
 assert.equal(opened.reserved&2,0,'New sessions default OFF');assert.equal(opened.reserved&1,0,'Reserved bit is clear');
 M.unsupportedTopology=true;await assert.rejects(()=>command(10,1),{code:'CIRCUIT_PIXEL_TOPOLOGY'});assert.equal(M.mode,false);M.unsupportedTopology=false;
 const before=await command(9),on=await command(10,1),after=await command(9); for(const field of ['coreStepUs','yieldWaitUs','resultCopyUs','commandWallUs']) assert.ok(Number.isFinite(after.hostStagesUs[field]) && after.hostStagesUs[field]>=0, 'Bounded host duration '+field);assert.equal(on.session,id);assert.equal(on.reserved&3,2);assert.deepEqual(after.records,before.records,'Idle enable cannot change physical display');
 const off=await command(10,0);assert.equal(off.reserved&3,0);assert.deepEqual((await command(9)).records,before.records);
 const running=command(3),queuedOn=command(10,1);await new Promise(resolve=>setTimeout(resolve,0));assert.equal(M.mode,false,'Queued toggle cannot mutate active work');assert.equal(M.commands.at(-1),3);M.release=true;
 assert.equal((await running).reserved&2,0);assert.equal((await queuedOn).reserved&2,2);assert.equal(M.state,0,'Physical mutation completes before mode change');
 const frame=await command(9);const [disabled,during,enabled,finished]=await Promise.all([command(10,0),command(9),command(10,1),command(9)]);assert.equal(disabled.reserved&2,0);assert.equal(enabled.reserved&2,2);assert.deepEqual(during.records,frame.records);assert.deepEqual(finished.records,frame.records);assert.equal(M.opened,1,'Toggles keep the actual native session');
 for(const invalid of [words(10,2),Object.assign(words(10),{12:1})])await assert.rejects(()=>bridge.command(id,JSON.stringify(invalid),'[]'),/Invalid circuit optimization mode/);
 const recordCommand=words(10);recordCommand[10]=1;await assert.rejects(()=>bridge.command(id,JSON.stringify(recordCommand),'[0,0,0,0]'),/Invalid circuit optimization mode/);
 const absent=new TextEncoder().encode(JSON.stringify({circuitWorldAbiVersion:2,circuitWorldWireHeadPixels:1,circuitWorldOptimization:0}));M.HEAPU8.fill(0,32,200);M.HEAPU8.set(absent,32);await assert.rejects(()=>command(10,1),/optimization is unavailable/);M.HEAPU8.set(new TextEncoder().encode(JSON.stringify({circuitWorldAbiVersion:2,circuitWorldWireHeadPixels:1,circuitWorldOptimization:1})),32);
 M.omitModeAck=true;await assert.rejects(()=>command(10,1),/Incomplete circuit result/);M.omitModeAck=false;await command(10,0);
 const trigger=[2,2,17,29,1,1,1,4,1,0,0,0,1,0,0,0];
 const ticks=[2,3,0,0,0,0,0,0,6,0,0,0,0,0,0,0];
 const selected=[2,9,37,19,23,11,1,0,0,0,0,0,0,0,0,0];
 const batch=(first=trigger,pixels=selected)=>bridge.commandAndReadPixels(id,JSON.stringify(first),JSON.stringify(pixels));
 for(const mode of [0,1]) {
  await command(10,mode);M.commands.length=0;const oldState=M.state;
  const [frame]=await Promise.all([batch(),command(10,mode)]);
  assert.deepEqual(M.commands,[2,9,10],'Trigger+selected pixels must not interleave a queued mode command');
  assert.equal(M.state,oldState^18);assert.equal(frame.command.reserved&2,mode*2);assert.equal(frame.pixels.reserved&2,mode*2);
  assert.equal(frame.command.resultKind,2);assert.equal(frame.pixels.resultKind,9);assert.equal(frame.readError,null);
  assert.deepEqual(Array.from(new Uint32Array(frame.pixels.records.buffer)).slice(0,3),[37,19,445],'Arbitrary selected coordinates are returned');
  assert.notEqual(frame.pixels.records.buffer,M.HEAPU8.buffer,'The initial borrowed-WASM ownership copy is mandatory');
  const owned=frame.pixels.records.slice();M.HEAPU8.fill(77,M.lastPixels,M.lastPixels+16);assert.deepEqual(frame.pixels.records,owned,'Owned single chunk must survive borrowed buffer reuse');
 }
 M.commands.length=0;const tickBatch=batch(ticks),queuedMode=command(10,0);
 await new Promise(resolve=>setTimeout(resolve,0));assert.deepEqual(M.commands,[3]);M.release=true;
 const tickFrame=await tickBatch;await queuedMode;
 assert.equal(tickFrame.command.resultKind,3);assert.equal(tickFrame.pixels.resultKind,9);assert.deepEqual(M.commands,[3,9,10],'Ticks+pixels use the same indivisible owner slot');
 const direct=trigger.slice();direct[12]=0;direct[8]=129;
 assert.equal((await batch(direct)).command.resultKind,2,'Pulse count is not bound to a sample CPU batch');
 const edge=selected.slice();edge.splice(2,4,1023,767,1,1);assert.equal((await batch(trigger,edge)).pixels.records.length,16);
 M.emptyPixels=true;const empty=await batch();assert.equal(empty.pixels.resultCount,0);assert.equal(empty.pixels.records.length,0);M.emptyPixels=false;
 const maximum=selected.slice();maximum.splice(2,4,0,0,256,256);M.fullPixels=true;
 const full=await batch(trigger,maximum);assert.equal(full.pixels.resultCount,65536);assert.equal(full.pixels.records.length,1024*1024);M.fullPixels=false;
 M.failRead=true;M.commands.length=0;const committed=await batch();
 assert.equal(committed.command.resultKind,2);assert.equal(committed.pixels,null);assert.match(committed.readError,/engine status/);assert.deepEqual(M.commands,[2,9],'Read failure cannot replay an accepted trigger');M.failRead=false;
 M.commands.length=0;M.afterCommandStats=()=>{M.afterCommandStats=null;bridge.cancelOperation();};
 const cancelled=await batch();assert.equal(cancelled.command.resultKind,2);assert.equal(cancelled.pixels,null);assert.match(cancelled.readError,/cancel/i);assert.deepEqual(M.commands,[2],'Cancellation after commit preserves its receipt without replay');
 const alter=(packet,index,value)=>Object.assign(packet.slice(),{[index]:value});
 for(const invalid of [alter(trigger,1,10),alter(trigger,7,0),alter(trigger,7,16),alter(trigger,12,2),alter(trigger,2,1024),alter(trigger,8,-1),alter(ticks,12,1),alter(trigger,10,1),alter(trigger,13,1),alter(trigger,15,1)]) {
  const count=M.commands.length;await assert.rejects(()=>batch(invalid),/Invalid circuit command and pixels batch/);assert.equal(M.commands.length,count);
 }
 for(const invalid of [alter(selected,1,1),alter(selected,4,0),alter(selected,2,1024),alter(selected,2,1002),alter(selected,3,768),alter(selected,3,758),alter(maximum,4,257),alter(selected,12,1),alter(selected,10,1),alter(selected,14,1),alter(selected,2,0.5)]) {
  const count=M.commands.length;await assert.rejects(()=>batch(trigger,invalid),/Invalid circuit command and pixels batch/);assert.equal(M.commands.length,count,'Rejected read arguments must not mutate the circuit');
 }
 await bridge.close(id);assert.equal(M.closed,1);
 console.log('PASS: optimization defaultOFF, mode/reserved bits, idle toggle display preservation, queued changes, same-session ownership, generic trigger/tick batches, sparse pixel bounds, committed read failure and malformed mode rejection');
})().catch(error=>{console.error(error);process.exitCode=1;});
