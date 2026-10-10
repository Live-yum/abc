// Actual WASM, original source-behavior fixtures shared with native tests.
// Usage: node <this> world.js world.wasm <exported fixture directory>
'use strict';
const fs=require('node:fs'),path=require('node:path'),vm=require('node:vm');
const assert=require('node:assert/strict');
const {createWorldCircuitBridge}=require('../../web/terra_world_circuit.js');

(async()=>{
 const context=vm.createContext({console,WebAssembly,TextDecoder,TextEncoder,Uint8Array,ArrayBuffer,setTimeout,clearTimeout,URL,performance,window:{},document:{currentScript:{src:'http://localhost/world.js'}},location:{href:'http://localhost/'}});
 vm.runInContext(fs.readFileSync(process.argv[2],'utf8'),context);
 const bridge=createWorldCircuitBridge(()=>context.TerraWorldWasmWeb({wasmBinary:fs.readFileSync(process.argv[3])}));
 const directory=process.argv[4],cases=JSON.parse(fs.readFileSync(path.join(directory,'cases.json'),'utf8'));
 let id;
 const command=(kind,fields={},points=[])=>{
  const words=[2,kind,...Array(14).fill(0)],indexes={x:2,y:3,width:4,height:5,stride:6,mask:7,count:8,source:11,flags:12};
  for(const [key,value] of Object.entries(fields))words[indexes[key]]=value;
  words[10]=points.length;
  return bridge.command(id,JSON.stringify(words),JSON.stringify(points.flat()));
 };
 const view=async(x,y,width,height)=>{
  const result=await command(1,{x,y,width,height,stride:1});
  const bytes=result.records,d=new DataView(bytes.buffer,bytes.byteOffset,bytes.byteLength),rows=[];
  for(let at=0;at<bytes.byteLength;at+=16)rows.push([0,4,8,12].map(offset=>d.getUint32(at+offset,true)));
  return rows;
 };
 const frames=async(c,expected)=>{
  const rows=await view(6,10,1,c.height);
  assert.deepEqual(rows.map(r=>r[3]&65535),Array(c.height).fill(expected));
  assert.deepEqual(rows.map(r=>r[3]>>>16),Array.from({length:c.height},(_,r)=>(c.style*c.height+r)*18));
  if(c.actuator){assert.ok(rows.every(r=>r[2]&(1<<17)));assert.ok(rows.every(r=>!(r[2]&(1<<18))));}
  return rows;
 };
 const pulse=(fields={})=>command(2,{x:3,y:10,width:1,height:1,mask:1,count:1,...fields});
 let executed=0;
 for(const c of cases)for(const optimized of [0,1]){
  const source=fs.readFileSync(path.join(directory,c.file));
  id=(await bridge.open(source)).session;
  await command(10,{mask:optimized});
  if(c.scenario==='ordinary'){
   await frames(c,0);await pulse();await frames(c,18);
   await pulse({mask:3});await frames(c,18);
   await pulse({mask:4});await frames(c,0);
   await pulse({mask:8});await frames(c,18);
   await pulse({mask:15});await frames(c,18);
   await pulse({count:2});await frames(c,18);
   await pulse({x:6,height:c.height});await frames(c,18);
   await pulse({x:6});await frames(c,0);
   await pulse();const expected=await frames(c,18);
   const saved=await command(6,{source:3});await bridge.close(id);
   id=(await bridge.open(saved.world)).session;
   assert.deepEqual(await frames(c,18),expected);
   await pulse();await frames(c,0);
  }else if(c.scenario==='part'){
   await frames(c,18);await pulse({y:10+c.row});await frames(c,0);
  }else if(c.scenario==='disconnected'){
   await pulse({height:3});await frames(c,18);
  }else{
   const before=await view(3,10,7,c.height);
   await assert.rejects(()=>pulse());
   assert.deepEqual(await view(3,10,7,c.height),before);
   await command(3,{count:1});await command(6,{source:3});
  }
  await bridge.close(id);executed++;
 }
 console.log(`PASS: actual Web WASM wired lights, ${executed} cases across OFF/ON; member routing, colour/footprint skip, save/reopen and malformed rollback`);
})().catch(error=>{console.error(error);process.exitCode=1;});
