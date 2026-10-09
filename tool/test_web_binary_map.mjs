import fs from 'node:fs';
import vm from 'node:vm';
import {inflateSync} from 'node:zlib';
import {createRequire} from 'node:module';
import assert from 'node:assert/strict';
const require = createRequire(import.meta.url);
const sandbox = {module:{exports:{}}, TextEncoder, TextDecoder, Uint8Array, DataView, setTimeout, console};
vm.runInNewContext(fs.readFileSync(new URL('../web/terra_engine.js',import.meta.url),'utf8'), sandbox);
const factory = require('../web/engine/world.js');
const bridge = sandbox.module.exports.createBridge(async () => factory({wasmBinary:fs.readFileSync(new URL('../web/engine/world.wasm',import.meta.url))}));
// This marker assertion requires the object fixture's sign/chest contents;
// the generic WLD fixture deliberately contains neither marker target.
const source = new Uint8Array(fs.readFileSync(process.env.TERRA_MAP_WLD_FIXTURE ?? process.env.TERRA_OBJECT_FIXTURE ?? new URL('../assets/qa/synthetic-objects.wld',import.meta.url)));
function validateMap(bytes) {
  const b=Buffer.from(bytes); let p=0;
  const u32=()=>{const n=b.readUInt32LE(p);p+=4;return n;};
  assert.equal(u32(),33083); assert.equal(b.subarray(p,p+8).toString('hex'),'72656c6f67696301'); p+=20;
  let n=0,shift=0,byte;
  do { byte=b[p++]; n+=(byte&127)*2**shift; shift+=7; } while(byte&128);
  p+=n+4; const height=u32(),width=u32();
  const counts=Array.from({length:6},()=>{const n=b.readUInt16LE(p);p+=2;return n;});
  const tileBits=b.subarray(p,p+Math.ceil(counts[0]/8));p+=tileBits.length;
  const wallBits=b.subarray(p,p+Math.ceil(counts[1]/8));p+=wallBits.length;
  for(const [count,bits] of [[counts[0],tileBits],[counts[1],wallBits]]) for(let i=0;i<count;i++) if(bits[i>>3]&(1<<(i&7)))p++;
  let chunks=0;
  for(let y=0;y<height;y+=64)for(let x=0;x<width;x+=64){const size=u32(); assert.equal(inflateSync(b.subarray(p,p+size)).length,16384);p+=size;chunks++;}
  assert.equal(p,b.length); return {width,height,chunks};
}
const world=JSON.parse(await bridge.open(source,'wld'));
try {
  for(let cycle=0;cycle<3;cycle++) {
    const plain=await bridge.generateMap(world.handle,'null'); validateMap(plain);
    const marked=await bridge.generateMap(world.handle,JSON.stringify({tile_markers:[{tile_type:55,color:'#FF00FF',radius:2}],chest_markers:[{item_id:8,color:'#00FFFF',radius:2}]}));
    assert.deepEqual(validateMap(marked),validateMap(plain));
    assert.notDeepEqual(marked,plain);
    assert.deepEqual(await bridge.save(world.handle),source);
    await assert.rejects(()=>bridge.generateMap(world.handle,'{"tile_markers":[{"tile_type":"bad"}]}'));
    validateMap(await bridge.generateMap(world.handle,'null'));
    assert.deepEqual(await bridge.save(world.handle),source);
  }
} finally {await bridge.close(world.handle);}
await assert.rejects(()=>bridge.generateMap(world.handle,'null'));
console.log('Binary MAP: full chunk inflation, plain/marked generation, repeated export, rejection recovery, close and unchanged WLD passed.');
