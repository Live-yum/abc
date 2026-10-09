/* Region parsing/writing is synchronous C inside this dedicated worker.
 * Structured cloning retains caller ownership of immutable source bytes. */
importScripts('terra_region.js');
const region=createRegionBridge(async()=>{
 importScripts('engine/world.js');
 return TerraWorldWasmWeb({locateFile:name=>new URL('engine/'+(name.endsWith('.wasm')?'world.wasm':name),self.location.href).href});
});
self.onmessage=async({data})=>{
 const {id,method,args}=data;
 try{if(!['read','objects','replace','operation','pixel','match'].includes(method))throw new Error('Unknown region worker operation');
  const value=await region[method](...args);self.postMessage({id,value},[value.buffer]);
 }catch(error){self.postMessage({id,error:String(error?.message||error)});}
};
