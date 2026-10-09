// Actual release WASM and attributed rules. Inputs never leave this process.
import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import assert from 'node:assert/strict';
import {createRequire} from 'node:module';
import {createHash} from 'node:crypto';
import {Measurements} from './metrics.mjs';
const require = createRequire(import.meta.url);
const {createBridge} = require('../../web/terra_engine.js');
const {createRegionBridge} = require('../../web/terra_region.js');
const {createCircuitBridge} = require('../../web/terra_circuit.js');
const {createWorldCircuitBridge} = require('../../web/terra_world_circuit.js');
const bench = new Measurements('wasm-actions');
const output = process.env.ABC_PERF_REPORT || 'build/performance/wasm-actions.json';
bench.journal(output);
const modules = new Map();
async function load(key, kind = 'wld') {
  if (!modules.has(key)) {
    const file = path.resolve(process.env[kind === 'wld' ? 'TERRA_WORLD_RUNTIME' : 'TERRA_PLAYER_RUNTIME'] || `web/engine/${kind === 'wld' ? 'world' : 'player'}.js`);
    const binary=fs.readFileSync(file.replace(/\.js$/, '.wasm'));
    const module = await require(file)({wasmBinary: binary});
    if(!bench.report.toolchain.artifacts.some(x=>x.id===`${kind}-wasm`))bench.report.toolchain.artifacts.push({id:`${kind}-wasm`,bytes:binary.length,sha256:createHash('sha256').update(binary).digest('hex'),loaderSha256:createHash('sha256').update(fs.readFileSync(file)).digest('hex')});
    modules.set(key, module); bench.modules.push(module);
  }
  return modules.get(key);
}
const engine = createBridge(kind => load(`document-${kind}`, kind));
const region = createRegionBridge(() => load('region'));
const circuit = createCircuitBridge(() => load('traversal'));
const tcw = createWorldCircuitBridge(() => load('tcw'));
const read = p => new Uint8Array(fs.readFileSync(p));
const source = read('assets/qa/synthetic-circuit.wld');
const objects = read('assets/qa/synthetic-objects.wld');
const fixtures = [{id: 'synthetic-circuit', kind: 'wld', bytes: source}, {id: 'synthetic-objects', kind: 'wld', bytes: objects}];
if(process.env.ABC_PERF_SYNTHETIC_WORLD) fixtures.push({id:'synthetic-scaled-world',kind:'wld',bytes:read(process.env.ABC_PERF_SYNTHETIC_WORLD)});
for (const [env, id, kind] of [['ABC_PERF_WORLD', 'private-world-1', 'wld'], ['ABC_PERF_WORLD2', 'private-world-2', 'wld'], ['ABC_PERF_PLAYER', 'private-player-1', 'plr']]) {
  if (process.env[env]) {
    if (bench.tier === 'ci') throw new Error('Private fixtures require local or soak tier');
    fixtures.push({id, kind, bytes: read(process.env[env]), provenance: 'user-provided-local-only'});
  }
}
const measure = (id, f, fn) => bench.measure(id, f.id, f.bytes.length, fn);
const own = (prefix, id) => bench.owners.add(`${prefix}:${id}`);
const release = (prefix, id) => bench.owners.delete(`${prefix}:${id}`);
async function open(f, id = `${f.kind}.open`) {
  const doc = JSON.parse(await measure(id, f, () => engine.open(f.bytes, f.kind)));
  own(f.kind, doc.handle); return doc;
}
async function close(doc, f) { await measure(`${f.kind}.close`, f, () => engine.close(doc.handle)); release(f.kind, doc.handle); }
async function documentCycle(f) {
  let doc = await open(f);
  try {
    const before = JSON.parse(await measure(`${f.kind}.inspect`, f, () => engine.inspect(doc.handle)));
    const fixtureInfo=bench.report.fixtures.find(x=>x.id===f.id);
    if(fixtureInfo) Object.assign(fixtureInfo,f.kind==='wld'?{formatVersion:before.format.version,width:before.header.maxTilesX,height:before.header.maxTilesY}:{formatVersion:before.version});
    assert.deepEqual(await measure(`${f.kind}.untouched-export`, f, () => engine.save(doc.handle)), f.bytes);
    if (f.kind === 'wld') {
      const png = await measure('wld.preview', f, () => engine.preview(doc.handle));
      assert.deepEqual(Array.from(png.slice(0,8)), [137,80,78,71,13,10,26,10]);
      await measure('wld.header-edit', f, () => engine.mutate(doc.handle, 'header_patch', JSON.stringify({patch: {worldName: 'Benchmark fixture'}})));
      assert.equal(JSON.parse(await engine.inspect(doc.handle)).header.worldName, 'Benchmark fixture');
      if (before.chests?.length) {
        const chests = structuredClone(before.chests); chests[0].name = 'Benchmark chest';
        await measure('wld.chest-edit', f, () => engine.mutate(doc.handle, 'replace_chests', JSON.stringify({chests})));
        assert.equal(JSON.parse(await engine.inspect(doc.handle)).chests[0].name, 'Benchmark chest');
      }
      if (before.format.version >= 210 && before.bestiary && Object.hasOwn(before.bestiary, 'kills')) {
        const bestiary = structuredClone(before.bestiary);
        bestiary.kills = [...bestiary.kills.filter(x => x.persistentNpcId !== 'abc-benchmark'), {persistentNpcId: 'abc-benchmark', killCount: 7}];
        await measure('wld.bestiary-edit', f, () => engine.mutate(doc.handle, 'replace_bestiary', JSON.stringify(bestiary)));
        assert.ok(JSON.parse(await engine.inspect(doc.handle)).bestiary.kills.some(x => x.persistentNpcId === 'abc-benchmark' && x.killCount === 7));
      }
    } else {
      await measure('plr.attribute-edit', f, () => engine.mutate(doc.handle, 'player_patch', JSON.stringify({patch: {statLife: 120, statLifeMax: 120}})));
      const inventory = structuredClone(before.inventory); inventory[0] = {...inventory[0], itemType: 8, stack: 50, prefix: 0};
      await measure('plr.inventory-edit', f, () => engine.mutate(doc.handle, 'player_patch', JSON.stringify({patch: {inventory}})));
      const after = JSON.parse(await engine.inspect(doc.handle)); assert.equal(after.statLife, 120); assert.equal(after.inventory[0].stack, 50);
    }
    await measure(`${f.kind}.reject-mutation`, f, () => assert.rejects(() => engine.mutate(doc.handle, 'unknown_operation', '{}')));
    const exported = await measure(`${f.kind}.export`, f, () => engine.save(doc.handle));
    await close(doc, f); doc = null;
    doc = await open({...f, bytes: exported}, `${f.kind}.reopen`);
    const after = JSON.parse(await engine.inspect(doc.handle));
    assert.equal(f.kind === 'wld' ? after.header.worldName : after.statLife, f.kind === 'wld' ? 'Benchmark fixture' : 120);
  } finally { if (doc) await close(doc, f); }
}
async function regionCycle() {
  const f = fixtures[0];
  const records = await measure('region.read', f, () => region.read(source, 1,2,2,3)); assert.equal(records.length,192);
  const view = new DataView(records.buffer, records.byteOffset, records.byteLength); view.setUint32(16,2,true);
  const candidate = await measure('region.replace', f, () => region.replace(source,1,2,2,3,records));
  assert.deepEqual(await region.read(candidate,1,2,2,3),records);
  const stamped = await measure('region.stamp', f, () => region.operation(source,'stamp_tiles',JSON.stringify({x:2,y:4,width:2,height:3,recordCount:6,recordSourceId:2,mode:'overlay'}),records,new Uint8Array()));
  assert.deepEqual(await region.read(stamped,2,4,2,3),records);
  const maps = new Uint8Array(24); maps[10]=3; maps[16]=1; maps[22]=1;
  const painted = await measure('pixel.write', f, () => region.pixel(source,2,3,2,2,maps,new Uint16Array([1,0,0,1])));
  assert.equal(new DataView((await region.read(painted,2,3,1,1)).buffer).getUint32(8,true)&65535,1);
  assert.deepEqual(await measure('pixel.match', f, () => region.match(new Uint32Array([0xfe0000,0x0000fe]),new Uint32Array([0xff0000,0x0000ff]),new Uint32Array([0,0]),0)),new Uint32Array([0,1]));
  const ruled = await measure('rules.batch-update', f, () => region.operation(source,'batch_update_tiles',JSON.stringify({rules:[{where:{type:1,wire_red:false},patch:{wall:2,wire_red:true},limit:1}]}),new Uint8Array(),new Uint8Array()));
  assert.equal(new DataView((await region.read(ruled,0,0,1,1)).buffer).getUint32(16,true)&65535,2);
  for (const mode of ['purify','corruption','crimson','hallow']) {
    const result=await measure(`rules.biome-${mode}`,f,()=>region.operation(source,'batch_update_tiles',JSON.stringify({biome_mode:mode}),new Uint8Array(),new Uint8Array()));
    assert.equal((await region.read(result,0,0,7,32)).length,224*32);
  }
  await measure('region.reject-recover',f,()=>assert.rejects(()=>region.replace(source,1,2,2,3,records.slice(0,32))));
  const o = fixtures[1], companion = await measure('region.objects',o,()=>region.objects(objects,1,2,8,3)); assert.ok(companion.length>32);
  const r = await region.read(objects,1,2,8,3);
  const pasted = await measure('region.stamp-objects',o,()=>region.operation(objects,'stamp_tiles',JSON.stringify({x:1,y:10,width:8,height:3,recordCount:24,recordSourceId:2,objectSourceId:3,objectCount:3,objectBytes:companion.length,mode:'overlay'}),r,companion));
  assert.deepEqual((await region.objects(pasted,1,10,8,3)).slice(32),companion.slice(32));
}
async function tcwCycle() {
  const f=fixtures[0]; let session;
  const command=(kind,x=0,y=0,w=0,h=0,count=0,flags=0)=>tcw.command(session,JSON.stringify([2,kind,x,y,w,h,1,1,count,0,0,kind===6?3:0,flags,0,0,0]),'[]');
  try {
    session=(await measure('tcw.open',f,()=>tcw.open(source))).session; own('tcw',session);
    const viewport=await measure('tcw.viewport',f,()=>command(1,3,10,1,1)); assert.equal(new DataView(viewport.records.buffer).getUint32(12,true)&65535,0);
    await measure('tcw.trigger',f,()=>command(2,2,10,1,1,1,1));
    await measure('tcw.tick60',f,()=>command(3,0,0,0,0,60));
    assert.equal(new DataView((await command(1,3,10,1,1)).records.buffer).getUint32(12,true)&65535,66);
    const saved=await measure('tcw.export',f,()=>command(6)); assert.ok(saved.world.length);
    await measure('tcw.close',f,()=>tcw.close(session)); release('tcw',session); session=null;
    session=(await measure('tcw.reopen',f,()=>tcw.open(saved.world))).session; own('tcw',session);
    assert.equal(new DataView((await command(1,3,10,1,1)).records.buffer).getUint32(12,true)&65535,66);
  } finally { if(session) {await tcw.close(session);release('tcw',session);} }
  await measure('tcw.reject-recover',f,()=>assert.rejects(()=>tcw.open(new Uint8Array([1,2,3]))));
  const cells=[];for(let x=1;x<=5;x++)cells.push(x,2,15,x===1||x===5?1:0);
  for(let color=0;color<4;color++) assert.deepEqual((await measure(`circuit.traverse-${color}`,f,()=>circuit.propagateRaw(8,8,cells,1,2,color))).sort((a,b)=>a-b),[17,18,19,20,21]);
}
async function largeWorldCycle(f) {
  // Host input, region and VM budgets bound this workload. Source bytes stay
  // immutable; exported candidates are held only for independent readback.
  const records=await measure('region.read-large-world',f,()=>region.read(f.bytes,0,0,32,32));assert.equal(records.length,32*32*32);
  const modified=records.slice(),d=new DataView(modified.buffer);const wall=(d.getUint32(16,true)&65535)===2?3:2;
  d.setUint32(16,(d.getUint32(16,true)&0xffff0000)|wall,true);
  const candidate=await measure('region.replace-large-world',f,()=>region.replace(f.bytes,0,0,32,32,modified));
  assert.deepEqual(await region.read(candidate,0,0,32,32),modified);
  const ruled=await measure('rules.batch-update-large-world',f,()=>region.operation(f.bytes,'batch_update_tiles',JSON.stringify({rules:[{where:{type:1,wire_red:false},patch:{wall:2,wire_red:true},limit:1}]}),new Uint8Array(),new Uint8Array()));
  assert.ok(ruled.length);assert.notDeepEqual(ruled,f.bytes);
  let session;
  const command=(kind,x=0,y=0,w=0,h=0,count=0,flags=0)=>tcw.command(session,JSON.stringify([2,kind,x,y,w,h,1,1,count,0,0,kind===6?3:0,flags,0,0,0]),'[]');
  try {
    const opened=await measure('tcw.open-large-world',f,()=>tcw.open(f.bytes));session=opened.session;own('tcw',session);
    assert.ok(opened.stats[2]>=32&&opened.stats[3]>=32);
    await measure('tcw.viewport-large-world',f,()=>command(1,0,0,32,32));
    await measure('tcw.trigger-large-world',f,()=>command(2,0,0,32,32,1,1));
    const tick=await measure('tcw.tick60-large-world',f,()=>command(3,0,0,0,0,60));assert.equal(tick.stats[18],60);
    const saved=await measure('tcw.export-large-world',f,()=>command(6));assert.ok(saved.world.length);
    await measure('tcw.close-large-world',f,()=>tcw.close(session));release('tcw',session);session=null;
    session=(await measure('tcw.reopen-large-world',f,()=>tcw.open(saved.world))).session;own('tcw',session);
  } finally {if(session){await tcw.close(session);release('tcw',session);}}
}
let rules;
async function rulesCycle() {
  if(!rules) {const scope=vm.createContext({});vm.runInContext(fs.readFileSync('web/engine/circuit_rules_web.js','utf8'),scope);rules=scope.createTerraCircuitRules(await load('rules'));}
  const fixture={id:'synthetic-circuit-rules',bytes:new Uint8Array()};
  const invoke=(id,method,args=[])=>measure(`circuit.${id}`,fixture,()=>rules.invoke(method,args));
  const edit=(id,method,args=[])=>invoke(id,'editor.command',[{method,args}]);
  const caps=rules.invoke('capabilities',[]);assert.equal(caps.sourceCommit,'366ebc57751cadfb077f968f4d5069028b3bf9a6');
  try {
    await invoke('load','editor.new',['Benchmark']); own('rules',1);
    await edit('paint','paint',[{x:1,y:3},{x:8,y:3},{tool:'wire',mask:15}]);
    await edit('place','placeTile',[{kind:'switch',x:1,y:3}]);await edit('place','placeTile',[{kind:'gemspark',x:8,y:3}]);
    await edit('select','select',[{x:1,y:3,width:8,height:1}]);await edit('copy','copy');await edit('paste','paste',[{x:1,y:8}]);
    await edit('undo','undo');await edit('redo','redo');await edit('rotate','transformClipboard',['rotate']);
    await edit('route','previewRoute',[{x:1,y:12},{x:8,y:12},1,'benchmark-route']);
    await edit('route-confirm','commitPreview',['benchmark-route']);
    const saved=rules.invoke('editor.snapshot',[]).document;
    const interaction=await invoke('trigger','simulation.command',[{method:'interact',args:[1,3],debug:true}]);
    assert.equal(interaction.packet.native.fallback,false);assert.ok(interaction.packet.native.commandVisits>0);
    const tick=await invoke('tick','simulation.command',[{method:'step',args:[1],debug:true}]);assert.equal(tick.packet.tick,1);
    const run=await invoke('run60','simulation.command',[{method:'step',args:[60],debug:true}]);assert.equal(run.packet.tick,61);
    assert.equal((await invoke('reset','simulation.reset')).document,saved);
    await invoke('reopen','editor.open',[saved]);assert.equal(rules.invoke('editor.snapshot',[]).document,saved);
    await measure('circuit.reject-command',fixture,async()=>assert.throws(()=>rules.invoke('simulation.command',[{method:'step',args:[61]}])));
  } finally {await invoke('close','editor.close');release('rules',1);}
  // Includes the large retained register topology. Every demo uses real WASM
  // traversal. Source-document content and coordinates never enter reports.
  for(const demo of caps.demos) {
    const f={id:`source-demo-${demo}`,bytes:{length:0}};
    let loaded;
    try {
      loaded=await measure('circuit.demo-load',f,()=>rules.invoke('editor.demo',[demo]));own('rules',1);
      const raw=JSON.parse(loaded.document),wires=raw.world.wires,first=wires[0]||[0,0];
      f.bytes={length:Buffer.byteLength(loaded.document)};
      for(const row of bench.rows.values())if(row.id==='circuit.demo-load'&&row.fixture===f.id)row.bytesPerOperation=f.bytes.length;
      if(!bench.report.fixtures.some(x=>x.id===f.id))bench.report.fixtures.push({id:f.id,kind:'circuit',provenance:'attributed-source-demo',bytes:f.bytes.length,sha256:createHash('sha256').update(loaded.document).digest('hex'),width:raw.world.width,height:raw.world.height,wireCells:wires.length,tiles:raw.world.tiles.length});
      const trigger=await measure('circuit.demo-trigger',f,()=>rules.invoke('simulation.command',[{method:'trigger',args:[[{x:first[0],y:first[1]}],15],debug:true}]));
      assert.equal(trigger.packet.native.fallback,false);if(wires.length)assert.ok(trigger.packet.native.commandVisits>0);
      const run=await measure('circuit.demo-run60',f,()=>rules.invoke('simulation.command',[{method:'step',args:[60],debug:true}]));assert.equal(run.packet.tick,60);
      assert.equal((await measure('circuit.demo-reset',f,()=>rules.invoke('simulation.reset',[]))).document,loaded.document);
      await measure('circuit.demo-reopen',f,()=>rules.invoke('editor.open',[loaded.document]));assert.equal(rules.invoke('editor.snapshot',[]).document,loaded.document);
    } finally {await measure('circuit.demo-close',f,()=>rules.invoke('editor.close',[]));release('rules',1);}
  }
}
try {
  const fresh=JSON.parse(await engine.createPlayer('Benchmark synthetic'));own('plr',fresh.handle);
  fixtures.push({id:'synthetic-player-v326',kind:'plr',bytes:await engine.save(fresh.handle)});
  await engine.close(fresh.handle);release('plr',fresh.handle);
  fixtures.forEach(f=>bench.fixture(f.id,f.kind,f.bytes,f.provenance));
  bench.fixture('synthetic-circuit-rules','circuit',new Uint8Array());
  bench.report.gaps.push('MAP coverage is supplied by the separate MAP format report.', 'This Node suite does not measure browser frames, mobile memory pressure, or native live allocations.', 'Input fixtures are loaded before timing: OS file-picker interaction and source-disk reads are excluded.', 'Vault/resource storage and Workspace undo/redo are measured by the native action suite.');
  if(!process.env.ABC_PERF_PLAYER)bench.report.gaps.push('No real PLR supplied: PLR codec measurements use a generated synthetic v326 player.');
  bench.memory('baseline');
  bench.write(output,'running');
  for(bench.cycle=-1;bench.cycle<bench.warmup+bench.cycles;bench.cycle++) {
    // Alternating document identities exercises actual close/open ownership on every cycle.
    for(const fixture of (bench.cycle%2?fixtures:[...fixtures].reverse()))await documentCycle(fixture);
    await regionCycle();await tcwCycle();
    for(const f of fixtures.filter(f=>f.kind==='wld'&&(f.provenance||f.id==='synthetic-scaled-world')))await largeWorldCycle(f);
    await rulesCycle();await bench.afterClose();bench.write(output,'running');
  }
  if(rules)rules.invoke('dispose',[]);
  bench.write(output);console.log(`PASS wasm-actions: ${bench.report.operations.length} operation rows; ${bench.cycles} measured cycles; ${output}`);
} catch(error) {bench.write(output,'failed');console.error(`FAIL wasm-actions at ${bench.report.failure?.operation || 'setup'} (${error.name})`);process.exitCode=1;}
