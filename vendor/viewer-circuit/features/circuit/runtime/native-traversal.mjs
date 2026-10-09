/** Persistent TerraWasm traversal. Device hits remain ordered by Wiring.HitWire. */
const MAX_CELLS = 1048576
const CHUNK = 4096
const RECORD_BYTES = 16
const STATUS = { '-1': '参数无效', '-2': '电路句柄已失效', '-3': '电路运行状态无效', '-4': '电路超过安全上限', '-5': '电路内存不足', '-6': '电路坐标越界', '-7': '电线坐标重复', '-8': '电路运行次数超过上限' }
const routing = tile => !tile ? 0 : tile.kind === 'junction' ? 2 + tile.style : tile.kind === 'pixel' ? 5 : 1
const nativeError = code => Object.assign(new Error(`TerraWasm：${STATUS[code] || `电路运算失败 (${code})`}；此次操作已回滚。`), { code: 'CIRCUIT_NATIVE_ERROR', nativeStatus: code })

export function supportsNativeTraversal(tx) {
  return tx?.Module?._terra_circuit_abi_version?.() === 1
    && ['create', 'load', 'compile', 'patch', 'begin', 'step', 'cancel', 'close', 'stats'].every(name => typeof tx?.Module?.[`_terra_circuit_${name}`] === 'function')
}

export function createNativeTraversal(tx, world, { maxBytes = 64 * 1024 * 1024 } = {}) {
  if (!supportsNativeTraversal(tx) || world.wires.size > MAX_CELLS) return null
  let handle = 0, data = 0, output = 0, meta = 0, closed = false, revision = -1, keys = new Set(), active = false
  const M = tx.Module
  const diagnostics = { backend: 'wasm', passes: 0, visits: 0, calls: 0, rebuilds: 0, cells: 0, peakBytes: 0 }
  function check(code) { if (code < 0) throw nativeError(code); return code }
  function records(entries) {
    let n = 0
    for (const [key, mask] of entries) {
      const [x, y] = key.split(',').map(Number), offset = (data >>> 2) + n * 4
      M.HEAPU32[offset] = x; M.HEAPU32[offset + 1] = y
      M.HEAPU32[offset + 2] = mask; M.HEAPU32[offset + 3] = routing(world.tileAt(x, y))
      n++
    }
    return n
  }
  function batches(fn) {
    let batch = []
    for (const entry of world.wires) {
      batch.push(entry)
      if (batch.length === CHUNK) { fn(records(batch)); batch = [] }
    }
    if (batch.length) fn(records(batch))
  }
  function bounds() {
    let width = 1, height = 1
    for (const key of world.wires.keys()) {
      const [x, y] = key.split(',').map(Number)
      // Include the empty neighbour: PixelBoxPass records an axis even without
      // a wire on the next cell, provided that neighbour is inside the world.
      width = Math.max(width, Math.min(world.width, x + 2))
      height = Math.max(height, Math.min(world.height, y + 2))
    }
    return width <= 65536 && height <= 65536 ? { width, height } : null
  }
  if (!bounds()) return null // Preserve the editor's larger, sparse coordinate space.
  function refreshStats() {
    check(M._terra_circuit_stats(handle, meta))
    diagnostics.cells = M.HEAPU32[(meta >>> 2) + 3]
    diagnostics.peakBytes = Math.max(diagnostics.peakBytes, M.HEAPU32[(meta >>> 2) + 12])
  }
  function sync() {
    if (revision === world.revision && handle) return
    const sameKeys = handle && keys.size === world.wires.size && [...world.wires.keys()].every(key => keys.has(key))
    if (sameKeys) {
      batches(count => check(M._terra_circuit_patch(handle, data, count)))
    } else {
      if (active) throw new Error('脉冲内新增电线需要重新编译拓扑；此次操作已回滚。')
      const size = bounds()
      if (!size || world.wires.size > MAX_CELLS) throw new RangeError('此电路超出当前 Wasm 拓扑容量')
      let replacement = 0
      try {
        M.HEAPU32[meta >>> 2] = 0
        check(M._terra_circuit_create(size.width, size.height, Math.max(1, world.wires.size), maxBytes, meta))
        replacement = M.HEAPU32[meta >>> 2]
        batches(count => check(M._terra_circuit_load(replacement, data, count)))
        while (check(M._terra_circuit_compile(replacement, CHUNK, meta)) === 1) { /* bounded native calls */ }
      } catch (error) { if (replacement) M._terra_circuit_close(replacement); throw error }
      if (handle) check(M._terra_circuit_close(handle))
      handle = replacement; keys = new Set(world.wires.keys()); diagnostics.rebuilds++
    }
    revision = world.revision; refreshStats()
  }
  try { data = tx.malloc(CHUNK * RECORD_BYTES); output = tx.malloc(CHUNK * RECORD_BYTES); meta = tx.malloc(64) }
  catch (error) { if (meta) tx.free(meta); if (output) tx.free(output); if (data) tx.free(data); throw error }

  return {
    diagnostics,
    run(engine, seeds, colour, mechanismPass) {
      if (closed) throw new Error('电路计算实例已关闭')
      if (seeds.length > CHUNK * 2) throw new RangeError('单次原版输入占格超过安全上限')
      sync()
      const skipped = new Set(seeds.map(p => `${p.x},${p.y}`)), state = engine.state(world)
      for (let i = 0; i < seeds.length; i++) { M.HEAPU32[(data >>> 2) + i * 2] = seeds[i].x; M.HEAPU32[(data >>> 2) + i * 2 + 1] = seeds[i].y }
      check(M._terra_circuit_begin(handle, data, seeds.length, colour, engine.collectTrace ? 1 : 0, Math.max(1, engine.operationLimit - engine.operations)))
      active = true; diagnostics.passes++
      try {
        let status
        do {
          sync() // A previous device hit may have reshaped/removed a tile.
          const allowance = Math.min(CHUNK, engine.operationLimit - engine.operations)
          // A paused tile may only need its pending expansion drained. Charge
          // actual visits below, so finishing exactly at the limit is allowed.
          status = M._terra_circuit_step(handle, Math.max(1, allowance), output, CHUNK, meta)
          const processed = M.HEAPU32[meta >>> 2], emitted = M.HEAPU32[(meta >>> 2) + 1]
          if (processed > CHUNK || emitted > CHUNK) throw new Error('Wasm 电路输出超过桥接缓冲区')
          diagnostics.calls++; diagnostics.visits += processed
          engine.budget(processed); check(status)
          // A tile event pauses before native expansion. Applying its effects here
          // preserves shape changes, SkipWire and the original colour-pass order.
          for (let i = 0; i < emitted; i++) {
            const offset = (output >>> 2) + i * 4, x = M.HEAPU32[offset], y = M.HEAPU32[offset + 1]
            const direction = M.HEAPU32[offset + 2], flags = M.HEAPU32[offset + 3], tile = world.tileAt(x, y)
            if (engine.collectTrace && engine.trace.length < engine.traceLimit) engine.trace.push({ world, x, y, colour, direction, tick: engine.tick })
            else if (engine.collectTrace) engine.traceTruncated = true
            if ((flags & 1) && !skipped.has(`${x},${y}`) && tile) engine.hitTile(world, tile, { x, y, direction }, colour, skipped, mechanismPass)
            if (tile?.kind === 'pixel' && (flags & 12)) state.pixels.set(tile, (state.pixels.get(tile) || 0) | ((flags & 4) ? 1 : 0) | ((flags & 8) ? 2 : 0))
          }
        } while (status === 1)
        refreshStats()
        return mechanismPass
      } finally { active = false; M._terra_circuit_cancel(handle) }
    },
    cancel() { if (handle) M._terra_circuit_cancel(handle); active = false; revision = -1 },
    close() {
      if (closed) return
      closed = true
      try { if (handle) M._terra_circuit_close(handle) }
      finally { handle = 0; tx.free(meta); tx.free(output); tx.free(data); keys.clear() }
    },
  }
}
