// Actual WASM browser worker bootstrap, executed with Node worker_threads.
// Host event-loop samples are not browser FPS or device UI measurements.
'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const {execFileSync} = require('node:child_process');
const {createClient} = require('../../web/terra_worker_rpc.js');
const {workerFactory} = require('./helpers/engine_worker_host.cjs');
const root = path.resolve(__dirname,'../..');
const hash = bytes => crypto.createHash('sha256').update(bytes).digest('hex');
const world = new Uint8Array(fs.readFileSync(path.join(root,'assets/qa/synthetic-objects.wld')));
const circuit = new Uint8Array(fs.readFileSync(path.join(root,'assets/qa/synthetic-circuit.wld')));
const originalHash = hash(world), circuitHash = hash(circuit), metrics=[];
let measuredCycle = 0;
function git(args) { try { return execFileSync('git',args,{cwd:root,encoding:'utf8',stdio:['ignore','pipe','ignore']}).trim(); } catch (_) { return null; } }
function provenance() {
  const commit=git(['rev-parse','HEAD']), status=git(['status','--porcelain','--untracked-files=normal']);
  const files=['web/engine/world.js','web/engine/world.wasm','web/engine/player.js','web/engine/player.wasm','web/terra_worker_rpc.js','web/terra_engine_worker.js','web/terra_engine.js','web/terra_world_circuit.js','web/terra_circuit.js'];
  return {
    source:{commit:process.env.ABC_PERF_COMMIT||commit||'unknown',worktreeCommit:commit||'unknown',dirty:status===null?'unknown':status.length>0,commitSource:process.env.ABC_PERF_COMMIT?'ABC_PERF_COMMIT':commit?'git':'unknown'},
    runtime:{node:process.versions.node,v8:process.versions.v8,platform:process.platform,arch:process.arch},
    artifacts:files.map(file=>{const content=fs.readFileSync(path.join(root,file));return {path:file,bytes:content.length,sha256:hash(content)};}),
  };
}
async function sample(action, run) {
  const gaps=[]; let previous=performance.now();
  const start=previous, timer=setInterval(()=>{const now=performance.now();gaps.push(now-previous);previous=now;},4);
  try { return await run(); }
  finally {
    clearInterval(timer);
    const completionGap=performance.now()-previous;
    // Include a delayed final tick, but do not count a sub-period completion as
    // an event-loop sample. Fast operations have no responsiveness sample.
    if(completionGap>=4)gaps.push(completionGap);
    const sorted=[...gaps].sort((a,b)=>a-b);
    metrics.push({action,cycle:measuredCycle,phase:measuredCycle===0?'cold':'warm',wall_ms:+(performance.now()-start).toFixed(3),host_event_loop_gap_p95_ms:sorted.length?+sorted[Math.ceil(sorted.length*.95)-1].toFixed(3):null,host_event_loop_gap_max_ms:sorted.length?+sorted.at(-1).toFixed(3):null,host_samples:gaps.length,host_event_loop_samples_ms:gaps.map(n=>+n.toFixed(3))});
  }
}
function direct(owner) {
  const factory=workerFactory({direct:true}), worker=factory.createWorker(owner), pending=new Map();let next=0;
  worker.onmessage=({data})=>{const p=pending.get(data.id);pending.delete(data.id);data.ok?p.resolve(data.value):p.reject(new Error(data.error));};
  worker.onerror=error=>{for(const p of pending.values())p.reject(error);pending.clear();};
  const bridge=new Proxy({}, {get:(_,method)=>(...args)=>new Promise((resolve,reject)=>{const id=++next;pending.set(id,{resolve,reject});worker.postMessage({id,method,args});})});
  return {bridge,close:async()=>{await worker.terminate();await Promise.all(factory.exits);}};
}
async function documentWork(bridge, benchmark=false) {
  const run=(name,fn)=>benchmark?sample(name,fn):fn();
  const opened=JSON.parse(await run('document.world.open',()=>bridge.open(world,'wld'))), id=opened.handle;
  const initial=await run('document.world.save.unchanged',()=>bridge.save(id));assert.equal(hash(initial),originalHash);
  await run('document.world.mutate',()=>bridge.mutate(id,'header_patch',JSON.stringify({patch:{worldName:opened.metadata.header.worldName+' worker',time:12.5}})));
  const metadata=JSON.parse(await run('document.world.inspect',()=>bridge.inspect(id)));assert.equal(metadata.header.time,12.5);
  const saved=await run('document.world.save.changed',()=>bridge.save(id));
  const preview=await run('document.world.preview',()=>bridge.preview(id));assert.deepEqual([...preview.slice(0,8)],[137,80,78,71,13,10,26,10]);
  const map=await run('document.world.generateMap',()=>bridge.generateMap(id,'null'));
  assert(map.length>32); assert.equal(new DataView(map.buffer,map.byteOffset).getUint32(0,true),33083);
  const marked=await run('document.world.generateMap.marked',()=>bridge.generateMap(id,'{"chest_markers":[{"item_id":8,"color":"#FF0000","radius":2}],"tile_markers":[]}'));
  await run('document.world.rejectMutation',()=>assert.rejects(bridge.mutate(id,'header_patch','{"patch":{"worldName":123}}')));
  await run('document.world.rejectMap',()=>assert.rejects(bridge.generateMap(id,'{"unexpected":true}')));
  assert.equal(hash(await bridge.save(id)),hash(saved));
  await run('document.world.close',()=>bridge.close(id));
  const reopened=JSON.parse(await bridge.open(saved,'wld'));assert.equal(reopened.metadata.header.time,12.5);await bridge.close(reopened.handle);
  const created=JSON.parse(await run('document.player.create',()=>bridge.createPlayer('Worker synthetic')));
  await run('document.player.mutate',()=>bridge.mutate(created.handle,'player_patch','{"patch":{"statLife":90}}'));
  const player=await run('document.player.save',()=>bridge.save(created.handle));
  const playerMetadata=JSON.parse(await bridge.inspect(created.handle));
  const projected=await run('document.player.project',()=>bridge.projectPlayer(JSON.stringify(playerMetadata)));
  await bridge.close(created.handle);
  const playerOpen=JSON.parse(await run('document.player.open',()=>bridge.open(player,'plr')));assert.equal(playerOpen.metadata.statLife,90);await bridge.close(playerOpen.handle);
  assert.equal(hash(world),originalHash);
  return {metadata,saved:hash(saved),preview:hash(preview),map:hash(map),marked:hash(marked),player:hash(player),projected:hash(projected)};
}
async function circuitWork(bridge, benchmark=false) {
  const run=(name,fn)=>benchmark?sample(name,fn):fn();
  let opened=await run('worldCircuit.open',()=>bridge.open(circuit)), id=opened.session;
  const cmd=(kind,x=0,y=0,w=0,h=0,count=0,flags=0)=>bridge.command(id,JSON.stringify([2,kind,x,y,w,h,1,1,count,0,0,kind===6?3:0,flags,0,0,0]),'[]');
  const frame=async()=>{const r=await cmd(1,3,10,1,1);return new DataView(r.records.buffer,r.records.byteOffset).getUint32(12,true)&65535;};
  assert.equal(await frame(),0);
  await run('worldCircuit.trigger',()=>cmd(2,2,10,1,1,1,1));
  await run('worldCircuit.tick',()=>cmd(3,0,0,0,0,60));assert.equal(await frame(),66);
  const saved=await run('worldCircuit.save',()=>cmd(6));await bridge.close(id);
  opened=await bridge.open(saved.world);id=opened.session;assert.equal(await frame(),66);await bridge.close(id);
  assert.equal(hash(circuit),circuitHash);return {world:hash(saved.world),stats:saved.stats};
}
(async()=>{
  // Baselines terminate before RPC owners start, bounding peak engine memory.
  const baselineDocument=direct('document');let expectedDoc;
  try {expectedDoc=await documentWork(baselineDocument.bridge);}finally{await baselineDocument.close();}
  const documentFactory=workerFactory(), documents=createClient('document',documentFactory);
  try {
    for(measuredCycle=0;measuredCycle<3;measuredCycle++) assert.deepEqual(await documentWork(documents,true),expectedDoc,'Worker output must equal the exported direct bridge');
    const old=JSON.parse(await documents.open(world,'wld')).handle;
    const pending=documents.generateMap(old,'null');const rejected=assert.rejects(pending,{code:'COMPUTATION_OWNER_LOST'});
    // Terminate the actual thread externally while a request is pending.
    await documentFactory.threads.at(-1).terminate();await rejected;
    await assert.rejects(documents.inspect(old),{code:'STALE_HANDLE'});
    await documents.close(old);
    const fresh=JSON.parse(await documents.open(world,'wld')).handle;assert.notEqual(fresh,old);
    assert.equal(hash(await documents.save(fresh)),originalHash);await documents.close(fresh);
  }finally{await documents.dispose();await Promise.all(documentFactory.exits);}
  const baselineCircuit=direct('worldCircuit');let expectedCircuit;
  try {expectedCircuit=await circuitWork(baselineCircuit.bridge);}finally{await baselineCircuit.close();}
  const circuitFactory=workerFactory(), tcw=createClient('worldCircuit',circuitFactory);
  try {for(measuredCycle=0;measuredCycle<3;measuredCycle++) assert.deepEqual(await circuitWork(tcw,true),expectedCircuit);}finally{await tcw.dispose();await Promise.all(circuitFactory.exits);}
  const traversalFactory=workerFactory(), traversal=createClient('circuit',traversalFactory);
  try {
    const cells=[];for(let x=1;x<=5;x++)cells.push(x,2,15,x===1||x===5?1:0);
    for(measuredCycle=0;measuredCycle<3;measuredCycle++)for(let colour=0;colour<4;colour++)assert.deepEqual(JSON.parse(await sample('circuit.propagate.'+colour,()=>traversal.propagate(8,8,JSON.stringify(cells),1,2,colour))).sort((a,b)=>a-b),[17,18,19,20,21]);
    await assert.rejects(traversal.propagate(8,8,JSON.stringify([...cells,...cells]),1,2,0));
    assert.equal(JSON.parse(await traversal.propagate(8,8,JSON.stringify(cells),1,2,0)).length,5);
  }finally{await traversal.dispose();await Promise.all(traversalFactory.exits);}
  assert.equal(hash(world),originalHash);assert.equal(hash(circuit),circuitHash);
  assert.equal(hash(fs.readFileSync(path.join(root,'assets/qa/synthetic-objects.wld'))),originalHash);
  assert.equal(hash(fs.readFileSync(path.join(root,'assets/qa/synthetic-circuit.wld'))),circuitHash);
  const report={schema:'abc.worker-host-smoke.v1',...provenance(),measurement:'Node worker host event-loop responsiveness; not browser FPS',fixtures:[{id:'synthetic-objects',provenance:'original-synthetic',bytes:world.length,sha256:originalHash},{id:'synthetic-circuit',provenance:'original-synthetic',bytes:circuit.length,sha256:circuitHash},{id:'synthetic-player',provenance:'schema-generated'}],status:'passed',sourcePreserved:true,gaps:['Transport correctness and responsiveness smoke: one cold and two warm passes, not the full performance benchmark.','Node host event-loop gaps do not measure browser frames, Flutter UI smoothness, or physical devices.','Tiny original fixtures do not establish large-world throughput.'],metrics};
  if(process.env.TERRA_ENGINE_WORKER_REPORT){fs.mkdirSync(path.dirname(process.env.TERRA_ENGINE_WORKER_REPORT),{recursive:true});fs.writeFileSync(process.env.TERRA_ENGINE_WORKER_REPORT,JSON.stringify(report,null,2)+'\n');}
  console.log(JSON.stringify(report));
  console.log('PASS: actual worker WASM WLD/PLR/MAP/TCW/traversal, direct bridge parity, retained sources, real thread termination, stale handles, and explicit reopen');
})().catch(error=>{console.error(error);process.exitCode=1;});
