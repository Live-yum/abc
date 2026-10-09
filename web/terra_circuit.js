/* Original ABI adapter: uses TerraWasm's actual sparse traversal, never a JS
 * flood-fill fallback. All buffers are caller-owned and freed on every path. */
(function(root) {
  'use strict';
  function createCircuitBridge(loadModule) {
    let modulePromise, queue=Promise.resolve();
    function propagate(width,height,cells,x,y,colour) {
      const run=queue.then(async()=>{
        if(!Number.isInteger(width)||!Number.isInteger(height)||width<1||height<1||width>256||height>256||
          !Array.isArray(cells)||cells.length%4||cells.length>262144||
          !Number.isInteger(x)||!Number.isInteger(y)||x<0||y<0||x>=width||y>=height||
          !Number.isInteger(colour)||colour<0||colour>3) throw new Error('Invalid circuit input');
        for(let i=0;i<cells.length;i++) if(!Number.isInteger(cells[i])||cells[i]<0||cells[i]>0xffffffff) throw new Error('Invalid circuit word');
        for(let i=3;i<cells.length;i+=4) if(cells[i]>1) throw new Error('Unsupported circuit routing');
        if(!cells.length) return [];
        const M=await (modulePromise ??= loadModule());
        for(const name of ['create','load','compile','begin','step','close']) if(typeof M['_terra_circuit_'+name]!=='function') throw new Error('Circuit engine ABI missing '+name);
        const allocated=[]; let handle=0;
        const alloc=n=>{const p=M._tx_malloc(n);if(!p)throw new Error('Circuit engine memory exhausted');allocated.push(p);return p;};
        const check=code=>{if(code<0)throw new Error('Circuit engine status '+code);return code;};
        try {
          const out=alloc(4),data=alloc(cells.length*4),seed=alloc(8),events=alloc(4096),step=alloc(16);
          M.HEAPU32.set(cells,data>>>2);M.HEAPU32[out>>>2]=0;
          check(M._terra_circuit_create(width,height,cells.length/4,16*1024*1024,out));
          handle=M.HEAPU32[out>>>2];
          check(M._terra_circuit_load(handle,data,cells.length/4));
          while(check(M._terra_circuit_compile(handle,65536,out))===1) await new Promise(r=>setTimeout(r,0));
          M.HEAPU32.set([x,y],seed>>>2);
          check(M._terra_circuit_begin(handle,seed,1,colour,1,cells.length*2+64));
          const seen=new Set();let status=1,batches=0;
          while(status===1) {
            status=check(M._terra_circuit_step(handle,256,events,256,step));
            const count=M.HEAPU32[(step>>>2)+1];if(count>256)throw new Error('Circuit event overflow');
            for(let i=0;i<count;i++) {const p=(events>>>2)+i*4;seen.add(M.HEAPU32[p+1]*width+M.HEAPU32[p]);}
            if(++batches%64===0)await new Promise(r=>setTimeout(r,0));
          }
          return [...seen];
        } finally {if(handle)M._terra_circuit_close(handle);for(const p of allocated)M._tx_free(p);}
      });
      queue=run.catch(()=>{});return run;
    }
    return {propagate:async(w,h,json,x,y,c)=>JSON.stringify(await propagate(w,h,JSON.parse(json),x,y,c)),propagateRaw:propagate};
  }
  async function load() {
    const base=new URL('engine/',root.document.baseURI);
    await new Promise((resolve,reject)=>{const s=root.document.createElement('script');s.src=new URL('world.js',base).href;s.onload=resolve;s.onerror=()=>reject(new Error('Missing verified circuit WASM artifact'));root.document.head.appendChild(s);});
    if(typeof root.TerraWorldWasmWeb!=='function')throw new Error('Circuit WASM factory unavailable');
    return root.TerraWorldWasmWeb({locateFile:f=>new URL(f.endsWith('.wasm')?'world.wasm':f,base).href});
  }
  root.terraCircuit=createCircuitBridge(load);
  if(typeof module==='object'&&module.exports)module.exports={createCircuitBridge};
})(globalThis);
