// Existing web host accepts the cache's ordinary one-byte READ protocol.
// This host contract uses a fake ABI producer; native cache behavior is tested
// separately through the compiled actual ABI, not simulated by this file.
'use strict';
const assert = require('node:assert/strict');
const {createWorldCircuitBridge} = require('../../web/terra_world_circuit.js');

function harness() {
 const owned = new Set(), counts = {supplies:0, results:0, cancels:0, closes:0};
 const M = {HEAPU8:new Uint8Array(4 * 1024 * 1024)};
 M.HEAPU32 = new Uint32Array(M.HEAPU8.buffer);
 M.HEAPU8.set(new TextEncoder().encode('{"circuitWorldAbiVersion":2}'),32);
 M._terra_build_info_json = () => 32;
 let next=1024, events=[], fault='', bridge;
 M._tx_malloc = size => { const p=next;next+=(size+7)&~7;assert.ok(next<M.HEAPU8.length);owned.add(p);return p; };
 M._tx_free = p => assert.ok(owned.delete(p));
 const ready = kind => [2,4,0,0,0,0,12,4,4,kind,0,4];
 M._terra_world_stream_open_begin = (_,size,out) => {assert.equal(size,16);M.HEAPU32[out>>>2]=11;return 0;};
 M._terra_world_stream_step = (_,work,event) => {M.HEAPU32.set([1,4,0,0,0,0,0,0,0,0,0,0],event>>>2);return 0;};
 M._terra_world_stream_adopt = (_,source,out) => {M.HEAPU32[out>>>2]=42;return 0;};
 M._terra_world_stream_supply_source = M._terra_world_stream_cancel = M._terra_world_stream_close = M._terra_world_close = () => 0;
 M._terra_circuit_world_begin = (_,scratch,budget,out) => {M.HEAPU32[out>>>2]=9;events=[ready(0)];return 0;};
 M._terra_circuit_world_step = (_,work,event) => {assert.ok(events.length);M.HEAPU32.set(events[0],event>>>2);return 0;};
 M._terra_circuit_world_command = (_,words) => {
  assert.equal(M.HEAPU32[(words>>>2)+1],1);
  M.HEAPU32.set([0,0,419|(1<<16),18],128);
  events=[[2,1,1,fault==='range'?17:3,1,0,13,0,4,0,0,0],
          [2,3,0,0,16,512,13,1,4,1,1,0],ready(1)];return 0;
 };
 M._terra_circuit_world_supply = (_,source,offset,p,length) => {
  assert.equal(source,1);assert.equal(offset,3);assert.equal(length,1);
  assert.equal(M.HEAPU8[p],3);counts.supplies++;events.shift();return 0;
 };
 M._terra_circuit_world_ack = () => {assert.equal(events[0][1],3);counts.results++;M.HEAPU8.fill(0,512,528);events.shift();return 0;};
 M._terra_circuit_world_cancel = () => {counts.cancels++;events=[];return 0;};
 M._terra_circuit_world_close = () => {counts.closes++;return 0;};
 M._terra_circuit_world_stats = (_,out) => {const s=Array(24).fill(0);s[0]=2;s[2]=s[3]=4;M.HEAPU32.set(s,out>>>2);return 0;};
 const storage = {kind:'test',async create(){return {size:0,async close(){},async read(){return new Uint8Array();},async write(){}};}};
 bridge=createWorldCircuitBridge(async()=>M,{createStorage:async()=>storage});
 const input = new class extends Blob {
  slice(start,end){
   if(fault==='short')return new Blob([]);
   if(fault==='read')throw new Error('source read failed');
   if(fault==='cancel')bridge.cancelOperation();
   return super.slice(start,end);
  }
 }([Uint8Array.from({length:16},(_,i)=>i)]);
 const command = session => bridge.command(session,JSON.stringify([2,1,0,0,1,1,1,0,0,0,0,0,0,0,0,0]),'[]');
 return {bridge,input,command,counts,owned,setFault(value){fault=value;}};
}

(async()=>{
 const success=harness(), opened=await success.bridge.openSource(success.input);
 for(let i=0;i<2;i++){
  const result=await success.command(opened.session);
  assert.deepEqual([...new Uint32Array(result.records.buffer,result.records.byteOffset,4)],[0,0,419|(1<<16),18]);
 }
 assert.equal(success.counts.supplies,2);assert.equal(success.counts.results,2);
 await success.bridge.close(opened.session);assert.equal(success.owned.size,0);
 for(const fault of ['short','read','range','cancel']){
  const h=harness(), session=await h.bridge.openSource(h.input);h.setFault(fault);
  await assert.rejects(h.command(session.session),fault==='cancel'?{code:'CIRCUIT_CANCELLED'}:/Truncated circuit input|source read failed|range/);
  assert.equal(h.counts.supplies,0);assert.equal(h.counts.results,0);assert.equal(h.counts.cancels,1);
  h.setFault('');const recovered=await h.command(session.session);assert.equal(recovered.records.length,16);
  await h.bridge.close(session.session);assert.equal(h.owned.size,0);assert.equal(h.counts.closes,1);
 }
 console.log('PASS: one-byte viewport validation READ, result copy before ACK, source read/short/range/cancel failures, recovery and exact host frees');
})().catch(error=>{console.error(error);process.exitCode=1;});
