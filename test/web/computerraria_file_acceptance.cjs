// Opt-in acceptance of ABC's exact Web WASM artifact and original complete WLD.
// Only physical wire pulses, ROM/RAM lamps, and native pixel queries are used.
// Usage: node test/web/computerraria_file_acceptance.cjs world.js world.wasm world.wld report.json [--pong Pong.bin] [--input input-once.bin] [--save] [--optimized] [--compound-frame]
'use strict';
const fs=require('node:fs'),path=require('node:path'),crypto=require('node:crypto'),assert=require('node:assert/strict');
const {createFileWorldOwner}=require('./helpers/world_file_host.cjs');
const {createClient,installHost}=require('../../web/terra_worker_rpc.js');
const SOURCE_SHA='55d0a24bd1f56d622003dbd30d52555e7d06d6d1bcacfc22ae506f2db5240c33';
const hash=bytes=>crypto.createHash('sha256').update(bytes).digest('hex');
async function hashBlob(blob){const h=crypto.createHash('sha256');for await(const bytes of blob.stream())h.update(bytes);return h.digest('hex');}
async function hashFile(file){const h=crypto.createHash('sha256');for await(const bytes of fs.createReadStream(file,{highWaterMark:1024*1024}))h.update(bytes);return h.digest('hex');}
function packet(kind,{x=0,y=0,width=0,height=0,mask=0,count=0,flags=0,source=0,aux=0}={},records=[]){return {words:[2,kind,x,y,width,height,1,mask,count,0,records.length/4,source,flags,aux,0,0],records};}
function trigger(x,y,mask,count=1){return packet(2,{x,y,width:1,height:1,mask,count});}
function clock(count=1){return trigger(3194,153,8,count);}
const resetBus=()=>[trigger(3243,226,2),trigger(3404,350,2),trigger(3198,198,8)];
function rows(result){const d=new DataView(result.records.buffer,result.records.byteOffset,result.records.byteLength),out=[];assert.equal(d.byteLength%16,0);for(let at=0;at<d.byteLength;at+=16)out.push([0,4,8,12].map(offset=>d.getUint32(at+offset,true)));return out;}
function romLamp(address,bit){const word=Math.floor(address/4),cell=word%8192;return [2853+cell+Math.floor((cell+1)/2),1143+131*Math.floor(word/8192)+3*(31-bit)];}
function ramRecords(addresses,write=false){const records=[];for(const address of addresses){assert.ok(address>=0x100000&&address<0x100000+368*1024);const word=Math.floor((address-0x100000)/4);for(let bit=0;bit<32;bit++)for(let mirror=0;mirror<(write?2:1);mirror++)records.push(2853+3*(word%4096)+mirror,4287+125*Math.floor(word/4096)+3*(31-bit),0,0);}return records;}
function* programWrites(before,after){assert.ok(after.length<=768*1024&&after.length%4===0&&before.length%4===0);let records=[];const old=new DataView(before.buffer,before.byteOffset,before.byteLength),fresh=new DataView(after.buffer,after.byteOffset,after.byteLength);for(let address=0;address<Math.max(before.length,after.length);address+=4){const oldWord=address<before.length?old.getUint32(address,true):0,newWord=address<after.length?fresh.getUint32(address,true):0,changed=oldWord^newWord;for(let bit=0;bit<32;bit++)if((changed&(1<<bit))!==0){records.push(...romLamp(address,bit),(newWord>>>bit)&1,0);if(records.length===8192*4){yield records;records=[];}}}if(records.length)yield records;}
function paddedProgram(bytes){assert.ok(bytes.length>0&&bytes.length<=768*1024);const result=new Uint8Array(Math.ceil(bytes.length/4)*4);result.set(bytes);return result;}
function summarizeClockSamples(samples){
 const sorted=samples.map(v=>v.milliseconds).sort((a,b)=>a-b),total=sorted.reduce((a,b)=>a+b,0),n=sorted.length;
 const median=n?(n%2?sorted[n>>1]:(sorted[(n>>1)-1]+sorted[n>>1])/2):null,p95=n?sorted[Math.ceil(n*.95)-1]:null;
 return {batches:n,pulses:n*128,milliseconds:total,medianMs:median,p95Ms:p95,pulsesPerSecond:total>0?n*128000/total:null,medianPulsesPerSecond:median>0?128000/median:null};
}
// Real RPC validation/remapping and transferable-buffer ownership, with the
// actual WASM/file bridge below. Both endpoints run in this Node process:
// this proves protocol/transfer correctness, not browser scheduling/threading.
function rpcLoopback(bridge){
 // Node24 deliberately rejects cloning fs.openAsBlob(). Keep those immutable
 // handles by identity in this same-process adapter; clone all other packet
 // structure and genuinely transfer ArrayBuffers. No file bytes are copied.
 function clonePacket(value,transfer){
  const blobs=[],tag='__abcLoopbackBlobIndex';
  function scrub(v){if(v instanceof Blob){blobs.push(v);return {[tag]:blobs.length-1};}if(v instanceof Uint8Array||v===null||typeof v!=='object')return v;if(Array.isArray(v))return v.map(scrub);assert.ok(!Object.hasOwn(v,tag));return Object.fromEntries(Object.entries(v).map(([k,child])=>[k,scrub(child)]));}
  function restore(v){if(v instanceof Uint8Array||v===null||typeof v!=='object')return v;if(Object.hasOwn(v,tag))return blobs[v[tag]];for(const k of Object.keys(v))v[k]=restore(v[k]);return v;}
  return restore(structuredClone(scrub(value),{transfer}));
 }
 return createClient('worldCircuit',{createWorker(){
  let terminated=false;
  const scope={postMessage(value,transfer=[]){const data=clonePacket(value,transfer);queueMicrotask(()=>{if(!terminated)worker.onmessage?.({data});});}};
  const worker={onmessage:null,onerror:null,onmessageerror:null,postMessage(value,transfer=[]){const data=clonePacket(value,transfer);queueMicrotask(()=>{if(!terminated)scope.onmessage({data});});},terminate(){terminated=true;}};
  installHost('worldCircuit',bridge,scope);return worker;
 }});
}
async function main(args){
 if(args.length<4)throw new Error('Expected world.js world.wasm WLD report.json [--pong path] [--input path] [--save] [--optimized] [--compound-frame]');
 const [loader,wasm,wld,reportPath]=args.slice(0,4);let pongPath,inputPath,save=false,optimized=false,compound=false;
 for(let n=4;n<args.length;n++){if(args[n]==='--save')save=true;else if(args[n]==='--optimized')optimized=true;else if(args[n]==='--compound-frame')compound=true;else if(args[n]==='--pong'&&args[n+1])pongPath=args[++n];else if(args[n]==='--input'&&args[n+1])inputPath=args[++n];else throw new Error('Unknown or incomplete acceptance option: '+args[n]);}
 const fixtures=JSON.parse(fs.readFileSync(path.resolve(__dirname,'../../native/fixtures/computerraria/programs.json'),'utf8'));
 const image=name=>new Uint8Array(Buffer.from(fixtures[name].hex,'hex'));
 const report={schema:'abc.computerraria.web-file-acceptance.v2',inputFormat:'wld-only',host:'Node File/Blob and random-access temporary files with ABC Web WASM',measurement:'Physical simulation acceptance; Node scheduling and query timing are not browser UI FPS',loaderSha256:await hashFile(loader),wasmSha256:await hashFile(wasm),runtime:process.version,requestedOptimization:optimized,defaultOptimization:false};
 report.pixelRule=optimized?'wirehead-color-pair-wave':'game-tripwire-crossing';report.displayCompatibility={status:optimized?'supported':'unsupported-under-game-rules',expectedBehavior:optimized?'moving-pong':'recorded-without-pong-display-claim'};
 const owner=createFileWorldOwner(loader,wasm),bridge=compound?rpcLoopback(owner.bridge):owner.bridge,start=performance.now();let id=0,previousProgram=new Uint8Array(),staged=null,peakRss=0,lastSample=performance.now(),maxOwnerGapMs=0;
 const compoundSamples=[];let lastCompoundDisplay=null;
 if(compound)report.compoundFrame={transport:'Actual RPC client/host and structuredClone ArrayBuffer transfers in a Node loopback, both endpoints on one thread; immutable fs.openAsBlob handles preserved by identity because Node24 forbids cloning them; not browser File transfer, threading or timing proof',monitorSelection:'Complete monochrome monitor after each unchanged128-pulse batch; compare returned selected pixels byte-for-byte with an ordinary read at the same electrical state',samples:compoundSamples};
 const samples=setInterval(()=>{const now=performance.now();maxOwnerGapMs=Math.max(maxOwnerGapMs,now-lastSample);lastSample=now;peakRss=Math.max(peakRss,process.memoryUsage().rss);},16);
 const progress=setInterval(async()=>{console.log(JSON.stringify({elapsedMs:performance.now()-start,progress:await bridge.progress()}));},10000);
 const command=c=>bridge.command(id,JSON.stringify(c.words),JSON.stringify(c.records));
 let activeOptimization=false;const clockSamples=[];
 async function setOptimization(enabled){const result=await command(packet(10,{mask:enabled?1:0}));assert.equal(result.session,id,'Mode toggle retains native session');assert.equal(result.reserved&2,enabled?2:0,'Native confirms requested optimization');assert.equal(result.reserved&1,0,'WLD-only reserved bit');assert.equal(result.reserved&12,enabled?12:4,'Qualified topology and selected pixel rule');activeOptimization=enabled;return result;}
 async function clock128(phase){
  const begin=performance.now(),mode=activeOptimization;let result,milliseconds;
  if(compound){
   const pixels=displayPacket();
   const frame=await bridge.commandAndReadPixels(id,JSON.stringify(clock(128).words),JSON.stringify(pixels.words)),roundTripMilliseconds=performance.now()-begin;
   assert.equal(frame.readError,null,'Compound display must succeed after accepted physical clocks');assert.ok(frame.pixels,'Compound returns selected actual pixels');
   result=frame.command;assert.equal(result.session,id,'Compound clock remaps public session');assert.equal(frame.pixels.session,id,'Compound display remaps same session');
   assert.equal(frame.pixels.resultKind,9);assert.equal(frame.pixels.records.length,3072*16,'Only selected monitor records are returned');
   assert.deepEqual(frame.pixels.stats.slice(18,24),result.stats.slice(18,24),'Compound display read adds no electrical work');
   milliseconds=result.hostStagesUs?.commandWallUs/1000;assert.ok(Number.isFinite(milliseconds)&&milliseconds>=0,'Separate clock-only host timing is available');
   const ordinary=await display();assert.deepEqual(frame.pixels.records,ordinary.records,'Compound selected pixels exactly equal separate read');
   lastCompoundDisplay=frame.pixels;
   compoundSamples.push({phase,optimized:mode,monitor:'mono',recordsBytes:frame.pixels.records.length,recordsSha256:hash(frame.pixels.records),clockCommandMilliseconds:milliseconds,roundTripMilliseconds,hostStagesUs:frame.hostStagesUs});
  }else{result=await command(clock(128));milliseconds=performance.now()-begin;}
  assert.equal(result.reserved&2,mode?2:0,'Clock batch retains selected mode');clockSamples.push({phase,optimized:mode,milliseconds});return result;
 }
 const lamps=(records,write=false)=>command(packet(write?5:4,{},records));
 const ready=async()=>{const values=rows(await lamps([3199,156,0,0]));assert.equal(values.length,1);assert.equal(values[0][3],419);return values[0][2]===1;};
 async function reset(){for(let n=0;!await ready()&&n<3;n++)await command(clock());if(!await ready())await command(trigger(3198,156,4));for(const c of resetBus())await command(c);}
 async function load(bytes){await reset();for(const records of programWrites(previousProgram,bytes))await lamps(records,true);previousProgram=bytes;await reset();}
 async function signature(addresses){for(const c of resetBus().slice(0,2))await command(c);const values=rows(await lamps(ramRecords(addresses)));return addresses.map((_,index)=>{let value=0;for(let bit=0;bit<32;bit++)value|=values[index*32+bit][2]<<bit;return value>>>0;});}
 async function execute(bytes,addresses,input,phase='program'){const begin=performance.now();await load(bytes);await lamps(ramRecords(addresses,true),true);await reset();if(input){for(const c of (Array.isArray(input)?input:[input]))await command(c);}let values=[],clocks=0;while(clocks<4096){await clock128(phase);clocks+=128;for(let n=0;!await ready()&&n<3;n++){await command(clock());clocks++;}assert.ok(await ready(),'Physical CPU reaches an instruction boundary');values=await signature(addresses);if(values.at(-1)===0x600dc0de)break;}assert.equal(values.at(-1),0x600dc0de,'Physical program completion marker');return {signature:values,clocks,milliseconds:performance.now()-begin};}
 const displayPacket=(old=false)=>packet(old?1:9,{x:6485,y:800,width:64,height:48});
 const display=(old=false)=>command(displayPacket(old));
 const passiveRam=ramRecords([...Array.from({length:16},(_,i)=>0x100000+i*4),...Array.from({length:256},(_,i)=>0x15bc00+i*4)]);
 const passiveRamHash=async()=>hash((await lamps(passiveRam)).records);
 try {
  const opened=await bridge.openSource(await fs.openAsBlob(wld));id=opened.session;
  report.circuitAbi=opened.stats[0];assert.equal(report.circuitAbi,2,'Actual WLD-only circuit ABI');
  report.import={milliseconds:performance.now()-start,sourceSha256:opened.sourceSha256,stats:opened.stats,diagnostics:opened.diagnostics,processMemory:process.memoryUsage()};
  assert.equal(opened.sourceSha256,SOURCE_SHA,'Complete original WLD identity');assert.equal(fs.statSync(wld).size,405983441);assert.equal(opened.stats[2],15200);assert.equal(opened.stats[3],7200);assert.equal(opened.stats[10],72939714);assert.equal(opened.stats[12],13641575);assert.equal(opened.reserved&1,0,'WLD-only reserved bit');assert.equal(opened.reserved&2,0,'Optimization defaults OFF at open');const selected=await setOptimization(optimized);report.readyMetadata={flags:selected.reserved,optimizationEnabled:optimized,topologyEligible:true,wireHeadPixelRulesEnabled:optimized};report.activeOptimizationAtStart=activeOptimization;
  assert.equal(rows(await display()).length,3072);
  const addresses=fixtures.main.checks.map(v=>v.address),expected=fixtures.main.checks.map(v=>v.expected);
  report.main=await execute(image('main'),addresses,null,'main');assert.deepEqual(report.main.signature,expected,'48 physical CPU signatures');
  const mutation=image('main');mutation[fixtures.mutationWord*4+2]^=0x10;report.negativeControl=await execute(mutation,addresses,null,'negativeControl');assert.deepEqual(report.negativeControl.signature,[0x7fffffff,...expected.slice(1)],'Actual one-bit ROM mutation');
  report.displayProgram=await execute(image('display'),[0x1000bc],null,'display');
  const mono=rows(await display()),litMono=mono.filter(v=>v[3]!==0);
  report.display={mono:litMono,recordCount:mono.length};report.correctness={displayMonoSha256:hash((await display()).records)};
  assert.deepEqual(litMono.map(v=>[v[0],v[1],v[3]]),optimized?[[6485,800,18],[6516,800,18]]:[],'Declared PixelBox rule');
  assert.deepEqual(rows(await display(true)),mono,'Direct mono pixels match native viewport');
  const queryStart=performance.now();for(let n=0;n<100;n++)await display();report.display={mono:litMono,monoQueries100Ms:performance.now()-queryStart};report.correctness={displayMonoSha256:hash((await display()).records)};
  console.log('PASS: full world, 48 signatures, actual ROM mutation, native monochrome pixels and viewport parity');
  if(inputPath){
   const program=inputPath==='-'?image('input'):paddedProgram(fs.readFileSync(inputPath)),probes=[];
   probes.push({sensor:null,run:await execute(program,[0x100000,0x1000bc])});
   for(const sensor of [[6516,851,9],[6517,866,5],[6519,858,10],[6520,857,5]]){
    for(const pulse of [1,2,3,0,1])probes.push({sensor,pulse,run:await execute(program,[0x100000,0x1000bc],pulse?trigger(...sensor,pulse):null)});
   }
   const keys=[trigger(6516,851,9),trigger(6517,866,5),trigger(6519,858,10),trigger(6520,857,5)];
   const pair=await execute(program,[0x100000,0x1000bc],keys.slice(0,2));assert.equal(pair.signature[0]&15,9);probes.push({sensor:'up+down',run:pair});
   const all=await execute(program,[0x100000,0x1000bc],[...keys,packet(10,{mask:optimized?0:1}),packet(10,{mask:optimized?1:0})]);assert.equal(all.signature[0]&15,15);probes.push({sensor:'all+idleSwitch',run:all});
   report.inputProbes=probes;
  }
  report.clearProgram=await execute(image('clear'),[0x1000bc],null,'clear');assert.equal(rows(await display()).filter(v=>v[3]!==0).length,0,'CPU clears mono pixels');
  if(pongPath){
   const binary=fs.readFileSync(pongPath),pong=paddedProgram(binary);await load(pong);
   const frames=[],hashes=new Set(),modeFlips=[],cpuTrace=[],play=performance.now();let clocks=0;
   async function flipPreservingState(enabled){
    const beforeMono=await display(),beforeLamps=await lamps([3199,156,0,0,...ramRecords([0x100000,0x1000bc])]);
    const changed=await setOptimization(enabled),afterMono=await display(),afterLamps=await lamps([3199,156,0,0,...ramRecords([0x100000,0x1000bc])]);
    assert.deepEqual(afterMono.records,beforeMono.records,'Idle toggle preserves exact mono pixels');assert.deepEqual(afterLamps.records,beforeLamps.records,'Idle toggle preserves live ready/RAM lamps');assert.deepEqual(changed.stats.slice(18,24),beforeLamps.stats.slice(18,24),'Idle toggle fires no electrical work');
    modeFlips.push({clocks,optimized:enabled,monoSha256:hash(afterMono.records),lampSha256:hash(afterLamps.records),session:id});
   }
   for(let n=0;n<12;n++){
    await clock128('pong');clocks+=128;
    const frame=compound&&lastCompoundDisplay?lastCompoundDisplay:await display(),lit=rows(frame).filter(v=>v[3]===18).map(v=>[v[0]-6485,v[1]-800]),digest=hash(frame.records);
    if(!hashes.has(digest)){hashes.add(digest);frames.push({clocks,sha256:digest,lit});}
    cpuTrace.push({clocks,ready:await ready(),ramSha256:await passiveRamHash()});
    if(n===3){await flipPreservingState(!optimized);await flipPreservingState(optimized);}
   }
   assert.equal(modeFlips.length,2,'Pong continues through both idle mode changes');assert.ok(optimized?frames.filter(v=>v.lit.some(p=>p[0]>1&&p[0]<62)).length>=3:frames.every(v=>v.lit.length===0),'Pong follows declared pixel rule');assert.ok(new Set(cpuTrace.map(r=>r.ramSha256)).size>1,'Physical Pong RAM/stack is live');
   report.pong={binarySha256:hash(binary),bytes:binary.length,clocks,milliseconds:performance.now()-play,frames,modeFlips,cpuTrace,cpuTraceMeasurement:'passive-ready-and-1088-ram-bytes-no-reset-bus',displayStatus:optimized?'moving':'expected-dark'};Object.assign(report.correctness,{pongFinalMonoSha256:hash((await display()).records)});console.log('PASS: original upstream Pong CPU/RAM trace; declared display '+(optimized?'moving':'expected dark under game rules'));
  }
  if(save){
   const priorMono=(await display()).records,priorRam=await passiveRamHash(),saveAt=performance.now();
   staged=await command(packet(6,{source:3}));
   report.save={status:'running',milliseconds:performance.now()-saveAt,worldBytes:staged.worldSource.size,
    worldSha256:await hashBlob(staged.worldSource.blob),beforeDisplaySha256:{mono:hash(priorMono)},beforeRamSha256:priorRam};
   assert.equal(staged.world,null);await bridge.close(id);id=0;
   const reopened=await bridge.openSource(staged.worldSource.blob);id=reopened.session;activeOptimization=false;
   assert.equal(reopened.reserved&2,0,'Reopened sessions default OFF');if(optimized)await setOptimization(true);
   const reopenedMono=(await display()).records;
   assert.deepEqual(reopenedMono,priorMono,'WLD save preserves mono physical state');
   report.save.reopenedRamSha256=await passiveRamHash();assert.equal(report.save.reopenedRamSha256,priorRam,'Saved physical RAM/stack');
   report.save.reopenedDisplaySha256={mono:hash(reopenedMono)};report.save.reopenedStats=reopened.stats;
   await execute(image('display'),[0x1000bc],null,'reopenDisplay');
   assert.equal(rows(await display()).filter(r=>r[1]===800&&r[0]<6517&&r[3]!==0).length,optimized?2:0);
   await execute(image('clear'),[0x1000bc],null,'reopenClear');
   const clearedMono=await display();
   assert.ok(rows(clearedMono).filter(r=>r[1]===800&&r[0]<6517).every(r=>r[3]===0));
   report.save.postProgramDisplaySha256={mono:hash(clearedMono.records)};report.save.status='passed';
  }
  if(compound){assert.ok(compoundSamples.length>0&&compoundSamples.every(v=>v.monitor==='mono'),'Compound RPC reads actual mono pixels');if(pongPath)assert.ok(compoundSamples.some(v=>v.phase==='pong'),'Actual Pong exercises compound monitor reads');report.compoundFrame.status='passed';}
  report.finalStats=(await display()).stats;report.activeOptimizationAtEnd=activeOptimization;report.hostProgress=await bridge.progress();report.status='passed';
 }catch(error){report.status='failed';report.error=String(error.stack||error);throw error;}
 finally {
  clearInterval(progress);clearInterval(samples);
  report.clock128Timing={measurement:compound?'Only the worker bridge clock command hostStagesUs.commandWallUs; excludes compound display read and loopback round trip, and is not the legacy externally-awaited timing':'Only the awaited128-clock command, including bounded owner dispatch; excludes ROM loading, state reads and rendering',all:summarizeClockSamples(clockSamples),byMode:[false,true].map(mode=>({optimized:mode,...summarizeClockSamples(clockSamples.filter(v=>v.optimized===mode))})),pongByMode:[false,true].map(mode=>({optimized:mode,...summarizeClockSamples(clockSamples.filter(v=>v.phase==='pong'&&v.optimized===mode))})),samples:clockSamples};
  try{if(id)await bridge.close(id);if(staged){await bridge.releaseSource(staged.worldSource.token);}}
  finally{if(compound)await bridge.dispose();report.peakRssBytes=Math.max(peakRss,process.memoryUsage().rss);report.maxOwnerTimerGapMs=maxOwnerGapMs;report.elapsedMilliseconds=performance.now()-start;report.nativeBytesAfterClose=owner.module?._tx_native_heap_used?.()??null;report.bridgeBytesAfterClose=owner.module?._tx_bridge_heap_used?.()??null;report.openFilesAfterClose=owner.openFiles;report.peakOpenFiles=owner.peakOpenFiles;if(report.nativeBytesAfterClose!==0||report.bridgeBytesAfterClose!==0||report.openFilesAfterClose!==0){report.status='failed';report.error=report.error||'Circuit owners remain after close';}fs.mkdirSync(path.dirname(reportPath),{recursive:true});fs.writeFileSync(reportPath,JSON.stringify(report,null,2)+'\n');owner.cleanup();}
 }
 assert.equal(report.nativeBytesAfterClose,0,'No native allocations remain');assert.equal(report.bridgeBytesAfterClose,0,'No bridge allocations remain');assert.equal(report.openFilesAfterClose,0,'No temporary file owners remain');
 console.log('PASS: Web artifact acceptance complete; report '+reportPath);
}
if(require.main===module)main(process.argv.slice(2)).catch(error=>{console.error(error);process.exitCode=1;});
module.exports={romLamp,ramRecords,programWrites,packet,rows,summarizeClockSamples};
