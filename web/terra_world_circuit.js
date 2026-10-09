/* Original whole-world VM host. Engine artifacts are separately authorized.
 * Independent module owns its WLD; events use the documented Wasm32 ABI only. */
(function(root){
'use strict';
function createWorldCircuitBridge(loadModule){
 let promise,queue=Promise.resolve(),session=null;
 const worldCheck=s=>{if(s!==0)throw new Error('World decoder status '+s);return s;};
 const check=s=>{if(s<0)throw new Error('World circuit engine status '+s);return s;};
 const serial=fn=>{const p=queue.then(fn);queue=p.catch(()=>{});return p;};
 function buildInfo(M){
  const p=M._terra_build_info_json?.();if(!p)throw new Error('Missing circuit build identity');
  let end=p;while(end<M.HEAPU8.length&&end-p<65536&&M.HEAPU8[end])end++;
  if(end===M.HEAPU8.length||end-p===65536)throw new Error('Invalid circuit build identity');
  return JSON.parse(new TextDecoder().decode(M.HEAPU8.subarray(p,end)));
 }
 function validateObjects(bytes,maxBytes,maxObjects){
  if(bytes.length<32||bytes.length>maxBytes)throw new Error('Invalid circuit object companion size');
  const d=new DataView(bytes.buffer,bytes.byteOffset,bytes.byteLength),word=at=>d.getUint32(at,true),count=word(12);
  if(word(0)!==0x31424f43||word(4)!==1||word(16)!==bytes.length||count>maxObjects||word(28)!==0)throw new Error('Invalid circuit COB1 companion');
  let at=32;
  for(let i=0;i<count;i++){
   if(at+32>bytes.length)throw new Error('Truncated circuit object');
   const section=word(at),kind=word(at+4),length=word(at+20);
   if(![2,3,5].includes(section)||(section!==5&&kind!==0)||(section===5&&kind>10)||word(at+16)>65535||word(at+24)!==0||word(at+28)!==0||at+32+length>bytes.length)throw new Error('Invalid circuit object record');
   at+=32+length;
  }
  if(at!==bytes.length)throw new Error('Trailing circuit object data');
 }

 async function open(world,twld){return serial(async()=>{
  if(session)throw new Error('Close the existing world circuit first');
  const M=await(promise??=loadModule());
  for(const n of ['begin','step','supply','ack','command','stats','cancel','close'])if(typeof M['_terra_circuit_world_'+n]!=='function')throw new Error('World circuit ABI missing '+n);
  if(!world.length||world.length>64*1024*1024||(twld?.length||0)>16*1024*1024)throw new Error('World input exceeds host budget');
  const out=M._tx_malloc(4),input=M._tx_malloc(world.length);let handle=0,w=0,task=0;
  try{
   if(!out||!input)throw new Error('Circuit allocation failed');M.HEAPU8.set(world,input);M.HEAPU32[out>>>2]=0;
   task=M._terra_world_open_begin(input,world.length);if(!task)throw new Error('Cannot begin world decode');let status;do{status=M._terra_world_open_step(task,64);if(status===10)await new Promise(r=>setTimeout(r,0));}while(status===10);worldCheck(status);worldCheck(M._terra_world_open_finish(task,out));w=M.HEAPU32[out>>>2];M._terra_world_task_close(task);task=0;
   check(M._terra_circuit_world_begin(w,2,twld&&twld.length?4:0,twld?.length||0,128*1024*1024,out));handle=M.HEAPU32[out>>>2];
   session={M,handle,world:w,files:new Map([[2,new Uint8Array()],[3,new Uint8Array()],[4,twld?twld.slice():new Uint8Array()],[5,new Uint8Array()],[6,new Uint8Array()]]),hasTwld:!!twld?.length};
   return await pump();
  }catch(e){if(handle)M._terra_circuit_world_close(handle);if(w)M._terra_world_close(w);session=null;throw e;}
  finally{if(task){M._terra_world_open_cancel(task);M._terra_world_task_close(task);}if(out)M._tx_free(out);if(input)M._tx_free(input);}
 });}
 async function pump(command){
  const kindExpected=command?.[1]||0,save=kindExpected===6,fragments=kindExpected===7||kindExpected===8,withObjects=kindExpected===8&&command[12]===1;
  const recordSize=fragments?32:16,recordLimit=fragments?command[8]:8*1024*1024/16;
  const {M,handle,files}=session, event=M._tx_malloc(48),stats=M._tx_malloc(96);
  let result=new Uint8Array(),batches=0,resultKind=0,resultCount=0,reserved=0,objectBytes=0;
  try{if(!event||!stats)throw new Error('Circuit allocation failed');
   for(;;){check(M._terra_circuit_world_step(handle,4096,event));const e=Array.from(M.HEAPU32.subarray(event>>>2,(event>>>2)+12));
    const [abi,kind,source,offset,length,pointer]=e;if(abi!==1)throw new Error('Unsupported circuit ABI');if(kind===4){
     resultKind=e[9];resultCount=e[10];reserved=e[11];
     if(resultKind!==kindExpected||(kindExpected===8&&resultCount*32!==result.length)||(kindExpected===7&&resultCount<result.length/32))throw new Error('Incomplete circuit result');
     break;
    }
    if(length>1024*1024||offset+length>128*1024*1024)throw new Error('Circuit I/O exceeds host budget');
    if(kind===1){const sourceBytes=files.get(source);if(!sourceBytes||offset+length>sourceBytes.length)throw new Error('Missing circuit input');const p=M._tx_malloc(length);try{if(!p)throw new Error('Circuit allocation failed');M.HEAPU8.set(sourceBytes.subarray(offset,offset+length),p);check(M._terra_circuit_world_supply(handle,source,offset,p,length));}finally{if(p)M._tx_free(p);}}
    else if(kind===2||kind===3){if((!pointer&&length)||pointer+length>M.HEAPU8.length)throw new Error('Invalid circuit output');const bytes=M.HEAPU8.slice(pointer,pointer+length);
     if(kind===2){
      if(source===6){if(!withObjects||offset!==objectBytes||length>65536||offset+length>command[4])throw new Error('Invalid circuit companion output');objectBytes+=length;}
      else if(source!==2&&!(save&&(source===3||source===5)))throw new Error('Unexpected circuit output source');
      let target=files.get(source);if(!target||source===4)throw new Error('Invalid circuit target');if(offset+length>target.length){const next=new Uint8Array(offset+length);next.set(target);target=next;files.set(source,target);}target.set(bytes,offset);}
     else{if(e[9]!==kindExpected||length!==e[10]*recordSize||result.length+length>recordLimit*recordSize)throw new Error('Circuit query exceeds host budget');const next=new Uint8Array(result.length+length);next.set(result);next.set(bytes,result.length);result=next;}
     check(M._terra_circuit_world_ack(handle));
    }else if(kind!==0)throw new Error('Unknown circuit event');
    if(++batches%16===0)await new Promise(r=>setTimeout(r,0));
   }
   const objects=withObjects?files.get(6).slice():null;
   if(objects)validateObjects(objects,command[4],command[5]);
   check(M._terra_circuit_world_stats(handle,stats));return {session:handle,resultKind,resultCount,reserved,objects,stats:Array.from(M.HEAPU32.subarray(stats>>>2,(stats>>>2)+24)),records:result,world:save?files.get(3).slice():null,twld:save&&session.hasTwld?files.get(5).slice():null};
  }finally{if(event)M._tx_free(event);if(stats)M._tx_free(stats);}
 }
 function command(id,json,recordsJson){return serial(async()=>{
  if(!session||id!==session.handle)throw new Error('Circuit session is closed');
  const words=JSON.parse(json),records=JSON.parse(recordsJson),{M,handle,files}=session;
  if(!Array.isArray(words)||!Array.isArray(records)||words.length!==16||words[0]!==1||words[1]<1||words[1]>8||words[9]!==0||words[14]!==0||words[15]!==0||records.length!==words[10]*4||records.length>65536*4||[...words,...records].some(v=>!Number.isInteger(v)||v<0||v>0xffffffff))throw new Error('Invalid circuit command');
  if(words[1]===7||words[1]===8){
   if(words[8]<1||words[8]>32768)throw new Error('Circuit fragments are limited to 32768 records');
   const info=buildInfo(M);
   if(words[1]===7){
    for(let i=0;i<records.length;i+=4){const shape=records[i+2],w=(shape>>>16)&255,h=shape>>>24;
     if(records[i]>65535||!w||!h||(shape&255)>=w||((shape>>>8)&255)>=h||records[i+3]>17)throw new Error('Invalid circuit object geometry');
     if(records[i+3]!==0&&info.circuitWorldFragmentSupports!==1)throw new Error('Circuit placement supports are unavailable');
    }
   }else{
    if(records.length||words[12]>1||(words[12]===1&&(words[13]!==6||words[4]<32||words[4]>4*1024*1024||words[5]<1||words[5]>32768))||(words[12]===0&&words[13]!==0))throw new Error('Invalid circuit companion extraction');
    if(words[12]===1&&info.circuitWorldFragmentObjects!==1)throw new Error('Circuit object companions are unavailable');
   }
  }
  const p=M._tx_malloc(64),r=M._tx_malloc(Math.max(4,records.length*4));
  try{if(!p||!r)throw new Error('Circuit allocation failed');M.HEAPU32.set(records,r>>>2);words[9]=r;M.HEAPU32.set(words,p>>>2);if(words[1]===6){files.set(3,new Uint8Array());files.set(5,new Uint8Array());}if(words[1]===8)files.set(6,new Uint8Array());check(M._terra_circuit_world_command(handle,p));return await pump(words);}
  catch(e){M._terra_circuit_world_cancel(handle);if(words[1]===8)files.set(6,new Uint8Array());throw e;}
  finally{if(p)M._tx_free(p);if(r)M._tx_free(r);}
 });}
 function close(id){return serial(async()=>{if(!session||id!==session.handle)return;const{M,handle,world}=session;check(M._terra_circuit_world_close(handle));worldCheck(M._terra_world_close(world));session=null;});}
 return {open,command,close};
}
async function load(){const base=new URL('engine/',root.document.baseURI);await new Promise((resolve,reject)=>{const s=root.document.createElement('script');s.src=new URL('world.js',base).href;s.onload=resolve;s.onerror=()=>reject(new Error('Missing verified whole-world circuit WASM'));root.document.head.appendChild(s);});return root.TerraWorldWasmWeb({locateFile:f=>new URL(f.endsWith('.wasm')?'world.wasm':f,base).href});}
root.terraWorldCircuit=createWorldCircuitBridge(load);
if(typeof module==='object'&&module.exports)module.exports={createWorldCircuitBridge};
})(globalThis);
