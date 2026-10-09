// Host ownership and queue contracts for the optional native generation stamps.
// This fake proves transport/state handling only; actual equivalence is checked
// by computerraria_file_acceptance against both newly built artifact modes.
'use strict';
const assert=require('node:assert/strict');
const {createWorldCircuitBridge}=require('../../web/terra_world_circuit.js');
function fakeModule(){
 const heap=new ArrayBuffer(1024*1024),M={HEAPU8:new Uint8Array(heap),HEAPU32:new Uint32Array(heap),mode:false,state:18,commands:[],opened:0,closed:0,release:false,omitModeAck:false};
 let next=4096,kind=0,query=false,busy=false;
 M._tx_malloc=n=>{const p=next;next+=(n+7)&~7;return p;};M._tx_free=()=>{};
 const info=new TextEncoder().encode(JSON.stringify({circuitWorldOptimization:1}));M.HEAPU8.set(info,32);M._terra_build_info_json=()=>32;
 M._terra_world_open_begin=()=>1;M._terra_world_open_step=()=>0;M._terra_world_open_finish=(t,p)=>{M.HEAPU32[p/4]=42;return 0;};M._terra_world_task_close=()=>0;M._terra_world_close=()=>0;
 M._terra_circuit_world_begin=(w,s,t,n,b,p)=>{M.opened++;M.HEAPU32[p/4]=9;return 0;};
 M._terra_circuit_world_step=(id,work,p)=>{
  const reserved=1|(M.mode&&!M.omitModeAck?2:0);
  if(busy&&!M.release){M.HEAPU32.set([1,0,0,0,0,0,8,0,1,0,0,0],p/4);return 0;}
  if(busy){busy=false;M.state^=18;}
  if(query){const data=M._tx_malloc(16);M.lastPixels=data;M.HEAPU32.set([6485,800,445,M.state],data/4);M.HEAPU32.set([1,3,0,0,16,data,0,0,0,kind,1,0],p/4);}
  else M.HEAPU32.set([1,4,0,0,0,0,0,0,0,kind,0,reserved],p/4);return 0;
 };
 M._terra_circuit_world_stats=(id,p)=>{M.HEAPU32.set(Array(24).fill(0),p/4);return 0;};
 M._terra_circuit_world_command=(id,p)=>{const w=Array.from(M.HEAPU32.subarray(p/4,p/4+16));kind=w[1];M.commands.push(kind);if(kind===2)M.state^=18;if(kind===9&&M.failRead)return -1;if(kind===10){assert.equal(busy,false,'Mode changes reach native only while idle');M.mode=w[7]===1;}if(kind===3){busy=true;M.release=false;}query=kind===9;return 0;};
 M._terra_circuit_world_ack=()=>{query=false;return 0;};M._terra_circuit_world_supply=()=>0;M._terra_circuit_world_cancel=()=>{busy=false;return 0;};M._terra_circuit_world_close=()=>{M.closed++;return 0;};
 return M;
}
function words(kind,mask=0){return [1,kind,kind===9?6485:0,kind===9?800:0,kind===9?1:0,kind===9?1:0,1,mask,0,0,0,0,0,0,0,0];}
(async()=>{
 const M=fakeModule(),bridge=createWorldCircuitBridge(async()=>M),opened=await bridge.open(new Uint8Array([1]),null),id=opened.session;
 const command=(kind,mask=0)=>bridge.command(id,JSON.stringify(words(kind,mask)),'[]');
 assert.equal(opened.reserved&2,0,'New sessions default OFF');assert.equal(opened.reserved&1,1,'TWLD compatibility is independent');
 const before=await command(9),on=await command(10,1),after=await command(9); for(const field of ['coreStepUs','yieldWaitUs','resultCopyUs','commandWallUs']) assert.ok(Number.isFinite(after.hostStagesUs[field]) && after.hostStagesUs[field]>=0, 'Bounded host duration '+field);assert.equal(on.session,id);assert.equal(on.reserved&3,3);assert.deepEqual(after.records,before.records,'Idle enable cannot change physical display');
 const off=await command(10,0);assert.equal(off.reserved&3,1);assert.deepEqual((await command(9)).records,before.records);
 const running=command(3),queuedOn=command(10,1);await new Promise(resolve=>setTimeout(resolve,0));assert.equal(M.mode,false,'Queued toggle cannot mutate active work');assert.equal(M.commands.at(-1),3);M.release=true;
 assert.equal((await running).reserved&2,0);assert.equal((await queuedOn).reserved&2,2);assert.equal(M.state,0,'Physical mutation completes before mode change');
 const frame=await command(9);const [disabled,during,enabled,finished]=await Promise.all([command(10,0),command(9),command(10,1),command(9)]);assert.equal(disabled.reserved&2,0);assert.equal(enabled.reserved&2,2);assert.deepEqual(during.records,frame.records);assert.deepEqual(finished.records,frame.records);assert.equal(M.opened,1,'Toggles keep the actual native session');
 for(const invalid of [words(10,2),Object.assign(words(10),{12:1})])await assert.rejects(()=>bridge.command(id,JSON.stringify(invalid),'[]'),/Invalid circuit optimization mode/);
 const recordCommand=words(10);recordCommand[10]=1;await assert.rejects(()=>bridge.command(id,JSON.stringify(recordCommand),'[0,0,0,0]'),/Invalid circuit optimization mode/);
 const absent=new TextEncoder().encode(JSON.stringify({circuitWorldOptimization:0}));M.HEAPU8.fill(0,32,200);M.HEAPU8.set(absent,32);await assert.rejects(()=>command(10,1),/optimization is unavailable/);M.HEAPU8.set(new TextEncoder().encode(JSON.stringify({circuitWorldOptimization:1})),32);
 M.omitModeAck=true;await assert.rejects(()=>command(10,1),/Incomplete circuit result/);M.omitModeAck=false;await command(10,0);
 const clock=JSON.stringify([1,2,3194,153,1,1,1,8,128,0,0,0,0,0,0,0]);
 const mono=JSON.stringify([1,9,6485,800,64,48,1,0,0,0,0,0,0,0,0,0]);
 const color=JSON.stringify([1,9,7371,1002,176,96,1,0,0,0,0,0,0,0,0,0]);
 for(const mode of [0,1]) {
  await command(10,mode);M.commands.length=0;const oldState=M.state;
  const [frame]=await Promise.all([bridge.computerFrame(id,clock,mode?color:mono),command(10,mode)]);
  assert.deepEqual(M.commands,[2,9,10],'Clock+selected monitor must not interleave a queued mode command');
  assert.equal(M.state,oldState^18);assert.equal(frame.clock.reserved&2,mode*2);assert.equal(frame.display.reserved&2,mode*2);
  assert.equal(frame.clock.resultKind,2);assert.equal(frame.display.resultKind,9);
  assert.notEqual(frame.display.records.buffer,M.HEAPU8.buffer,'The initial borrowed-WASM ownership copy is mandatory');
  const owned=frame.display.records.slice();M.HEAPU8.fill(77,M.lastPixels,M.lastPixels+16);assert.deepEqual(frame.display.records,owned,'Owned single chunk must survive borrowed buffer reuse');
 }
 M.failRead=true;M.commands.length=0;const committed=await bridge.computerFrame(id,clock,mono);
 assert.equal(committed.clock.resultKind,2);assert.equal(committed.display,null);assert.match(committed.displayError,/engine status/);assert.deepEqual(M.commands,[2,9],'Read failure cannot replay accepted clocks');M.failRead=false;
 for(const invalid of [JSON.stringify([1,2,3194,153,1,1,1,8,129,0,0,0,0,0,0,0]),JSON.stringify(words(3))]) {
  const count=M.commands.length;await assert.rejects(()=>bridge.computerFrame(id,invalid,mono),/Invalid physical computer frame/);assert.equal(M.commands.length,count);
 }
 await assert.rejects(()=>bridge.computerFrame(id,clock,JSON.stringify(words(9))),/Invalid physical computer frame/);
 await bridge.close(id);assert.equal(M.closed,1);
 console.log('PASS: optimization defaultOFF, mode/profile bits, idle toggle display preservation, queued changes, same-session ownership and malformed mode rejection');
})().catch(error=>{console.error(error);process.exitCode=1;});
