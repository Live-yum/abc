import { hasOwn, fromEntries } from './compat.mjs'
import { STORAGE_TYPES, STORAGE_PALETTE } from './storage-catalog.mjs'
import { storageStatus } from './storage-state.mjs'
import { REMAINING_TYPES, REMAINING_PALETTE, MATERIAL_PALETTE } from './remaining-catalog.mjs'
import { remainingStatus } from './remaining-state.mjs'
import { PULSE_TYPES, PULSE_PALETTE } from './pulse-catalog.mjs'
import { pulseStatus } from './pulse-state.mjs'
import { EFFECT_TYPES, EFFECT_PALETTE } from './effects-catalog.mjs'
import { effectStatus } from './effect-state.mjs'
import { DEVICE_TYPES, DEVICE_PALETTE } from './devices-catalog.mjs'
import { MECHANISM_TYPES, MECHANISM_PALETTE } from './mechanisms-catalog.mjs'
import { LIGHTING_TYPES, LIGHTING_PALETTE, lightingVariant } from './lighting-catalog.mjs'
import { NATIVE_TILE_TYPES, NATIVE_PALETTE, nativeTileVariant } from './native-tiles.mjs'
import { WORLD_TILE_TYPES } from './world-tile.mjs'

/** The compatibility target is a commit, not a moving "latest" branch. */
export const TARGET = Object.freeze({
  game: '1.4.5.8',
  source: '8255d34616c780af12079425ac92a0a7aed87d71',
  reference: 'https://github.com/Live-yum/TerrariaDecompiledSource/blob/8255d34616c780af12079425ac92a0a7aed87d71/Terraria/Wiring.cs',
  terraLogic: '98247c33d3b6e6d21801a9808e97f27fc8d93c33',
})

// Wiring.TripWire order: wire(), wire2(), wire3(), wire4(). Do not sort by hue.
export const WIRE_COLORS = Object.freeze(['#ef5350', '#42a5f5', '#66bb6a', '#ffee58'])
export const WIRE_NAMES = Object.freeze(['红线', '蓝线', '绿线', '黄线'])
export const GATE_NAMES = Object.freeze(['AND', 'OR', 'NAND', 'NOR', 'XOR', 'XNOR'])
export const TIMER_TICKS = Object.freeze([60, 180, 300, 30, 15])
export const TIMER_NAMES = Object.freeze(['1 秒', '3 秒', '5 秒', '1/2 秒', '1/4 秒'])
export const GEM_COLORS = Object.freeze(['#bd76df', '#f3c651', '#598de8', '#62bb64', '#e85656', '#dedeea', '#ed9c49'])
export const GEM_NAMES = Object.freeze(['紫晶', '黄玉', '蓝玉', '翡翠', '红玉', '钻石', '琥珀'])
export const LIMITS = Object.freeze({
  dimension: 2147483647,
  bytes: 8 * 1024 * 1024, operations: 250000, historyBytes: 16 * 1024 * 1024,
  history: 50, trace: 12000, route: 60000,
})

export const DEFINITIONS = Object.freeze({
  ...STORAGE_TYPES, ...LIGHTING_TYPES, ...MECHANISM_TYPES, ...DEVICE_TYPES, ...EFFECT_TYPES, ...PULSE_TYPES, ...REMAINING_TYPES, ...NATIVE_TILE_TYPES, ...WORLD_TILE_TYPES,
  switch: { name: '开关', group: '输入', tileId: 136, width: 1, height: 1 },
  lever: { name: '拉杆', group: '输入', tileId: 132, width: 2, height: 2 },
  timer: { name: '定时器', group: '输入', tileId: 144, width: 1, height: 1 },
  lamp: { name: '逻辑灯', group: '逻辑', tileId: 419, width: 1, height: 1 },
  gate: { name: '逻辑门', group: '逻辑', tileId: 420, width: 1, height: 1 },
  junction: { name: '接线盒', group: '布线', tileId: 424, width: 1, height: 1 },
  pixel: { name: '像素盒', group: '输出', tileId: 445, width: 1, height: 1 },
  gemspark: { name: '宝石火花块', group: '输出', tileId: 255, width: 1, height: 1 },
  block: { name: '石块／制动器', group: '输出', tileId: 1, width: 1, height: 1 },
  activeStone: { name: '活动石块', group: '输出', tileId: 130, width: 1, height: 1 },
})

// Item.SetDefaults + ItemID.cs at TARGET.source. The brush state is part of identity.
const BASE_ITEMS = Object.freeze({
  switch: [538, 'Switch'], lever: [513, 'Lever'], pixel: [3725, 'PixelBox'], activeStone: [511, 'ActiveStoneBlock'],
  'lamp-off': [3602, 'LogicGateLamp_Off'], 'lamp-on': [3618, 'LogicGateLamp_On'], 'lamp-faulty': [3663, 'LogicGateLamp_Faulty'],
  ...fromEntries([583, 584, 585, 4484, 4485].map((id, i) => [`timer-${i}`, [id, ['Timer1Second', 'Timer3Second', 'Timer5Second', 'TimerOneHalfSecond', 'TimerOneFourthSecond'][i]]])),
  ...fromEntries(['AND', 'OR', 'NAND', 'NOR', 'XOR', 'NXOR'].map((name, i) => [`gate-${i}`, [3603 + i, `LogicGate_${name}`]])),
  ...fromEntries([0, 1, 2].map(i => [`junction-${i}`, [3616, 'WirePipe']])),
  ...fromEntries(['Amethyst', 'Topaz', 'Sapphire', 'Emerald', 'Ruby', 'Diamond', 'Amber'].map((name, i) => [`gemspark-${i}`, [1970 + i, `${name}GemsparkBlock`]])),
})
export const BASE_PALETTE = Object.freeze([
  { id: 'switch', label: '开关', kind: 'switch' },
  { id: 'lever', label: '拉杆 2×2', kind: 'lever' },
  ...TIMER_NAMES.map((label, style) => ({ id: `timer-${style}`, label, kind: 'timer', style })),
  { id: 'lamp-off', label: '逻辑灯 · 灭', kind: 'lamp', on: false },
  { id: 'lamp-on', label: '逻辑灯 · 亮', kind: 'lamp', on: true },
  { id: 'lamp-faulty', label: '故障逻辑灯', kind: 'lamp', faulty: true },
  ...GATE_NAMES.map((label, style) => ({ id: `gate-${style}`, label, kind: 'gate', style })),
  ...['十字交叉', '左上／右下', '右上／左下'].map((label, style) => ({ id: `junction-${style}`, label, kind: 'junction', style })),
  { id: 'pixel', label: '像素盒', kind: 'pixel' },
  ...GEM_NAMES.map((name, style) => ({ id: `gemspark-${style}`, label: `${name}火花块`, kind: 'gemspark', on: true, style, color: GEM_COLORS[style] })),
  { id: 'block', label: '石块 + 制动器', kind: 'block', actuator: true },
  { id: 'activeStone', label: '活动石块', kind: 'activeStone', on: true },
].map(item => BASE_ITEMS[item.id] ? { ...item, itemId: BASE_ITEMS[item.id][0], itemName: BASE_ITEMS[item.id][1] } : item))

// Keep the original common-palette and all historical indices stable.
// An inventory Stone Block must not silently install an actuator.
export const ITEM_PLACEMENT_PALETTE = Object.freeze([
  { id: 'stone-block', label: '石块', kind: 'block', itemId: 3, itemName: 'StoneBlock', actuator: false },
  { id: 'inactive-stone-block', label: '非活动石块', kind: 'activeStone', itemId: 512, itemName: 'InactiveStoneBlock', on: false },
])

export const PALETTE = Object.freeze([...BASE_PALETTE, ...LIGHTING_PALETTE, ...MECHANISM_PALETTE, ...DEVICE_PALETTE, ...EFFECT_PALETTE, ...PULSE_PALETTE, ...REMAINING_PALETTE, ...MATERIAL_PALETTE, ...STORAGE_PALETTE, ...ITEM_PLACEMENT_PALETTE, ...NATIVE_PALETTE])

export function gateValue(style, total, on) {
  switch (style) {
    case 0: return total === on
    case 1: return on > 0
    case 2: return total !== on
    case 3: return on === 0
    // Terraria XOR is EXACTLY ONE, not parity. See Wiring.CheckLogicGate.
    case 4: return on === 1
    case 5: return on !== 1
    default: throw new RangeError('未知逻辑门类型')
  }
}
export const keyOf = (x, y) => `${x},${y}`
export function allWires(count) {
  if (!Number.isInteger(count) || count < 1 || count > 4) throw new RangeError('原版只支持红、蓝、绿、黄四个通道')
  return (2 ** count - 1) >>> 0
}
export const hasWire = (mask, index) => ((mask >>> index) & 1) !== 0
export const uint = (n) => n >>> 0
export function tileLabel(t) {
  // The initial page and an empty hovered cell have no tile. Guard before every family lookup.
  if (!t) return '空格'
  if (t.kind === 'worldTile') return `原世界物件 · Tile ${t.style} · 静态保留`
  if (t.kind === 'nativeTile') return `${nativeTileVariant(t.style)?.label || '未知原版物件'} · 静态摆放`
  if (hasOwn(STORAGE_TYPES,t.kind)) return `${STORAGE_PALETTE.find(p => p.kind === t.kind && p.style === t.style)?.label || STORAGE_TYPES[t.kind].name} · ${storageStatus(t)}`
  if (hasOwn(REMAINING_TYPES,t.kind)) return `${(t.kind==='material'?MATERIAL_PALETTE:REMAINING_PALETTE).find(p=>p.kind===t.kind&&p.style===t.style)?.label || REMAINING_TYPES[t.kind].name} · ${remainingStatus(t)}`
  if (hasOwn(PULSE_TYPES, t.kind)) return `${PULSE_PALETTE.find(p => p.kind === t.kind && p.style === t.style)?.label || PULSE_TYPES[t.kind].name} · ${pulseStatus(t)}`
  if (hasOwn(EFFECT_TYPES, t.kind)) return `${EFFECT_PALETTE.find(p => p.kind === t.kind && p.style === t.style)?.label || EFFECT_TYPES[t.kind].name} · ${effectStatus(t)}`
  if (hasOwn(DEVICE_TYPES, t.kind)) return `${DEVICE_PALETTE.find(p => p.kind === t.kind && p.style === t.style)?.label || DEVICE_TYPES[t.kind].name} · ${DEVICE_TYPES[t.kind].role === 'door' ? t.on ? '开' : '关' : t.cooldown ? '冷却中' : '就绪'}`
  if (hasOwn(MECHANISM_TYPES, t.kind)) return `${MECHANISM_PALETTE.find(p => p.kind === t.kind && p.style === t.style)?.label || MECHANISM_TYPES[t.kind].name} · ${t.cooldown ? '冷却中' : '就绪'}`
  if (LIGHTING_TYPES[t.kind]) return `${lightingVariant(t.kind, t.style)?.label || LIGHTING_TYPES[t.kind].name} · ${t.on ? '亮' : '灭'}`
  if (t.kind === 'gate') return `${GATE_NAMES[t.style]} 逻辑门${t.faulty ? ' · 故障模式' : ''}`
  if (t.kind === 'timer') return `${TIMER_NAMES[t.style]}定时器`
  if (t.kind === 'gemspark') return `${GEM_NAMES[t.style]}宝石火花块 · ${t.on ? '亮' : '灭'}`
  if (t.kind === 'lamp') return t.faulty ? '故障逻辑灯' : `逻辑灯 · ${t.on ? '亮' : '灭'}`
  return DEFINITIONS[t.kind]?.name || t.kind
}

/** Native tile identity, including type-changing wired blocks (not an invented tile). */
export function gameTileId(t) {
  if (!t || !Object.prototype.hasOwnProperty.call(DEFINITIONS, t.kind)) throw new TypeError('不是已支持的原版元件')
  if (t.kind === 'worldTile') return t.style
  if (t.kind === 'nativeTile') {
    const variant = nativeTileVariant(t.style)
    if (!variant) throw new RangeError('没有此原版物品的已核验静态方块样式')
    return variant.nativeTileId
  }
  if (hasOwn(DEVICE_TYPES, t.kind) && t.on) return DEVICE_TYPES[t.kind].openTileId
  if (t.kind === 'material') return t.style
  if (t.kind === 'conveyor') return t.on ? 422 : 421
  if (t.kind === 'grate') return t.on ? 557 : 546
  if (t.kind === 'gemspark') return (t.on ? 262 : 255) + t.style
  if (t.kind === 'activeStone') return t.on ? 130 : 131
  return DEFINITIONS[t.kind].tileId
}
