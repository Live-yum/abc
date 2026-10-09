/* Original MAP RPC adapter. Decoded grids never leave the owner worker. */
(function(root) {
  'use strict';
  const METHODS=new Set(['open','edit','undo','redo','render','export']);
  const INPUT_LIMIT=128*1024*1024, META_LIMIT=512*1024;
  function createTerraMapClient({createWorker, timeoutMs=120000}={}) {
    let worker=null, sequence=0, generation=0, queuedBytes=0;
    const pending=new Map();
    function shutdown(reason) {
      generation++;
      const previous=worker; worker=null;
      if(previous) {previous.onmessage=previous.onerror=previous.onmessageerror=null;previous.terminate();}
      for(const p of pending.values()) {clearTimeout(p.timer);p.reject(reason);}
      pending.clear();queuedBytes=0;
    }
    function ensure() {
      if(worker)return worker;
      const current=(createWorker || (()=>new root.Worker(new URL('terra_map_worker.js',root.document.baseURI))))();
      worker=current;
      current.onmessage=({data})=>{
        if(worker!==current || !data || data.generation!==generation)return;
        const request=pending.get(data.id);if(!request)return;
        pending.delete(data.id);queuedBytes-=request.byteLength;clearTimeout(request.timer);
        if(data.ok!==true) {request.reject(new Error(data.error||'MAP owner failed'));return;}
        if(typeof data.json!=='string'||data.json.length>META_LIMIT ||
            (data.bytes!=null && (!(data.bytes instanceof Uint8Array)||data.bytes.length>INPUT_LIMIT))) {
          request.reject(new Error('Invalid MAP worker reply'));return;
        }
        request.resolve({json:data.json,bytes:data.bytes??null});
      };
      current.onerror=current.onmessageerror=()=>{
        if(worker===current)shutdown(new Error('MAP worker stopped; reopen the MAP'));
      };
      return current;
    }
    function invoke(method,args,bytes) {
      try {
        if(!METHODS.has(method)||typeof args!=='string'||args.length>META_LIMIT)throw new Error('Invalid MAP request');
        const parsed=JSON.parse(args);
        if(!parsed||typeof parsed!=='object'||Array.isArray(parsed))throw new Error('MAP arguments must be an object');
        if(method==='open' && (!(bytes instanceof Uint8Array)||bytes.length<4||bytes.length>INPUT_LIMIT))throw new Error('Invalid MAP input size');
        if(method!=='open' && bytes!=null)throw new Error('Only MAP open accepts input bytes');
        const size=bytes?.length||0;
        if(pending.size>=8||queuedBytes+size>INPUT_LIMIT)throw new Error('MAP request queue is full');
        const current=ensure(),id=++sequence;
        // Transfer a dedicated copy so the caller's immutable source/Vault
        // input remains valid. Only this compressed binary crosses to owner.
        const input=bytes?.slice();
        return new Promise((resolve,reject)=>{
          const timer=setTimeout(()=>{if(pending.has(id))shutdown(new Error('MAP worker timed out; reopen the MAP'));},timeoutMs);
          pending.set(id,{resolve,reject,timer,byteLength:size});queuedBytes+=size;
          try {current.postMessage({id,generation,method,args,bytes:input},input?[input.buffer]:[]);}
          catch(error){shutdown(error);}
        });
      } catch(error){return Promise.reject(error);}
    }
    return Object.freeze({invoke,dispose:()=>shutdown(new Error('MAP session closed'))});
  }
  root.createTerraMapClient=createTerraMapClient;
  if(typeof module==='object'&&module.exports)module.exports={createTerraMapClient};
})(globalThis);
