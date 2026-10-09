import { hasOwn } from './compat.mjs'
import { EFFECT_TYPES } from './effects-catalog.mjs'

export const isEffect = tile => !!tile && hasOwn(EFFECT_TYPES, tile.kind)
export const ANNOUNCEMENT_TICKS = 180
export const MESSAGE_LIMIT = 500
// Wiring uses native bulb frame bits in red/green/blue/yellow order, while wire passes are R/B/G/Y.
export const BULB_BITS = Object.freeze([1, 4, 2, 8])
const checked = (v, min, max, name) => {
  if (!Number.isSafeInteger(v) || v < min || v > max) throw new RangeError(`${name}超出范围 (${min}–${max})`)
  return v
}
function message(value, label) {
  if (typeof value !== 'string' || value.length > MESSAGE_LIMIT) throw new TypeError(`${label}必须是最多 ${MESSAGE_LIMIT} 字符的文字`)
  return value // Literal text, never HTML, script, sound, chat commands or a remote request.
}
export function effectIsOn(tile) { return tile.kind !== 'announcementBox' && (tile.effectMode ?? Number(tile.on)) !== 0 }
export function readEffectState(spec, tile) {
  if (!isEffect(tile)) {
    if (['effectMode', 'message', 'announcementText'].some(k => spec[k] !== undefined)) throw new TypeError('此元件不支持环境档位或广播文字')
    return
  }
  const def = EFFECT_TYPES[tile.kind]
  if (!def.styles.includes(tile.style)) throw new TypeError('不是已核验的原版环境元件样式')
  if (tile.inactive || tile.color !== '#ffffff' || spec.spent || spec.actuator || spec.faulty) throw new TypeError('环境元件不支持虚构材质、消耗或独立制动状态')
  if (['contact', 'occupants', 'liquid', 'actor', 'sensorReady', 'offDelay'].some(k => spec[k] !== undefined)) throw new TypeError('只模拟物品状态，不接受人物或环境条件')
  if (spec.cooldown !== undefined || spec.globalCooldown !== undefined || spec.portalMode !== undefined) throw new TypeError('这些环境元件没有自身机械冷却或炮台模式')
  tile.effectMode = checked(spec.effectMode ?? Number(tile.on), 0, def.modeMax, '原版状态档位')
  const on = effectIsOn(tile)
  if (spec.on !== undefined && spec.on !== on) throw new TypeError('高亮状态与原版档位不一致')
  tile.on = on
  tile.pulses = checked(spec.pulses ?? 0, 0, Number.MAX_SAFE_INTEGER - 1, '累计触发数')
  tile.pulseTicks = checked(spec.pulseTicks ?? 0, 0, def.role === 'announcement' ? ANNOUNCEMENT_TICKS : 45, '反馈 tick')
  if (def.role === 'announcement') {
    tile.message = message(spec.message ?? '', '广播文字')
    tile.announcementText = message(spec.announcementText ?? '', '正在播报的文字')
    if (tile.pulseTicks > 0 && (!tile.pulses || !tile.announcementText.trim())) throw new TypeError('活动播报缺少有效文字或触发记录')
    if (!tile.pulseTicks && tile.announcementText) throw new TypeError('已结束的播报不能残留活动文字')
  } else if (spec.message !== undefined || spec.announcementText !== undefined) throw new TypeError('只有广播盒能保存广播文字')
}
export function effectJSON(tile) {
  const out = { effectMode: tile.effectMode, pulses: tile.pulses, pulseTicks: tile.pulseTicks }
  if (tile.kind === 'announcementBox') Object.assign(out, { message: tile.message, announcementText: tile.announcementText })
  return out
}
export function effectStatus(tile) {
  const def = EFFECT_TYPES[tile.kind]
  if (!def) return ''
  if (def.role === 'announcement') return tile.pulseTicks > 0 ? '已触发 · 高亮' : '等待线路触发'
  if (def.role === 'mask') return ['红', '蓝', '绿', '黄'].filter((_, i) => (tile.effectMode ?? 0) & BULB_BITS[i]).join(' / ') || '关闭'
  return def.modes[tile.effectMode ?? Number(tile.on)]
}
export function hitEffect(engine, world, tile, colour, skipped) {
  if (!isEffect(tile)) return false
  for (let x = 0; x < tile.width; x++) for (let y = 0; y < tile.height; y++) skipped.add(`${tile.x + x},${tile.y + y}`)
  const def = EFFECT_TYPES[tile.kind]
  if (def.role === 'announcement' && !tile.message.trim()) return true // Source ignores empty/whitespace signs.
  if (tile.pulses >= Number.MAX_SAFE_INTEGER - 1) throw new RangeError('累计触发数达到安全上限')
  if (def.role === 'mask') {
    checked(colour, 0, 3, '电线颜色')
    engine.mutate(tile, 'effectMode', tile.effectMode ^ BULB_BITS[colour])
  } else if (def.role !== 'announcement') engine.mutate(tile, 'effectMode', (tile.effectMode + 1) % (def.modeMax + 1))
  engine.mutate(tile, 'on', effectIsOn(tile))
  engine.mutate(tile, 'pulses', tile.pulses + 1)
  engine.mutate(tile, 'pulseTicks', def.role === 'announcement' ? ANNOUNCEMENT_TICKS : 45)
  if (def.role === 'announcement') engine.mutate(tile, 'announcementText', tile.message)
  engine.log(world, tile.x, tile.y, def.role === 'announcement' ? 'announcement' : 'effect', def.role === 'announcement' ? tile.message : `仅物品状态／高亮：${effectStatus(tile)}`)
  return true
}
