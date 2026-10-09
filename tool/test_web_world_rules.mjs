// Real WASM, original synthetic world: no private saves or preset tables copied.
import fs from 'node:fs';
import assert from 'node:assert/strict';
import {createRequire} from 'node:module';
const require=createRequire(import.meta.url),{createRegionBridge}=require('../web/terra_region.js');
const runtime=process.env.TERRA_WORLD_RUNTIME;
if(!runtime)throw new Error('Set TERRA_WORLD_RUNTIME');
const factory=require(runtime), bridge=createRegionBridge(()=>factory({wasmBinary:fs.readFileSync(runtime.replace(/\.js$/,'.wasm'))}));
const source=new Uint8Array(fs.readFileSync(new URL('../assets/qa/synthetic-circuit.wld',import.meta.url))),original=source.slice(),empty=new Uint8Array();
const run=request=>bridge.operation(source,'batch_update_tiles',JSON.stringify(request),empty,empty);
const changed=await run({rules:[{where:{type:1,wire_red:false},patch:{wall:2,wire_red:true},limit:1}]});
const records=await bridge.read(changed,0,0,7,32),view=new DataView(records.buffer,records.byteOffset,records.byteLength);
let count=0;for(let i=0;i<records.length;i+=32)if((view.getUint32(i+16,true)&65535)===2)count++;
assert.equal(count,1);assert.equal(view.getUint32(20,true)>>>24,1);
await assert.rejects(()=>run({rules:[{where:{type:'bad'},patch:{wall:2}}]}));
for(const mode of ['purify','corruption','crimson','hallow']) {
 const candidate=await run({biome_mode:mode});
 assert.equal((await bridge.read(candidate,0,0,7,32)).length,224*32);
}
assert.deepEqual(source,original);
assert.deepEqual(await run({rules:[{where:{type:1,wire_red:false},patch:{wall:2,wire_red:true},limit:1}]}),changed);
console.log('PASS: actual WASM full-world predicates, per-rule limit, four core biome presets, readback and error recovery');
