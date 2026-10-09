// CDP for this diagnostic's fresh Chrome only. Uses Node's built-in WebSocket.
// The release app, its UI, file gateway, worker bridge and WASM are unchanged.
import fs from 'node:fs';
import path from 'node:path';
import {pathToFileURL} from 'node:url';
import {runCycles} from './browser_load_cycles.mjs';

export const WORLD_BYTES = 405983441;
export const WORLD_SHA = '55d0a24bd1f56d622003dbd30d52555e7d06d6d1bcacfc22ae506f2db5240c33';
export const VERIFIED_LABEL = '已核验：完整 Computerraria WLD、实际存储器坐标及 64 × 48 黑白显示器。';

export function validOpen(event) {
  return event?.type === 'bridge-result' && event.method === 'openSource'
    && event.sourceSha256 === WORLD_SHA && event.session > 0
    && event.stats?.length === 24 && event.stats[0] === 2;
}

export function enabledNode(nodes, label) {
  const candidates = nodes.filter(n => !n.ignored && n.name?.value === label
    && (['button', 'tab', 'link', 'radio', 'checkbox', 'menuitem'].includes(n.role?.value)
      || n.properties?.some(p => p.name === 'defaultActionVerb' && p.value?.value === 'click'))
    && !n.properties?.some(p => p.name === 'disabled' && p.value?.value === true));
  // Fail closed on ambiguous labels rather than clicking a similarly named item.
  return candidates.length === 1 ? candidates[0] : null;
}

export function readyEvidence(state, nodes) {
  return validOpen(state.openResult) && state.file?.isFile === true
    && state.file.size === WORLD_BYTES && state.legacyOpenCalls === 0 && state.openSourceCalls === 1
    && nodes.some(n => !n.ignored && n.name?.value === VERIFIED_LABEL)
    && !!enabledNode(nodes, '关闭');
}

export function installInstrumentation() {
  const emit = event => globalThis.__abcBrowserDiagnostic(JSON.stringify({
    ...event, pageNowMs: performance.now(), pageTimeOriginMs: performance.timeOrigin,
  }));
  const bridge = globalThis.terraWorldCircuit;
  if (!bridge) throw new Error('Original world circuit bridge is unavailable');
  // createClient intentionally returns Object.freeze(client). Never mutate it:
  // Dart's @JS('terraWorldCircuit') getter resolves this global on every call.
  // This test-only facade keeps every original method and forwards its values.
  const observedBridge = {...bridge};
  const NativeWorker = globalThis.Worker;
  let nextWorker = 0;
  globalThis.Worker = class extends NativeWorker {
    constructor(...args) {
      super(...args);
      const relevant = String(args[0]).includes('terra_engine_worker.js?owner=worldCircuit');
      if (!relevant) return;
      const workerId = ++nextWorker;
      emit({type: 'world-worker-created', workerId});
      this.addEventListener('error', event => emit({type: 'world-worker-error', workerId,
        message: String(event.message).slice(0, 2048)}));
      this.addEventListener('messageerror', () => emit({type: 'world-worker-messageerror', workerId}));
      const terminate = this.terminate.bind(this);
      this.terminate = () => { emit({type: 'world-worker-terminated', workerId}); return terminate(); };
    }
  };
  for (const method of ['open', 'openSource', 'progress', 'command', 'close', 'cleanup']) {
    const original = bridge[method].bind(bridge);
    observedBridge[method] = (...args) => {
      if (method !== 'progress') emit({type: 'bridge-call', method,
        ...(method === 'openSource' ? {file: {isFile: args[0] instanceof File,
          isBlob: args[0] instanceof Blob, size: args[0]?.size, name: args[0]?.name}} : {})});
      return original(...args).then(result => {
        // Do not retain or serialize the result's records, File, Blob or buffers.
        const data = method === 'progress' ? {progress: result} : {
          session: result?.session, sourceSha256: result?.sourceSha256,
          stats: result?.stats, resultKind: result?.resultKind,
          hostStagesUs: result?.hostStagesUs,
        };
        emit({type: 'bridge-result', method, ...data});
        return result;
      }, error => {
        emit({type: 'bridge-error', method, message: String(error).slice(0, 2048)});
        throw error;
      });
    };
  }
  globalThis.terraWorldCircuit = Object.freeze(observedBridge);
  emit({type: 'instrumentation-installed',
    method: 'scalar-only bridge observations; Worker creation/termination observations'});
}

export class Cdp {
  constructor(socket, receive) {
    this.socket = socket;
    this.nextId = 0;
    this.pending = new Map();
    socket.addEventListener('message', event => {
      const row = JSON.parse(event.data);
      if (row.id) {
        const pending = this.pending.get(row.id);
        if (!pending) return;
        this.pending.delete(row.id);
        clearTimeout(pending.timer);
        row.error ? pending.reject(new Error(JSON.stringify(row.error))) : pending.resolve(row.result);
      } else receive(row);
    });
    socket.addEventListener('close', () => {
      for (const request of this.pending.values()) {
        clearTimeout(request.timer);
        request.reject(new Error('Owned Chrome CDP socket closed'));
      }
      this.pending.clear();
    });
  }
  call(method, params = {}, sessionId) {
    return new Promise((resolve, reject) => {
      const id = ++this.nextId;
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error(`CDP timeout: ${method}`));
      }, 15000);
      this.pending.set(id, {resolve, reject, timer});
      this.socket.send(JSON.stringify({id, method, params, ...(sessionId ? {sessionId} : {})}));
    });
  }
}

async function main() {
  const [port, appUrl, fixture, output] = process.argv.slice(2);
  if (!/^\d+$/.test(port) || new URL(appUrl).hostname !== '127.0.0.1'
      || !path.isAbsolute(fixture) || !path.isAbsolute(output)) {
    throw new Error('Expected owned loopback Chrome/app and absolute public fixture/evidence paths');
  }
  const events = fs.openSync(path.join(output, 'browser-events.ndjson'), 'wx');
  const state = {file: null, openResult: null, lastProgress: null, legacyOpenCalls: 0, openSourceCalls: 0,
    workerCreated: 0, workerTerminated: 0, closeAcknowledged: false, errors: [], crashes: []};
  const result = {schema: 'abc.browser-load-driver.v1', status: 'failed',
    navigationMode: 'original-release-app-accessibility-ui',
    inputMode: 'CDP DOM.setFileInputFiles to original product picker; native File',
    requestedLoadCount: 1, readyIdleMs: 15000, afterCloseMs: 20000,
    performanceClaim: 'loading memory diagnostic only; no device or screen FPS'};
  const write = row => fs.writeSync(events, JSON.stringify({
    ...row, hostMonoNs: Number(process.hrtime.bigint()), hostUtcMs: Date.now(),
  }) + '\n');
  const stage = name => write({type: 'stage', name});
  const receive = row => {
    if (row.method === 'Runtime.bindingCalled' && row.params.name === '__abcBrowserDiagnostic') {
      const event = JSON.parse(row.params.payload);
      write(event);
      if (event.type === 'bridge-call' && event.method === 'openSource') {
        state.file = event.file;
        state.openSourceCalls++;
      }
      if (event.type === 'bridge-call' && event.method === 'open') state.legacyOpenCalls++;
      if (event.type === 'bridge-result' && event.method === 'openSource') state.openResult = event;
      if (event.type === 'bridge-result' && event.method === 'progress') state.lastProgress = event.progress;
      if (event.type === 'bridge-result' && event.method === 'close') state.closeAcknowledged = true;
      if (event.type === 'bridge-error' && event.method !== 'progress') state.errors.push(event);
      if (event.type === 'world-worker-created') state.workerCreated++;
      if (event.type === 'world-worker-terminated') state.workerTerminated++;
      if (event.type === 'world-worker-error' || event.type === 'world-worker-messageerror') state.errors.push(event);
    } else if (['Target.targetCrashed', 'Inspector.targetCrashed', 'Inspector.detached',
      'Runtime.exceptionThrown', 'Page.fileChooserOpened'].includes(row.method)) {
      write({type: 'cdp-event', method: row.method, params: row.params});
      if (row.method.endsWith('targetCrashed')) state.crashes.push(row);
    }
  };
  let cdp, socket, session;
  const call = (method, params) => cdp.call(method, params, session);
  const evaluate = async expression => {
    const response = await call('Runtime.evaluate', {expression, returnByValue: true,
      awaitPromise: true, userGesture: true});
    if (response.exceptionDetails) throw new Error(JSON.stringify(response.exceptionDetails));
    return response.result.value;
  };
  const failIfBroken = () => {
    if (state.crashes.length) throw new Error('Chrome reported a renderer/target crash');
    if (state.errors.length) throw new Error(`Product world load error: ${state.errors[0].message}`);
  };
  const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
  const wait = async (name, predicate, milliseconds) => {
    const deadline = performance.now() + milliseconds;
    while (performance.now() < deadline) {
      failIfBroken();
      const value = await predicate();
      if (value) return value;
      await sleep(250);
    }
    throw new Error(`Timed out waiting for ${name} after ${milliseconds} ms`);
  };
  const ax = async () => (await call('Accessibility.getFullAXTree', {})).nodes;
  const click = async label => {
    const node = await wait(`enabled UI control: ${label}`, async () => enabledNode(await ax(), label), 30000);
    if (!node.backendDOMNodeId) throw new Error(`No UI DOM node for ${label}`);
    await call('DOM.scrollIntoViewIfNeeded', {backendNodeId: node.backendDOMNodeId});
    const {model} = await call('DOM.getBoxModel', {backendNodeId: node.backendDOMNodeId});
    const q = model.content;
    const x = (q[0] + q[2] + q[4] + q[6]) / 4;
    const y = (q[1] + q[3] + q[5] + q[7]) / 4;
    await call('Input.dispatchMouseEvent', {type: 'mousePressed', x, y, button: 'left', clickCount: 1});
    await call('Input.dispatchMouseEvent', {type: 'mouseReleased', x, y, button: 'left', clickCount: 1});
    write({type: 'ui-click', label});
  };
  const screenshot = async name => {
    const image = await call('Page.captureScreenshot', {format: 'png'});
    fs.writeFileSync(path.join(output, name), Buffer.from(image.data, 'base64'));
  };
  try {
    stage('driver-start');
    const version = await (await fetch(`http://127.0.0.1:${port}/json/version`)).json();
    if (new URL(version.webSocketDebuggerUrl).hostname !== '127.0.0.1') throw new Error('CDP must be owned loopback');
    result.browserVersion = version.Browser;
    result.protocolVersion = version['Protocol-Version'];
    socket = new WebSocket(version.webSocketDebuggerUrl);
    await new Promise((resolve, reject) => {
      socket.addEventListener('open', resolve, {once: true});
      socket.addEventListener('error', reject, {once: true});
    });
    cdp = new Cdp(socket, receive);
    await cdp.call('Target.setDiscoverTargets', {discover: true});
    const {targetInfos} = await cdp.call('Target.getTargets');
    const pages = targetInfos.filter(t => t.type === 'page' && t.url === 'about:blank');
    if (pages.length !== 1) throw new Error('Expected exactly one fresh blank app page');
    ({sessionId: session} = await cdp.call('Target.attachToTarget', {targetId: pages[0].targetId, flatten: true}));
    await call('Page.enable');
    await call('Runtime.enable');
    await call('Inspector.enable');
    await call('Accessibility.enable');
    await call('Page.setInterceptFileChooserDialog', {enabled: true});
    await call('Page.navigate', {url: appUrl});
    stage('app-navigate');
    await wait('Flutter semantics placeholder', () => evaluate(`(() => {
      const placeholder = document.querySelector('flt-semantics-placeholder');
      if (!placeholder) return false;
      placeholder.click();
      return true;
    })()`), 60000);
    await click('电路实验室');
    await click('世界电路');
    await wait('original file picker control', async () => enabledNode(await ax(), '选择完整 WLD'), 30000);
    await call('Runtime.addBinding', {name: '__abcBrowserDiagnostic'});
    await evaluate(`(${installInstrumentation.toString()})()`);
    result.environment = await evaluate(`({userAgent:navigator.userAgent,
      devicePixelRatio, hardwareConcurrency:navigator.hardwareConcurrency,
      deviceMemoryGiB:navigator.deviceMemory ?? null,
      viewport:{width:innerWidth,height:innerHeight},
      crossOriginIsolated, secureContext:isSecureContext})`);
    await click('选择完整 WLD');
    const inputObject = await wait('original hidden file input', async () => {
      const object = await call('Runtime.evaluate', {expression: `document.querySelector('input[type="file"][accept=".wld"]')`});
      return object.result?.subtype !== 'null' && object.result?.objectId;
    }, 10000);
    await call('DOM.setFileInputFiles', {objectId: inputObject, files: [fixture]});
    await call('Runtime.releaseObject', {objectId: inputObject});
    stage('file-selected');
    await screenshot('before-load.png');
    stage('baseline-start');
    await sleep(10000);
    stage('load-start');
    await click('导入完整电路');
    await wait('actual File import, source hash, verified computer UI and enabled Close',
      async () => readyEvidence(state, await ax()), 610000);
    failIfBroken();
    stage('ready');
    result.ready = {file: state.file, openResult: state.openResult,
      verifiedUiLabel: VERIFIED_LABEL, closeButtonEnabled: true};
    await screenshot('ready.png');
    await sleep(15000);
    failIfBroken();
    stage('ready-idle-complete');
    stage('close-start');
    await click('关闭');
    await wait('UI closed and original worker close acknowledged', async () =>
      state.closeAcknowledged && !!enabledNode(await ax(), '选择完整 WLD'), 30000);
    stage('close-complete');
    // Do not poll bridge.progress here: it could recreate a retired owner.
    await sleep(20000);
    failIfBroken();
    stage('release-complete');
    if (state.workerCreated !== 1 || state.workerTerminated !== 1) {
      throw new Error('Expected one world owner and acknowledged worker retirement after close');
    }
    await screenshot('after-close.png');
    result.status = 'observed';
  } catch (error) {
    result.failure = String(error);
    stage('driver-failed');
    if (cdp && session) {
      try { await screenshot('failure.png'); } catch (error) { result.failureScreenshot = String(error); }
      try { fs.writeFileSync(path.join(output, 'failure-accessibility.json'), JSON.stringify(await ax(), null, 2)); }
      catch (error) { result.failureAccessibility = String(error); }
    }
  } finally {
    result.state = state;
    stage('browser-close-request');
    fs.writeFileSync(path.join(output, 'driver-result.json'), JSON.stringify(result, null, 2) + '\n');
    if (cdp) { try { await cdp.call('Browser.close'); } catch (error) { write({type:'browser-close-cdp-result', message:String(error)}); } }
    socket?.close();
    fs.closeSync(events);
  }
  process.exitCode = result.status === 'observed' ? 0 : 1;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  if (process.argv[6] === '--cycles=3') {
    await runCycles(process.argv.slice(2));
  } else if (process.argv.length === 6) {
    await main();
  } else {
    throw new Error('Expected one-load arguments or explicit --cycles=3');
  }
}
