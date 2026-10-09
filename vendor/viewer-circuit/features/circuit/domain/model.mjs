import { readMechanicalState } from './mechanical-state.mjs'
import { nativeTileSize } from './native-tiles.mjs'
import { worldTileSize, readNativeTileData, nativeTileJSON, readBackground } from './world-tile.mjs'
import { isStorage, readStorageState, storageJSON } from './storage-state.mjs'
import { readActuation } from './actuation.mjs'
import { readOneShotRecovery, oneShotRecoveryJSON } from './one-shot-state.mjs'
import { isRemaining, readRemainingState, remainingJSON, readCircuitContext } from './remaining-state.mjs'
import { isPulseDevice, readPulseState, pulseJSON } from './pulse-state.mjs'
import { isEffect, readEffectState, effectJSON } from './effect-state.mjs'
import { isDevice, deviceSize, readDeviceState, deviceJSON } from './device-state.mjs'
import { DEFINITIONS, GEM_COLORS, LIMITS, TARGET, WIRE_COLORS, keyOf, allWires } from './catalog.mjs'

import { readMechanismState, mechanismJSON, isMechanism } from './mechanism-state.mjs'

export function integer(value, min, max, label) {
  if (!Number.isSafeInteger(value) || value < min || value > max) throw new RangeError(`${label}超出范围 (${min}–${max})`)
  return value
}
export function color(value) {
  if (typeof value !== 'string' || !/^#[0-9a-f]{6}$/i.test(value)) throw new TypeError('颜色必须是 #RRGGBB')
  return value.toLowerCase()
}
export const clone = (value) => JSON.parse(JSON.stringify(value))

/** Sparse, positive-coordinate board; empty space costs no memory. */
export class CircuitWorld {
  constructor(width = LIMITS.dimension, height = LIMITS.dimension) {
    this.width = integer(width, 1, LIMITS.dimension, '宽度')
    this.height = integer(height, 1, LIMITS.dimension, '高度')
    this.wires = new Map()
    this.background = new Map()
    this.tiles = new Map()
    this.occupancy = new Map()
    this.revision = 0
  }
  contains(x, y) { return Number.isSafeInteger(x) && Number.isSafeInteger(y) && x >= 0 && y >= 0 && x < this.width && y < this.height }
  wireAt(x, y) { return this.wires.get(keyOf(x, y)) || 0 }
  tileAt(x, y) { return this.occupancy.get(keyOf(x, y)) || null }
  setWire(x, y, mask) {
    if (!this.contains(x, y)) return false
    const k = keyOf(x, y)
    integer(mask, 0, 15, '原版四色电线位掩码')
    if (this.wireAt(x, y) === mask) return false
    if (mask) this.wires.set(k, mask)
    else this.wires.delete(k)
    this.revision++
    return true
  }
  paintWire(x, y, mask, remove = false) { integer(mask, 1, 15, '原版四色电线位掩码'); return this.setWire(x, y, remove ? this.wireAt(x, y) & ~mask : this.wireAt(x, y) | mask) }
  removeTile(x, y, force = false) {
    const t = this.tileAt(x, y)
    if (!t) return false
    this.tiles.delete(keyOf(t.x, t.y))
    for (let dx = 0; dx < t.width; dx++) for (let dy = 0; dy < t.height; dy++) this.occupancy.delete(keyOf(t.x + dx, t.y + dy))
    this.revision++
    return true
  }
  putTile(spec, { replace = true, force = false } = {}) {
    const t = makeTile(spec)
    if (!this.contains(t.x, t.y) || !this.contains(t.x + t.width - 1, t.y + t.height - 1)) throw new RangeError('元件超出画布边界')
    const overlaps = new Set()
    for (let dx = 0; dx < t.width; dx++) for (let dy = 0; dy < t.height; dy++) {
      const old = this.tileAt(t.x + dx, t.y + dy)
      if (old) overlaps.add(old)
    }
    if (!replace && overlaps.size) return null
    overlaps.forEach(o => this.removeTile(o.x, o.y, true))
    this.tiles.set(keyOf(t.x, t.y), t)
    for (let dx = 0; dx < t.width; dx++) for (let dy = 0; dy < t.height; dy++) this.occupancy.set(keyOf(t.x + dx, t.y + dy), t)
    this.revision++
    return t
  }
  bounds() {
    let left = Infinity, top = Infinity, right = 0, bottom = 0
    const include = (x, y, w = 1, h = 1) => { left = Math.min(left, x); top = Math.min(top, y); right = Math.max(right, x + w); bottom = Math.max(bottom, y + h) }
    for (const k of this.wires.keys()) include(...k.split(',').map(Number))
    for (const t of this.tiles.values()) include(t.x, t.y, t.width, t.height)
    for (const k of this.background.keys()) include(...k.split(',').map(Number))
    return left === Infinity ? { x: 0, y: 0, width: 24, height: 16 } : { x: left, y: top, width: right - left, height: bottom - top }
  }
  toJSON() {
    return { width: this.width, height: this.height,
      wires: [...this.wires].map(([k, mask]) => [...k.split(',').map(Number), mask]),
      tiles: [...this.tiles.values()].map(tileJSON),
      ...(this.background.size ? { background: [...this.background].map(([key, values]) => [...key.split(',').map(Number), ...values]) } : {}) }
  }
}

export function makeTile(spec = {}) {
  if (!Object.prototype.hasOwnProperty.call(DEFINITIONS, spec.kind)) throw new TypeError(`非原版或尚未支持的元件：${String(spec.kind)}；已拒绝导入，不会丢弃原文件内容`)
  if (spec.inner !== undefined || spec.innerWidth !== undefined || spec.innerHeight !== undefined || spec.interfaceX !== undefined || spec.interfaceY !== undefined || spec.respectWire !== undefined) throw new TypeError('原版元件不能包含模块、内部电路或跨模块引脚')
  for (const field of ['on', 'faulty', 'actuator', 'inactive']) if (spec[field] !== undefined && typeof spec[field] !== 'boolean') throw new TypeError(`元件 ${field} 必须是布尔值`)
  if (spec.faulty && !['lamp', 'gate'].includes(spec.kind)) throw new TypeError('故障状态只适用于逻辑灯和逻辑门')
  const def = DEFINITIONS[spec.kind], size = spec.kind === 'worldTile' ? worldTileSize(spec) : spec.kind === 'nativeTile' ? nativeTileSize(spec) : deviceSize(spec) || def
  if ((spec.width !== undefined && spec.width !== size.width) || (spec.height !== undefined && spec.height !== size.height)) throw new TypeError('元件尺寸不符合游戏原版')
  const styleMax = spec.kind === 'gate' ? 5 : spec.kind === 'timer' ? 4 : spec.kind === 'junction' ? 2 : spec.kind === 'gemspark' ? 6 : def.styleMax ?? 0
  const t = {
    kind: spec.kind,
    x: integer(spec.x ?? 0, 0, LIMITS.dimension - 1, '横坐标'), y: integer(spec.y ?? 0, 0, LIMITS.dimension - 1, '纵坐标'),
    width: size.width, height: size.height,
    style: integer(spec.style ?? 0, 0, styleMax, '元件样式'),
    on: spec.on ?? def.defaultOn === true, faulty: spec.faulty === true && (spec.kind === 'lamp' || spec.kind === 'gate'),
    actuator: false, inactive: false,
    color: color(spec.color ?? (spec.kind === 'gemspark' ? GEM_COLORS[spec.style ?? 0] : '#ffffff')),
  }
  if (def.family === 'lighting' && (t.inactive || t.color !== '#ffffff')) throw new TypeError('照明元件不支持虚化或自定义材质颜色')
  if (def.orientations) t.orientation = integer(spec.orientation ?? 0, 0, def.orientations.length - 1, '元件原版朝向')
  else if (spec.orientation !== undefined) throw new TypeError('此元件不支持自定义朝向')
  // Actuation is validated once against native tile flags, independently of the load family.
  const stateSpec = { ...spec, actuator: false, inactive: false }
  readEffectState(stateSpec, t)
  readDeviceState(stateSpec, t)
  readPulseState(stateSpec, t)
  readRemainingState(stateSpec, t)
  readStorageState(stateSpec, t)
  if (!isStorage(t) && !isRemaining(t) && !isDevice(t) && !isEffect(t) && !isPulseDevice(t)) readMechanismState(stateSpec, t)
  readActuation(spec, t)
  if (t.kind === 'timer') t.remaining = integer(spec.remaining ?? 18000, 0, 18000, '定时器剩余相位')
  if (t.kind === 'timer' || t.cooldown !== undefined) t.mechanicalOrder = integer(spec.mechanicalOrder ?? 0, 0, Number.MAX_SAFE_INTEGER - 1, '机械调度顺序')
  else if (spec.mechanicalOrder !== undefined) throw new TypeError('此元件没有机械调度状态')
  if (t.kind === 'gemspark' && t.color !== GEM_COLORS[t.style]) throw new TypeError('宝石火花块只能选择游戏原版中的七种材质，不支持自定义颜色')
  readNativeTileData(spec, t)
  readOneShotRecovery(spec, t, DEFINITIONS)
  return t
}
export function tileJSON(t) {
  const out = { kind: t.kind, x: t.x, y: t.y, width: t.width, height: t.height, style: t.style, on: t.on, faulty: t.faulty, actuator: t.actuator, inactive: t.inactive, color: t.color }
  if (DEFINITIONS[t.kind]?.orientations) out.orientation = t.orientation ?? 0
  if (isMechanism(t)) Object.assign(out, mechanismJSON(t))
  if (isDevice(t)) Object.assign(out, deviceJSON(t))
  if (isEffect(t)) Object.assign(out, effectJSON(t))
  if (isPulseDevice(t)) Object.assign(out, pulseJSON(t))
  if (isRemaining(t)) Object.assign(out, remainingJSON(t))
  if (isStorage(t)) Object.assign(out, storageJSON(t))
  if (t.cellActuators?.length || t.cellInactive?.length) { out.cellActuators = [...t.cellActuators]; out.cellInactive = [...t.cellInactive] }
  if (t.kind === 'timer') out.remaining = t.remaining
  if (t.kind === 'timer' || t.cooldown !== undefined) out.mechanicalOrder = t.mechanicalOrder ?? 0
  oneShotRecoveryJSON(t, out)
  return nativeTileJSON(t, out)
}

export function readWorld(raw, paletteSize = 4, budget = { worlds: 0, cells: 0, tiles: 0 }, depth = 0) {
  if (!raw || typeof raw !== 'object' || depth !== 0) throw new TypeError('原版电路必须是单层画布，不支持嵌套模块')
  allWires(paletteSize)
  if (!Array.isArray(raw.wires) || !Array.isArray(raw.tiles)) throw new TypeError('缺少电线或元件数据')
  budget.cells += raw.wires.length; budget.tiles += raw.tiles.length
  const world = new CircuitWorld(raw.width, raw.height)
  for (const row of raw.wires) {
    if (!Array.isArray(row) || row.length !== 3) throw new TypeError('电线数据格式错误')
    const [x, y, mask] = row
    integer(mask, 1, allWires(paletteSize), '电线位掩码')
    if (!world.contains(x, y) || world.wires.has(keyOf(x, y))) throw new TypeError('电线坐标重复或越界')
    world.setWire(x, y, mask)
  }
  for (const spec of raw.tiles) {
    if (!spec || typeof spec !== 'object') throw new TypeError('元件数据格式错误')
    if (!Object.prototype.hasOwnProperty.call(DEFINITIONS, spec.kind)) throw new TypeError(`非原版或尚未支持的元件：${spec.kind}，已取消整个导入`)
    const size = spec.kind === 'worldTile' ? worldTileSize(spec) : spec.kind === 'nativeTile' ? nativeTileSize(spec) : deviceSize(spec) || DEFINITIONS[spec.kind]
    if (spec.width !== undefined && spec.width !== size.width) throw new TypeError('元件宽度不匹配')
    if (spec.height !== undefined && spec.height !== size.height) throw new TypeError('元件高度不匹配')
    budget.footprint = (budget.footprint || 0) + (spec.width ?? size.width ?? 1) * (spec.height ?? size.height ?? 1)
    const t = world.putTile(spec, { replace: false })
    if (!t) throw new TypeError('元件发生重叠')
  }
  readBackground(world, raw.background)
  return world
}
export function newDocument(title = '未命名电路') {
  return { title, palette: [...WIRE_COLORS], world: new CircuitWorld(), circuitContext: readCircuitContext(), seed: 1, randomState: 1, tick: 0, viewport: { x: 0, y: 0, zoom: 2 }, notes: '' }
}
export function documentJSON(doc) {
  assertVanillaDocument(doc)
  return { format: 'viewer-terralogic', version: 1, target: TARGET.game, source: TARGET.source,
    title: doc.title, mechanicalState: readMechanicalState(doc.mechanicalState, doc.world), circuitContext: readCircuitContext(doc.circuitContext), palette: [...doc.palette], seed: doc.seed, randomState: doc.randomState, tick: doc.tick, viewport: { ...doc.viewport }, notes: doc.notes || '', world: doc.world.toJSON() }
}
export function serializeDocument(doc) { return JSON.stringify(documentJSON(doc)) }
export function parseDocument(input) {
  if (typeof input !== 'string' || input.length > LIMITS.bytes) throw new RangeError('文件为空或超过 8 MB')
  const raw = JSON.parse(input)
  if (raw?.format !== 'viewer-terralogic' || raw.version !== 1) throw new TypeError('不是受支持的电路文件（schema 1）')
  if (raw.target !== TARGET.game || raw.source !== TARGET.source) throw new TypeError('该电路文件的游戏兼容版本不同，请先升级或迁移')
  assertVanillaPalette(raw.palette)
  const palette = [...WIRE_COLORS]
  const world = readWorld(raw.world, palette.length)
  const viewport = raw.viewport || {}
  const zoom = Number(viewport.zoom)
  return { title: String(raw.title || '导入电路').slice(0, 80), palette, world, mechanicalState: readMechanicalState(raw.mechanicalState, world), circuitContext: readCircuitContext(raw.circuitContext),
    seed: integer(raw.seed ?? 1, -2147483648, 2147483647, '随机种子'),
    randomState: integer(raw.randomState ?? raw.seed ?? 1, -2147483648, 2147483647, '随机状态'), tick: integer(raw.tick ?? 0, 0, Number.MAX_SAFE_INTEGER, '模拟 tick'), notes: String(raw.notes || '').slice(0, 4000),
    viewport: { x: Number.isFinite(viewport.x) ? Math.max(0, Math.min(viewport.x, LIMITS.dimension * 16)) : 0,
      y: Number.isFinite(viewport.y) ? Math.max(0, Math.min(viewport.y, LIMITS.dimension * 16)) : 0,
      zoom: Number.isFinite(zoom) ? Math.max(0.05, Math.min(zoom, 12)) : 2 } }
}
export function assertVanillaPalette(palette) {
  if (!Array.isArray(palette) || palette.length !== 4) throw new RangeError('原版只支持红、蓝、绿、黄四个通道；额外通道文件未导入')
  if (palette.some((c, i) => color(c) !== WIRE_COLORS[i])) throw new TypeError('原版电线颜色固定；自定义调色板未导入')
}
export function assertVanillaDocument(doc) {
  assertVanillaPalette(doc.palette)
  readCircuitContext(doc.circuitContext)
  readMechanicalState(doc.mechanicalState, doc.world)
  for (const mask of doc.world.wires.values()) integer(mask, 1, 15, '原版四色电线位掩码')
  for (const tile of doc.world.tiles.values()) makeTile(tile)
}
export function compatibilityIssues(doc) {
  try { assertVanillaDocument(doc); return [] } catch (e) { return [e.message] }
}
