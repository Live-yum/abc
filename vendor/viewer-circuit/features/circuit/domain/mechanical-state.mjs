import { hasOwn, fromEntries } from './compat.mjs'
/** Wiring's mechanical state belongs to coordinates / the world, never item identities.
 * Kept separately from render-only tile projections so edits cannot erase cooldowns.
 */
import { launcherGroup, launcherGlobalTicks } from './device-state.mjs'
import { LIMITS } from './catalog.mjs'

export const GLOBAL_LIMITS = Object.freeze({ 'cannon-0': 120, 'cannon-1': 480, snow: 15 })
const integer = (n, lo, hi) => {
  if (!Number.isSafeInteger(n) || n < lo || n > hi) throw new RangeError('无效的机械运行状态')
  return n
}
export function readMechanicalState(raw, world) {
  if (raw === undefined) return undefined // Legacy files are migrated once, by the engine.
  if (!raw || typeof raw !== 'object' || raw.version !== 1 || !Array.isArray(raw.records) || raw.records.length > 999 || !raw.globals || typeof raw.globals !== 'object') throw new TypeError('无效的机械运行状态')
  for (const key of Object.keys(raw.globals)) if (!hasOwn(GLOBAL_LIMITS, key)) throw new TypeError('未知的共享冷却类别')
  const globals = fromEntries(Object.entries(GLOBAL_LIMITS).map(([key, max]) => [key, integer(raw.globals[key] ?? 0, 0, max)]))
  const nextOrder = integer(raw.nextOrder, 0, Number.MAX_SAFE_INTEGER - 1)
  const positions = new Set(), orders = new Set()
  const records = raw.records.map(r => {
    if (!r || typeof r !== 'object') throw new TypeError('无效的机械登记')
    const x = integer(r.x, 0, (world?.width ?? LIMITS.dimension) - 1), y = integer(r.y, 0, (world?.height ?? LIMITS.dimension) - 1)
    const remaining = integer(r.remaining, 1, 18000), order = integer(r.order, 1, nextOrder)
    const key = `${x},${y}`
    if (positions.has(key) || orders.has(order)) throw new TypeError('机械坐标或登记顺序重复')
    positions.add(key); orders.add(order)
    return { x, y, remaining, order }
  }).sort((a, b) => a.order - b.order)
  return { version: 1, globals, nextOrder, records }
}
export function migrateMechanicalState(world) {
  const globals = fromEntries(Object.keys(GLOBAL_LIMITS).map(k => [k, 0])), records = []
  const tiles = [...world.tiles.values()]
  for (const tile of tiles) {
    const group = launcherGroup(tile)
    if (group) globals[group] = Math.max(globals[group], Math.min(tile.globalCooldown || 0, launcherGlobalTicks(tile)))
  }
  const pending = tiles.filter(t => t.kind === 'timer' ? t.on || t.mechanicalOrder : t.cooldown > 0)
    .sort((a, b) => (a.mechanicalOrder || Infinity) - (b.mechanicalOrder || Infinity))
  let nextOrder = pending.reduce((n, t) => Math.max(n, t.mechanicalOrder || 0), 0)
  const used = new Set()
  for (const tile of pending) {
    // Old copies could duplicate mechanicalOrder. Preserve their stable relative order,
    // while producing unique registrations for the new format.
    let order = tile.mechanicalOrder
    if (!order || used.has(order)) order = ++nextOrder
    used.add(order)
    records.push({ x: tile.x, y: tile.y, remaining: tile.kind === 'timer' ? tile.remaining || 18000 : tile.cooldown, order })
  }
  return readMechanicalState({ version: 1, globals, nextOrder, records }, world)
}
