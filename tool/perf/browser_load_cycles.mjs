// Opt-in engineering interaction protocol. Only the launcher's owned Chrome is used.
import fs from 'node:fs';
import path from 'node:path';
import {Cdp, WORLD_BYTES, WORLD_SHA, VERIFIED_LABEL, enabledNode, validOpen} from './browser_load_driver.mjs';

export const CYCLE_LIMITS = Object.freeze({cycles: 3, baselineMs: 10000, readyIdleMs: 15000,
  afterCloseMs: 20000, pauseQuietMs: 2000, bootBatches: 40, bootBatchPulses: 128,
  liveObservationMs: 5000, inputWaitMs: 15000, stepWaitMs: 120000, loadWaitMs: 610000,
  globalSoftMs: 3240000, revealAttempts: 12, eventBytes: 64 * 1024 * 1024, screenshotBytes: 8 * 1024 * 1024});
export const DISPLAY_LABEL = '黑白显示器，显示实际物理像素状态';
export const PROGRAM_LABEL = 'ROM 程序：Pong (upstream RV32I).bin';
export const EMPTY_ROM_LABEL = '原始 ROM 为空。选择从地址 0 启动的 RV32I .bin 或十六进制 .txt。';

// Matches the production ComputerDisplayRegion.decode contract. This reads only
// one 49,152-byte physical monitor response; it never retains the response buffer.
// FNV-1a is a compact change fingerprint, not a cryptographic integrity assertion.
export function summarizeDisplay(result) {
  const bytes = result?.records;
  // PIXELS RESULT events carry records; the final READY/DONE envelope's
  // resultCount stays zero (terra_circuit_world.c:221-222). Match the product
  // ComputerDisplayRegion.decode contract: kind + actual record bytes/pixels.
  if (result?.resultKind !== 9 || !(bytes instanceof Uint8Array)
      || bytes.byteLength !== 49152) throw new Error('Physical monitor result shape mismatch');
  const data = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const seen = new Uint8Array(3072), pixels = new Uint8Array(3072);
  let recordHash = 2166136261;
  for (const byte of bytes) recordHash = Math.imul(recordHash ^ byte, 16777619) >>> 0;
  for (let at = 0; at < bytes.byteLength; at += 16) {
    const x = data.getUint32(at, true) - 6485, y = data.getUint32(at + 4, true) - 800;
    const tile = data.getUint32(at + 8, true) & 65535;
    const fx = data.getInt16(at + 12, true), fy = data.getInt16(at + 14, true);
    if (x < 0 || x >= 64 || y < 0 || y >= 48 || tile !== 445 || ![0, 18].includes(fx) || fy !== 0)
      throw new Error('Invalid physical monitor pixel');
    const index = y * 64 + x;
    if (seen[index]) throw new Error('Duplicate physical monitor pixel');
    seen[index] = 1; pixels[index] = fx === 18 ? 1 : 0;
  }
  let pixelHash = 2166136261, litCount = 0, interiorLitCount = 0, leftRows = 0, leftSum = 0;
  for (let i = 0; i < pixels.length; i++) {
    const bit = pixels[i], x = i % 64, y = Math.floor(i / 64);
    pixelHash = Math.imul(pixelHash ^ bit, 16777619) >>> 0;
    if (bit) { litCount++; if (x > 1 && x < 62) interiorLitCount++;
      if (x === 0) { leftRows++; leftSum += y; } }
  }
  return {width: 64, height: 48, pixelCount: 3072, recordBytes: bytes.byteLength,
    hashAlgorithm: 'fnv1a32-change-fingerprint', recordHash: recordHash.toString(16).padStart(8, '0'),
    pixelHash: pixelHash.toString(16).padStart(8, '0'), litCount, interiorLitCount,
    leftPaddleRows: leftRows, leftPaddleCenter: leftRows ? leftSum / leftRows : null};
}

export function commandKind(words) {
  if (!Array.isArray(words) || words.length !== 16 || words[0] !== 2) return null;
  const trigger = (x, y, mask) => words[1] === 2 && words[2] === x && words[3] === y
    && words[4] === 1 && words[5] === 1 && words[6] === 1 && words[7] === mask
    && words[9] === 0 && words[10] === 0 && words[11] === 0 && words[12] === 0
    && words[13] === 0 && words[14] === 0 && words[15] === 0;
  if (trigger(3194, 153, 8) && Number.isInteger(words[8]) && words[8] >= 1 && words[8] <= 128) return 'clock';
  if (trigger(6516, 851, 9) && words[8] === 1) return 'up';
  if (trigger(6517, 866, 5) && words[8] === 1) return 'down';
  if (words.every((v, i) => v === [2, 9, 6485, 800, 64, 48, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0][i])) return 'display';
  if (words.every((v, i) => v === [2, 10, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0][i])) return 'optimization-on';
  return 'other';
}

// Serialization installs read-only observations around original API calls.
// Nothing invokes a product operation, dispatches Dart state or changes inputs.
export function installCycleInstrumentation(displaySummary) {
  const emit = event => globalThis.__abcBrowserDiagnostic(JSON.stringify({...event,
    pageNowMs: performance.now(), pageTimeOriginMs: performance.timeOrigin}));
  const bridge = globalThis.terraWorldCircuit;
  if (!bridge || typeof bridge.computerFrame !== 'function') throw new Error('Original bridge/frame capability required');
  const observed = {...bridge}, NativeWorker = globalThis.Worker;
  let nextWorker = 0, nextCall = 0, nextKey = 0;
  globalThis.Worker = class extends NativeWorker {
    constructor(...args) {
      super(...args);
      if (!String(args[0]).includes('terra_engine_worker.js?owner=worldCircuit')) return;
      const workerId = ++nextWorker;
      emit({type: 'world-worker-created', workerId});
      this.addEventListener('error', e => emit({type: 'world-worker-error', workerId, message: String(e.message).slice(0, 2048)}));
      this.addEventListener('messageerror', () => emit({type: 'world-worker-messageerror', workerId}));
      const terminate = this.terminate.bind(this);
      this.terminate = () => { emit({type: 'world-worker-terminated', workerId}); return terminate(); };
    }
  };
  for (const type of ['keydown', 'keyup']) globalThis.addEventListener(type, event => {
    if (!['ArrowUp', 'ArrowDown'].includes(event.key)) return;
    emit({type: 'dom-key-event', keyEventId: ++nextKey, eventType: event.type,
      key: event.key, code: event.code, isTrusted: event.isTrusted, repeat: event.repeat,
      timeStamp: event.timeStamp, targetTag: event.target?.tagName ?? null});
  }, true);
  const words = value => {
    const parsed = JSON.parse(value);
    if (!Array.isArray(parsed) || parsed.length !== 16 || parsed.some(v => !Number.isInteger(v)))
      throw new Error('Unexpected observed command ABI');
    return parsed;
  };
  const monitor = row => row?.every((v, i) => v === [2, 9, 6485, 800, 64, 48, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0][i]);
  const shape = result => {
    const observed = {resultKind: null, resultCount: null};
    try {
      observed.resultKind = Number.isSafeInteger(result?.resultKind) ? result.resultKind : null;
      observed.resultCount = Number.isSafeInteger(result?.resultCount) ? result.resultCount : null;
      const records = result?.records, name = records?.constructor?.name;
      return {...observed, recordsConstructor: typeof name === 'string' ? name.slice(0, 64) : null,
        recordsByteLength: Number.isSafeInteger(records?.byteLength) ? records.byteLength : null};
    } catch (error) { return {...observed, shapeError: String(error).slice(0, 256)}; }
  };
  const scalar = result => ({session: result?.session, sourceSha256: result?.sourceSha256,
    stats: result?.stats, resultKind: result?.resultKind, resultCount: result?.resultCount,
    reserved: result?.reserved, hostStagesUs: result?.hostStagesUs});
  for (const method of ['open', 'openSource', 'progress', 'command', 'computerFrame', 'close', 'cleanup', 'releaseSource']) {
    const original = bridge[method].bind(bridge);
    observed[method] = (...args) => {
      const callId = ++nextCall;
      let descriptor = {type: 'bridge-call', method, callId};
      try {
        if (['command', 'computerFrame', 'close'].includes(method)) descriptor.requestSession = args[0];
        if (method === 'command' || method === 'computerFrame') descriptor.words = words(args[1]);
        if (method === 'computerFrame') descriptor.pixelWords = words(args[2]);
        if (method === 'openSource') descriptor.file = {isFile: args[0] instanceof File,
          isBlob: args[0] instanceof Blob, size: args[0]?.size, name: args[0]?.name};
        emit(descriptor);
        return original(...args).then(result => {
          try {
            const data = method === 'progress' ? {progress: result} : method === 'computerFrame'
              ? {clock: scalar(result?.clock), display: scalar(result?.display), displayError: result?.displayError,
                ...(result?.display && monitor(descriptor.pixelWords) ? {monitor: displaySummary(result.display)} : {})}
              : {...scalar(result), ...(method === 'command' && monitor(descriptor.words)
                ? {monitor: displaySummary(result)} : {})};
            emit({type: 'bridge-result', method, callId, ...data});
          } catch (error) {
            emit({type: 'observation-error', method, callId, message: String(error).slice(0, 2048),
              ...(method === 'command' && monitor(descriptor.words) ? {resultShape: shape(result)}
                : method === 'computerFrame' && monitor(descriptor.pixelWords) ? {resultShape: shape(result?.display)} : {})});
          }
          return result;
        }, error => {
          emit({type: 'bridge-error', method, callId, message: String(error).slice(0, 2048)});
          throw error;
        });
      } catch (error) {
        emit({type: 'observation-error', method, callId, message: String(error).slice(0, 2048)});
        throw error;
      }
    };
  }
  globalThis.terraWorldCircuit = Object.freeze(observed);
  emit({type: 'instrumentation-installed', method: 'passive scalar calls/ACKs, bounded monitor fingerprints, trusted DOM keys and worker lifetime'});
}

export function newCycleState() {
  return {file: null, openResult: null, lastOpenCallId: null, bridgeCalls: 0, openCalls: 0, legacyOpenCalls: 0, closeCalls: 0,
    closeAcks: 0, pending: new Map(), activeSessions: new Set(), allSessions: new Set(),
    workers: new Set(), workerCreated: 0, workerTerminated: 0, clockPulses: 0, clockAcks: 0,
    inputAcks: {up: [], down: []}, keyEvents: [], display: null, displayCount: 0,
    displayChanges: 0, optimizationOnAcks: 0, errors: [], crashes: []};
}

// Fail closed on stale public handles; reset must remove the previous session
// before the replacement appears. IDs are observations, never guessed totals.
export function observeCycleEvent(state, event) {
  const error = message => state.errors.push({type: 'protocol-error', message});
  if (event.type === 'world-worker-created') {
    if (state.workers.has(event.workerId)) error('Duplicate worker creation');
    state.workers.add(event.workerId); state.workerCreated++;
  }
  if (event.type === 'world-worker-terminated') {
    if (!state.workers.delete(event.workerId)) error('Unknown or duplicate worker termination');
    state.workerTerminated++;
  }
  if (event.type === 'dom-key-event') {
    state.keyEvents.push(event);
    if (state.keyEvents.length > 128) error('Unexpected keyboard event flood');
  }
  if (event.type === 'bridge-call') {
    state.bridgeCalls++;
    if (state.pending.has(event.callId)) error('Duplicate bridge call ID');
    state.pending.set(event.callId, event);
    if (['command', 'computerFrame', 'close'].includes(event.method) && !state.activeSessions.has(event.requestSession))
      error('Observed operation on stale or unknown public session');
    if (event.method === 'openSource') { state.openCalls++; state.file = event.file; state.lastOpenCallId = event.callId; }
    if (event.method === 'open') state.legacyOpenCalls++;
    if (event.method === 'close') state.closeCalls++;
    if (state.pending.size > 256) error('Unexpected pending bridge call count');
  }
  if (['bridge-result', 'bridge-error', 'observation-error'].includes(event.type)) {
    const request = state.pending.get(event.callId);
    if (!request || request.method !== event.method) error('Unmatched bridge completion');
    state.pending.delete(event.callId);
    if (event.type !== 'bridge-result') { state.errors.push(event); return; }
    if (event.method === 'openSource') {
      if (!validOpen(event) || state.activeSessions.size || state.allSessions.has(event.session)) error('Invalid replacement or reused public session');
      state.activeSessions.add(event.session); state.allSessions.add(event.session); state.openResult = event;
    }
    if (event.method === 'close') { state.activeSessions.delete(request?.requestSession); state.closeAcks++; }
    if (event.method === 'command' || event.method === 'computerFrame') {
      const response = event.method === 'computerFrame' ? event.clock : event;
      if (response?.session !== request?.requestSession) error('Command result has stale or mismatched session');
      const kind = commandKind(request?.words);
      if (kind === 'clock') { state.clockPulses += request.words[8]; state.clockAcks++; }
      if (kind === 'up' || kind === 'down') state.inputAcks[kind].push({callId: event.callId,
        atPulses: state.clockPulses, hostMonoNs: event.hostMonoNs});
      if (kind === 'optimization-on') {
        if ((response.reserved & 10) !== 10) error('Optimization ON not acknowledged');
        state.optimizationOnAcks++;
      }
      if (event.method === 'computerFrame' && (event.displayError || event.display?.session !== request?.requestSession))
        error('Missing or mismatched physical display result');
      if (event.monitor) {
        if (state.display?.pixelHash !== event.monitor.pixelHash) state.displayChanges++;
        state.displayCount++;
        state.display = {...event.monitor, session: response.session, callId: event.callId, atPulses: state.clockPulses,
          hostMonoNs: event.hostMonoNs};
      }
    }
  }
  if (['world-worker-error', 'world-worker-messageerror'].includes(event.type)) state.errors.push(event);
}

function hasLabel(nodes, label) { return nodes.some(n => !n.ignored && n.name?.value === label); }
function displayNode(nodes) {
  const found = nodes.filter(n => !n.ignored && n.name?.value === DISPLAY_LABEL
    && ['image', 'img'].includes(n.role?.value));
  return found.length === 1 ? found[0] : null;
}
export function optimizationNode(nodes) {
  const found = nodes.filter(n => !n.ignored && ['switch', 'checkbox'].includes(n.role?.value)
    && (n.name?.value === '电路优化' || /^电路优化[\n ]/.test(n.name?.value ?? ''))
    && !n.properties?.some(p => p.name === 'disabled' && p.value?.value === true));
  return found.length === 1 ? found[0] : null;
}
export function checked(node) {
  const value = node?.properties?.find(p => p.name === 'checked')?.value?.value;
  return value === true || value === 'true' ? true : value === false || value === 'false' ? false : null;
}
export function uiPulses(nodes) {
  const values = nodes.filter(n => !n.ignored).map(n => /^已执行 (\d+) 个物理时钟脉冲 ·/.exec(n.name?.value ?? ''))
    .filter(Boolean).map(m => Number(m[1]));
  const distinct = [...new Set(values)];
  return distinct.length === 1 ? distinct[0] : null;
}
export function cycleReadyEvidence(state, nodes, expectedOpens) {
  return state.openCalls === expectedOpens && state.legacyOpenCalls === 0 && validOpen(state.openResult)
    && state.openResult.callId === state.lastOpenCallId && !state.pending.has(state.lastOpenCallId)
    && state.file?.isFile === true && state.file.size === WORLD_BYTES
    && state.activeSessions.size === 1 && state.activeSessions.has(state.openResult.session)
    && state.workers.size === 1 && hasLabel(nodes, VERIFIED_LABEL)
    && !!enabledNode(nodes, '关闭') && !!enabledNode(nodes, '重置') && state.errors.length === 0;
}

export function closedEvidence(state) {
  return state.activeSessions.size === 0 && state.workers.size === 0 && state.pending.size === 0
    && state.openCalls === state.closeCalls && state.closeCalls === state.closeAcks
    && state.workerCreated > 0 && state.workerCreated === state.workerTerminated && state.errors.length === 0;
}

export function releaseWindow(state, direction) {
  return {startPulse: state.clockPulses, sensorCount: state.inputAcks[direction].length};
}
export function releaseWindowComplete(state, direction, window) {
  return state.clockPulses >= window.startPulse + 128
    && state.inputAcks[direction].length === window.sensorCount;
}
export function ownershipSnapshot(state) {
  return {openCalls: state.openCalls, closeCalls: state.closeCalls, closeAcks: state.closeAcks,
    bridgeCalls: state.bridgeCalls, workerCreated: state.workerCreated, workerTerminated: state.workerTerminated};
}
export function quietCloseEvidence(state, snapshot) {
  return closedEvidence(state) && Object.entries(snapshot).every(([key, value]) => state[key] === value);
}

export function clickGeometry(quad, viewport) {
  if (!Array.isArray(quad) || quad.length !== 8 || !quad.every(Number.isFinite)
      || !Number.isFinite(viewport?.width) || !Number.isFinite(viewport?.height)
      || viewport.width < 32 || viewport.height < 32) throw new Error('Invalid UI geometry');
  const left = Math.min(quad[0], quad[2], quad[4], quad[6]);
  const right = Math.max(quad[0], quad[2], quad[4], quad[6]);
  const top = Math.min(quad[1], quad[3], quad[5], quad[7]);
  const bottom = Math.max(quad[1], quad[3], quad[5], quad[7]);
  if (right <= left || bottom <= top) throw new Error('Empty UI geometry');
  const x = (left + right) / 2, y = (top + bottom) / 2;
  return {x, y, visible: x >= 8 && x <= viewport.width - 8 && y >= 8 && y <= viewport.height - 8,
    wheelX: Math.max(-700, Math.min(700, x < 8 || x > viewport.width - 8 ? x - viewport.width / 2 : 0)),
    wheelY: Math.max(-700, Math.min(700, y < 8 || y > viewport.height - 8 ? y - viewport.height / 2 : 0))};
}

export async function runCycles(args) {
  const [port, appUrl, fixture, output, mode] = args;
  if (!/^\d+$/.test(port) || new URL(appUrl).hostname !== '127.0.0.1' || !path.isAbsolute(fixture)
      || !path.isAbsolute(output) || mode !== '--cycles=3' || args.length !== 5)
    throw new Error('Expected owned loopback Chrome/app, absolute public fixture/evidence paths and --cycles=3');
  const state = newCycleState(), start = performance.now();
  const result = {schema: 'abc.browser-cycle-driver.v1', status: 'failed', requestedLoadCount: 3, requestedCycles: 3,
    protocol: 'UI import; explicit optimization ON; 40x128 UI boot; focused live ArrowUp/Down; pause; original reset; close',
    limits: CYCLE_LIMITS, afterCloseMs: CYCLE_LIMITS.afterCloseMs, cycles: [],
    performanceClaim: 'bounded engineering interaction and memory observations; no screen FPS or leak-freedom claim'};
  const events = fs.openSync(path.join(output, 'browser-events.ndjson'), 'wx');
  let eventBytes = 0, exhausted = false, cycle = 0, cdp, socket, session, asynchronousError;
  const write = row => {
    const timed = {...row, cycle, hostMonoNs: Number(process.hrtime.bigint()), hostUtcMs: Date.now()};
    const line = JSON.stringify(timed) + '\n';
    if (eventBytes + Buffer.byteLength(line) > CYCLE_LIMITS.eventBytes) {
      exhausted = true; throw new Error('Browser event evidence reached 64 MiB bound');
    }
    eventBytes += Buffer.byteLength(line); fs.writeSync(events, line); return timed;
  };
  const stage = name => write({type: 'stage', name});
  const receive = row => {
    try {
      if (row.method === 'Runtime.bindingCalled' && row.params.name === '__abcBrowserDiagnostic')
        observeCycleEvent(state, write(JSON.parse(row.params.payload)));
      else if (['Target.targetCrashed', 'Inspector.targetCrashed', 'Inspector.detached',
        'Runtime.exceptionThrown', 'Page.fileChooserOpened'].includes(row.method)) {
        const event = write({type: 'cdp-event', method: row.method, params: row.params});
        if (row.method.endsWith('targetCrashed')) state.crashes.push(event);
        if (row.method === 'Runtime.exceptionThrown' || row.method === 'Inspector.detached') state.errors.push(event);
      }
    } catch (error) { asynchronousError = String(error); }
  };
  const call = (method, params) => cdp.call(method, params, session);
  const evaluate = async expression => {
    const response = await call('Runtime.evaluate', {expression, returnByValue: true, awaitPromise: true, userGesture: true});
    if (response.exceptionDetails) throw new Error(JSON.stringify(response.exceptionDetails));
    return response.result.value;
  };
  const check = () => {
    if (asynchronousError || exhausted || state.errors.length || state.crashes.length)
      throw new Error(asynchronousError ?? JSON.stringify(state.errors[0] ?? state.crashes[0] ?? 'Evidence bound exceeded'));
    if (performance.now() - start >= CYCLE_LIMITS.globalSoftMs) throw new Error('Global 3240-second interaction deadline');
  };
  const sleep = async ms => {
    const until = performance.now() + ms;
    do { check(); await new Promise(resolve => setTimeout(resolve, Math.min(250, Math.max(1, until - performance.now())))); }
    while (performance.now() < until);
    check();
  };
  const wait = async (name, predicate, ms = 30000) => {
    const until = performance.now() + ms;
    while (performance.now() < until) { check(); const value = await predicate(); if (value) return value; await sleep(100); }
    throw new Error(`Timed out: ${name} (${ms} ms)`);
  };
  const ax = async () => (await call('Accessibility.getFullAXTree')).nodes;
  let viewport;
  const click = async (label, select = nodes => enabledNode(nodes, label)) => {
    viewport ??= await evaluate('({width:innerWidth,height:innerHeight})');
    for (let attempt = 0; attempt < CYCLE_LIMITS.revealAttempts; attempt++) {
      const node = await wait(`unique enabled UI ${label}`, async () => select(await ax()));
      if (!node.backendDOMNodeId) throw new Error(`No DOM node: ${label}`);
      await call('DOM.scrollIntoViewIfNeeded', {backendNodeId: node.backendDOMNodeId});
      const {model} = await call('DOM.getBoxModel', {backendNodeId: node.backendDOMNodeId});
      const geometry = clickGeometry(model.content, viewport);
      if (!geometry.visible) {
        // Flutter's scrollables may need an ordinary pointer-wheel event even
        // after DOM scrollIntoView. Never invoke semantics/Dart actions directly.
        await call('Input.dispatchMouseEvent', {type: 'mouseWheel', x: viewport.width / 2,
          y: viewport.height / 2, deltaX: geometry.wheelX, deltaY: geometry.wheelY});
        write({type: 'ui-reveal-wheel', label, attempt: attempt + 1, deltaX: geometry.wheelX, deltaY: geometry.wheelY});
        await sleep(100); continue;
      }
      const {x, y} = geometry;
      await call('Input.dispatchMouseEvent', {type: 'mousePressed', x, y, button: 'left', clickCount: 1});
      await call('Input.dispatchMouseEvent', {type: 'mouseReleased', x, y, button: 'left', clickCount: 1});
      write({type: 'ui-click', label, backendDOMNodeId: node.backendDOMNodeId, x, y});
      return;
    }
    throw new Error(`UI control remained outside viewport after ${CYCLE_LIMITS.revealAttempts} reveals: ${label}`);
  };
  const screenshot = async label => {
    const image = await call('Page.captureScreenshot', {format: 'png'});
    const buffer = Buffer.from(image.data, 'base64');
    if (buffer.length > CYCLE_LIMITS.screenshotBytes) throw new Error('Screenshot exceeds 8 MiB bound');
    fs.writeFileSync(path.join(output, `cycle-${cycle}-${label}.png`), buffer);
  };
  const ready = async expectedOpens => cycleReadyEvidence(state, await ax(), expectedOpens);
  const assertOff = async () => {
    if ((state.openResult.reserved & 2) !== 0 || (state.openResult.reserved & 4) !== 4
        || checked(optimizationNode(await ax())) !== false)
      throw new Error('Initial optimization OFF and supported state were not verified');
  };
  const key = async (direction, down) => {
    const keyboardKey = direction === 'up' ? 'ArrowUp' : 'ArrowDown', keyCode = direction === 'up' ? 38 : 40;
    const before = state.keyEvents.length;
    write({type: 'keyboard-dispatch', key: keyboardKey, eventType: down ? 'keydown' : 'keyup',
      mode: 'CDP Input.dispatchKeyEvent on UI-click-focused actual monitor'});
    await call('Input.dispatchKeyEvent', {type: down ? 'rawKeyDown' : 'keyUp', key: keyboardKey, code: keyboardKey,
      windowsVirtualKeyCode: keyCode, nativeVirtualKeyCode: keyCode, autoRepeat: false});
    return wait('trusted DOM keyboard event', () => state.keyEvents.slice(before).find(e => e.key === keyboardKey
      && e.eventType === (down ? 'keydown' : 'keyup') && e.isTrusted === true && e.repeat === false), 3000);
  };
  try {
    write({type: 'lifecycle', name: 'driver-start'});
    const version = await (await fetch(`http://127.0.0.1:${port}/json/version`)).json();
    if (new URL(version.webSocketDebuggerUrl).hostname !== '127.0.0.1') throw new Error('CDP must be owned loopback');
    result.browserVersion = version.Browser; result.protocolVersion = version['Protocol-Version'];
    socket = new WebSocket(version.webSocketDebuggerUrl);
    await new Promise((resolve, reject) => { socket.addEventListener('open', resolve, {once: true}); socket.addEventListener('error', reject, {once: true}); });
    cdp = new Cdp(socket, receive);
    await cdp.call('Target.setDiscoverTargets', {discover: true});
    const {targetInfos} = await cdp.call('Target.getTargets');
    const pages = targetInfos.filter(t => t.type === 'page' && t.url === 'about:blank');
    if (pages.length !== 1) throw new Error('Expected exactly one fresh blank app page');
    ({sessionId: session} = await cdp.call('Target.attachToTarget', {targetId: pages[0].targetId, flatten: true}));
    for (const domain of ['Page', 'Runtime', 'Inspector', 'Accessibility']) await call(`${domain}.enable`);
    await call('Page.setInterceptFileChooserDialog', {enabled: true});
    await call('Page.navigate', {url: appUrl});
    await wait('Flutter semantics placeholder', () => evaluate(`(() => { const p = document.querySelector('flt-semantics-placeholder'); if (!p) return false; p.click(); return true; })()`), 60000);
    await click('电路实验室'); await click('世界电路');
    await call('Runtime.addBinding', {name: '__abcBrowserDiagnostic'});
    await evaluate(`(${installCycleInstrumentation.toString()})(${summarizeDisplay.toString()})`);
    result.environment = await evaluate(`({userAgent:navigator.userAgent, devicePixelRatio,
      hardwareConcurrency:navigator.hardwareConcurrency, deviceMemoryGiB:navigator.deviceMemory ?? null,
      viewport:{width:innerWidth,height:innerHeight}, crossOriginIsolated, secureContext:isSecureContext})`);
    for (cycle = 1; cycle <= CYCLE_LIMITS.cycles; cycle++) {
      const row = {cycle, status: 'partial', afterCloseMs: CYCLE_LIMITS.afterCloseMs, inputs: []}; result.cycles.push(row);
      const counts = {opens: state.openCalls, closes: state.closeAcks, created: state.workerCreated, terminated: state.workerTerminated};
      if (state.activeSessions.size || state.workers.size || state.pending.size) throw new Error('Previous cycle still owns handles/workers/calls');
      await click('选择完整 WLD');
      const objectId = await wait('original hidden WLD file input', async () => {
        const object = await call('Runtime.evaluate', {expression: `document.querySelector('input[type="file"][accept=".wld"]')`});
        return object.result?.subtype !== 'null' && object.result?.objectId;
      }, 10000);
      try { await call('DOM.setFileInputFiles', {objectId, files: [fixture]}); }
      finally { await call('Runtime.releaseObject', {objectId}); }
      stage('file-selected'); stage('baseline-start'); await sleep(CYCLE_LIMITS.baselineMs);
      stage('load-start'); await click('导入完整电路');
      await wait('full File import and actual verified computer UI', () => ready(counts.opens + 1), CYCLE_LIMITS.loadWaitMs);
      await assertOff(); row.originalSession = state.openResult.session; row.defaultOptimizationOff = true;
      stage('ready'); await sleep(CYCLE_LIMITS.readyIdleMs);
      const onAcks = state.optimizationOnAcks;
      stage('optimization-start'); await click('电路优化', optimizationNode);
      await wait('explicit optimization ON acknowledgement/UI', async () => state.optimizationOnAcks === onAcks + 1
        && checked(optimizationNode(await ax())) === true && !!enabledNode(await ax(), '载入 Pong 程序'));
      row.explicitOptimizationOn = true;
      stage('program-start'); await click('载入 Pong 程序');
      await wait('loaded upstream Pong program and enabled physical step', async () => hasLabel(await ax(), PROGRAM_LABEL)
        && !!enabledNode(await ax(), '128 个脉冲'), CYCLE_LIMITS.stepWaitMs);
      const initialPulse = state.clockPulses, initialDisplay = state.displayCount;
      const checkpoints = []; stage('boot-start');
      for (let batch = 0; batch < CYCLE_LIMITS.bootBatches; batch++) {
        const pulses = state.clockPulses, displayCount = state.displayCount;
        await click('128 个脉冲');
        await wait('exact 128 physical pulses, monitor result and completed UI step', async () =>
          state.clockPulses === pulses + 128 && state.displayCount > displayCount
          && uiPulses(await ax()) === (batch + 1) * 128 && !!enabledNode(await ax(), '128 个脉冲'), CYCLE_LIMITS.stepWaitMs);
        if (batch % 4 === 3) checkpoints.push({batch: batch + 1, ...state.display});
      }
      if (state.clockPulses - initialPulse !== 5120 || state.displayCount - initialDisplay < 40
          || !checkpoints.some(d => d.litCount > 0) || new Set(checkpoints.map(d => d.pixelHash)).size < 2)
        throw new Error('Pong boot lacks bounded physical clocks and changing non-dark actual monitor evidence');
      row.boot = {pulses: 5120, inputTrace: 'no-input UI boot; live keyboard trace follows', checkpoints};
      stage('pong-ready'); await screenshot('pong-ready');
      stage('input-start'); await click('运行物理时钟');
      await wait('live physical clock', async () => !!enabledNode(await ax(), '暂停'));
      await click(DISPLAY_LABEL, displayNode);
      // Start away from the nearest vertical boundary, then reverse once.
      // This is fixed two-direction coverage, not an unbounded retry.
      const firstDirection = state.display?.leftPaddleCenter <= 23.5 ? 'down' : 'up';
      row.inputOrder = firstDirection === 'down' ? ['down', 'up'] : ['up', 'down'];
      for (const direction of row.inputOrder) {
        const before = {...state.display}, sensorBefore = state.inputAcks[direction].length;
        if (before.leftPaddleCenter === null) throw new Error('No actual left paddle before keyboard input');
        let pressed = false, down, up, observed;
        try {
          pressed = true; down = await key(direction, true);
          observed = await wait(`physical ${direction} sensor ACK and actual paddle state change`, () =>
            state.inputAcks[direction].length > sensorBefore && state.display?.callId > before.callId
            && state.display.leftPaddleCenter !== null && (direction === 'up'
              ? state.display.leftPaddleCenter < before.leftPaddleCenter
              : state.display.leftPaddleCenter > before.leftPaddleCenter)
            && {...state.display}, CYCLE_LIMITS.inputWaitMs);
        } finally { if (pressed) up = await key(direction, false); }
        const releasePulse = state.clockPulses;
        await wait('released first accepted batch drains', () => state.clockPulses >= releasePulse + 128, CYCLE_LIMITS.inputWaitMs);
        const releaseObservation = releaseWindow(state, direction);
        // Polling can overshoot both original pulse thresholds. Always observe
        // a NEW interval after the actual first-drain observation.
        await wait('released next physical batch after observed drain', () =>
          state.clockPulses >= releaseObservation.startPulse + 128, CYCLE_LIMITS.inputWaitMs);
        if (!releaseWindowComplete(state, direction, releaseObservation)) throw new Error('Sensor pulses persisted after key release drain');
        row.inputs.push({direction, down, up, sensorAck: state.inputAcks[direction][sensorBefore],
          before, observed, releasePulse, releaseObservation, verifiedReleasePulse: state.clockPulses, noFurtherSensorPulses: true});
      }
      stage('input-complete');
      const livePulse = state.clockPulses, liveChanges = state.displayChanges;
      stage('live-start'); await sleep(CYCLE_LIMITS.liveObservationMs);
      if (state.clockPulses <= livePulse || state.displayChanges - liveChanges < 2) throw new Error('Live run did not show clocks and changing physical monitor');
      row.live = {pulses: state.clockPulses - livePulse, displayChanges: state.displayChanges - liveChanges,
        windowMs: CYCLE_LIMITS.liveObservationMs};
      stage('pause-start'); await click('暂停');
      await wait('paused UI and completed pending calls', async () => !!enabledNode(await ax(), '128 个脉冲')
        && !!enabledNode(await ax(), '运行物理时钟') && state.pending.size === 0);
      const pausedPulses = state.clockPulses, pausedUI = uiPulses(await ax()), pausedInputs = state.inputAcks.up.length + state.inputAcks.down.length;
      if (pausedUI === null) throw new Error('Paused physical pulse UI missing');
      stage('paused'); await sleep(CYCLE_LIMITS.pauseQuietMs);
      if (state.clockPulses !== pausedPulses || uiPulses(await ax()) !== pausedUI
          || state.inputAcks.up.length + state.inputAcks.down.length !== pausedInputs)
        throw new Error('Physical pulses or inputs progressed after pause');
      row.pause = {quietMs: CYCLE_LIMITS.pauseQuietMs, pulses: pausedUI, unchanged: true}; stage('pause-verified');
      const preResetDisplays = state.displayCount;
      stage('reset-start'); await click('重置');
      await wait('original-world reset confirmation', async () => hasLabel(await ax(), '丢弃当前模拟状态并从原始世界重新加载？'));
      await click('继续');
      await wait('fresh original-world session after acknowledged reset close', () => ready(counts.opens + 2), CYCLE_LIMITS.loadWaitMs);
      await assertOff();
      if (state.closeAcks !== counts.closes + 1 || state.openResult.session === row.originalSession
          || uiPulses(await ax()) !== 0 || !hasLabel(await ax(), EMPTY_ROM_LABEL)
          || state.displayCount <= preResetDisplays || state.display?.session !== state.openResult.session
          || state.display.litCount !== 0)
        throw new Error('Reset did not restore original empty ROM, dark physical display, OFF and zero pulses');
      row.resetSession = state.openResult.session; row.resetDefaultOptimizationOff = true; stage('reset-ready');
      stage('close-start'); await click('关闭');
      await wait('closed UI, balanced ACKs and retired owners', async () => closedEvidence(state)
        && !!enabledNode(await ax(), '选择完整 WLD'));
      const closeOwnership = ownershipSnapshot(state);
      stage('close-complete'); await sleep(CYCLE_LIMITS.afterCloseMs);
      if (!quietCloseEvidence(state, closeOwnership)) throw new Error('Owner recreated or stale activity during after-close window');
      stage('release-complete'); await screenshot('after-close');
      if (!quietCloseEvidence(state, closeOwnership) || state.openCalls - counts.opens !== 2
          || state.closeAcks - counts.closes !== 2)
        throw new Error('Unexpected lifecycle activity outside the two planned imports/closes');
      row.ownership = {openCalls: state.openCalls - counts.opens, closeAcks: state.closeAcks - counts.closes,
        workerCreated: state.workerCreated - counts.created, workerTerminated: state.workerTerminated - counts.terminated,
        activeSessions: [...state.activeSessions], liveWorkers: [...state.workers], pendingCalls: state.pending.size};
      row.status = 'observed';
      fs.writeFileSync(path.join(output, 'driver-result.json'), JSON.stringify(result, null, 2) + '\n');
    }
    check(); result.status = 'observed';
  } catch (error) {
    result.failure = String(error);
    if (!exhausted) { try {
      if (cycle >= 1 && cycle <= CYCLE_LIMITS.cycles) stage('driver-failed');
      else write({type: 'lifecycle', name: 'driver-failed'});
    } catch {} }
    if (cdp && session) {
      try { await screenshot('failure'); } catch (error) { result.failureScreenshot = String(error); }
      try { const tree = JSON.stringify(await ax(), null, 2); if (Buffer.byteLength(tree) > 4 * 1024 * 1024) throw new Error('AX evidence exceeds 4 MiB');
        fs.writeFileSync(path.join(output, 'failure-accessibility.json'), tree); }
      catch (error) { result.failureAccessibility = String(error); }
    }
  } finally {
    result.eventBytes = eventBytes;
    result.state = {...state, pending: [...state.pending.values()], activeSessions: [...state.activeSessions],
      allSessions: [...state.allSessions], workers: [...state.workers]};
    fs.writeFileSync(path.join(output, 'driver-result.json'), JSON.stringify(result, null, 2) + '\n');
    if (cdp) { try { await cdp.call('Browser.close'); } catch {} }
    socket?.close(); fs.closeSync(events);
  }
  process.exitCode = result.status === 'observed' ? 0 : 1;
}
