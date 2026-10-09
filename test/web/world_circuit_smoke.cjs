// Actual engine test. Arguments: authorized world.js world.wasm synthetic.wld.
const fs=require('node:fs'),assert=require('node:assert/strict'),vm=require('node:vm');
const {createWorldCircuitBridge}=require('../../web/terra_world_circuit.js');
(async()=>{
 const context=vm.createContext({console,WebAssembly,TextDecoder,TextEncoder,Uint8Array,ArrayBuffer,setTimeout,clearTimeout,URL,performance,window:{},document:{currentScript:{src:'http://localhost/world.js'}},location:{href:'http://localhost/'}});
 vm.runInContext(fs.readFileSync(process.argv[2],'utf8'),context);
 const bridge=createWorldCircuitBridge(()=>context.TerraWorldWasmWeb({wasmBinary:fs.readFileSync(process.argv[3])}));
 const source=fs.readFileSync(process.argv[4]);let r=await bridge.open(source,null),id=r.session;
 const cmd=(kind,x=0,y=0,w=0,h=0,count=0,flags=0)=>bridge.command(id,JSON.stringify([1,kind,x,y,w,h,1,1,count,0,0,kind===6?3:0,flags,kind===6?5:0,0,0]),'[]');
 const frame=async()=>{const r=await cmd(1,3,10,1,1);return new DataView(r.records.buffer,r.records.byteOffset).getUint32(12,true)&65535;};
 assert.equal(await frame(),0);await cmd(2,2,10,1,1,1,1);await cmd(3,0,0,0,0,59);assert.equal(await frame(),0);await cmd(3,0,0,0,0,1);assert.equal(await frame(),66);
 const saved=await cmd(6);await bridge.close(id);r=await bridge.open(saved.world,null);id=r.session;assert.equal(await frame(),66);await bridge.close(id);
 await assert.rejects(()=>bridge.open(new Uint8Array([1,2,3]),null));r=await bridge.open(source,null);await bridge.close(r.session);
 console.log('PASS: actual Web WASM whole-world timer at60ticks, save, independent reopen');
})().catch(e=>{console.error(e);process.exitCode=1;});
