import { hasOwn, fromEntries } from './compat.mjs'
import { MECHANISM_TYPES } from './mechanisms-catalog.mjs'

export const isMechanism = tile => !!tile && hasOwn(MECHANISM_TYPES, tile.kind)
const safeInteger = (v, min, max, name) => {
  if (!Number.isSafeInteger(v) || v < min || v > max) throw new RangeError(`${name}超出范围`)
  return v
}
const bool = (v, name) => { if (typeof v !== 'boolean') throw new TypeError(`${name}必须是布尔值`); return v }
const fields = ['pulses', 'cooldown', 'pulseTicks', 'spent']
export function readMechanismState(spec, tile) {
  if (['contact', 'occupants', 'liquid', 'actor', 'sensorReady', 'offDelay'].some(k => spec[k] !== undefined)) throw new TypeError('本工具只模拟电路信号，不接受人物、接触或环境条件')
  if (!isMechanism(tile)) {
    if (fields.some(k => spec[k] !== undefined)) throw new TypeError('此元件不支持机关状态参数')
    return
  }
  const def = MECHANISM_TYPES[tile.kind]
  if (!def.styles.includes(tile.style)) throw new TypeError('此样式在本批没有原版电路行为')
  if (tile.inactive || tile.color !== '#ffffff') throw new TypeError('机关不支持虚化或自定义贴图颜色')
  Object.assign(tile, {
    pulses: safeInteger(spec.pulses ?? 0, 0, Number.MAX_SAFE_INTEGER - 1, '触发计数'),
    cooldown: safeInteger(spec.cooldown ?? 0, 0, 600, '冷却 tick'),
    pulseTicks: safeInteger(spec.pulseTicks ?? 0, 0, 45, '反馈 tick'),
    spent: bool(spec.spent ?? false, '已消耗状态'),
  })
  if (tile.spent && !(tile.kind === 'pressurePlate' && tile.style === 7)) throw new TypeError('只有橙压力板存在一次性消耗状态')
  if (tile.cooldown > mechanismCooldown(tile)) throw new TypeError('此机关没有自身机械冷却')
}
export function mechanismJSON(tile) { return fromEntries(fields.map(k => [k, tile[k]])) }
export function mechanismCooldown(tile) {
  if (tile.kind === 'trap') return [200, 200, 200, 300, 90, 200][tile.style]
  if (tile.kind === 'statue') return [2, 17, 37].includes(tile.style) ? 600 : [40, 41].includes(tile.style) ? 300 : 30
  return 0
}
function pulse(engine, world, tile, detail) {
  if (tile.pulses >= Number.MAX_SAFE_INTEGER - 1) throw new RangeError('触发计数已达到安全上限')
  engine.mutate(tile, 'pulses', tile.pulses + 1)
  engine.mutate(tile, 'pulseTicks', 45)
  engine.log(world, tile.x, tile.y, 'mechanism', detail)
}
/** Manual circuit test input. No actors, collision, daytime or liquids are simulated.
 * Incoming wires do NOT re-emit through these sources: they are not wire-powered latches.
 * The indicator is a tool pulse visualisation, not a claim about environmental sensor state.
 */
export function triggerMechanismInput(engine, world, tile) {
  if (!isMechanism(tile) || MECHANISM_TYPES[tile.kind].role !== 'input') throw new TypeError('此元件不是电路输入口')
  if (tile.spent) { engine.log(world, tile.x, tile.y, 'mechanism', '橙压力板已消耗，可点击恢复或使用恢复机关'); return false }
  pulse(engine, world, tile, '手动测试输入：输出一次电路脉冲（不模拟人物或环境）')
  engine.mutate(tile, 'on', true)
  engine.trip(world, [{ x: tile.x, y: tile.y }])
  if (tile.kind === 'pressurePlate' && tile.style === 7) {
    engine.mutate(tile, 'spent', true); engine.mutate(tile, 'on', false)
    engine.log(world, tile.x, tile.y, 'mechanism', '橙压力板已消耗；编辑器保留标记，可单独或批量恢复')
  }
  return true
}
export function interactMechanism(engine, world, tile) {
  if (!isMechanism(tile) || MECHANISM_TYPES[tile.kind].role !== 'input') return false
  triggerMechanismInput(engine, world, tile)
  return true
}
export function newMechanismPass() { return { first: null, last: null, pumpIn: 0, pumpOut: 0 } }
export function hitMechanism(engine, world, tile, point, skipped, pass) {
  if (!isMechanism(tile)) return false
  const role = MECHANISM_TYPES[tile.kind].role
  if (role === 'input') return true // Sources do not become wire-driven latches.
  if (role === 'teleport') {
    if (!pass.first) pass.first = tile
    else if (tile !== pass.first) pass.last = tile // native first + last encountered, NOT nearest neighbour
    return true
  }
  for (let x = 0; x < tile.width; x++) for (let y = 0; y < tile.height; y++) skipped.add(`${tile.x + x},${tile.y + y}`)
  if (role === 'pump') {
    const field = tile.kind === 'inletPump' ? 'pumpIn' : 'pumpOut'
    if (pass[field] >= 19) return true // Wiring stores at most 19 inlet/outlet tile coordinates per colour.
    pass[field] = Math.min(19, pass[field] + 4)
    pulse(engine, world, tile, `${tile.kind === 'inletPump' ? '入水泵' : '出水泵'}收到信号；仅播放流向反馈`)
    return true
  }
  if (tile.cooldown > 0) return true
  if (!engine.registerCooldown(world, tile, mechanismCooldown(tile))) return true
  pulse(engine, world, tile, role === 'statue' ? '雕像 +1（抽象触发，不生成怪物或掉落物）' : '陷阱 +1（发射反馈，不创建弹幕）')
  return true
}
export function finishMechanismTeleports(engine, world, passes) {
  for (const pass of passes) {
    const a = pass.first, b = pass.last
    if (!a || !b) continue
    // Native asymmetric close/vertical-overlap guard, not a made-up distance threshold.
    if (a.x < b.x + 3 && a.x > b.x - 3 && a.y > b.y - 3 && a.y < b.y) continue
    pulse(engine, world, a, `传送连接 → ${b.x},${b.y}；仅状态动画`)
    pulse(engine, world, b, `传送连接 → ${a.x},${a.y}；仅状态动画`)
  }
}
