#!/usr/bin/env node
// Capture build metadata from the actual staged Web artifact, not a guessed
// source revision string. Run after build_web_engine.sh and staging its outputs.
import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import crypto from 'node:crypto';
import { fileURLToPath } from 'node:url';
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const sha256 = bytes => crypto.createHash('sha256').update(bytes).digest('hex');
const engine = path.join(root, 'web/engine');
const manifest = JSON.parse(fs.readFileSync(path.join(engine, 'manifest.json'), 'utf8'));
const artifacts = [];
for (const name of ['world.js', 'world.wasm', 'player.js', 'player.wasm']) {
  const data = fs.readFileSync(path.join(engine, name));
  const actual = { bytes: data.length, sha256: sha256(data) };
  if (JSON.stringify(actual) !== JSON.stringify(manifest.artifacts[name])) throw new Error('Staged artifact differs from build manifest: ' + name);
  artifacts.push({ path: 'web/engine/' + name, ...actual });
}
const sourceManifest = { path: 'native/vendor/TerraWasm/SOURCE_MANIFEST.json', sha256: sha256(fs.readFileSync(path.join(root, 'native/vendor/TerraWasm/SOURCE_MANIFEST.json'))) };
if (sourceManifest.sha256 !== manifest.sourceManifestSha256) throw new Error('Engine artifact was built from a different distributed source manifest');
const context = vm.createContext({console, WebAssembly, TextDecoder, TextEncoder, Uint8Array, ArrayBuffer, setTimeout, clearTimeout, URL, performance,
  window: {}, document: {currentScript: {src: 'http://localhost/world.js'}}, location: {href: 'http://localhost/'}});
vm.runInContext(fs.readFileSync(path.join(engine, 'world.js'), 'utf8'), context, {filename: 'world.js'});
const M = await context.TerraWorldWasmWeb({wasmBinary: fs.readFileSync(path.join(engine, 'world.wasm'))});
const pointer = M._terra_build_info_json();
let end = pointer;
while (M.HEAPU8[end] && end - pointer < 65536) end++;
if (!pointer || end - pointer === 65536) throw new Error('Invalid artifact build metadata');
const buildInfo = JSON.parse(new TextDecoder().decode(M.HEAPU8.subarray(pointer, end)));
const target = path.join(engine, 'circuit_rules.engine-provenance.json');
const prior = JSON.parse(fs.readFileSync(target, 'utf8'));
fs.writeFileSync(target, JSON.stringify({...prior, buildInfo, artifacts, sourceManifest}, null, 2) + '\n');
console.log(JSON.stringify({sourceManifest, capabilities: {pixels: buildInfo.circuitWorldPixels, optimization: buildInfo.circuitWorldOptimization}, artifacts}, null, 2));
