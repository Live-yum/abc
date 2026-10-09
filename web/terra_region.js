/* Original bytes-in/bytes-out adapter. Its own WASM instance owns all handles.
 * C facade validates region objects and pumps the authoritative stream writer. */
(function(root){
'use strict';
function createRegionBridge(loadModule){
 let promise,queue=Promise.resolve();
 function run(kind,world,args,records,objects){const work=queue.then(async()=>{
  const M=await(promise??=loadModule()),allocated=[];
  function alloc(bytes){if(!bytes.length)return 0;const p=M._tx_malloc(bytes.length);if(!p)throw new Error('Region allocation failed');allocated.push(p);M.HEAPU8.set(bytes,p);return p;}
  const text=s=>alloc(new TextEncoder().encode(s+'\0'));
  const out=alloc(new Uint8Array(4)),size=alloc(new Uint8Array(4));let result=0;
  try{
   if(!(world instanceof Uint8Array)||!world.length||world.length>64*1024*1024)throw new Error('Invalid world input');
   if(['read','objects','replace'].includes(kind)&&(!args.every(Number.isSafeInteger)||args[0]<0||args[1]<0||args[0]>0x7fffffff||args[1]>0x7fffffff||args[2]<1||args[3]<1||args[2]>16384||args[3]>16384||args[2]*args[3]>262144))throw new Error('Invalid region bounds');
   const input=alloc(world);let status;
   if(kind==='read'||kind==='objects')status=M[kind==='read'?'_abc_region_read':'_abc_region_objects'](input,world.length,...args,out,size);
   else if(kind==='replace')status=M._abc_region_replace(input,world.length,...args,alloc(records),records.length,out,size);
   else if(kind==='pixel'){
    const [x,y,w,h,maps,indices]=args;
    if(![x,y,w,h].every(Number.isSafeInteger)||x< -0x80000000||y< -0x80000000||x>0x7fffffff||y>0x7fffffff||w<1||h<1||w>16384||h>16384||indices.length!==w*h||w*h>262144||maps.length%12||!maps.length||maps.length/12>65536)throw new Error('Invalid indexed pixel input');
    status=M._abc_region_pixel(input,world.length,x,y,w,h,alloc(maps),maps.length/12,alloc(new Uint8Array(indices.buffer,indices.byteOffset,indices.byteLength)),out,size);
   }else status=M._abc_region_operation(input,world.length,text(args[0]),text(args[1]),alloc(records),records.length,alloc(objects),objects.length,out,size);
   result=M.HEAPU32[out>>>2];
   if(status!==0){const error=alloc(new Uint8Array(8192)),needed=alloc(new Uint8Array(8));M._terra_info_get_last_error_json(error,8192n,needed);let end=error;while(end<error+8192&&M.HEAPU8[end])end++;throw new Error(new TextDecoder().decode(M.HEAPU8.subarray(error,end))||'Region operation failed');}
   const n=M.HEAPU32[size>>>2];if(n>512*1024*1024||result+n>M.HEAPU8.length)throw new Error('Invalid region output');return M.HEAPU8.slice(result,result+n);
  }finally{if(result)M._abc_region_free(result);allocated.forEach(p=>M._tx_free(p));}
 });queue=work.catch(()=>{});return work;}
 function match(rgb,candidates,flags,mode){const work=queue.then(async()=>{
  if(rgb.length>65536||candidates.length>65536||candidates.length!==flags.length)throw new Error('Invalid colour matching length');
  const M=await(promise??=loadModule()),c=M._tx_malloc(candidates.length*8+8),q=M._tx_malloc(rgb.length*4+4),out=M._tx_malloc(rgb.length*4+4);
  try{if(!c||!q||!out)throw new Error('Colour match allocation failed');for(let i=0;i<candidates.length;i++){M.HEAPU32[(c>>>2)+i*2]=candidates[i];M.HEAPU32[(c>>>2)+i*2+1]=flags[i];}M.HEAPU32.set(rgb,q>>>2);
   const status=M._terra_pixel_workspace_match_colors(c,candidates.length,q,rgb.length,mode,out);if(status!==0)throw new Error('Core colour matching failed: '+status);return M.HEAPU32.slice(out>>>2,(out>>>2)+rgb.length);
  }finally{if(c)M._tx_free(c);if(q)M._tx_free(q);if(out)M._tx_free(out);}
 });queue=work.catch(()=>{});return work;}
 return {match,objects:(world,x,y,w,h)=>run('objects',world,[x,y,w,h]),replace:(world,x,y,w,h,records)=>run('replace',world,[x,y,w,h],records),read:(world,x,y,w,h)=>run('read',world,[x,y,w,h]),operation:(world,op,json,records,objects)=>run('operation',world,[op,json],records,objects),pixel:(world,x,y,w,h,maps,indices)=>run('pixel',world,[x,y,w,h,maps,indices])};
}
async function load(){const base=new URL('engine/',root.document.baseURI);await new Promise((resolve,reject)=>{const s=root.document.createElement('script');s.src=new URL('world.js',base).href;s.onload=resolve;s.onerror=()=>reject(new Error('Missing verified region WASM'));root.document.head.appendChild(s);});return root.TerraWorldWasmWeb({locateFile:f=>new URL(f.endsWith('.wasm')?'world.wasm':f,base).href});}
root.createRegionBridge=createRegionBridge;
function workerBridge(){
 const url=new URL('terra_region_worker.js',root.document.baseURI),worker=new Worker(url),pending=new Map();let sequence=0,failed=null;
 worker.onmessage=({data})=>{const p=pending.get(data.id);if(!p)return;pending.delete(data.id);data.error?p.reject(new Error(data.error)):p.resolve(data.value);};
 worker.onerror=event=>{failed=new Error(event.message||'Region worker failed');worker.terminate();for(const p of pending.values())p.reject(new Error(event.message||'Region worker failed'));pending.clear();};
 const invoke=(method,args)=>new Promise((resolve,reject)=>{if(failed){reject(failed);return;}const id=++sequence;pending.set(id,{resolve,reject});worker.postMessage({id,method,args});});
 return Object.fromEntries(['read','objects','replace','operation','pixel','match'].map(method=>[method,(...args)=>invoke(method,args)]));
}
root.terraRegion=root.document&&typeof root.Worker==='function'?workerBridge():createRegionBridge(load);
if(typeof module==='object'&&module.exports)module.exports={createRegionBridge};
})(globalThis);
