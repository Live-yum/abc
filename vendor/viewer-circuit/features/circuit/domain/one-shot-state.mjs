// Kept separate from the edit planner: model/session loading needs only this
// small, bounded state contract, never the editor or placement catalog.
const indirect = new Set(['boulder', 'rollingCactus', 'tntBarrel', 'bouncyBoulder', 'lifeCrystalBoulder', 'rainbowBoulder', 'poulder', 'lavaBoulder', 'spiderBoulder', 'ghoulder'])
const consumable = new Set(['fireworkRocket', 'explosives', 'landMine'])
const baseStyles = { gate:5, timer:4, junction:2, gemspark:6 }
export const isOneShot = t => !!t && (indirect.has(t.kind) || consumable.has(t.kind) || t.kind === 'pressurePlate' && t.style === 7)
export const canRearmOneShot = t => isOneShot(t) && t.spent === true

export function readOneShotRecovery(spec, tile, definitions) {
  const raw = spec.oneShotRecovery
  if (!indirect.has(tile.kind)) {
    if (raw != null) throw new TypeError('只有间接机关可以保存支撑恢复数据')
    return
  }
  tile.oneShotRecovery = null // Atomic rollback also restores the initial null.
  if (raw == null) return
  const fail = () => { throw new TypeError('机关支撑恢复数据无效') }
  if (raw.version !== 1 || !Array.isArray(raw.supports) || raw.supports.length > 4) fail()
  const seen = new Set()
  const supports = raw.supports.map(s => {
    if (!s || !Object.prototype.hasOwnProperty.call(definitions, s.kind)
      || ![s.dx, s.dy, s.rx, s.ry, s.width, s.height, s.style].every(Number.isSafeInteger)
      || s.dx < 0 || s.dx >= tile.width || ![-1, tile.height].includes(s.dy)
      || s.width < 1 || s.width > 32 || s.height < 1 || s.height > 32
      || s.rx > s.dx || s.rx + s.width <= s.dx || s.ry > s.dy || s.ry + s.height <= s.dy
      || s.style < 0 || s.style > (baseStyles[s.kind] ?? definitions[s.kind].styleMax ?? 0)
      || typeof s.on !== 'boolean' || typeof s.inactive !== 'boolean' || typeof s.actuator !== 'boolean'
      || typeof s.color !== 'string' || !/^#[0-9a-f]{6}$/i.test(s.color)) fail()
    const key = `${s.dx},${s.dy}`
    if (seen.has(key)) fail()
    seen.add(key)
    const out = { dx:s.dx, dy:s.dy, rx:s.rx, ry:s.ry, kind:s.kind, style:s.style, width:s.width, height:s.height, on:s.on, inactive:s.inactive, actuator:s.actuator, color:s.color }
    if (s.nativeCells !== undefined) {
      if (s.width !== 1 || s.height !== 1 || !Array.isArray(s.nativeCells) || s.nativeCells.length !== 4
        || s.nativeCells.some(n => !Number.isInteger(n) || n < 0 || n > 0xffffffff)
        || typeof s.nativeState !== 'string' || s.nativeState.length > 160) fail()
      out.nativeCells = [...s.nativeCells]; out.nativeState = s.nativeState
    }
    return out
  })
  tile.oneShotRecovery = { version:1, supports }
}

export function oneShotRecoveryJSON(tile, out) {
  if (tile.oneShotRecovery) out.oneShotRecovery = { version:1, supports:tile.oneShotRecovery.supports.map(s => ({ ...s, ...(s.nativeCells ? { nativeCells:[...s.nativeCells] } : {}) })) }
}

export function mirrorOneShotRecovery(tile) {
  if (tile.oneShotRecovery) tile.oneShotRecovery = { version:1, supports:tile.oneShotRecovery.supports.map(s => ({ ...s, dx:tile.width - 1 - s.dx, rx:tile.width - s.rx - s.width })) }
}
