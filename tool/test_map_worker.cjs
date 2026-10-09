// Real worker_threads owner running the same Dart2JS/host pair as the browser.
const fs=require('node:fs'),path=require('node:path'),crypto=require('node:crypto'),assert=require('node:assert/strict');
const {Worker}=require('node:worker_threads');
const {createTerraMapClient}=require('../web/terra_map.js');
const {metadata}=require('./perf/map_report_metadata.cjs');
const input=process.env.TERRA_MAP_FIXTURE;
if(!input)throw new Error('Set TERRA_MAP_FIXTURE to a local generated or authorized MAP');
const compiled=path.resolve('web/engine/map_worker.js');
function spawn(){
  const owner=new Worker(path.join(__dirname,'perf/map_worker_node_owner.cjs'),{workerData:{compiled}});
  const wrapper={onmessage:null,onerror:null,onmessageerror:null,
    postMessage:(data,transfer)=>owner.postMessage(data,transfer),terminate:()=>owner.terminate()};
  owner.on('message',data=>wrapper.onmessage?.({data}));
  owner.on('error',error=>wrapper.onerror?.(error));return wrapper;
}
const client=createTerraMapClient({createWorker:spawn});
const source=new Uint8Array(fs.readFileSync(input)),hash=b=>crypto.createHash('sha256').update(b).digest('hex');
const digest=hash(source);
let token=0;
const call=async(method,args={},bytes=null)=>client.invoke(method,JSON.stringify({token,...args}),bytes);
(async()=>{
  let timerTicks=0;const intervals=[];let last=performance.now();
  const interval=setInterval(()=>{const now=performance.now();intervals.push(now-last);last=now;timerTicks++;},10);
  try {
    const opened=await call('open',{},source),info=JSON.parse(opened.json);token=info.token;
    assert.equal(opened.bytes,null);assert.ok(opened.json.length<1024);
    assert.equal(hash(source),digest,'transfer must not detach or mutate caller source');
    assert.ok(timerTicks>5,'MAP decoding must allow main-thread timers to progress');
    const before=await call('export');assert.equal(hash(before.bytes),digest);
    await assert.rejects(()=>call('open',{},new Uint8Array([0,0,0,0])));
    assert.equal(hash((await call('export')).bytes),digest,'failed replacement preserves prior MAP');
    await assert.rejects(()=>call('open',{expectedWorld:{worldId:-999}},source));
    assert.equal(hash((await call('export')).bytes),digest,'identity mismatch preserves prior MAP');
    const rendered=await call('render',{maxWidth:960}),raster=JSON.parse(rendered.json);
    assert.equal(rendered.bytes.length,raster.width*raster.height*4);
    assert.ok(rendered.bytes.length<=960*2048*4);
    await call('edit',{x:0,y:0,width:64,height:64,light:177,color:12});
    const edited=await call('export');assert.notEqual(hash(edited.bytes),digest);
    await call('undo');assert.equal(hash((await call('export')).bytes),digest);
    await call('redo');assert.equal(hash((await call('export')).bytes),hash(edited.bytes));
    const reopened=await call('open',{},edited.bytes);token=JSON.parse(reopened.json).token;
    assert.equal(hash((await call('export')).bytes),hash(edited.bytes));
    // Stale token cannot mutate a newer session.
    await assert.rejects(()=>call('undo',{token:token-1}));
    const pending=call('open',{},source);const cancelled=assert.rejects(pending,/closed/);
    client.dispose();await cancelled;
    const recovered=await call('open',{},source);token=JSON.parse(recovered.json).token;
    assert.equal(hash((await call('export')).bytes),digest);
    assert.equal(hash(fs.readFileSync(input)),digest);
    const sorted=intervals.slice().sort((a,b)=>a-b);
    const report={...metadata([['map-worker',compiled]]),status:'passed',timerTicks,mainThreadTimerP95Ms:sorted[Math.ceil(sorted.length*.95)-1],
      mainThreadTimerMaxMs:sorted.at(-1),sourcePreserved:true,metadataOnlyOnOpen:true,
      fixture:{id:'local-map-1',bytes:source.length,sha256:digest},
      note:'Real Node worker timing is not browser rAF or Flutter frame evidence.'};
    if(process.env.ABC_MAP_WORKER_REPORT)fs.writeFileSync(process.env.ABC_MAP_WORKER_REPORT,JSON.stringify(report,null,2)+'\n');
    console.log(JSON.stringify({status:report.status,timerTicks:report.timerTicks,mainThreadTimerP95Ms:report.mainThreadTimerP95Ms,mainThreadTimerMaxMs:report.mainThreadTimerMaxMs,sourcePreserved:true,metadataOnlyOnOpen:true,note:report.note}));
  } finally {clearInterval(interval);client.dispose();}
})().catch(error=>{console.error(error);process.exitCode=1;});
