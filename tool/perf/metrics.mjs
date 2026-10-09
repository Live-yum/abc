// Shared, dependency-free benchmark report. Values are measurements, not budgets.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {performance} from 'node:perf_hooks';
import {randomUUID, createHash} from 'node:crypto';
import {execFileSync} from 'node:child_process';

export class Measurements {
  constructor(suite, options = {}) {
    this.tier = process.env.ABC_PERF_TIER || 'ci';
    if (!['ci', 'local', 'soak'].includes(this.tier)) throw new Error('Invalid ABC_PERF_TIER');
    this.cycles = Number(process.env.ABC_PERF_CYCLES || ({ci: 25, local: 10, soak: 50}[this.tier]));
    this.warmup = Number(process.env.ABC_PERF_WARMUP || 5);
    if (!Number.isInteger(this.cycles) || this.cycles < 3 || !Number.isInteger(this.warmup) || this.warmup < 1) throw new Error('Use at least three measured cycles and one warmup');
    this.rows = new Map(); this.cycle = -1; this.modules = []; this.owners = new Set();
    this.report = {schema: 'abc.performance.v1', runId: randomUUID(), suite, runtime: `node-${process.versions.node}`, buildMode: 'release-wasm-node', tier: this.tier,
      source: sourceRevision(),
      toolchain: {node:process.versions.node,v8:process.versions.v8,hostCompiler: command('cc',['--version'])?.split('\n')[0] || 'unknown',flutterPinned:fs.existsSync('.flutter-version')?fs.readFileSync('.flutter-version','utf8').trim():'unknown',emscripten:manifestVersion(),artifacts:[]},
      machine: {platform: process.platform, osImage:process.env.ABC_PERF_OS_IMAGE||process.env.ImageOS||osImage(), kernel:os.release(), arch: process.arch, cpuModel: os.cpus()[0]?.model, logicalCpus: os.cpus().length},
      methodology: {clock: 'performance.now', cold: 'First complete workload cycle in this process; an operation can repeat within that cycle. Codec bootstrap may already occur during fixture preparation. OS file cache is not flushed.', warmupCycles: this.warmup, measuredCycles: this.cycles,
        timing: 'Awaited core/bridge operation latency; not browser frames or interaction smoothness',
        bookkeeping: 'Raw samples/report metadata are retained in this process and contribute to JS heap/RSS. Compare equal cycle counts; core live-payload counters are separate from this host bookkeeping.',
        memory: 'RSS and JS heap are process-wide. wasmCapacityBytes is retained linear-memory capacity, NOT live allocation bytes. wasmNativeLiveBytes and wasmBridgeLiveBytes use exported tx allocator live-payload counters (native includes persistent roots; excludes libc allocations and allocator headers). Owned handles count explicit harness owners only. GC samples are recorded separately when --expose-gc is used.'},
      fixtures: [], operations: [], memory: [], gaps: [], status: 'running', ...options};
  }
  journal(output) {
    this.journalPath=`${output}.events.jsonl`;
    fs.mkdirSync(path.dirname(output),{recursive:true});
    this.event({event:'run-start',suite:this.report.suite,tier:this.tier,cycles:this.cycles,warmup:this.warmup});
  }
  event(value) {
    if(this.journalPath)fs.appendFileSync(this.journalPath,JSON.stringify({runId:this.report.runId,...value})+'\n');
  }
  fixture(id, kind, bytes, provenance = 'original-synthetic') {
    this.report.fixtures.push({id, kind, bytes: bytes.length, sha256:createHash('sha256').update(bytes).digest('hex'), provenance});
  }
  async measure(id, fixture, bytesPerOperation, fn) {
    this.report.lastOperation={id,fixture,cycle:this.cycle};
    this.event({event:'begin',id,fixture,cycle:this.cycle,rssBytes:process.memoryUsage().rss});
    const start = performance.now();
    let result;
    try { result = await fn(); }
    catch (error) { this.report.failure = {operation: id, fixture, cycle: this.cycle, errorType: error?.name || 'Error'}; throw error; }
    const elapsed = performance.now() - start;
    this.event({event:'end',id,fixture,cycle:this.cycle,durationMs:elapsed,rssBytes:process.memoryUsage().rss,maxRssBytes:process.resourceUsage().maxRSS*1024});
    const phase = this.cycle === -1 ? 'cold' : 'warm';
    if (this.cycle >= 0 && this.cycle < this.warmup) return result;
    const key = `${id}/${fixture}/${phase}`;
    if (!this.rows.has(key)) this.rows.set(key, {id, fixture, phase, unit: 'ms', warmup: phase === 'cold' ? 0 : this.warmup, bytesPerOperation, samplesMs: []});
    this.rows.get(key).samplesMs.push(elapsed);
    return result;
  }
  memory(phase) {
    const m = process.memoryUsage();
    const unique = [...new Set(this.modules)];
    this.report.memory.push({cycle: this.cycle, phase, rssBytes: m.rss, heapUsedBytes: m.heapUsed, heapCapacityBytes: m.heapTotal,
      externalBytes: m.external, arrayBufferBytes: m.arrayBuffers, wasmCapacityBytes: unique.reduce((n, m) => n + m.HEAPU8.buffer.byteLength, 0),
      wasmNativeLiveBytes: unique.every(m=>typeof m._tx_native_heap_used==='function') ? unique.reduce((n,m)=>n+m._tx_native_heap_used(),0) : null,
      wasmBridgeLiveBytes: unique.every(m=>typeof m._tx_bridge_heap_used==='function') ? unique.reduce((n,m)=>n+m._tx_bridge_heap_used(),0) : null,
      ownedHandles: this.owners.size});
  }
  async afterClose() {
    if (this.owners.size) throw new Error('Benchmark leaked an explicitly owned handle');
    this.memory('after-close');
    if (this.report.memory.at(-1).wasmBridgeLiveBytes > 0) throw new Error('WASM bridge allocation remains live after complete close cycle');
    if (this.report.memory.at(-1).wasmNativeLiveBytes > 0) throw new Error('WASM native/persistent allocation remains live after complete close cycle');
    if (global.gc) { global.gc(); await new Promise(r => setImmediate(r)); global.gc(); this.memory('after-close-gc'); }
  }
  write(output, status = 'passed') {
    this.report.status = status;
    this.report.operations = [...this.rows.values()].map(row => {
      const sorted = [...row.samplesMs].sort((a, b) => a-b), n = sorted.length;
      const medianMs = n % 2 ? sorted[(n-1)/2] : (sorted[n/2-1]+sorted[n/2])/2;
      return {...row, iterations: n, medianMs, p95Ms: sorted[Math.ceil(n*0.95)-1], maxMs: sorted[n-1], throughputPerSecond: 1000*n/row.samplesMs.reduce((a,b)=>a+b,0)};
    });
    fs.mkdirSync(path.dirname(output), {recursive: true});
    fs.writeFileSync(output, JSON.stringify(this.report, null, 2)+'\n');
    if(status!=='running')this.event({event:'run-end',status});
  }
}

function command(name,args) {try{return execFileSync(name,args,{encoding:'utf8',stdio:['ignore','pipe','ignore']}).trim();}catch{return null;}}
function sourceRevision() {
  const workingCommit=command('git',['rev-parse','HEAD']);
  const status=command('git',['status','--porcelain','--untracked-files=normal']);
  return {commit:process.env.ABC_PERF_COMMIT||process.env.GITHUB_SHA||workingCommit||'unknown',worktreeCommit:workingCommit||'unknown',dirty:status===null?'unknown':status.length>0,commitSource:process.env.ABC_PERF_COMMIT?'ABC_PERF_COMMIT':process.env.GITHUB_SHA?'GITHUB_SHA':workingCommit?'git':'unknown'};
}
function manifestVersion() {try{return JSON.parse(fs.readFileSync('web/engine/manifest.json','utf8')).emscripten||'unknown';}catch{return 'unknown';}}
function osImage(){try{return fs.readFileSync('/etc/os-release','utf8').match(/^PRETTY_NAME="?(.+?)"?$/m)?.[1]||'unknown';}catch{return 'unknown';}}
