const assert = require('node:assert/strict');
const {createWorldCircuitBridge} = require('../../web/terra_world_circuit.js');
function fakeModule() {
 const heap = new ArrayBuffer(4*1024*1024);
 const M = {HEAPU8:new Uint8Array(heap),HEAPU32:new Uint32Array(heap),scenario:'valid',acks:0,cancels:0};
 let next=65536,events=[];
 const allocate=n=>{const p=next;next+=(n+7)&~7;return p;};
 M._tx_malloc=allocate;M._tx_free=()=>{};
 const info=new TextEncoder().encode(JSON.stringify({circuitWorldAbiVersion:2,circuitWorldFragmentObjects:1,circuitWorldFragmentSupports:1}));
 M.HEAPU8.set(info,32);M._terra_build_info_json=()=>32;
 const ready=(kind,count=0)=>[2,4,0,0,0,0,0,0,0,kind,count,0];
 const payload=(kind,values,source=0,offset=0,count=values.length/8)=>{
  const p=allocate(values.length*4);M.HEAPU32.set(values,p/4);
  return [2,source?2:3,source,offset,values.length*4,p,0,0,0,kind,count,0];
 };
 M._terra_world_open_begin=()=>1;M._terra_world_open_step=()=>0;
 M._terra_world_open_finish=(t,p)=>{M.HEAPU32[p/4]=42;return 0;};
 M._terra_world_task_close=()=>0;M._terra_world_close=()=>0;
 M._terra_circuit_world_begin=(w,s,b,p)=>{M.HEAPU32[p/4]=9;events=[ready(0)];return 0;};
 M._terra_circuit_world_stats=(id,p)=>{M.HEAPU32.set([2,0,64,64,...Array(20).fill(0)],p/4);return 0;};
 M._terra_circuit_world_command=(id,p)=>{
  const w=Array.from(M.HEAPU32.subarray(p/4,p/4+16));
  if(w[1]===7)events=[payload(7,[17,4,6,1,1,1,1,0]),ready(7,23)];
  if(w[1]===8){
   const object=payload(8,[0x31424f43,1,326,0,32,4,6,0],6,0,0);
   const result=payload(8,[4,6,0,0xffffffff,0,1<<24,0,0]);
   if(M.scenario==='badCount')result[10]=2;
   if(M.scenario==='badSink')object[3]=1;
   if(M.scenario==='badReady')events=[object,result,ready(8,2)];
   else events=[object,result,ready(8,1)];
  }
  return 0;
 };
 M._terra_circuit_world_step=(id,work,p)=>{M.HEAPU32.set(events[0],p/4);return 0;};
 M._terra_circuit_world_ack=()=>{M.acks++;const event=events.shift();M.HEAPU8.fill(0,event[5],event[5]+event[4]);return 0;};
 M._terra_circuit_world_supply=()=>0;M._terra_circuit_world_cancel=()=>{M.cancels++;events=[];return 0;};
 M._terra_circuit_world_close=()=>0;
 return M;
}
(async()=>{
 const M=fakeModule(), bridge=createWorldCircuitBridge(async()=>M);
 const {session}=await bridge.open(new Uint8Array([1]));
 const command=(kind,count=1)=>bridge.command(session,JSON.stringify([2,kind,0,0,kind===8?4194304:0,kind===8?32768:0,1,17,count,0,0,0,kind===8?1:0,kind===8?6:0,0,0]),'[]');
 const page=await command(7);
 assert.equal(page.resultKind,7);assert.equal(page.resultCount,23);assert.equal(page.reserved,0);assert.equal(page.records.length,32);
 const first=await command(8);assert.equal(first.resultCount,1);assert.equal(first.records.length,32);
 assert.equal(new DataView(first.objects.buffer).getUint32(0,true),0x31424f43);
 const copy=first.objects.slice();await command(8);assert.deepEqual(first.objects,copy);
 for(const scenario of ['badCount','badSink','badReady']){M.scenario=scenario;await assert.rejects(()=>command(8));}
 assert.equal(M.cancels,3);M.scenario='valid';await command(8);
 await assert.rejects(()=>command(7,32769));
 await bridge.close(session);
 console.log('PASS: fragment READY metadata, eight-word budgets, independent COB1 capture, malformed output rollback and recovery');
})().catch(e=>{console.error(e);process.exitCode=1;});
