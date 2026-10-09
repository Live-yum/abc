import fs from 'node:fs';
import path from 'node:path';
import {performance, PerformanceObserver} from 'node:perf_hooks';

// Stream each record immediately. No cross-cycle GC/sample array is retained.
// V8 observer delivery is asynchronous: GC startTime, not callback time, is the
// attribution clock. Cycle files and operation intervals must be joined by it.
export class DiagnosticProbe {
  constructor(directory, bench) {
    this.directory = directory;
    this.bench = bench;
    this.fd = null;
    this.cycle = null;
    this.sequence = 0;
    this.gcCount = 0;
    this.observerMs = 0;
    this.boundaryMs = 0;
    this.writeMs = 0;
    fs.mkdirSync(directory, {recursive: false});
    this.observer = new PerformanceObserver(list => {
      const begin = performance.now();
      this.recordGc(list.getEntries());
      this.observerMs += performance.now() - begin;
    });
    this.observer.observe({entryTypes: ['gc']});
  }
  emit(record) {
    if (this.fd === null) throw new Error('Diagnostic record outside an open observation cycle');
    const begin = performance.now();
    fs.writeSync(this.fd, JSON.stringify({sequence: this.sequence++, observedCycle: this.cycle, ...record}) + '\n');
    this.writeMs += performance.now() - begin;
  }
  recordGc(entries) {
    for (const entry of entries) {
      this.gcCount++;
      this.emit({event: 'gc', startMs: entry.startTime, durationMs: entry.duration,
        detail: entry.detail, deliveredMs: performance.now()});
    }
  }
  startCycle(cycle) {
    if (this.fd !== null) throw new Error('Previous observation cycle was not closed');
    this.cycle = cycle;
    this.fd = fs.openSync(path.join(this.directory, `cycle-${String(cycle).padStart(2, '0')}.jsonl`), 'wx');
    this.gcCount = this.observerMs = this.boundaryMs = this.writeMs = 0;
    this.emit({event: 'cycle-start', startMs: performance.now(), timeOriginMs: performance.timeOrigin});
    this.boundary('cycle-before');
  }
  boundary(event, id = null, fixture = null) {
    const begin = performance.now();
    const memory = process.memoryUsage();
    const modules = [...new Set(this.bench.modules)];
    const wasmCapacityBytes = modules.reduce((n, m) => n + m.HEAPU8.buffer.byteLength, 0);
    const nativeLiveBytes = modules.reduce((n, m) => n + m._tx_native_heap_used(), 0);
    const bridgeLiveBytes = modules.reduce((n, m) => n + m._tx_bridge_heap_used(), 0);
    const sampledMs = performance.now();
    this.emit({event, id, fixture, observationStartMs: begin, sampledMs,
      memory, moduleCount: modules.length, wasmCapacityBytes, nativeLiveBytes,
      bridgeLiveBytes, ownedHandles: this.bench.owners.size});
    this.boundaryMs += performance.now() - begin;
  }
  async endCycle() {
    this.boundary('cycle-after');
    // Let GC records from unchanged afterClose() reach the observer. These
    // diagnostic-only turns are outside the original per-operation timers.
    await new Promise(resolve => setImmediate(resolve));
    this.recordGc(this.observer.takeRecords());
    await new Promise(resolve => setImmediate(resolve));
    this.recordGc(this.observer.takeRecords());
    this.emit({event: 'cycle-end', endMs: performance.now(), gcCount: this.gcCount,
      overhead: {boundaryWallMs: this.boundaryMs, observerCallbackWallMs: this.observerMs,
        fileWriteWallMs: this.writeMs, note: 'Nested totals overlap. Observer callbacks can overlap an awaited timed operation. Final record/close overhead is not included.'}});
    fs.closeSync(this.fd);
    this.fd = null;
  }
  async close() {
    if (this.fd !== null) await this.endCycle();
    this.observer.disconnect();
  }
}
