// Lightweight protocol tests: no browser, WASM, or private world files.
'use strict';
const assert = require('node:assert/strict');
const {createClient} = require('../../web/terra_worker_rpc.js');
const tick = () => new Promise(resolve => setImmediate(resolve));
const progress = {stage:'ready',phase:0,completed:0,total:0};
const result = () => ({session:7,stats:[2,...Array(23).fill(0)],resultKind:0,resultCount:0,reserved:0,records:new Uint8Array()});
function harness(owner = 'worldCircuit', timeoutMs = 1000) {
 const workers = [];
 const client = createClient(owner, {timeoutMs, createWorker() {
  const worker = {sent:[], terminated:0, postMessage(data) { this.sent.push(data); }, terminate() { this.terminated++; }};
  workers.push(worker); return worker;
 }});
 const reply = (worker, request, value, error) => worker.onmessage?.({data:{id:request.id,generation:request.generation,control:request.control,ok:!error,...(error ? {error} : {value})}});
 async function open() { const pending = client.open(new Uint8Array([1]), ...(owner === 'document' ? ['wld'] : [])); const worker = workers.at(-1); reply(worker, worker.sent.at(-1), owner === 'document' ? '{"handle":7}' : result()); return owner === 'document' ? JSON.parse(await pending).handle : (await pending).session; }
 return {client, workers, reply, open};
}
async function close(h, id) { const pending = h.client.close(id), worker = h.workers.at(-1); h.reply(worker, worker.sent.at(-1)); await pending; }
(async () => {
 const h = harness(); let previousHandle = 0, previousRequest = 0, previousGeneration = 0;
 for (let i = 0; i < 8; i++) {
  const id = await h.open(), worker = h.workers.at(-1), stale = worker.onmessage;
  assert.ok(id > previousHandle); assert.ok(worker.sent[0].id > previousRequest); assert.ok(worker.sent[0].generation > previousGeneration);
  const closing = h.client.close(id); let continuation = false;
  closing.then(() => { continuation = true; assert.equal(worker.terminated, 1, 'Retirement must precede the awaiting caller'); });
  h.reply(worker, worker.sent.at(-1));
  assert.equal(continuation, false); assert.equal(worker.terminated, 1);
  await closing;
  stale({data:{id:worker.sent[0].id,generation:worker.sent[0].generation,ok:true,value:result()}});
  await h.client.close(id); await assert.rejects(h.client.command(id,'[]','[]'), {code:'STALE_HANDLE'});
  previousHandle=id; previousRequest=worker.sent.at(-1).id; previousGeneration=worker.sent[0].generation;
 }
 await h.client.cleanup(); assert.equal(h.workers.length,8,'Local cleanup must not create an idle worker');

 const retained = harness(), id = await retained.open(), worker = retained.workers[0], tokens = [];
 for (let i=0;i<2;i++) {
  const pending=retained.client.command(id,'save','[]');
  retained.reply(worker,worker.sent.at(-1), {...result(),worldSource:{blob:new Blob(['abc']),size:3,name:'output.wld',token:i+1}});
  tokens.push((await pending).worldSource.token);
 }
 await close(retained,id); assert.equal(worker.terminated,0,'Output leases outlive close');
 let release=retained.client.releaseSource(tokens[0]); retained.reply(worker,worker.sent.at(-1)); await release;
 assert.equal(worker.terminated,0,'Every lease must be released');
 release=retained.client.releaseSource(tokens[1]); const failed=assert.rejects(release,/remove failed/); retained.reply(worker,worker.sent.at(-1),null,'remove failed'); await failed;
 assert.equal(worker.terminated,0,'Failed release retains the lease');
 release=retained.client.releaseSource(tokens[1]); retained.reply(worker,worker.sent.at(-1)); await release; assert.equal(worker.terminated,1);
 const nextId=await retained.open(); assert.ok(nextId>id); await retained.client.releaseSource(tokens[1]); assert.equal(retained.workers[1].terminated,0,'Stale release cannot arm retirement'); await close(retained,nextId);

 const retry=harness(), retryId=await retry.open(), retryWorker=retry.workers[0];
 const closing=retry.client.close(retryId), duplicate=retry.client.close(retryId); assert.equal(closing,duplicate,'Concurrent close callers share the remote completion');
 const failedClose=assert.rejects(closing,/close failed/); retry.reply(retryWorker,retryWorker.sent.at(-1),null,'close failed'); await failedClose;
 await assert.rejects(retry.client.command(retryId,'[]','[]'),{code:'STALE_HANDLE'});
 await assert.rejects(retry.client.open(new Uint8Array([2])),{code:'WORKER_STATE'});
 assert.equal(retryWorker.sent.filter(r=>r.method==='open').length,1,'Failed close cannot alias a reused native handle');
 await close(retry,retryId); assert.equal(retryWorker.sent.filter(r=>r.method==='close').length,2); assert.equal(retryWorker.terminated,1);

 const failedQueued=harness(), failedId=await failedQueued.open(), fw=failedQueued.workers[0];
 const failure=failedQueued.client.close(failedId), failureRequest=fw.sent.at(-1), queuedFailure=failedQueued.client.open(new Uint8Array([2]));
 const failures=[assert.rejects(failure,/close failed/),assert.rejects(queuedFailure,{code:'WORKER_STATE'})];
 failedQueued.reply(fw,failureRequest,null,'close failed');await Promise.all(failures);
 assert.equal(fw.sent.length,2,'A reopen queued behind failed close must not reach the bridge');await close(failedQueued,failedId);

 const controls=harness(), controlId=await controls.open(), cw=controls.workers[0];
 const polling=controls.client.progress(), poll=cw.sent.at(-1);
 await close(controls,controlId); assert.equal(cw.terminated,0,'Unacknowledged progress blocks retirement');
 controls.reply(cw,poll,progress); await polling; assert.equal(cw.terminated,1,'Acknowledged control rechecks an armed retirement');

 for (const timeout of [false,true]) {
  const blocked=harness('worldCircuit',timeout?20:1000), bid=await blocked.open(), bw=blocked.workers[0];
  const polling=blocked.client.progress(), poll=bw.sent.at(-1), rejected=assert.rejects(polling, timeout?{code:'WORKER_TIMEOUT'}:/progress failed/);
  if (!timeout) blocked.reply(bw,poll,null,'progress failed');
  await rejected; await close(blocked,bid); assert.equal(bw.terminated,0,'Rejected/timed-out control is not a drain acknowledgement');
  blocked.reply(bw,poll,progress); const cleanup=blocked.client.cleanup(); blocked.reply(bw,bw.sent.at(-1)); await cleanup;
  assert.equal(bw.terminated,0,'Late replies or subsequent cleanup cannot clear this generation veto');
  await blocked.client.dispose(); const fresh=await blocked.open(); await close(blocked,fresh); assert.equal(blocked.workers[1].terminated,1,'Veto belongs only to the lost generation');
 }

 const queued=harness(), qid=await queued.open(), qw=queued.workers[0];
 const qclose=queued.client.close(qid), closeRequest=qw.sent.at(-1), qopen=queued.client.open(new Uint8Array([2]));
 queued.reply(qw,closeRequest); await qclose; assert.equal(qw.terminated,0,'Already queued reopen prevents retirement');
 queued.reply(qw,qw.sent.at(-1),result()); const reopened=(await qopen).session;
 await close(queued,reopened); assert.equal(qw.terminated,1);

 // A new failed operation or cancellation must not inherit an older close arm.
 for (const method of ['open','cancelOperation']) {
  const disarmed=harness(), did=await disarmed.open(), dw=disarmed.workers[0];
  const pollFuture=disarmed.client.progress(), poll=dw.sent.at(-1);
  await close(disarmed,did); const work=method==='open'?disarmed.client.open(new Uint8Array([2])):disarmed.client.cancelOperation(), request=dw.sent.at(-1);
  const settled=method==='open'?assert.rejects(work,/import failed/):work;
  disarmed.reply(dw,request,null,method==='open'?'import failed':undefined); await settled;
  disarmed.reply(dw,poll,progress); await pollFuture; assert.equal(dw.terminated,0);
  const cleanup=disarmed.client.cleanup(); disarmed.reply(dw,dw.sent.at(-1)); await cleanup; assert.equal(dw.terminated,1,'Explicit no-handle cleanup can acknowledge a failed/cancelled import');
 }
 const independent=harness(), independentId=await independent.open();
 const other=harness(), otherId=await other.open(); await close(independent,independentId); assert.equal(other.workers[0].terminated,0); await close(other,otherId);
 const document=harness('document'), documentId=await document.open(); await close(document,documentId); assert.equal(document.workers[0].terminated,0,'Document owner lifecycle is unchanged'); await document.client.dispose();
 const traversal=harness('circuit'), traversalWork=traversal.client.propagate(1,1,'[]',0,0,0), tw=traversal.workers[0]; traversal.reply(tw,tw.sent.at(-1),'[]'); await traversalWork; assert.equal(tw.terminated,0); await traversal.client.dispose();
 await tick();
 console.log('PASS: exclusive world retirement, monotonic generations/IDs, stale events, leases, close retry, control acknowledgement/veto, queued reopen and other owners');
})().catch(error => { console.error(error); process.exitCode=1; });
