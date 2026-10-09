import { hasOwn, fromEntries } from './compat.mjs'
import { STORAGE_TYPES } from './storage-catalog.mjs'
export const isStorage = tile => !!tile && hasOwn(STORAGE_TYPES, tile.kind)
export const isStorageInput = tile => isStorage(tile) && (STORAGE_TYPES[tile.kind].role === 'input' || tile.kind === 'container2' && tile.style === 4)
export const STORAGE_FEEDBACK_TICKS = 45
export const CHEST_ANIMATION_TICKS = 30
export const CHEST_ANIMATION_FRAMES = Object.freeze([1, 2, 2, 2, 1])
const integer = (value, min, max, name) => {
  if (!Number.isSafeInteger(value) || value < min || value > max) throw new RangeError(`${name}超出范围`)
  return value
}
export function readStorageState(spec, tile) {
  if (!isStorage(tile)) {
    if (spec.lidTicks !== undefined) throw new TypeError('只有机关宝箱能保存开盖动画')
    return
  }
  const def = STORAGE_TYPES[tile.kind]
  if (!def.styles.includes(tile.style)) throw new TypeError('没有此原版容器／马桶样式')
  if (tile.on || tile.color !== '#ffffff' || spec.faulty || spec.spent) throw new TypeError('容器／马桶没有虚构的持续开关、消耗或自定义颜色状态')
  if (['inventory', 'items', 'chest', 'locked', 'usingChest', 'actor', 'occupants', 'liquid', 'projectiles', 'damage', 'supportArmed'].some(key => spec[key] !== undefined)) throw new TypeError('容器／马桶只模拟电路请求与自身反馈，不接受库存、人物或世界参数')
  tile.pulses = integer(spec.pulses ?? 0, 0, Number.MAX_SAFE_INTEGER - 1, '内部兼容触发记录')
  tile.cooldown = integer(spec.cooldown ?? 0, 0, def.cooldown, '自身冷却')
  tile.pulseTicks = integer(spec.pulseTicks ?? 0, 0, STORAGE_FEEDBACK_TICKS, '高亮时间')
  tile.lidTicks = integer(spec.lidTicks ?? 0, 0, def.role === 'input' ? CHEST_ANIMATION_TICKS : 0, '原版机关宝箱动画时间')
}
export function storageJSON(tile) {
  return fromEntries(['pulses', 'cooldown', 'pulseTicks', 'lidTicks'].map(key => [key, tile[key]]))
}
export function storageStatus(tile) {
  return tile.lidTicks > 0 ? '开盖动画' : tile.cooldown > 0 ? `冷却 ${tile.cooldown} tick` : '就绪'
}
const cells = tile => Array.from({ length: tile.width * tile.height }, (_, i) => ({ x: tile.x + i % tile.width, y: tile.y + Math.floor(i / tile.width) }))
function feedback(engine, world, tile, detail) {
  if (tile.pulses >= Number.MAX_SAFE_INTEGER - 1) throw new RangeError('内部触发记录达到安全上限')
  engine.mutate(tile, 'pulses', tile.pulses + 1)
  engine.mutate(tile, 'pulseTicks', STORAGE_FEEDBACK_TICKS)
  engine.log(world, tile.x, tile.y, 'storage', detail)
}
/** HitSwitch(441/468/467:4) is a source, never re-emitted by HitWireSingle. */
export function triggerStorageInput(engine, world, tile) {
  if (!isStorageInput(tile)) return false
  // Player interaction starts Animation type 2 for false chests, not for ordinary containers.
  if (STORAGE_TYPES[tile.kind].role === 'input') engine.mutate(tile, 'lidTicks', CHEST_ANIMATION_TICKS)
  feedback(engine, world, tile, '机关宝箱直接输出测试脉冲；不模拟角色开箱或库存')
  engine.trip(world, cells(tile))
  return true
}
/** Hopper and toilet own CheckMech(60) are retained; world transfer/spawn conditions are outside item-state mode. */
export function hitStorage(engine, world, tile, skipped) {
  if (!isStorage(tile)) return false
  for (const point of cells(tile)) skipped.add(`${point.x},${point.y}`)
  const def = STORAGE_TYPES[tile.kind]
  if (def.role === 'input' || tile.cooldown > 0) return true
  if (!engine.registerCooldown(world, tile, def.cooldown)) return true
  feedback(engine, world, tile, tile.kind.toLowerCase().includes('toilet') ? '冲水请求：仅当前物品高亮，不创建弹幕' : '通电吸取请求：仅当前物品高亮，不声称已转移物品')
  return true
}
export function transformStorage(tile, operation) {
  if (!isStorage(tile)) return
  if (operation !== 'flipX') throw new Error('原版容器和马桶不能侧置或倒置')
  if (STORAGE_TYPES[tile.kind].orientations) tile.orientation = 1 - (tile.orientation ?? 0)
}
