// Bounded diagnostic: continue the same physical Pong CPU across WLD save.
// Usage: node ... world.js world.wasm input.wld pong.bin report.json
// This explicitly selects optimized WireHead-style PixelBox rules before both traces.
// This Node file-owner probe is not a browser timing or threading benchmark.
'use strict';
const fs = require('node:fs'), path = require('node:path'), crypto = require('node:crypto');
const assert = require('node:assert/strict');
const {createFileWorldOwner} = require('./helpers/world_file_host.cjs');
const {packet, rows, ramRecords, programWrites} = require('./computerraria_file_acceptance.cjs');
const digest = data => crypto.createHash('sha256').update(data).digest('hex');
async function fileHash(name) { const h=crypto.createHash('sha256'); for await (const b of fs.createReadStream(name)) h.update(b); return h.digest('hex'); }
const trigger = (x,y,mask,count=1) => packet(2,{x,y,width:1,height:1,mask,count});
const clock = count => trigger(3194,153,8,count);
const resetBus = [trigger(3243,226,2),trigger(3404,350,2),trigger(3198,198,8)];
const sensors = {up:[6516,851,9],down:[6517,866,5]};
const inputFor = batch => batch===0?['up']:batch===8?['down']:batch===16?['up','down']:batch>=24&&batch<28?['up']:[];
function validateContinuation(report) {
  assert.equal(report.live.length,32);assert.equal(report.reopened.length,32);
  assert.deepEqual(report.afterReopen,report.beforeSave);
  assert.deepEqual(report.reopened,report.live);
  const all=[report.beforeSave,...report.live];
  const distinct=Object.fromEntries(['mono','ram','cpuProbe','inputProbe'].map(key=>[key,new Set(all.map(row=>row[key])).size]));
  for(const key of ['mono','ram','cpuProbe']) assert.ok(distinct[key]>1,'Equal but halted continuation is insufficient: '+key);
  assert.ok(report.live.slice(24).some(row=>row.leftPaddleCenter!==report.live[23].leftPaddleCenter),'Held-UP must visibly move the real left paddle');
  return {distinctStates:distinct,initialLeftPaddleCenter:report.beforeSave.leftPaddleCenter,
    singleUpCenters:report.live.slice(0,8).map(row=>row.leftPaddleCenter),
    singleDownCenters:report.live.slice(8,16).map(row=>row.leftPaddleCenter),
    simultaneousCenters:report.live.slice(16,24).map(row=>row.leftPaddleCenter),
    heldUpCenters:report.live.slice(24).map(row=>row.leftPaddleCenter)};
}
async function main(args) {
  assert.equal(args.length,5);
  const [loader,wasm,wld,pong,output]=args;
  const report={schema:'abc.computerraria.continuation-probe.v2',status:'running',inputFormat:'wld-only',host:'Node file-backed Web WASM; sequential live and reopened sessions',mode:'optimized',pixelRule:'wirehead-color-pair-wave',clockBatchPulses:128,saveAtPulses:5120,continuationPulses:4096,source:{wld:await fileHash(wld),pong:await fileHash(pong),wasm:await fileHash(wasm)},probeScope:{cpu:'ordinary logic lamps in x3150..3449,y130..329 plus known ready lamp; not an asserted complete architectural register map',ram:'first64bytes and final1024bytes of physical368KiB RAM, including current Pong stack',input:'all ordinary logic lamps in x6450..6559,y840..909; raw coordinates, no guessed latch-to-bit labels'},live:[],reopened:[]};
  assert.equal(report.source.wld,'55d0a24bd1f56d622003dbd30d52555e7d06d6d1bcacfc22ae506f2db5240c33');
  assert.equal(report.source.pong,'d2a7d5a26eb168a55c80ae60b32205957d8f2ae215cbdce7c5d50acc2049946d');
  fs.mkdirSync(path.dirname(output),{recursive:true});
  const write=()=>fs.writeFileSync(output,JSON.stringify(report,null,2)+'\n');
  const owner=createFileWorldOwner(loader,wasm),bridge=owner.bridge,start=performance.now();
  let id=0,staged=null,phase='import',cpuPoints,inputPoints;
  const progress=setInterval(()=>console.log(JSON.stringify({phase,elapsedMs:performance.now()-start,rss:process.memoryUsage().rss})),10000);
  const command=c=>bridge.command(id,JSON.stringify(c.words),JSON.stringify(c.records));
  const lamps=(points,write=false)=>command(packet(write?5:4,{},points));
  const ready=async()=>rows(await lamps([3199,156,0,0]))[0][2]===1;
  const display=()=>command(packet(9,{x:6485,y:800,width:64,height:48}));
  async function reset() { for(let i=0;i<3&&!await ready();i++) await command(clock(1)); if(!await ready()) await command(trigger(3198,156,4)); for(const c of resetBus) await command(c); }
  async function discover(x,y,width,height) { const viewport=await command(packet(1,{x,y,width,height})); return rows(viewport).filter(r=>(r[2]&65535)===419&&(r[3]&65535)!==36).flatMap(r=>[r[0],r[1],0,0]); }
  const addresses=[...Array.from({length:16},(_,i)=>0x100000+i*4),...Array.from({length:256},(_,i)=>0x15bc00+i*4)];
  const ramPoints=ramRecords(addresses);
  async function checkpoint(pulses,inputs=[]) {
    const mono=await display(),ram=await lamps(ramPoints),cpu=await lamps(cpuPoints),input=await lamps(inputPoints),readiness=await lamps([3199,156,0,0]);
    const left=rows(mono).filter(r=>r[0]===6485&&r[3]===18).map(r=>r[1]-800);
    const lit=rows(mono).filter(r=>r[3]===18).map(r=>[r[0]-6485,r[1]-800]);
    return {pulses,inputs,mono:digest(mono.records),ram:digest(ram.records),cpuProbe:digest(cpu.records),inputProbe:digest(input.records),ready:rows(readiness)[0][2],leftPaddleRows:left,leftPaddleCenter:left.length?left.reduce((a,b)=>a+b,0)/left.length:-1,lit,inputLamps:rows(input).map(r=>r.slice(0,3))};
  }
  async function continuation(target,expected) {
    for(let batch=0;batch<32;batch++) {
      const inputs=inputFor(batch);
      for(const direction of inputs) await command(trigger(...sensors[direction]));
      await command(clock(128));
      const next=await checkpoint((batch+1)*128,inputs);target.push(next);
      if(expected) {
        try { assert.deepEqual(next,expected[batch]); }
        catch(error) { report.firstDivergence={batch,atContinuationPulses:next.pulses,fields:Object.keys(next).filter(k=>JSON.stringify(next[k])!==JSON.stringify(expected[batch][k]))}; write(); throw error; }
      }
      if(batch%8===7) { write(); console.log(JSON.stringify({phase,batches:batch+1,center:next.leftPaddleCenter,ready:next.ready})); }
    }
  }
  try {
    const opened=await bridge.openSource(await fs.openAsBlob(wld));id=opened.session;
    assert.equal(opened.reserved&3,0);assert.equal(opened.reserved&4,4);
    const selected=await command(packet(10,{mask:1}));assert.equal(selected.reserved&14,14);report.circuitAbi=opened.stats[0];assert.equal(report.circuitAbi,2);report.openMilliseconds=performance.now()-start;
    phase='load-pong';await reset();
    for(const points of programWrites(new Uint8Array(),new Uint8Array(fs.readFileSync(pong)))) await lamps(points,true);
    await reset();
    phase='fixed5120-trace';
    for(let batch=0;batch<40;batch++) {
      if(batch>=8&&batch<12) await command(trigger(...sensors.up));
      if(batch>=20&&batch<26) await command(trigger(...sensors.down));
      await command(clock(128));
    }
    phase='discover-read-only-probes';cpuPoints=await discover(3150,130,300,200);inputPoints=await discover(6450,840,110,70);
    assert.ok(cpuPoints.length>0&&inputPoints.length>0);report.probeCounts={cpuLamps:cpuPoints.length/4,inputLamps:inputPoints.length/4,ramWords:addresses.length};
    report.beforeSave=await checkpoint(0);phase='save';
    staged=await command(packet(6,{source:3}));
    assert.deepEqual(await checkpoint(0),report.beforeSave,'Saving must preserve current circuit state');
    report.save={worldBytes:staged.worldSource.size};write();
    phase='live-continuation';await continuation(report.live);
    await bridge.close(id);id=0;phase='reopen-saved-world';
    const reopened=await bridge.openSource(staged.worldSource.blob);id=reopened.session;assert.equal(reopened.reserved&3,0);
    const resumedMode=await command(packet(10,{mask:1}));assert.equal(resumedMode.reserved&14,14);
    // Deliberately no reset, ROM write, ready-boundary advance or bus-zero pulse.
    report.afterReopen=await checkpoint(0);
    try { assert.deepEqual(report.afterReopen,report.beforeSave); }
    catch(error) { report.firstDivergence={atContinuationPulses:0,fields:Object.keys(report.afterReopen).filter(k=>JSON.stringify(report.afterReopen[k])!==JSON.stringify(report.beforeSave[k]))};write();throw error; }
    phase='reopened-continuation';await continuation(report.reopened,report.live);
    report.liveness=validateContinuation(report);
    report.status='passed';report.exactCheckpointEquality=true;
  } catch(error) {report.status='failed';report.error=String(error.stack||error);throw error;}
  finally {
    clearInterval(progress);
    try { if(id) await bridge.close(id);if(staged){await bridge.releaseSource(staged.worldSource.token);} }
    finally { report.elapsedMilliseconds=performance.now()-start;report.nativeBytesAfterClose=owner.module?._tx_native_heap_used?.()??null;report.bridgeBytesAfterClose=owner.module?._tx_bridge_heap_used?.()??null;report.openFilesAfterClose=owner.openFiles;write();owner.cleanup(); }
  }
  assert.equal(report.nativeBytesAfterClose,0);assert.equal(report.bridgeBytesAfterClose,0);assert.equal(report.openFilesAfterClose,0);
  console.log('PASS: live and reopened physical Pong continuation match every128-pulse checkpoint');
}
if(require.main===module)main(process.argv.slice(2)).catch(error=>{console.error(error);process.exitCode=1;});
module.exports={validateContinuation};
