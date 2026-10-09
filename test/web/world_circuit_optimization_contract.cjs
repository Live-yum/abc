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
  if(query){const data=M._tx_malloc(16);M.HEAPU32.set([6485,800,445,M.state],data/4);M.HEAPU32.set([1,3,0,0,16,data,0,0,0,kind,1,0],p/4);}
  else M.HEAPU32.set([1,4,0,0,0,0,0,0,0,kind,0,reserved],p/4);return 0;
 };
 M._terra_circuit_world_stats=(id,p)=>{M.HEAPU32.set(Array(24).fill(0),p/4);return 0;};
 M._terra_circuit_world_command=(id,p)=>{const w=Array.from(M.HEAPU32.subarray(p/4,p/4+16));kind=w[1];M.commands.push(kind);if(kind===10){assert.equal(busy,false,'Mode changes reach native only while idle');M.mode=w[7]===1;}if(kind===3){busy=true;M.release=false;}query=kind===9;return 0;};
 M._terra_circuit_world_ack=()=>{query=false;return 0;};M._terra_circuit_world_supply=()=>0;M._terra_circuit_world_cancel=()=>{busy=false;return 0;};M._terra_circuit_world_close=()=>{M.closed++;return 0;};
 return M;
}
function words(kind,mask=0){return [1,kind,kind===9?6485:0,kind===9?800:0,kind===9?1:0,kind===9?1:0,1,mask,0,0,0,0,0,0,0,0];}
(async()=>{
 const M=fakeModule(),bridge=createWorldCircuitBridge(async()=>M),opened=await bridge.open(new Uint8Array([1]),null),id=opened.session;
 const command=(kind,mask=0)=>bridge.command(id,JSON.stringify(words(kind,mask)),'[]');
 assert.equal(opened.reserved&2,0,'New sessions default OFF');assert.equal(opened.reserved&1,1,'TWLD compatibility is independent');
 const before=await command(9),on=await command(10,1),after=await command(9);assert.equal(on.session,id);assert.equal(on.reserved&3,3);assert.deepEqual(after.records,before.records,'Idle enable cannot change physical display');
 const off=await command(10,0);assert.equal(off.reserved&3,1);assert.deepEqual((await command(9)).records,before.records);
 const running=command(3),queuedOn=command(10,1);await new Promise(resolve=>setTimeout(resolve,0));assert.equal(M.mode,false,'Queued toggle cannot mutate active work');assert.equal(M.commands.at(-1),3);M.release=true;
 assert.equal((await running).reserved&2,0);assert.equal((await queuedOn).reserved&2,2);assert.equal(M.state,0,'Physical mutation completes before mode change');
 const frame=await command(9);const [disabled,during,enabled,finished]=await Promise.all([command(10,0),command(9),command(10,1),command(9)]);assert.equal(disabled.reserved&2,0);assert.equal(enabled.reserved&2,2);assert.deepEqual(during.records,frame.records);assert.deepEqual(finished.records,frame.records);assert.equal(M.opened,1,'Toggles keep the actual native session');
 for(const invalid of [words(10,2),Object.assign(words(10),{12:1})])await assert.rejects(()=>bridge.command(id,JSON.stringify(invalid),'[]'),/Invalid circuit optimization mode/);
 const recordCommand=words(10);recordCommand[10]=1;await assert.rejects(()=>bridge.command(id,JSON.stringify(recordCommand),'[0,0,0,0]'),/Invalid circuit optimization mode/);
 const absent=new TextEncoder().encode(JSON.stringify({circuitWorldOptimization:0}));M.HEAPU8.fill(0,32,200);M.HEAPU8.set(absent,32);await assert.rejects(()=>command(10,1),/optimization is unavailable/);M.HEAPU8.set(new TextEncoder().encode(JSON.stringify({circuitWorldOptimization:1})),32);
 M.omitModeAck=true;await assert.rejects(()=>command(10,1),/Incomplete circuit result/);M.omitModeAck=false;await command(10,0);
 await bridge.close(id);assert.equal(M.closed,1);
 console.log('PASS: optimization defaultOFF, mode/profile bits, idle toggle display preservation, queued changes, same-session ownership and malformed mode rejection');
})().catch(error=>{console.error(error);process.exitCode=1;});
