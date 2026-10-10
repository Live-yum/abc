'use strict';
// Dedicated Node observer/oracle process, never used for frozen timings.
const fs = require('node:fs');
const vm = require('node:vm');
const [script, fixture] = process.argv.slice(2);
if (!script) throw new Error('Expected a compiled Dart2JS file');
const sandbox = {
  self: null, console, performance, setTimeout, clearTimeout,
  mapMemoryFixture: fixture,
  mapMemorySnapshot() {
    const m = process.memoryUsage();
    return JSON.stringify({rssBytes: m.rss, heapUsedBytes: m.heapUsed,
      externalBytes: m.external, arrayBufferBytes: m.arrayBuffers});
  },
};
sandbox.self = sandbox;
vm.runInNewContext(fs.readFileSync(script, 'utf8'), sandbox, {filename: script});
