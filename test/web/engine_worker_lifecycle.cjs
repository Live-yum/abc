// Lightweight protocol/lifecycle contracts; no WASM or private save data.
'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const {createClient, installHost} = require('../../web/terra_worker_rpc.js');
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
function harness(owner, bridge, timeoutMs = 1000) {
  const workers = [];
  const client = createClient(owner, {timeoutMs, createWorker() {
    const worker = {sent:[], terminated:false};
    const scope = {postMessage(data, transfer) {
      const copy = structuredClone(data, {transfer});
      queueMicrotask(() => worker.onmessage?.({data:copy}));
    }};
    installHost(owner, bridge, scope);
    worker.postMessage = (data, transfer) => {
      const copy = structuredClone(data, {transfer}); worker.sent.push(copy);
      queueMicrotask(() => { if (!worker.terminated) scope.onmessage({data:copy}); });
    };
    worker.terminate = () => { worker.terminated = true; };
    workers.push(worker); return worker;
  }});
  return {client, workers};
}
(async () => {
  let release, calls = 0, input;
  const h = harness('document', {
    open: async bytes => { input = bytes; return JSON.stringify({handle:1,kind:'wld',metadata:{}}); },
    inspect: async () => '{"valid":true}',
    save: async () => new Uint8Array([8,9]),
    mutate: async () => { calls++; await new Promise(resolve => { release = resolve; }); },
    close: async () => {},
  });
  const original = new Uint8Array([0,1,2,3]), view = original.subarray(1,3);
  const opening = h.client.open(view, 'wld'); view[0] = 77;
  const first = JSON.parse(await opening).handle;
  assert.deepEqual([...input], [1,2], 'Input must be snapshotted before dispatch');
  assert.deepEqual([...original], [0,77,2,3], 'The source buffer must never be transferred');
  assert.deepEqual([...await h.client.save(first)], [8,9]);
  const mutation = h.client.mutate(first, 'header_patch', '{}');
  const queued = h.client.inspect(first);
  const losses = [assert.rejects(mutation, {code:'COMPUTATION_OWNER_LOST'}), assert.rejects(queued, {code:'COMPUTATION_OWNER_LOST'})];
  await sleep(0); const old = h.workers[0], delayed = old.onmessage;
  await h.client.cancel(); await Promise.all(losses);
  assert.equal(old.terminated, true);
  assert.equal(calls, 1);
  release();
  await assert.rejects(h.client.inspect(first), {code:'STALE_HANDLE'});
  await h.client.close(first); // Stale cleanup remains harmless after owner loss.
  const second = JSON.parse(await h.client.open(new Uint8Array([4]), 'wld')).handle;
  assert.notEqual(second, first, 'Recovered owners must never reuse a public handle');
  delayed({data:{id:999,generation:1,ok:true,value:'stale'}});
  await h.client.close(first); // Cannot close a new owner's reused native handle.
  assert.equal(await h.client.inspect(second), '{"valid":true}');
  assert.equal(calls, 1, 'An interrupted mutation must never be replayed');
  const closing = h.client.close(second);
  await assert.rejects(h.client.inspect(second), {code:'STALE_HANDLE'});
  await closing;
  await assert.rejects(h.client.inspect(second), {code:'STALE_HANDLE'});
  await h.client.dispose();

  const timed = harness('document', {open:async () => new Promise(()=>{})}, 15);
  await assert.rejects(timed.client.open(new Uint8Array([1]), 'wld'), {code:'COMPUTATION_OWNER_LOST'});
  assert.equal(timed.workers[0].terminated, true);
  const queuedHost = harness('document', {projectPlayer:async()=>new Promise(()=>{})});
  const requests = Array.from({length:16}, () => queuedHost.client.projectPlayer('{}'));
  const rejects = requests.map(request => assert.rejects(request, {code:'COMPUTATION_OWNER_LOST'}));
  await assert.rejects(queuedHost.client.projectPlayer('{}'), {code:'WORKER_LIMIT'});
  assert.equal(queuedHost.workers[0].sent.length, 1, 'Only one request may execute per owner');
  await queuedHost.client.reset(); await Promise.all(rejects);
  await assert.rejects(h.client.open(new Uint8Array([1]), 'zip'), {code:'WORKER_INPUT'});
  await assert.rejects(h.client.mutate(1, '__proto__', '{}'), {code:'WORKER_INPUT'});
  await assert.rejects(h.client.projectPlayer('x'.repeat(4*1024*1024+1)), {code:'WORKER_INPUT'});

  let hostCalls = 0; const responses = [];
  const scope = {postMessage: data => responses.push(data)};
  installHost('document', {inspect:async()=>{hostCalls++;return '{}';}}, scope);
  scope.onmessage({data:{id:1,generation:1,method:'constructor',args:[]}});
  scope.onmessage({data:{id:2,generation:1,method:'inspect',args:[1]}});
  scope.onmessage({data:{id:2,generation:1,method:'inspect',args:[1]}});
  scope.onmessage({data:{id:3,generation:2,method:'inspect',args:[1]}});
  await sleep(0);
  assert.equal(hostCalls, 1, 'Unknown methods, replayed IDs, and stale generations must not execute');
  assert.equal(responses.filter(r=>r.ok===false).length, 3);

  let nativeDocument = 0;
  const bounded = harness('document', {createPlayer:async()=>JSON.stringify({handle:++nativeDocument,kind:'plr',metadata:{}}),close:async()=>{}});
  const boundedHandles=[];
  for(let i=0;i<32;i++) boundedHandles.push(JSON.parse(await bounded.client.createPlayer('bounded')).handle);
  await assert.rejects(bounded.client.createPlayer('overflow'), {code:'WORKER_LIMIT'});
  await bounded.client.close(boundedHandles[0]);
  assert.ok(JSON.parse(await bounded.client.createPlayer('replacement')).handle > boundedHandles.at(-1));
  await bounded.client.dispose();

  const tcw = harness('worldCircuit', {open:async()=>({session:1,stats:[2,...Array(23).fill(0)],resultKind:0,resultCount:0,reserved:0,records:new Uint8Array()}), close:async()=>{}});
  const a = (await tcw.client.open(new Uint8Array([1]))).session;
  await tcw.client.close(a);
  const b = (await tcw.client.open(new Uint8Array([1]))).session;
  assert.notEqual(a,b, 'Native TCW handle reuse cannot alias closed public handles');
  await assert.rejects(tcw.client.command(a, '[]', '[]'), {code:'STALE_HANDLE'});
  const dying = tcw.client.close(b); const rejected = assert.rejects(dying, {code:'COMPUTATION_OWNER_LOST'});
  tcw.workers.at(-1).onerror({message:'unexpected worker exit'}); await rejected;

  let finishStream, finishCommand, releasedSource, streamCancelled = false;
  const streamResult = () => ({session:7,stats:[2,...Array(23).fill(0)],resultKind:0,resultCount:0,reserved:0,records:new Uint8Array()});
  const sourceBlob = new Blob([new Uint8Array([7,8,9])]);
  const streamed = harness('worldCircuit', {
    openSource:async source => { assert.ok(source instanceof Blob); assert.equal(source.size,3); await new Promise(resolve => { finishStream=resolve; }); return streamResult(); },
    progress:async () => ({stage:'compile',phase:1,completed:2,total:3}),
    cancelOperation:async () => { streamCancelled=true; finishCommand?.(); },
    command:async (_,words) => { if (words==='wait') await new Promise(resolve => { finishCommand=resolve; }); return {...streamResult(),worldSource:{blob:sourceBlob,size:3,name:'staged.wld',token:11}}; },
    computerFrame:async () => ({clock:{...streamResult(),resultKind:2},display:{...streamResult(),resultKind:9},displayError:null,hostStagesUs:{commandWallUs:1}}),
    releaseSource:async token => { releasedSource=token; },
    close:async()=>{},
  });
  const sourceOpening=streamed.client.openSource(sourceBlob);
  await sleep(0);
  assert.equal((await streamed.client.progress()).stage,'compile','Progress must bypass the active import');
  finishStream();const streamedId=(await sourceOpening).session;
  const running=streamed.client.command(streamedId,'wait','[]');
  const afterRunning=streamed.client.command(streamedId,'next','[]');
  await sleep(0);await streamed.client.cancelOperation();assert.equal(streamCancelled,true);
  const firstOutput=await running,secondOutput=await afterRunning;
  for(const output of [firstOutput,secondOutput]) {
    assert.ok(Number.isFinite(output.hostStagesUs.rpcWallUs) && output.hostStagesUs.rpcWallUs >= 0);
    assert.ok(Number.isFinite(output.hostStagesUs.rpcQueueUs) && output.hostStagesUs.rpcQueueUs >= 0);
    assert.ok(output.hostStagesUs.rpcWallUs >= output.hostStagesUs.rpcQueueUs);
  }
  assert.notEqual(firstOutput.worldSource.token,secondOutput.worldSource.token,'Public output identity cannot alias a native token');
  const combined=await streamed.client.computerFrame(streamedId,'clock','pixels');
  assert.equal(combined.clock.session,streamedId);assert.equal(combined.display.session,streamedId);
  assert.equal(combined.hostStagesUs.commandWallUs,1);assert.ok(combined.hostStagesUs.rpcWallUs>=0);
  assert.equal(streamed.workers[0].sent.at(-1).method,'computerFrame');
  await streamed.client.close(streamedId);await streamed.client.releaseSource(firstOutput.worldSource.token);assert.equal(releasedSource,11);
  await streamed.client.dispose();await streamed.client.releaseSource(secondOutput.worldSource.token);

  // Missing Worker support must fail; browser entrypoints cannot load heavy WASM.
  const browser = vm.createContext({document:{baseURI:'http://test/'}, TextEncoder, TextDecoder, Uint8Array, setTimeout, clearTimeout});
  for (const file of ['terra_worker_rpc.js','terra_engine.js','terra_world_circuit.js','terra_circuit.js']) vm.runInContext(fs.readFileSync(require.resolve('../../web/'+file),'utf8'), browser);
  await assert.rejects(browser.terraForge.createPlayer('test'), {code:'COMPUTATION_OWNER_LOST'});
  assert.equal(typeof browser.TerraWorldWasmWeb, 'undefined');
  console.log('PASS: worker lifecycle, cancellation, source snapshots, queues, timeouts, generations, non-replayed mutations, stale handles, method bounds, and no browser main-thread fallback');
})().catch(error=>{console.error(error);process.exitCode=1;});
