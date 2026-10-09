// Opt-in integration test: private artifacts and user saves stay outside this repo.
// TERRA_REFERENCE_ROOT=/path/to/reference TERRA_WLD_FIXTURE=/path/world.wld
// TERRA_PLR_FIXTURE=/path/player.plr node tool/test_web_engine.mjs
import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import {createRequire} from 'node:module';
import assert from 'node:assert/strict';
const require=createRequire(import.meta.url);
const sandbox={module:{exports:{}},TextEncoder,TextDecoder,Uint8Array,DataView,setTimeout,console};
vm.runInNewContext(fs.readFileSync(new URL('../web/terra_engine.js',import.meta.url),'utf8'),sandbox);
const {createBridge,parse}=sandbox.module.exports;
const logical = value => value.format?.positions
  ? {...value, format: {...value.format, positions: value.format.positions.map(() => 0)}}
  : value;
assert.equal(parse('{"id":9223372036854775807}').id,'9223372036854775807');
const unavailable=createBridge(async()=>{throw new Error('Missing verified engine');});
await assert.rejects(()=>unavailable.open(new Uint8Array(), 'wld'));
await assert.rejects(()=>unavailable.open(new Uint8Array([1]), 'wld'),/Missing verified engine/);
await assert.rejects(()=>unavailable.open(new Uint8Array([1]), 'unknown'));
await assert.rejects(()=>unavailable.inspect(1));
const root=process.env.TERRA_REFERENCE_ROOT;
const worldRuntime=process.env.TERRA_WORLD_RUNTIME,playerRuntime=process.env.TERRA_PLAYER_RUNTIME;
if(!root && !(worldRuntime && playerRuntime)) { console.log('Precision unit check passed; set TERRA_REFERENCE_ROOT and fixture paths for real integration tests.'); process.exit(0); }
const bridge=createBridge(async kind=>{
  const file=(kind==='wld'?worldRuntime:playerRuntime) ?? path.join(root,kind==='wld' ? 'infrastructure/wasm/generated/terrax_world_wasm_web.js' : 'features/player-editor/pages/runtime/terra_player_web.js');
  const factory=require(file);
  return factory({wasmBinary:fs.readFileSync(file.replace(/\.js$/,'.wasm'))});
});
for(const kind of ['plr','wld']) {
  const fixture=process.env[kind==='wld' ? 'TERRA_WLD_FIXTURE' : 'TERRA_PLR_FIXTURE'];
  if(!fixture) continue;
  const original=new Uint8Array(fs.readFileSync(fixture)), doc=JSON.parse(await bridge.open(original,kind));
  const before=JSON.parse(await bridge.inspect(doc.handle));
  assert.deepEqual(await bridge.save(doc.handle),original,'Untouched export is byte-identical');
  const patch=kind==='wld' ? {worldName:'TerraForge local verification'} : {name:'TerraForge test',statLife:120,statLifeMax:120,inventory:before.inventory.map((item,i)=>i===0 ? {...item,itemType:8,stack:50,prefix:0} : item)};
  await bridge.mutate(doc.handle,kind==='wld' ? 'header_patch' : 'player_patch',JSON.stringify({patch}));
  const after=JSON.parse(await bridge.inspect(doc.handle));
  assert.equal(kind==='wld' ? after.header.worldName : after.name,Object.values(patch)[0]);
  const exported=await bridge.save(doc.handle);
  assert.deepEqual(logical(JSON.parse(await bridge.inspect(doc.handle))),logical(after),'Export roundtrip preserves logical document and section count');
  await assert.rejects(()=>bridge.mutate(doc.handle,'unknown_operation','{}'));
  await assert.rejects(()=>bridge.mutate(doc.handle,kind==='wld' ? 'header_patch' : 'player_patch',JSON.stringify({patch:kind==='wld' ? {worldName:123} : {statLife:'invalid'}})));
  assert.deepEqual(original,new Uint8Array(fs.readFileSync(fixture)),'Input save remains untouched');
  assert.deepEqual(logical(JSON.parse(await bridge.inspect(doc.handle))),logical(after),'Rejected mutation preserves state');
  if(kind==='wld') {
    const png=await bridge.preview(doc.handle);
    assert.deepEqual(Array.from(png.slice(0,8)),[137,80,78,71,13,10,26,10]);
  }
  await bridge.close(doc.handle);
  await assert.rejects(()=>bridge.inspect(doc.handle));
  assert.equal(before.version ?? before.format.version,after.version ?? after.format.version);
  console.log(kind+': decode, original preservation, edit, export, read-back, rollback, close'+(kind==='wld' ? ', thumbnail' : '')+' passed');
}

const fresh=JSON.parse(await bridge.createPlayer('TerraForge new'));
assert.equal(JSON.parse(await bridge.inspect(fresh.handle)).name,'TerraForge new');
assert.ok((await bridge.save(fresh.handle)).length>0);
const sourceBytes=await bridge.save(fresh.handle), sourceModel=JSON.parse(await bridge.inspect(fresh.handle));
for(const version of [38,135,218,279,326]) {
  const candidate=JSON.parse(JSON.stringify(sourceModel));
  candidate.version=version;
  const count=version<164?0:version<167?8:version<197?10:version<230?11:12;
  candidate.tailLayout={builderAccStatusCount:count,includesDeathMetadata:version>=200};
  candidate.builderAccStatus=Array(count||12).fill(0);
  const bytes=await bridge.projectPlayer(JSON.stringify(candidate));
  const projected=JSON.parse(await bridge.open(bytes,'plr'));
  try {
    assert.equal(JSON.parse(await bridge.inspect(projected.handle)).version,version);
    assert.deepEqual(await bridge.save(projected.handle),bytes);
  } finally { await bridge.close(projected.handle); }
  assert.deepEqual(await bridge.save(fresh.handle),sourceBytes);
}
await assert.rejects(()=>bridge.projectPlayer('{"version":326}'));
await assert.rejects(()=>bridge.mutate(fresh.handle,'player_patch',JSON.stringify({patch:{version:279}})));
assert.deepEqual(await bridge.save(fresh.handle),sourceBytes);
await bridge.close(fresh.handle);
console.log('New player and detached version projections, source preservation, generic version block passed');
