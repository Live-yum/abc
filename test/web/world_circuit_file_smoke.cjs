// Opt-in actual WASM file-backed smoke. No fixture is copied into product files.
// Usage: node test/web/world_circuit_file_smoke.cjs world.js world.wasm source.wld [source.twld] [--save]
// The Node disk adapter verifies host ownership; it is not browser OPFS/FPS QA.
'use strict';
const fs=require('node:fs'),assert=require('node:assert/strict');
const {createFileWorldOwner}=require('./helpers/world_file_host.cjs');
(async()=>{
 const args=process.argv.slice(2),save=args.includes('--save'),files=args.filter(arg=>arg!=='--save');
 if(files.length<3||files.length>4)throw new Error('Expected world.js world.wasm source.wld [source.twld] [--save]');
 const [loader,wasm,wld,twld]=files;
 const owner=createFileWorldOwner(loader,wasm),bridge=owner.bridge;
 const source=await fs.openAsBlob(wld),sidecar=twld?await fs.openAsBlob(twld):null;
 const report={schema:'abc.world-file-wasm-smoke.v1',sourceBytes:source.size,twldBytes:sidecar?.size||0,runtime:process.version,measurement:'Node Wasm with ranged File/Blob input and random-access temp files; not browser FPS'};
 let id,saved;
 try {
  const before=performance.now(),opened=await bridge.openSource(source,sidecar);id=opened.session;report.openMs=performance.now()-before;report.sourceSha256=opened.sourceSha256;report.stats=opened.stats;report.openDiagnostics=opened.diagnostics;
  const query=[1,9,0,0,128,96,1,0,0,0,0,0,0,0,0,0],pixels=await bridge.command(id,JSON.stringify(query),'[]');assert.equal(pixels.resultKind,9);report.pixelQueryBytes=pixels.records.length;
  if(save){const start=performance.now();saved=await bridge.command(id,JSON.stringify([1,6,0,0,0,0,0,0,0,0,0,3,0,5,0,0]),'[]');report.saveMs=performance.now()-start;assert.equal(saved.world,null);assert.ok(saved.worldSource.blob instanceof Blob);if(sidecar)assert.ok(saved.twldSource.blob instanceof Blob);report.savedWorldBytes=saved.worldSource.size;report.savedTwldBytes=saved.twldSource?.size||0;}
  await bridge.close(id);id=null;
  if(saved){const reopened=await bridge.openSource(saved.worldSource.blob,saved.twldSource?.blob||null);id=reopened.session;assert.deepEqual(reopened.stats.slice(2,4),opened.stats.slice(2,4));report.reopenedStats=reopened.stats;await bridge.close(id);id=null;await bridge.releaseSource(saved.worldSource.token);if(saved.twldSource)await bridge.releaseSource(saved.twldSource.token);saved=null;}
  assert.equal(owner.openFiles,0);report.peakOpenFiles=owner.peakOpenFiles;const M=owner.module;report.processMemory=process.memoryUsage();report.nativeBytesAfterClose=typeof M._tx_native_heap_used==='function'?M._tx_native_heap_used():null;report.bridgeBytesAfterClose=typeof M._tx_bridge_heap_used==='function'?M._tx_bridge_heap_used():null;
  assert.equal(report.bridgeBytesAfterClose,0);assert.equal(report.nativeBytesAfterClose,0);report.status='passed';console.log(JSON.stringify(report,null,2));
 }finally{if(id)await bridge.close(id);if(saved){await bridge.releaseSource(saved.worldSource.token);if(saved.twldSource)await bridge.releaseSource(saved.twldSource.token);}owner.cleanup();}
})().catch(error=>{console.error(error);process.exitCode=1;});
