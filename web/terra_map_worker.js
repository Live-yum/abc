/* Dedicated MAP owner. Compiler output installs the synchronous dispatcher. */
(function(scope){
  'use strict';
  function installMapWorker(root, load) {
    let initialized=false;
    root.onmessage=({data})=>{
      if(!data||!Number.isSafeInteger(data.id)||!Number.isSafeInteger(data.generation))return;
      try {
        if(!['open','edit','undo','redo','render','export'].includes(data.method) ||
            typeof data.args!=='string'||data.args.length>256*1024 ||
            (data.bytes!=null&&(!(data.bytes instanceof Uint8Array)||data.bytes.length>128*1024*1024))) {
          throw new Error('MAP worker request exceeds protocol bounds');
        }
        if(!initialized){load();initialized=true;}
        const result=root.terraMapDispatch(data.method,data.args,data.bytes??null);
        const response={id:data.id,generation:data.generation,ok:true,json:result.json,bytes:result.bytes??null};
        root.postMessage(response,response.bytes?[response.bytes.buffer]:[]);
      } catch(error){root.postMessage({id:data.id,generation:data.generation,ok:false,error:String(error?.message||error)});}
    };
  }
  if(typeof module==='object'&&module.exports)module.exports={installMapWorker};
  else installMapWorker(scope,()=>scope.importScripts(new URL('engine/map_worker.js',scope.location.href).href));
})(globalThis);
