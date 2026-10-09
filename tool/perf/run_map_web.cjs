// Run the actual cross-platform Dart MAP codec, compiled with dart compile js.
// Optional input is read only on this machine and never uploaded or published.
const fs = require('node:fs'), vm = require('node:vm'), crypto = require('node:crypto');
const {metadata}=require('./map_report_metadata.cjs');
const [script, output, input, provenance = 'authorized-local-input', count = '10'] = process.argv.slice(2);
if (!script || !output) throw new Error('Usage: node run_map_web.cjs COMPILED_JS REPORT [LOCAL_MAP PROVENANCE ITERATIONS]');
const original = input ? fs.readFileSync(input) : null;
const hash = b => crypto.createHash('sha256').update(b).digest('hex');
const sandbox = {self: null, console, performance, setTimeout, clearTimeout,
  mapPerfMemory: () => { const m=process.memoryUsage(); return JSON.stringify({rssBytes:m.rss,heapUsedBytes:m.heapUsed,heapCapacityBytes:m.heapTotal,externalBytes:m.external,arrayBufferBytes:m.arrayBuffers}); },
  mapPerfInput: JSON.stringify({base64: original?.toString('base64'), provenance, iterations: Number(count), tier:process.env.ABC_PERF_TIER||'local'})};
sandbox.self = sandbox;
vm.runInNewContext(fs.readFileSync(script, 'utf8'), sandbox, {filename: script});
const report = JSON.parse(sandbox.mapPerfOutput);
Object.assign(report,metadata([['compiled-map-benchmark',script]]));
if (original && hash(original) !== hash(fs.readFileSync(input))) throw new Error('MAP source changed');
report.sourcePreserved = true;
report.gaps.push('Node executes Dart2JS output; this is not a browser/Flutter UI measurement.');
report.gaps.push('Dart2JS Stopwatch has millisecond resolution here; a reported zero is below resolution, not zero cost.');
fs.writeFileSync(output, JSON.stringify(report, null, 2) + '\n');
console.log(JSON.stringify({status: report.status, fixtures: report.fixtures.length, sourcePreserved: true}));
