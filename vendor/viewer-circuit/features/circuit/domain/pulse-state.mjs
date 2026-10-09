import { hasOwn, fromEntries } from './compat.mjs'
import { PULSE_TYPES } from './pulse-catalog.mjs'

export const isPulseDevice = tile => !!tile && hasOwn(PULSE_TYPES, tile.kind)
export const PULSE_FEEDBACK_TICKS = 45
const fields = ['pulses', 'cooldown', 'pulseTicks', 'spent']
function integer(v, min, max, label) {
  if (!Number.isSafeInteger(v) || v < min || v > max) throw new RangeError(`${label}超出范围 (${min}–${max})`)
  return v
}
export function readPulseState(spec, tile) {
  if (!isPulseDevice(tile)) return
  const def = PULSE_TYPES[tile.kind]
  if (!def.styles.includes(tile.style)) throw new TypeError('此样式没有原版烟花／爆破物品')
  if (tile.inactive || tile.color !== '#ffffff' || spec.faulty || spec.actuator) throw new TypeError('此机关不支持虚化、自定义材质或制动器')
  if (['actor', 'contact', 'occupants', 'liquid', 'sensorReady', 'offDelay', 'projectiles', 'damage', 'blastRadius'].some(k => spec[k] !== undefined)) throw new TypeError('只模拟物品自身状态，不接受人物、弹幕、伤害或世界参数')
  if (tile.kind !== 'detonator' && tile.on) throw new TypeError('此机关没有持续开关状态；高亮由反馈 tick 决定')
  if (spec.spent !== undefined && typeof spec.spent !== 'boolean') throw new TypeError('已消耗状态必须是布尔值')
  Object.assign(tile, {
    pulses: integer(spec.pulses ?? 0, 0, Number.MAX_SAFE_INTEGER - 1, '累计触发数'),
    cooldown: integer(spec.cooldown ?? 0, 0, def.cooldown, '自身冷却／回弹 tick'),
    pulseTicks: integer(spec.pulseTicks ?? 0, 0, PULSE_FEEDBACK_TICKS, '反馈 tick'),
    spent: spec.spent ?? false,
  })
  if (tile.spent && !def.consumable) throw new TypeError('此机关不是一次性物品')
}
export const pulseJSON = tile => fromEntries(fields.map(k => [k, tile[k]]))
export function pulseStatus(tile) {
  if (tile.spent) return '已消耗'
  if (tile.kind === 'detonator') return `${tile.on ? '按下' : '抬起'}${tile.cooldown ? ` · 回弹 ${tile.cooldown} tick` : ''}`
  return tile.cooldown ? `冷却 ${tile.cooldown} tick` : '就绪'
}
function feedback(engine, world, tile, detail) {
  if (tile.pulses >= Number.MAX_SAFE_INTEGER - 1) throw new RangeError('累计触发数达到安全上限')
  engine.mutate(tile, 'pulses', tile.pulses + 1)
  engine.mutate(tile, 'pulseTicks', PULSE_FEEDBACK_TICKS)
  engine.log(world, tile.x, tile.y, 'pulse-device', detail)
}
function register(engine, world, tile) {
  return engine.registerCooldown(world, tile, PULSE_TYPES[tile.kind].cooldown)
}
const cells = tile => {
  const out = []
  for (let x = 0; x < tile.width; x++) for (let y = 0; y < tile.height; y++) out.push({ x: tile.x + x, y: tile.y + y })
  return out
}
/** Wiring.HitSwitch: direct activation schedules a 60-tick return and trips the whole 2x2.
 * Repeated explicit inputs still toggle and emit; CheckMech does not restart an existing return.
 * A received wire toggles only the frame: no recursive pulse and no new return timer.
 */
export function triggerDetonator(engine, world, tile) {
  if (tile?.kind !== 'detonator') throw new TypeError('此元件不是引爆器输入')
  register(engine, world, tile)
  engine.mutate(tile, 'on', !tile.on)
  feedback(engine, world, tile, '引爆器输出一次脉冲；不模拟接触、爆炸或音效')
  engine.trip(world, cells(tile))
}
export function interactPulseDevice(engine, world, tile) {
  if (tile?.kind !== 'detonator') return false
  triggerDetonator(engine, world, tile)
  return true
}
export function hitPulseDevice(engine, world, tile, skipped) {
  if (!isPulseDevice(tile)) return false
  for (const p of cells(tile)) skipped.add(`${p.x},${p.y}`)
  if (tile.spent) return true // Consumed tiles are kept as editable ghosts, never active loads.
  const def = PULSE_TYPES[tile.kind]
  if (tile.kind === 'detonator') {
    engine.mutate(tile, 'on', !tile.on)
    feedback(engine, world, tile, '线路切换引爆器外观，不再输出脉冲或安排回弹')
    return true
  }
  if (def.cooldown && !register(engine, world, tile)) return true
  feedback(engine, world, tile, `${def.name} +1；仅有效触发请求，不创建弹幕、巨石、伤害或世界破坏`)
  if (def.consumable) engine.mutate(tile, 'spent', true)
  return true
}
