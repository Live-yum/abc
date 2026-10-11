// Actual A and B Emscripten engines; no fake ABI or shipped stale engine path.
'use strict';
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const assert = require('node:assert/strict');
const {createFileWorldOwner} = require('./helpers/world_file_host.cjs');
const sha = bytes => crypto.createHash('sha256').update(bytes).digest('hex');
const [aJs, aWasm, bJs, bWasm, fixtureDirectory, output] = process.argv.slice(2);
assert.ok(output, 'A.js A.wasm B.js B.wasm fixture-directory new-report.json required');
assert.equal(fs.existsSync(output), false);
const records = [];
const report = {schema:'abc.viewport-cache-actual-wasm.v1', status:'running', artifacts:{}, records,
  limits:['Synthetic semantic equivalence only; not browser UI or performance.',
    'Real native ABI exhaustive work-budget/cancel/pressure corpus is separate.',
    'Blob errors prove browser host READ failures; filesystem mtime/type checks belong to Dart.',
    'openFiles cleanup counts scratch handles, not WASM allocations; Native private pressure contracts cover allocation ownership.']};
for (const [name, file] of Object.entries({aJs, aWasm, bJs, bWasm})) {
  const bytes = fs.readFileSync(file);
  report.artifacts[name] = {path:path.resolve(file), sha256:sha(bytes), bytes:bytes.length};
}
const scene = {x:0,y:8,width:96,height:42,stride:1};
const shapes = [
  {name:'one',x:384,y:63,width:1,height:1,stride:1},
  {name:'3072',x:61,y:8,width:64,height:48,stride:1},
  {name:'4096',x:64,y:0,width:64,height:64,stride:1},
  {name:'4097',x:64,y:10,width:241,height:17,stride:1},
  {name:'4097-strided',x:64,y:10,width:241,height:17,stride:2},
  {name:'stride0',x:61,y:25,width:12,height:10,stride:0},
  {name:'stride2',x:61,y:25,width:12,height:10,stride:2},
  {name:'gate-outside-roi',x:65,y:28,width:6,height:1,stride:1},
];
function rows(bytes) {
  const data = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength), result=[];
  for(let n=0;n<bytes.length;n+=16) result.push([0,4,8,12].map(i=>data.getUint32(n+i,true)));
  return result;
}
function operations() {
  const result = [1,2,4,8,3,15].map(mask=>[`colour-${mask}`,2,{x:3,y:10,width:1,height:1,mask,count:1}]);
  result.push(['multi-pulse',2,{x:3,y:10,width:1,height:1,mask:1,count:3}],
    ['pixel-four-ports',2,{x:79,y:39,width:3,height:3,mask:15,count:1}],
    ['pixel-two-colours',2,{x:79,y:39,width:3,height:3,mask:3,count:1}]);
  for(const x of [86,90,94]) result.push([`junction-${x}`,2,{x:x-1,y:40,width:1,height:1,mask:15,count:1}]);
  for(const [x,y] of [[60,29],[64,27],[67,26]]) result.push([`gate-${x}`,2,{x,y,width:1,height:1,mask:1,count:7}]);
  for(const [x,y] of [[10,20],[20,20],[30,20],[10,24]]) result.push([`interact-${x}`,2,{x,y,width:1,height:1,mask:15,count:1,flags:1}]);
  result.push(['ticks-59',3,{count:59}],['ticks-boundary',3,{count:1}],['ticks-120',3,{count:120}]);
  return result;
}
function owner(js, wasm) {
  const value = createFileWorldOwner(js,wasm);
  value.session=null;
  value.command=async(kind,fields={},points=[])=>{
    const words=[2,kind,...Array(14).fill(0)], indexes={x:2,y:3,width:4,height:5,stride:6,mask:7,count:8,source:11,flags:12};
    for(const [key,field] of Object.entries(fields)) words[indexes[key]]=field;
    words[10]=points.length;
    return value.bridge.command(value.session,JSON.stringify(words),JSON.stringify(points.flat()));
  };
  return value;
}
async function compare(pair,label,kind,fields={},points=[],expectWarm=false) {
  const results=[];
  for(const current of pair) results.push(await current.command(kind,fields,points));
  assert.deepEqual(Buffer.from(results[0].records),Buffer.from(results[1].records),label);
  if(kind===10) for(const value of results) {
    assert.equal((value.reserved&2)!==0,fields.mask===1,`${label} actual optimization mode`);
    assert.equal((value.reserved&8)!==0,fields.mask===1,`${label} actual WireHead mode`);
  }
  assert.deepEqual(Array.from(results[0].stats).slice(2,15),Array.from(results[1].stats).slice(2,15),`${label} topology`);
  assert.deepEqual(Array.from(results[0].stats).slice(18),Array.from(results[1].stats).slice(18),`${label} work counters`);
  if(expectWarm) {
    assert.equal(results[1].diagnostics.sourceReadRequests-pair[1].lastReads.requests,1,`${label} probe count`);
    assert.equal(results[1].diagnostics.sourceReadBytes-pair[1].lastReads.bytes,1,`${label} probe length`);
  }
  for(let i=0;i<2;i++) pair[i].lastReads={requests:results[i].diagnostics.sourceReadRequests,bytes:results[i].diagnostics.sourceReadBytes};
  records.push({case:label,records:results[0].records.length/16,sha256:sha(results[0].records),
    counters:Array.from(results[0].stats).slice(18),candidateDiagnostics:results[1].diagnostics});
  return results;
}
async function run() {
  for(const mode of [0,1]) {
    const pair=[owner(aJs,aWasm),owner(bJs,bWasm)];
    try {
      for(const current of pair) current.session=(await current.bridge.openSource(await fs.openAsBlob(path.join(fixtureDirectory,'original.wld')))).session;
      await compare(pair,`mode${mode}`,10,{mask:mode});
      for(const shape of shapes) {
        const {name,...fields}=shape;
        for(const [index,flags] of [0,2,0,2].entries()) await compare(pair,`mode${mode}/${name}/${index}`,1,{...fields,flags},[],index>0&&fields.width*fields.height<=4096);
      }
      let previous=(await compare(pair,`mode${mode}/scene`,1,scene))[0].records;
      const changed=new Set();
      for(const [name,kind,fields] of operations()) {
        await compare(pair,`mode${mode}/${name}`,kind,fields);
        const value=(await compare(pair,`mode${mode}/${name}/warm`,1,scene,[],true))[0].records;
        const a=rows(previous),b=rows(value);
        for(let i=0;i<a.length;i++) if(a[i].some((v,j)=>v!==b[i][j])) changed.add(a[i][2]&65535);
        previous=value;
      }
      const required=[...Array.from({length:14},(_,i)=>255+i),4,33,49,174,372,646,419,420,421,422,132,136,144,411,42,93,130,131,1,445];
      assert.ok(required.every(value=>changed.has(value)),`mode${mode}: unexercised live branch`);
      await compare(pair,`mode${mode}/write-lamps`,5,{},[[28,10,1,0],[63,29,0,0],[70,27,1,0]]);
      const before=(await compare(pair,`mode${mode}/write-lamps/warm`,1,scene,[],true))[0].records;
      const saved=await compare(pair,`mode${mode}/save`,6,{source:3});
      const bytes=await Promise.all(saved.map(async value=>Buffer.from(await value.worldSource.blob.arrayBuffer())));
      assert.deepEqual(bytes[0],bytes[1],`mode${mode} byte-exact save`);
      records.push({case:`mode${mode}/save-bytes`,sha256:sha(bytes[0]),bytes:bytes[0].length});
      for(let i=0;i<2;i++) {
        await pair[i].bridge.close(pair[i].session);
        pair[i].session=(await pair[i].bridge.openSource(new Blob([bytes[i]]))).session;
        await pair[i].bridge.releaseSource(saved[i].worldSource.token);
      }
      await compare(pair,`mode${mode}/reopen/restore-mode`,10,{mask:mode});
      const reopened=(await compare(pair,`mode${mode}/reopen`,1,scene))[0].records;
      assert.deepEqual(rows(reopened),rows(before).map(([x,y,c,f])=>[x,y,c,(c&65535)===144?f&65535:f]));
      await compare(pair,`mode${mode}/reopen/warm`,1,scene,[],true);
      await compare(pair,`mode${mode}/continue`,2,{x:67,y:26,width:1,height:1,mask:1,count:11});
      await compare(pair,`mode${mode}/continue/warm`,1,scene,[],true);
    } finally {
      for(const current of pair) {if(current.session!==null) await current.bridge.close(current.session);assert.equal(current.openFiles,0);current.cleanup();}
    }
  }
  for(const mode of [0,1]) for(const fault of ['read','short','cancel']) {
    const current=owner(bJs,bWasm);
    let active=false, requested=[];
    const injected=new Error('actual warm source read failure');
    const source=new class extends Blob {
      slice(start,end) {
        if(active) {
          requested.push(end-start);
          if(fault==='read') throw injected;
          if(fault==='short') return new Blob([]);
          if(fault==='cancel') current.bridge.cancelOperation();
        }
        return super.slice(start,end);
      }
    }([fs.readFileSync(path.join(fixtureDirectory,'original.wld'))]);
    try {
      current.session=(await current.bridge.openSource(source)).session;
      const selected=await current.command(10,{mask:mode});
      assert.equal((selected.reserved&2)!==0,mode===1);
      assert.equal((selected.reserved&8)!==0,mode===1);
      const cold=await current.command(1,scene),warm=await current.command(1,scene);
      assert.deepEqual(Buffer.from(cold.records),Buffer.from(warm.records));
      active=true;
      await assert.rejects(current.command(1,scene),error=>{
        if(fault==='read') return error===injected;
        if(fault==='short') return error.message==='Truncated circuit input';
        return error.code==='CIRCUIT_CANCELLED';
      });
      assert.deepEqual(requested,[1]);
      active=false;
      const recovered=await current.command(1,scene);
      assert.deepEqual(Buffer.from(recovered.records),Buffer.from(cold.records));
      records.push({case:`mode${mode}/actual-warm-probe/${fault}`,requestedLengths:requested,recoveredSha256:sha(recovered.records)});
    } finally {if(current.session!==null) await current.bridge.close(current.session);assert.equal(current.openFiles,0);current.cleanup();}
  }
}
run().then(()=>{report.status='passed';}).catch(error=>{report.status='failed';report.error=String(error.stack||error);process.exitCode=1;}).finally(()=>{
  fs.writeFileSync(output,JSON.stringify(report,null,2)+'\n');
  console.log(JSON.stringify({status:report.status,records:records.length,output,error:report.error}));
});
