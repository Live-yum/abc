/* Original TerraForge bridge. Engine binaries are separately supplied artifacts. */
(function (root) {
  'use strict';
  const LIMIT = { wld: 64 * 1024 * 1024, plr: 2 * 1024 * 1024, json: 8 * 1024 * 1024 };
  const utf8 = new TextEncoder(), decoder = new TextDecoder();
  // Preserve integer tokens before JSON.parse can round save-file timestamps/IDs.
  function parse(text) {
    return JSON.parse(text.replace(/"(?:\\.|[^"\\])*"|-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?/g, token => {
      if (token[0] === '"') return token;
      const n = Number(token);
      if (!Number.isFinite(n)) throw new Error('Non-finite engine JSON number');
      if (!/[.eE]/.test(token) && !Number.isSafeInteger(n)) return JSON.stringify(token);
      if (Math.abs(n) > Number.MAX_SAFE_INTEGER) throw new Error('Imprecise engine JSON number');
      return token;
    }));
  }
  function encode(value, key = '') {
    if (typeof value === 'number' && (!Number.isFinite(value) || (Number.isInteger(value) && !Number.isSafeInteger(value)))) throw new Error('Unsafe numeric value');
    if (typeof value === 'string' && /^(magicAndType|favoriteFlags|playTimeTicks|lastSaveUtcTicks|creationTime|lastPlayed|worldGeneratorVersion)$/.test(key) && /^-?\d+$/.test(value)) return value;
    if (Array.isArray(value)) return '[' + value.map(v => encode(v)).join(',') + ']';
    if (value && typeof value === 'object') return '{' + Object.entries(value).map(([k,v]) => JSON.stringify(k) + ':' + encode(v,k)).join(',') + '}';
    const result = JSON.stringify(value);
    if (result === undefined) throw new Error('Undefined JSON value');
    return result;
  }
  function equal(a,b) {
    if (a === b) return true;
    if (!a || !b || typeof a !== 'object' || typeof b !== 'object') return false;
    const keys = Object.keys(a);
    return keys.length === Object.keys(b).length && keys.every(k => Object.hasOwn(b,k) && equal(a[k],b[k]));
  }
  function sameSavedMetadata(kind, actual, expected) {
    if (kind !== 'wld') return equal(actual, expected);
    // Variable-length sections (for example renamed chests) legitimately move
    // later offsets. The parser validates these offsets; compare their shape,
    // while retaining every format identity field and all logical content.
    const normalize = value => {
      const positions = value.format?.positions;
      if (!Array.isArray(positions)) return value;
      return {...value, format: {...value.format, positions: positions.map(() => 0)}};
    };
    return equal(normalize(actual), normalize(expected));
  }
  const pointer = k => '/' + k.replace(/~/g,'~0').replace(/\//g,'~1');
  function abi(M) {
    function alloc(n) { const p = M._tx_malloc(n); if (!p) throw new Error('Engine memory exhausted'); return p; }
    function text(s, fn) {
      const b = utf8.encode(s); if (b.length >= LIMIT.json) throw new Error('JSON input exceeds budget');
      const p = alloc(b.length + 1);
      try { M.HEAPU8.set(b,p); M.HEAPU8[p+b.length]=0; return fn(p); } finally { M._tx_free(p); }
    }
    function check(code) {
      if (code === 0) return;
      let detail = '';
      try { detail = read((p,n,s) => M._terra_info_get_last_error_json(p,n,s),true,65536); } catch (_) { /* Retain status. */ }
      throw new Error('Engine status ' + code + (detail ? ': ' + detail : ''));
    }
    function read(fn, wide = true, limit = LIMIT.json, binary = false, dimensions = 0) {
      const size = alloc(8), dims = []; let out = 0;
      try {
        M.HEAPU8.fill(0,size,size+8);
        for (let i=0;i<dimensions;i++) dims.push(alloc(4));
        const probe = fn(0,wide ? 0n : 0,size,...dims);
        if (probe !== 0 && probe !== 2) throw new Error('Engine output probe failed ('+probe+')');
        const n = wide ? Number(new DataView(M.HEAPU8.buffer).getBigUint64(size,true)) : M.HEAPU32[size>>>2];
        if (!Number.isSafeInteger(n) || n < 1 || n > limit) throw new Error('Engine output size exceeds budget');
        out=alloc(n); check(fn(out,wide ? BigInt(n) : n,size,...dims));
        const after = wide ? Number(new DataView(M.HEAPU8.buffer).getBigUint64(size,true)) : M.HEAPU32[size>>>2];
        if (after !== n) throw new Error('Engine output length changed');
        return binary ? M.HEAPU8.slice(out,out+n) : decoder.decode(M.HEAPU8.subarray(out,out+n-(M.HEAPU8[out+n-1]===0 ? 1 : 0)));
      } finally { if(out) M._tx_free(out); M._tx_free(size); dims.forEach(p=>M._tx_free(p)); }
    }
    return { M, alloc, text, check, read };
  }
  // Explicit empty gameplay state, generated from schema rather than a user save.
  function blankPlayer(name) {
    const items=n=>Array.from({length:n},()=>({itemType:0,stack:0,prefix:0,favorited:false}));
    const d={version:326,name,metadata:{magicAndType:'244154697780061554',revision:0,favoriteFlags:0},
      statLife:100,statLifeMax:100,statMana:20,statManaMax:20,voiceVariant:1,
      tailLayout:{builderAccStatusCount:12,includesDeathMetadata:true},
      hideVisibleAccessory:Array(10).fill(false),hideInfo:Array(13).fill(false),
      dpadRadialBindings:Array(4).fill(0),builderAccStatus:Array(12).fill(0),
      spawnPoints:[],creativeItemSacrifices:[],temporarySlots:Array(4).fill(null),
      pendingRefunds:[],oneTimeDialoguesSeen:[],respawnTimer:null,
      buffs:Array.from({length:44},()=>({buffType:0,buffTime:0})),
      loadouts:Array.from({length:3},()=>({armor:items(20),dyes:items(10),hide:Array(10).fill(false)})),
      creativePowers:{godmodeEnabled:false,farPlacementEnabled:false,spawnRateSlider:0.5}};
    for(const key of 'difficulty playTimeTicks hair hairDye team hideMisc skinVariant taxMoney numberOfDeathsPve numberOfDeathsPvp voidVaultInfo anglerQuestsFinished bartenderQuestLog lastSaveUtcTicks golferScoreAccumulated currentLoadoutIndex voicePitchOffset'.split(' ')) d[key]=0;
    for(const key of 'extraAccessory unlockedBiomeTorches usingBiomeTorches ateArtisanBread usedAegisCrystal usedAegisFruit usedArcaneCrystal usedGalaxyPearl usedGummyWorm usedAmbrosia downedDd2EventAnyDifficulty hbLocked dead creativeTrackerHasNewUnlocks unlockedSuperCart enabledSuperCart'.split(' ')) d[key]=false;
    for(const [key,count] of Object.entries({armor:20,dyes:10,inventory:58,miscEquips:5,miscDyes:5,piggyBank:40,safe:40,defendersForge:40,voidVault:40})) d[key]=items(count);
    for(const key of ['hairColor','skinColor','eyeColor','shirtColor','underShirtColor','pantsColor','shoeColor']) d[key]={r:128,g:128,b:128};
    return d;
  }
  function createBridge(loadModule) {
    const modules = new Map(), docs = new Map(); let next = 1, queue = Promise.resolve();
    const serial = fn => { const work=queue.then(fn); queue=work.catch(()=>{}); return work; };
    async function moduleFor(kind) {
      if (!['wld','plr'].includes(kind)) throw new Error('Only WLD and PLR files are supported');
      if (!modules.has(kind)) {
        const M=await loadModule(kind);
        for (const symbol of ['_tx_malloc','_tx_free',kind==='wld' ? '_terra_world_workspace_save_to_buffer' : '_terra_plr_set_many']) if (typeof M[symbol] !== 'function') throw new Error('Engine ABI missing '+symbol);
        if (kind==='wld' && M._txw_use_builtin_map_runtime) M._txw_use_builtin_map_runtime();
        modules.set(kind,abi(M));
      }
      return modules.get(kind);
    }
    async function openNative(a,kind,bytes) {
      const {M,alloc,check}=a, p=alloc(bytes.length), out=alloc(4); let task=0, adopted=false;
      try {
        M.HEAPU8.set(bytes,p); M.HEAPU32[out>>>2]=0;
        if (kind==='plr') check(M._terra_plr_open_from_buffer(p,bytes.length,out));
        else {
          task=M._terra_world_open_begin(p,bytes.length);
          if (!task) throw new Error('Cannot begin world decode');
          let code;
          do { code=M._terra_world_open_step(task,64); if(code===10) await new Promise(r=>setTimeout(r,0)); } while(code===10);
          check(code); check(M._terra_world_open_finish(task,out)); adopted=true;
        }
        const handle=M.HEAPU32[out>>>2]; if(!handle) throw new Error('Engine returned empty document');
        return handle;
      } finally {
        if(task) { if(!adopted) M._terra_world_open_cancel(task); M._terra_world_task_close(task); }
        M._tx_free(p); M._tx_free(out);
      }
    }
    const get = id => { const d=docs.get(id); if(!d) throw new Error('Document is closed'); return d; };
    const release = d => d.a.check(d.a.M[d.kind==='wld' ? '_terra_world_close' : '_terra_plr_close'](d.native));
    function section(d,name) { return d.a.text(name,p=>parse(d.a.read((o,n,s)=>d.a.M._terra_section_get_json(d.native,p,o,n,s)))); }
    function inspect(d) {
      if(d.kind==='plr') return parse(d.a.read((o,n,s)=>d.a.M._terra_plr_get_json(d.native,o,n,s),true));
      return {header:section(d,'header'),format:section(d,'format'),chests:section(d,'chests'),bestiary:section(d,'bestiary')};
    }
    function serialize(d) {
      const fn=d.a.M[d.kind==='wld' ? '_terra_world_workspace_save_to_buffer' : '_terra_plr_save_to_buffer'];
      if(d.kind==='plr') return d.a.read((o,n,s)=>fn(d.native,o,n,s),false,LIMIT.plr,true);
      const {M,alloc,check}=d.a, out=alloc(4); let token=0;
      try {
        check(M._terra_world_workspace_checkpoint_size(d.native,out));
        const budget=M.HEAPU32[out>>>2];
        if(budget>LIMIT.wld) throw new Error('World checkpoint exceeds memory budget');
        check(M._terra_world_workspace_begin(d.native,budget,out)); token=M.HEAPU32[out>>>2];
        const bytes=d.a.read((o,n,s)=>fn(d.native,o,n,s),false,LIMIT.wld,true);
        check(M._terra_world_workspace_commit(d.native,token)); token=0; return bytes;
      } finally { if(token) check(M._terra_world_workspace_rollback(d.native,token)); M._tx_free(out); }
    }
    function exec(d,op,args) {
      return d.a.text(op,p=>d.a.text(encode(args),q=>parse(d.a.read((o,n,s)=>d.a.M._terra_op_execute_json(d.native,p,q,o,n,s)))));
    }
    function model(d) { const info=inspect(d); return {handle:d.id,kind:d.kind,metadata:info}; }
    const bridge={
      projectPlayer:input=>serial(async()=>{
        if(typeof input!=='string' || utf8.encode(input).length>4*1024*1024) throw new Error('Player projection JSON exceeds budget');
        const candidate=parse(input), version=candidate.version;
        if(!Number.isInteger(version)||version<38||version>326) throw new Error('Projection target must be 38–326');
        const a=await moduleFor('plr'), out=a.alloc(4); let native=0;
        try {
          a.M.HEAPU32[out>>>2]=0;
          a.text(encode(candidate),p=>a.check(a.M._terra_plr_open_json(p,out)));
          native=a.M.HEAPU32[out>>>2];
          if(!native) throw new Error('Projection returned no handle');
          const bytes=serialize({kind:'plr',a,native});
          const old=native; native=0; a.check(a.M._terra_plr_close(old));
          native=await openNative(a,'plr',bytes);
          if(inspect({kind:'plr',a,native}).version!==version) throw new Error('Projection version mismatch');
          return bytes;
        } finally { if(native) a.check(a.M._terra_plr_close(native)); a.M._tx_free(out); }
      }),
      createPlayer:name=>serial(async()=>{
        if(typeof name!=='string' || !name.trim() || name.length>100) throw new Error('Player name must be 1–100 characters');
        const a=await moduleFor('plr'), out=a.alloc(4); let native=0;
        try {
          a.M.HEAPU32[out>>>2]=0;
          a.text(encode(blankPlayer(name)),p=>a.check(a.M._terra_plr_open_json(p,out)));
          native=a.M.HEAPU32[out>>>2];
          if(!native) throw new Error('Player creation returned no handle');
          const d={id:next++,kind:'plr',a,native,dirty:true};
          d.original=serialize(d);
          a.check(a.M._terra_plr_close(native)); native=await openNative(a,'plr',d.original); d.native=native;
          const result=model(d); docs.set(d.id,d); return JSON.stringify(result);
        } catch(error) { if(native) a.M._terra_plr_close(native); throw error; }
        finally { a.M._tx_free(out); }
      }),
      open: (bytes,kind)=>serial(async()=>{
        if(!(bytes instanceof Uint8Array) || !bytes.length || bytes.length>LIMIT[kind]) throw new Error('File is empty or exceeds budget');
        if(kind==='wld' && [...docs.values()].some(d=>d.kind==='wld')) throw new Error('Close the current world before opening another');
        const a=await moduleFor(kind), native=await openNative(a,kind,bytes);
        const d={id:next++,kind,a,native,original:bytes.slice(),dirty:false};
        try { const result=model(d); docs.set(d.id,d); return JSON.stringify(result); } catch(error) { release(d); throw error; }
      }),
      inspect:id=>serial(()=>JSON.stringify(inspect(get(id)))),
      mutate:(id,operation,json)=>serial(async()=>{
        const d=get(id), args=JSON.parse(json), before=inspect(d), backup=serialize(d); let expected;
        try {
          if(d.kind==='plr') {
            if(!['player_patch','patch'].includes(operation)) throw new Error('Unsupported player operation: '+operation);
            const patch=args.patch ?? args;
            if(!patch || Array.isArray(patch) || typeof patch!=='object' || !Object.keys(patch).length) throw new Error('Empty player patch');
            if(before.version>326) throw new Error('This player version is read-only');
            if(Object.hasOwn(patch,'version') && patch.version!==before.version) throw new Error('Version conversion needs a verified conversion profile');
            for(const key of Object.keys(patch)) if(!Object.hasOwn(before,key) || ['metadata','tailLayout'].includes(key)) throw new Error('Unsupported player field: '+key);
            expected={...before,...patch};
            const edits='['+Object.entries(patch).map(([k,v])=>'{"path":'+JSON.stringify(pointer(k))+',"value":'+encode(v,k)+'}').join(',')+']';
            d.a.text(edits,p=>d.a.check(d.a.M._terra_plr_set_many(d.native,p)));
            if(!equal(inspect(d),expected)) throw new Error('Player edit read-back mismatch');
          } else {
            if(!['header_patch','world_patch','replace_chests','replace_bestiary'].includes(operation)) throw new Error('Unsupported world operation: '+operation);
            const op=operation==='world_patch' ? 'header_patch' : operation;
            const request=op==='header_patch' ? {patch:args.patch ?? args} : args;
            if(op==='header_patch') {
              const patch=request.patch;
              if(!patch || Array.isArray(patch) || typeof patch!=='object' || !Object.keys(patch).length) throw new Error('Empty header patch');
              for(const key of Object.keys(patch)) if(!Object.hasOwn(before.header,key)) throw new Error('Unknown world header field: '+key);
              expected={...before.header,...patch};
            }
            exec(d,op,request);
            if(expected && !equal(section(d,'header'),expected)) throw new Error('World edit read-back mismatch');
          }
          d.dirty=true;
        } catch(error) {
          // Restore the entire pre-operation binary, even for partial native failures.
          release(d); d.native=await openNative(d.a,d.kind,backup);
          throw error;
        }
      }),
      save:id=>serial(async()=>{
        const d=get(id), expected=inspect(d), bytes=d.dirty ? serialize(d) : d.original.slice();
        release(d); d.native=0;
        try {
          d.native=await openNative(d.a,d.kind,bytes);
          if(!sameSavedMetadata(d.kind,inspect(d),expected)) throw new Error('Export read-back validation failed');
        } catch(error) {
          if(d.native) release(d);
          d.native=await openNative(d.a,d.kind,d.original); d.dirty=false;
          throw new Error(String(error)+'; workspace restored to untouched original');
        }
        return bytes;
      }),
      preview:id=>serial(()=>{
        const d=get(id); if(d.kind!=='wld') return null;
        exec(d,'render_thumbnail_png',{max_w:960});
        return d.a.read((o,n,s,w,h)=>d.a.M._terra_op_get_thumbnail_png(d.native,o,n,s,w,h),true,16*1024*1024,true,2);
      }),
      generateMap:(id,json)=>serial(()=>{
        const d=get(id); if(d.kind!=='wld') throw new Error('MAP generation requires a world');
        const markers=JSON.parse(json);
        if(markers!==null && (typeof markers!=='object' || Array.isArray(markers) ||
            Object.keys(markers).some(key=>!['chest_markers','tile_markers'].includes(key)))) {
          throw new Error('MAP accepts only chest and tile markers');
        }
        try {
          exec(d,markers===null ? 'render_lit_map' : 'mark_tiles_and_chests_map',markers ?? {});
          return d.a.read((o,n,s,w,h)=>d.a.M._terra_op_get_map(d.native,o,n,s,w,h),true,128*1024*1024,true,2);
        } finally {
          // The successful get releases media; reclaim also covers a failed
          // allocation/copy, keeping the next queued operation usable.
          d.a.M._tx_reclaim_transients?.();
        }
      }),
      close:id=>serial(()=>{ const d=get(id); release(d); docs.delete(id); }),
    };
    return Object.freeze(bridge);
  }
  root.createTerraDocumentBridge = createBridge;
  if (root.document) {
    root.terraForge = root.TerraWorkerRPC.createClient('document');
    root.addEventListener?.('pagehide', () => root.terraForge.dispose());
  }
  if(typeof module==='object' && module.exports) module.exports={createBridge,parse,encode};
})(globalThis);
