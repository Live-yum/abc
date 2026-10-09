// Actual WASM plus the original generated WLD. A Dart proof directory is optional.
const fs=require('node:fs'),assert=require('node:assert/strict'),vm=require('node:vm');
const {createWorldCircuitBridge}=require('../../web/terra_world_circuit.js');
const {createRegionBridge}=require('../../web/terra_region.js');
(async()=>{
 const context=vm.createContext({console,WebAssembly,TextDecoder,TextEncoder,Uint8Array,ArrayBuffer,setTimeout,clearTimeout,URL,performance,window:{},document:{currentScript:{src:'http://localhost/world.js'}},location:{href:'http://localhost/'}});
 vm.runInContext(fs.readFileSync(process.argv[2],'utf8'),context);
 const load=()=>context.TerraWorldWasmWeb({wasmBinary:fs.readFileSync(process.argv[3])});
 const input=process.argv[4],isProof=fs.statSync(input).isDirectory();
 const proof=isProof?JSON.parse(fs.readFileSync(`${input}/fragment.json`,'utf8')):null;
 const source=new Uint8Array(fs.readFileSync(isProof?`${input}/source.wld`:input)),original=source.slice();
 const geometry=[];
 for(const [tile,width,height] of [[21,2,2],[55,2,2],[378,2,3]])for(let x=0;x<width;x++)for(let y=0;y<height;y++)geometry.push(tile,x*18|(y*18<<16),x|(y<<8)|(width<<16)|(height<<24),1);
 if(proof)assert.deepEqual(geometry,proof.geometry);
 const bridge=createWorldCircuitBridge(load), opened=await bridge.open(source,null),id=opened.session;
 const page=(offset,geometry=[])=>bridge.command(id,JSON.stringify([1,7,offset,0,0,0,1,0,1,0,geometry.length/4,0,0,0,0,0]),JSON.stringify(geometry));
 const first=await page(0,geometry),second=await page(1);
 assert.equal(first.resultKind,7);assert.equal(first.resultCount,2);assert.equal(first.records.length,32);assert.equal(second.resultCount,2);
 const extract=(fragment,count=32768)=>bridge.command(id,JSON.stringify([1,8,0,0,4194304,32768,1,fragment,count,0,0,0,1,6,0,0]),'[]');
 const descriptors=[first,second].map(p=>Array.from({length:8},(_,i)=>new DataView(p.records.buffer).getUint32(i*4,true)));
 const descriptor=descriptors.find(d=>(d[7]&2)!==0),selectedId=descriptor[0];
 assert.deepEqual(descriptor.slice(1,6),[1,2,10,4,24]);assert.ok(descriptor[6]>0&&descriptor[6]<=10);assert.equal(descriptor[7],2);
 const selected=await extract(selectedId),objects=selected.objects.slice();
 assert.equal(selected.resultKind,8);assert.equal(selected.resultCount*32,selected.records.length);
 if(proof)assert.equal(Buffer.from(objects).toString('base64'),proof.objects);
 const bundle=new DataView(objects.buffer);assert.equal(objects.length,253);
 assert.deepEqual(Array.from({length:8},(_,i)=>bundle.getUint32(i*4,true)),[0x31424f43,1,139,3,253,1,2,0]);
 const expectedSections=[[2,0,0,0,21,104],[3,0,4,0,55,19],[5,0,8,0,378,2]];
 let objectAt=32;
 for(const expected of expectedSections){
  assert.deepEqual(Array.from({length:6},(_,i)=>bundle.getUint32(objectAt+i*4,true)),expected);
  const bytes=objects.slice(objectAt+32,objectAt+32+expected[5]);
  if(expected[0]===2){assert.equal(new TextDecoder().decode(bytes.slice(1,15)),'Keep\0inventory');const chest=new DataView(bytes.buffer);assert.equal(chest.getUint32(15,true),40);assert.equal(chest.getInt16(19,true),9);assert.equal(chest.getInt32(21,true),8);assert.equal(bytes[25],3);}
  if(expected[0]===3)assert.equal(new TextDecoder().decode(bytes.slice(1)),'Original\0sign text');
  if(expected[0]===5)assert.deepEqual(Array.from(bytes),[255,255]);
  objectAt+=32+expected[5];
 }
 const records=selected.records.slice(),data=new DataView(records.buffer),header=new DataView(objects.buffer);
 for(let i=0;i<records.length;i+=32){data.setUint32(i,data.getUint32(i,true)-header.getUint32(20,true),true);data.setUint32(i+4,data.getUint32(i+4,true)-header.getUint32(24,true),true);}
 if(proof)assert.equal(Buffer.from(records).toString('base64'),proof.records);
 const other=descriptors.find(d=>d[0]!==selectedId)[0];
 const wireOnly=await extract(other);assert.equal(wireOnly.objects.length,32);assert.deepEqual(selected.objects,objects);
 await assert.rejects(()=>extract(selectedId,1));await extract(selectedId);await bridge.close(id);
 const regions=createRegionBridge(load);
 const request={x:18,y:10,width:10,height:4,recordCount:24,recordSourceId:2,mode:'overlay',objectSourceId:3,objectBytes:253,objectCount:3};
 if(proof)assert.deepEqual(request,proof.request);
 const candidate=await regions.operation(source,'stamp_tiles',JSON.stringify(request),records,objects);
 const {x,y,width,height}=request;
 const reread=await regions.objects(candidate,x,y,width,height);
 assert.deepEqual(reread.slice(32),objects.slice(32));
 await assert.rejects(()=>regions.operation(candidate,'stamp_tiles',JSON.stringify(request),records,objects));
 assert.deepEqual(source,original);
 console.log('PASS: actual WASM fragments/extraction, original chest/sign/entity payloads, budget recovery, object-preserving stamp and collision rejection'+(proof?', exact native cell/COB1 parity':''));
})().catch(e=>{console.error(e);process.exitCode=1;});
