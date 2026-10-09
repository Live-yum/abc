// Generated geometry only; no private fixture is needed.
import fs from 'node:fs';
import {createRequire} from 'node:module';
import assert from 'node:assert/strict';
const require=createRequire(import.meta.url);
const {createCircuitBridge}=require('../web/terra_circuit.js');
const runtime=process.env.TERRA_WORLD_RUNTIME;
if(!runtime) throw new Error('Set TERRA_WORLD_RUNTIME to verified world JS runtime');
const factory=require(runtime);
const bridge=createCircuitBridge(()=>factory({wasmBinary:fs.readFileSync(runtime.replace(/\.js$/,'.wasm'))}));
const cells=[];for(let x=1;x<=5;x++)cells.push(x,2,15,x===1||x===5?1:0);
for(let c=0;c<4;c++)assert.deepEqual((await bridge.propagateRaw(8,8,cells,1,2,c)).sort((a,b)=>a-b),[17,18,19,20,21]);
const broken=cells.filter((_,i)=>Math.floor(i/4)!==2);
assert.deepEqual((await bridge.propagateRaw(8,8,broken,1,2,0)).sort((a,b)=>a-b),[17,18]);
await assert.rejects(()=>bridge.propagateRaw(8,8,[...cells,...cells],1,2,0));
assert.equal((await bridge.propagateRaw(8,8,cells,1,2,0)).length,5,'Failure frees engine handle');
console.log('Actual WASM four-colour traversal, disconnect, duplicate rejection and recovery passed');
