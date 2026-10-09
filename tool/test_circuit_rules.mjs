// Local parity runner. Generated cases/results are written only when the
// caller explicitly supplies TERRA_CIRCUIT_CORPUS in an ignored directory.
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import { openSync, writeSync, closeSync } from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import { createRequire } from 'node:module';
import { pathToFileURL, fileURLToPath } from 'node:url';
import { createHash } from 'node:crypto';

process.on('uncaughtException', error => {
  console.error(String(error.message).slice(0, 1600));
  console.error(String(error.stack).split('\n').filter(line => line.trim().startsWith('at ')).slice(0, 12).join('\n'));
  process.exitCode = 1;
});

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const source = process.env.TERRA_CIRCUIT_SOURCE || path.join(root, 'vendor/viewer-circuit');
const runtime = process.env.TERRA_WORLD_RUNTIME;
if (!runtime) throw new Error('Set TERRA_WORLD_RUNTIME to the verified local world.js; TERRA_CIRCUIT_SOURCE optionally overrides the attributed source subset');
const require = createRequire(import.meta.url);
const factory = require(path.resolve(runtime));
const wasmBinary = await fs.readFile(runtime.replace(/\.js$/, '.wasm'));
const webModule = await factory({ wasmBinary }), nativeModule = await factory({ wasmBinary });
const original = await import(pathToFileURL(path.join(source, 'features/circuit/services/computation-session.mjs')).href);
const { createDemo } = await import(pathToFileURL(path.join(source, 'features/circuit/domain/editor.mjs')).href);
const { serializeDocument } = await import(pathToFileURL(path.join(source, 'features/circuit/domain/model.mjs')).href);
const handles = new Set();
let nativeCalls = 0, liveBuffers = 0;
function nativeCallback(channel, encoded) {
  assert.equal(channel, 'terraCircuitNative'); nativeCalls++;
  const { op, args } = JSON.parse(encoded), M = nativeModule, allocations = [];
  const allocate = words => {
    const p = M._tx_malloc(Math.max(4, words.length * 4)); assert.ok(p);
    liveBuffers++; allocations.push(p); M.HEAPU32.set(words, p >>> 2); return p;
  };
  const read = (p, count) => Array.from(M.HEAPU32.subarray(p >>> 2, (p >>> 2) + count));
  let result;
  try {
    if (op === 'abi') result = { status: 0, abi: M._terra_circuit_abi_version() };
    else if (op === 'create') {
      const out = allocate([0]), status = M._terra_circuit_create(...args, out), handle = read(out, 1)[0];
      if (status >= 0) handles.add(handle);
      result = { status, handle };
    } else if (op === 'load' || op === 'patch') result = { status: M[`_terra_circuit_${op}`](args[0], allocate(args[1]), args[1].length / 4) };
    else if (op === 'compile') { const out = allocate([0]); result = { status: M._terra_circuit_compile(...args, out), compiled: read(out, 1)[0] }; }
    else if (op === 'begin') result = { status: M._terra_circuit_begin(args[0], allocate(args[1]), args[1].length / 2, ...args.slice(2)) };
    else if (op === 'step') {
      const out = allocate(new Array(args[2] * 4).fill(0)), metaPointer = allocate(new Array(16).fill(0));
      const status = M._terra_circuit_step(args[0], args[1], out, args[2], metaPointer), meta = read(metaPointer, 4);
      assert.ok(meta[1] <= args[2]); result = { status, meta, events: read(out, meta[1] * 4) };
    } else if (op === 'stats') { const out = allocate(new Array(16).fill(0)); result = { status: M._terra_circuit_stats(args[0], out), words: read(out, 16) }; }
    else if (op === 'cancel' || op === 'close') {
      result = { status: M[`_terra_circuit_${op}`](...args) };
      if (op === 'close' && result.status >= 0) handles.delete(args[0]);
    } else throw new Error(`Unexpected native opcode: ${op}`);
    return JSON.stringify(result);
  } finally { for (const p of allocations) { M._tx_free(p); liveBuffers--; } }
}
const nativeContext = vm.createContext({ sendMessage: nativeCallback });
vm.runInContext(await fs.readFile(path.join(root, 'assets/private/circuit_rules_native.js'), 'utf8'), nativeContext);
const native = nativeContext.TerraCircuitRules;
const webContext = vm.createContext({});
vm.runInContext(await fs.readFile(path.join(root, 'web/engine/circuit_rules_web.js'), 'utf8'), webContext);
const web = webContext.createTerraCircuitRules(webModule);
const normalize = value => {
  const result = JSON.parse(JSON.stringify(value));
  if (result?.packet) delete result.packet.native;
  return result;
};
let cases = 0;
let corpusCases = 0, corpusDemo = false, corpusCommands = 0;
let corpusFile = null;
if (process.env.TERRA_CIRCUIT_CORPUS) {
  const output = path.resolve(process.env.TERRA_CIRCUIT_CORPUS);
  if (!output.startsWith(path.join(root, 'qa-evidence') + path.sep)) throw new Error('Generated corpus must remain in ignored qa-evidence/');
  await fs.mkdir(path.dirname(output), { recursive: true });
  corpusFile = openSync(output, 'w');
  writeSync(corpusFile, '{"schema":1,"sourceCommit":"366ebc57751cadfb077f968f4d5069028b3bf9a6","normalization":"Omit packet.native. When expectedDocumentSha256 is present, hash UTF-8 result.document and omit result.document before comparing expected. expectedError true accepts any thrown error. Native replay records the first four demo commands; all commands are verified by the JS/WASM runner.","cases":[');
}
function record(value) {
  cases++;
  if (value.method === 'editor.demo') { corpusDemo = true; corpusCommands = 0; }
  if (value.method === 'editor.close') corpusDemo = false;
  if (corpusDemo && value.method === 'simulation.command' && ++corpusCommands > 4) return;
  if (corpusFile !== null) {
    if (typeof value.expected?.document === 'string') {
      value = { ...value, expected: { ...value.expected }, expectedDocumentSha256: createHash('sha256').update(value.expected.document).digest('hex') };
      delete value.expected.document;
    }
    writeSync(corpusFile, (corpusCases ? ',' : '') + JSON.stringify(value));
    corpusCases++;
  }
}
function call(method, args = []) {
  const expected = normalize(web.invoke(method, args));
  assert.deepEqual(normalize(native.invoke(method, args)), expected, method);
  record({ method, args, expected });
  assert.equal(liveBuffers, 0);
  return expected;
}
function rejected(method, args, code) {
  for (const host of [web, native]) assert.throws(() => host.invoke(method, args), error => !code || error.code === code);
  record({ method, args, expectedError: code || true });
}
const capabilities = call('capabilities');
assert.equal(capabilities.sourceCommit, '366ebc57751cadfb077f968f4d5069028b3bf9a6');
const catalog = call('catalog');
assert.equal(catalog.palette.length, 2776);
assert.equal(catalog.demos.length, 15);
call('editor.new', ['Parity']);
const edit = (method, args = []) => call('editor.command', [{ method, args }]);
edit('paint', [{ x: 1, y: 3 }, { x: 8, y: 3 }, { tool: 'wire', mask: 15 }]);
edit('placeTile', [{ kind: 'switch', x: 1, y: 3 }]);
edit('placeTile', [{ kind: 'gemspark', x: 8, y: 3 }]);
edit('select', [{ x: 1, y: 3, width: 8, height: 1 }]);
edit('copy'); edit('paste', [{ x: 1, y: 8 }]);
edit('undo'); edit('redo'); edit('transformClipboard', ['rotate']);
edit('paste', [{ x: 15, y: 3 }]); edit('undo');
edit('select', [{ x: 1, y: 8, width: 8, height: 1 }]);
edit('cut'); edit('undo'); edit('redo'); edit('undo');
edit('updateTile', [8, 3, { on: true }]);
edit('select', [{ x: 1, y: 3, width: 8, height: 1 }]); edit('applyActuators', [true]);
edit('markSaved');
const saved = call('editor.snapshot').document;
const simulated = call('simulation.command', [{ method: 'interact', args: [1, 3], debug: true }]);
assert.equal(simulated.canReset, true);
assert.equal(call('simulation.reset').document, saved);
call('simulation.cancel');
call('editor.open', [saved]); assert.equal(call('editor.snapshot').document, saved);
rejected('editor.command', [{ method: 'constructor', args: [] }], 'CIRCUIT_COMMAND');
rejected('editor.command', [{ method: 'select', args: [{ x: 0, y: 0, width: 1000, height: 1000 }] }], 'CIRCUIT_LIMIT');
rejected('simulation.command', [{ method: 'step', args: [61] }], 'COMPUTATION_COMMAND');
rejected('simulation.command', [{ method: 'close', args: [] }], 'COMPUTATION_COMMAND');
rejected('editor.open', ['{"format":"incompatible"}']);
assert.equal(call('editor.snapshot').document, saved, 'Rejected import preserves current document');
call('editor.close'); rejected('editor.snapshot', [], 'STALE_OPERATION');

let packetCount = 0, structuralPackets = 0;
for (const demo of catalog.demos) {
  console.log(`Checking demo ${demo}`);
  const snapshot = call('editor.demo', [demo]);
  const reference = original.createCircuitComputation({});
  const referenceId = reference.invoke('open', [serializeDocument(createDemo(demo))]).id;
  const raw = JSON.parse(snapshot.document);
  const commands = [];
  for (const tile of raw.world.tiles.slice(0, 24)) {
    commands.push({ method: 'interact', args: [tile.x, tile.y], debug: true });
    commands.push({ method: 'step', args: [1], debug: true });
  }
  for (const wire of raw.world.wires.slice(0, 8)) for (const mask of [1, 2, 4, 8]) commands.push({ method: 'trigger', args: [[{ x: wire[0], y: wire[1] }], mask], debug: true });
  for (let i = 0; i < 12; i++) commands.push({ method: 'step', args: [60], debug: i % 2 === 0 });
  commands.push({ method: 'advanceBoundary', args: ['dawn'], debug: true }, { method: 'advanceBoundary', args: ['dusk'], debug: true });
  for (const command of commands) {
    const result = call('simulation.command', [command]);
    const expected = JSON.parse(reference.invoke('execute', [referenceId, command]).packet);
    const actual = { ...result.packet };
    delete expected.native; delete expected.id; delete actual.id;
    assert.deepEqual(actual, expected, `${demo}: ${JSON.stringify(command)}`);
    packetCount++; if (actual.structureChanged) structuralPackets++;
  }
  assert.equal(call('simulation.reset').document, snapshot.document);
  call('editor.close'); reference.dispose();
  assert.equal(handles.size, 0, `${demo}: native owner released`);
  globalThis.gc?.();
}
// Retained editor IDs cannot be reused, and the fifth editor is refused before
// displacing an existing document. These internal facade APIs are not exposed
// by the browser worker's user-facing whitelist.
const retained = [];
for (let i = 0; i < 4; i++) retained.push(call('createDemo', ['timer']).id);
rejected('createDemo', ['timer'], 'CIRCUIT_LIMIT');
for (const id of retained) call('closeDocument', [id]);
rejected('snapshot', [retained[0]], 'STALE_OPERATION');
call('dispose'); rejected('catalog', [], 'COMPUTATION_OWNER_LOST');
assert.equal(handles.size, 0); assert.equal(liveBuffers, 0);
if (corpusFile !== null) { writeSync(corpusFile, ']}\n'); closeSync(corpusFile); }
console.log(JSON.stringify({ demos: catalog.demos.length, palette: catalog.palette.length, packetCount, structuralPackets, nativeCalls, cases, corpusCases, leakedHandles: handles.size, liveBuffers }));
