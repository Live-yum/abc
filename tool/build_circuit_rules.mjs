#!/usr/bin/env node
// Original packaging helper. Authoritative behavior is bundled unchanged from
// the attributed source subset or an explicitly supplied verified checkout.
import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { createRequire } from 'node:module';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const commit = '366ebc57751cadfb077f968f4d5069028b3bf9a6';
const sourceArg = process.argv[2] || path.join(root, 'vendor/viewer-circuit');
if (process.argv.length > 4) throw new Error('Usage: node tool/build_circuit_rules.mjs [authorized-source [retrieved-source-manifest.json]]');
const source = await fs.realpath(sourceArg);
const git = (...args) => execFileSync('git', ['-C', source, ...args], { encoding: 'utf8' }).trim();
let manifestBytes = null;
try { manifestBytes = await fs.readFile(process.argv[3] || path.join(source, 'retrieved-source-manifest.json')); }
catch (error) { if (process.argv[3] || error.code !== 'ENOENT') throw error; }
const manifest = manifestBytes ? JSON.parse(manifestBytes) : null;
if ((manifest?.commit || git('rev-parse', 'HEAD')) !== commit) throw new Error(`Authoritative source must be pinned to ${commit}`);
const manifestFiles = new Map((manifest?.files || []).map(file => [file.path, file]));
let esbuild;
try { esbuild = createRequire(path.join(root, 'package.json'))('esbuild'); }
catch (error) {
  if (!process.argv[2]) throw new Error('Run npm ci in the project root before building circuit rules', { cause: error });
  esbuild = createRequire(path.join(source, 'package.json'))('esbuild');
}
if (esbuild.version !== '0.20.1') throw new Error('Circuit rules require the pinned esbuild 0.20.1');
const aliases = {
  editor: 'features/circuit/domain/editor.mjs',
  catalog: 'features/circuit/domain/catalog.mjs',
  model: 'features/circuit/domain/model.mjs',
  'computation-session': 'features/circuit/services/computation-session.mjs',
  memory: 'features/circuit/services/memory.mjs',
  routing: 'features/circuit/domain/routing.mjs',
  'native-traversal': 'features/circuit/runtime/native-traversal.mjs',
};
const hash = bytes => createHash('sha256').update(bytes).digest('hex');
const outputs = [];
const sourceInputs = new Map();
const adapterInputs = new Map();
for (const target of ['native', 'web']) {
  const output = target === 'native' ? 'assets/private/circuit_rules_native.js' : 'web/engine/circuit_rules_web.js';
  const result = await esbuild.build({
    absWorkingDir: root,
    entryPoints: [`web/circuit_rules_adapter/${target}-entry.mjs`],
    bundle: true, write: false, metafile: true, format: 'iife', platform: 'neutral',
    target: 'es2020', charset: 'utf8', legalComments: 'none', minify: true,
    define: { __CIRCUIT_SOURCE_COMMIT__: JSON.stringify(commit) },
    plugins: [{ name: 'verified-authoritative-source', setup(build) {
      build.onResolve({ filter: /^authoritative:/ }, args => {
        const relative = aliases[args.path.slice('authoritative:'.length)];
        if (!relative) throw new Error(`Unknown authoritative import: ${args.path}`);
        return { path: path.join(source, relative) };
      });
      if (target === 'native') build.onResolve({ filter: /(?:^|\/)native-traversal\.mjs$/ }, args => {
        if (args.importer.startsWith(source + path.sep)) return { path: path.join(root, 'web/circuit_rules_adapter/native-traversal.mjs') };
      });
    } }],
  });
  for (const [input, info] of Object.entries(result.metafile.inputs)) {
    if (info.imports.some(value => value.external)) throw new Error('External import in retained rules closure');
    const absolute = path.resolve(root, input), bytes = await fs.readFile(absolute);
    if (absolute.startsWith(source + path.sep)) {
      const relative = path.relative(source, absolute).split(path.sep).join('/');
      if (manifest) {
        const record = manifestFiles.get(relative);
        const blobHash = createHash('sha1').update(`blob ${bytes.length}\0`).update(bytes).digest('hex');
        if (!record || record.size !== bytes.length || record.sha !== blobHash) throw new Error(`Authoritative module differs from retrieved commit manifest: ${relative}`);
      } else {
        const pinned = execFileSync('git', ['-C', source, 'show', `${commit}:${relative}`]);
        if (!bytes.equals(pinned)) throw new Error(`Authoritative module differs from pinned commit: ${relative}`);
      }
      sourceInputs.set(relative, { path: relative, bytes: bytes.length, sha256: hash(bytes) });
    } else {
      if (!absolute.startsWith(path.join(root, 'web/circuit_rules_adapter') + path.sep)) throw new Error('Unexpected bundle input');
      const relative = path.relative(root, absolute).split(path.sep).join('/');
      adapterInputs.set(relative, { path: relative, bytes: bytes.length, sha256: hash(bytes) });
    }
  }
  const bytes = result.outputFiles[0].contents;
  await fs.mkdir(path.dirname(path.join(root, output)), { recursive: true });
  await fs.writeFile(path.join(root, output), bytes);
  outputs.push({ path: output, bytes: bytes.length, sha256: hash(bytes) });
}
const byPath = (a, b) => a.path.localeCompare(b.path, 'en');
const helper = await fs.readFile(fileURLToPath(import.meta.url));
const hosts = [];
for (const relative of ['web/terra_circuit_rules.js', 'web/terra_circuit_rules_worker.js', 'lib/engine/web_engine.dart', 'lib/engine/circuit_rules_backend.dart']) {
  const bytes = await fs.readFile(path.join(root, relative));
  hosts.push({ path: relative, bytes: bytes.length, sha256: hash(bytes) });
}
const provenance = {
  schema: 1, sourceCommit: commit,
  sourceRepository: 'Live-yan/viewer-app',
  sourceUrl: `https://github.com/Live-yan/viewer-app/tree/${commit}/features/circuit`,
  source: 'Authoritative viewer circuit domain, editor, computation session and traversal; included under the user\'s explicit publication authorization',
  distribution: 'User-authorized inclusion in abc source and builds. Preserve source attribution and this provenance. Game artwork, executables and personal saves remain excluded.',
  bundler: { name: 'esbuild', version: esbuild.version },
  sourceVerification: manifest ? { method: 'retrieved-git-blob-manifest', sha256: hash(manifestBytes) } : { method: 'git-commit-blobs' },
  helper: { path: 'tool/build_circuit_rules.mjs', bytes: helper.length, sha256: hash(helper) },
  modules: [...sourceInputs.values()].sort(byPath), adapters: [...adapterInputs.values()].sort(byPath), hosts, outputs,
};
await fs.writeFile(path.join(root, 'assets/private/circuit_rules.provenance.json'), JSON.stringify(provenance, null, 2) + '\n');
console.log(JSON.stringify({ sourceCommit: commit, modules: sourceInputs.size, outputs }, null, 2));
