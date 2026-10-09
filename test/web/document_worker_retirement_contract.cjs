// Lightweight protocol tests: no browser, WASM, file input, or large allocation.
'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const rpcSource = fs.readFileSync(require.resolve('../../web/terra_worker_rpc.js'), 'utf8');

function harness(timeoutMs = 1000) {
  // Deterministic event-loop turns: timeout(0) retirement is advanced explicitly,
  // without racing sleeps against worker messages or request timeouts.
  const workers = [], timers = new Map(); let timerSequence = 0;
  const context = vm.createContext({TextEncoder, Uint8Array, Blob,
    setTimeout(fn, delay) { const id = ++timerSequence; timers.set(id, {fn,delay}); return id; },
    clearTimeout(id) { timers.delete(id); },
  });
  vm.runInContext(rpcSource, context);
  const {createClient} = context.TerraWorkerRPC;
  const idleTimers = () => [...timers.entries()].filter(([,t]) => t.delay === 0);
  const flushIdle = () => { for (const [id,timer] of idleTimers()) { timers.delete(id); timer.fn(); } };
  const client = createClient('document', {timeoutMs, createWorker() {
    const worker = {
      sent:[], terminated:0, nextNative:7,
      postMessage(data) { this.sent.push(data); },
      terminate() { this.terminated++; },
    };
    workers.push(worker); return worker;
  }});
  function reply(worker, request, value, error, transfer = []) {
    const data = structuredClone({id:request.id, generation:request.generation,
      ok:!error, ...(error ? {error} : {value})}, {transfer});
    worker.onmessage?.({data});
  }
  async function open(kind = 'wld') {
    const pending = client.open(new Uint8Array([1]), kind), worker = workers.at(-1);
    reply(worker, worker.sent.at(-1), JSON.stringify({handle:worker.nextNative++, kind, metadata:{}}));
    return JSON.parse(await pending).handle;
  }
  async function close(id) {
    const pending = client.close(id), worker = workers.at(-1);
    reply(worker, worker.sent.at(-1)); await pending; flushIdle();
  }
  return {client, workers, reply, open, close, flushIdle, idleTimers};
}

(async () => {
  const h = harness(); let oldHandle = 0, oldGeneration = 0, oldRequest = 0;
  for (let cycle = 0; cycle < 8; cycle++) {
    const id = await h.open(), worker = h.workers.at(-1), late = worker.onmessage;
    assert.ok(id > oldHandle); assert.ok(worker.sent[0].generation > oldGeneration);
    assert.ok(worker.sent[0].id > oldRequest);
    const closing = h.client.close(id), duplicate = h.client.close(id);
    assert.equal(duplicate, closing, 'Concurrent close must await the same ACK');
    assert.equal(worker.sent.filter(r => r.method === 'close').length, 1);
    assert.equal(worker.terminated, 0, 'Submitting close is not a cleanup ACK');
    let resumed = false;
    closing.then(() => { resumed = true; assert.equal(worker.terminated, 0); });
    h.reply(worker, worker.sent.at(-1));
    assert.equal(resumed, false); assert.equal(worker.terminated, 0);
    await closing;
    assert.equal(h.idleTimers().length, 1); h.flushIdle(); assert.equal(worker.terminated, 1);
    late({data:{id:worker.sent[0].id, generation:worker.sent[0].generation, ok:true, value:'{"handle":7}'}});
    await h.client.close(id); assert.equal(h.workers.length, cycle + 1, 'Stale close must not create a worker');
    await assert.rejects(h.client.inspect(id), {code:'STALE_HANDLE'});
    oldHandle = id; oldGeneration = worker.sent[0].generation; oldRequest = worker.sent.at(-1).id;
  }

  // A shared WLD/PLR owner may retire only after both document handles close.
  const shared = harness(), world = await shared.open(), player = await shared.open('plr');
  const sw = shared.workers[0]; await shared.close(world);
  assert.equal(sw.terminated, 0, 'A live player keeps the shared document owner');
  const inspection = shared.client.inspect(player);
  shared.reply(sw, sw.sent.at(-1), '{"player":true}'); assert.equal(await inspection, '{"player":true}');
  await shared.close(player); assert.equal(sw.terminated, 1);

  // A save must finish and transfer its output before a queued last close.
  const saved = harness(), savedId = await saved.open(), savedWorker = saved.workers[0];
  const saving = saved.client.save(savedId), saveRequest = savedWorker.sent.at(-1);
  const afterSave = saved.client.close(savedId); assert.equal(savedWorker.sent.length, 2);
  const savedBytes = new Uint8Array([3,4,5]);
  saved.reply(savedWorker, saveRequest, savedBytes, null, [savedBytes.buffer]);
  assert.equal(savedBytes.byteLength, 0, 'The worker no longer owns transferred output');
  const output = await saving; assert.equal(savedWorker.terminated, 0);
  saved.reply(savedWorker, savedWorker.sent.at(-1)); await afterSave;
  assert.equal(savedWorker.terminated, 0); saved.flushIdle();
  assert.equal(savedWorker.terminated, 1); assert.deepEqual([...output], [3,4,5]);

  // A reopen submitted before close ACK retains the existing shared owner.
  const queued = harness(), queuedId = await queued.open(), qw = queued.workers[0];
  const closing = queued.client.close(queuedId), closeRequest = qw.sent.at(-1);
  const reopening = queued.client.open(new Uint8Array([2]), 'wld');
  queued.reply(qw, closeRequest); await closing; assert.equal(qw.terminated, 0);
  assert.equal(qw.sent.at(-1).method, 'open');
  queued.reply(qw, qw.sent.at(-1), '{"handle":8,"kind":"wld","metadata":{}}');
  const reopened = JSON.parse(await reopening).handle; assert.ok(reopened > queuedId);
  await queued.close(reopened); assert.equal(qw.terminated, 1);

  // Projection is handle-free, but queued work or other documents still veto
  // retirement. Its completed transferred output survives owner termination.
  const projection = harness(), projectionId = await projection.open(), pw = projection.workers[0];
  const projectionClose = projection.client.close(projectionId), pc = pw.sent.at(-1);
  const projecting = projection.client.projectPlayer('{}');
  projection.reply(pw, pc); await projectionClose; assert.equal(pw.terminated, 0);
  const projectedBytes = new Uint8Array([6,7]);
  projection.reply(pw, pw.sent.at(-1), projectedBytes, null, [projectedBytes.buffer]);
  assert.deepEqual([...await projecting], [6,7]); projection.flushIdle(); assert.equal(pw.terminated, 1);
  const ownerlessProjection = projection.client.projectPlayer('{}'), fresh = projection.workers.at(-1);
  assert.notEqual(fresh, pw, 'A later projection lazily creates another owner');
  projection.reply(fresh, fresh.sent.at(-1), new Uint8Array([8]));
  assert.deepEqual([...await ownerlessProjection], [8]); projection.flushIdle(); assert.equal(fresh.terminated, 1);
  const active = harness(), activeId = await active.open('plr'), aw = active.workers[0];
  const activeProjection = active.client.projectPlayer('{}');
  active.reply(aw, aw.sent.at(-1), new Uint8Array([9])); await activeProjection;
  assert.equal(aw.terminated, 0, 'Projection cannot release another live document'); await active.close(activeId);

  // A rejected close is not an ACK and does not make subsequent close lie.
  const retry = harness(), retryId = await retry.open(), rw = retry.workers[0];
  const failedClose = retry.client.close(retryId), rejected = assert.rejects(failedClose, /close failed/);
  assert.equal(retry.client.close(retryId), failedClose);
  assert.equal(retry.idleTimers().length, 0, 'An unacknowledged close cannot schedule retirement');
  retry.reply(rw, rw.sent.at(-1), null, 'close failed'); await rejected;
  assert.equal(retry.idleTimers().length, 0, 'A rejected close cannot schedule retirement');
  retry.flushIdle();
  assert.equal(rw.terminated, 0); await assert.rejects(retry.client.inspect(retryId), {code:'STALE_HANDLE'});
  await retry.close(retryId); assert.equal(rw.sent.filter(r => r.method === 'close').length, 2);
  assert.equal(rw.terminated, 1);

  // A projection rejection acknowledges its completion. With no handles or
  // output leases, releasing this owner also covers failed native cleanup.
  const failed = harness(), failedId = await failed.open(), fw = failed.workers[0];
  const beforeFailure = failed.client.close(failedId), fc = fw.sent.at(-1);
  const failingProjection = failed.client.projectPlayer('{}'), failedProjection = assert.rejects(failingProjection, {code:'WORKER_ENGINE', message:'projection failed'});
  failed.reply(fw, fc); await beforeFailure;
  failed.reply(fw, fw.sent.at(-1), null, 'projection failed'); await failedProjection;
  failed.flushIdle();
  assert.equal(fw.terminated, 1); await failed.client.dispose(); assert.equal(fw.terminated, 1);
  const failedWithDocument = harness(), keptId = await failedWithDocument.open('plr'), keptWorker = failedWithDocument.workers[0];
  const keptFailure = failedWithDocument.client.projectPlayer('{}'), keptRejected = assert.rejects(keptFailure, /projection failed/);
  failedWithDocument.reply(keptWorker, keptWorker.sent.at(-1), null, 'projection failed'); await keptRejected;
  assert.equal(keptWorker.terminated, 0, 'A failed projection cannot retire another live document');
  const keptInspect = failedWithDocument.client.inspect(keptId);
  failedWithDocument.reply(keptWorker, keptWorker.sent.at(-1), '{"stillOpen":true}');
  assert.equal(await keptInspect, '{"stillOpen":true}'); await failedWithDocument.close(keptId);
  const failedWithQueue = harness(), noHandleFailure = failedWithQueue.client.projectPlayer('{}'), qfw = failedWithQueue.workers[0], noHandleRequest = qfw.sent.at(-1);
  const noHandleRejected = assert.rejects(noHandleFailure, /projection failed/);
  const queuedOpen = failedWithQueue.client.open(new Uint8Array([2]), 'wld');
  failedWithQueue.reply(qfw, noHandleRequest, null, 'projection failed'); await noHandleRejected;
  assert.equal(qfw.terminated, 0, 'Queued work prevents retirement after projection rejection');
  failedWithQueue.reply(qfw, qfw.sent.at(-1), '{"handle":7,"kind":"wld","metadata":{}}');
  await failedWithQueue.close(JSON.parse(await queuedOpen).handle); assert.equal(qfw.terminated, 1);

  // Retirement invalidates old public/native identities even while a new
  // worker has reused its own native handle. Delayed replies cannot resolve it.
  const stale = harness(), first = await stale.open(), firstWorker = stale.workers[0], late = firstWorker.onmessage;
  await stale.close(first); const second = await stale.open(), secondWorker = stale.workers[1];
  const pendingInspect = stale.client.inspect(second), inspectRequest = secondWorker.sent.at(-1);
  late({data:{id:inspectRequest.id, generation:firstWorker.sent[0].generation, ok:true, value:'{"wrong":true}'}});
  await stale.client.close(first); assert.equal(secondWorker.sent.at(-1), inspectRequest);
  stale.reply(secondWorker, inspectRequest, '{"fresh":true}'); assert.equal(await pendingInspect, '{"fresh":true}');
  await stale.close(second);

  // A caller resuming from close ACK can hand off immediately. A canceled
  // retirement callback arriving late cannot affect its replacement request.
  const handoff = harness(), hid = await handoff.open(), hw = handoff.workers[0];
  const hclose = handoff.client.close(hid); handoff.reply(hw, hw.sent.at(-1)); await hclose;
  const obsoleteIdle = handoff.idleTimers()[0][1].fn;
  const hopen = handoff.client.open(new Uint8Array([2]), 'wld');
  assert.equal(handoff.idleTimers().length, 0); obsoleteIdle(); assert.equal(hw.terminated, 0);
  handoff.reply(hw, hw.sent.at(-1), '{"handle":8,"kind":"wld","metadata":{}}');
  const handed = JSON.parse(await hopen).handle;
  assert.equal(handoff.workers.length, 1, 'Immediate await-close/open reuses its owner');
  const newClose = handoff.client.close(handed); handoff.reply(hw, hw.sent.at(-1)); await newClose;
  const newerTimer = handoff.idleTimers()[0][0]; obsoleteIdle();
  assert.equal(handoff.idleTimers()[0][0], newerTimer, 'An old callback cannot clear a newer retirement check');
  handoff.flushIdle(); assert.equal(hw.terminated, 1);

  // A failed immediate open/create handoff canceled the old idle timer. Its
  // settled rejection must arm a fresh check if it left the owner empty.
  for (const method of ['open','createPlayer']) {
    const failedHandoff = harness(), fid = await failedHandoff.open(), fw = failedHandoff.workers[0];
    const fclosing = failedHandoff.client.close(fid); failedHandoff.reply(fw, fw.sent.at(-1)); await fclosing;
    const canceledTimer = failedHandoff.idleTimers()[0][1].fn;
    const request = method === 'open' ? failedHandoff.client.open(new Uint8Array([2]), 'wld') : failedHandoff.client.createPlayer('failed');
    const rejected = assert.rejects(request, {code:'WORKER_ENGINE', message:'handoff failed'});
    assert.equal(failedHandoff.idleTimers().length, 0); canceledTimer(); assert.equal(fw.terminated, 0);
    failedHandoff.reply(fw, fw.sent.at(-1), null, 'handoff failed'); await rejected;
    assert.equal(failedHandoff.idleTimers().length, 1); failedHandoff.flushIdle(); assert.equal(fw.terminated, 1);
    const recovered = await failedHandoff.open(); assert.equal(failedHandoff.workers.length, 2);
    canceledTimer(); assert.equal(failedHandoff.workers[1].terminated, 0); await failedHandoff.close(recovered);

    const retained = harness(), liveId = await retained.open('plr'), liveWorker = retained.workers[0];
    const failedRequest = method === 'open' ? retained.client.open(new Uint8Array([2]), 'wld') : retained.client.createPlayer('failed');
    const retainedRejected = assert.rejects(failedRequest, /handoff failed/);
    retained.reply(liveWorker, liveWorker.sent.at(-1), null, 'handoff failed'); await retainedRejected;
    assert.equal(retained.idleTimers().length, 0); retained.flushIdle(); assert.equal(liveWorker.terminated, 0);
    const inspection = retained.client.inspect(liveId); retained.reply(liveWorker, liveWorker.sent.at(-1), '{"live":true}');
    assert.equal(await inspection, '{"live":true}'); await retained.close(liveId);

    const queuedFailure = harness();
    const first = method === 'open' ? queuedFailure.client.open(new Uint8Array([2]), 'wld') : queuedFailure.client.createPlayer('failed');
    const qworker = queuedFailure.workers[0], firstRequest = qworker.sent.at(-1), firstRejected = assert.rejects(first, /handoff failed/);
    const next = queuedFailure.client.open(new Uint8Array([3]), 'plr');
    queuedFailure.reply(qworker, firstRequest, null, 'handoff failed'); await firstRejected;
    assert.equal(queuedFailure.idleTimers().length, 0); assert.equal(qworker.terminated, 0);
    queuedFailure.reply(qworker, qworker.sent.at(-1), '{"handle":7,"kind":"plr","metadata":{}}');
    await queuedFailure.close(JSON.parse(await next).handle);
  }

  // A projection submitted during the idle turn cancels retirement while it
  // remains active, even before its success/failure response is available.
  const interrupted = harness(), iid = await interrupted.open(), iw = interrupted.workers[0];
  const iclose = interrupted.client.close(iid); interrupted.reply(iw, iw.sent.at(-1)); await iclose;
  const oldIdle = interrupted.idleTimers()[0][1].fn;
  const iprojection = interrupted.client.projectPlayer('{}'); assert.equal(interrupted.idleTimers().length, 0);
  oldIdle(); assert.equal(iw.terminated, 0);
  interrupted.reply(iw, iw.sent.at(-1), new Uint8Array([1])); await iprojection;
  interrupted.flushIdle(); assert.equal(iw.terminated, 1);

  // Owner-wide teardown clears a scheduled timer; an already queued callback
  // from that generation cannot retire a newly created owner.
  for (const method of ['dispose','cancel','reset']) {
    const cancelled = harness(), cid = await cancelled.open(), cw = cancelled.workers[0];
    const cclose = cancelled.client.close(cid); cancelled.reply(cw, cw.sent.at(-1)); await cclose;
    const lateIdle = cancelled.idleTimers()[0][1].fn;
    await cancelled.client[method](); assert.equal(cancelled.idleTimers().length, 0); assert.equal(cw.terminated, 1);
    const next = await cancelled.open(), nextWorker = cancelled.workers[1];
    lateIdle(); assert.equal(nextWorker.terminated, 0); await cancelled.close(next);
  }

  const independent = harness(), independentId = await independent.open();
  const other = harness(), otherId = await other.open(); await independent.close(independentId);
  assert.equal(other.workers[0].terminated, 0, 'Other owners remain untouched'); await other.close(otherId);
  console.log('PASS: deterministic document idle retirement, shared ownership, ACK/close retry, immediate handoff, queued requests, late timers, teardown cleanup, output transfer and stale generations');
})().catch(error => { console.error(error); process.exitCode = 1; });
