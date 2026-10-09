import { hasOwn, fromEntries } from './compat.mjs'
import { DEVICE_TYPES } from './devices-catalog.mjs'
import { reshapeNativeTileData } from './world-tile.mjs'

export const isDevice = tile => !!tile && hasOwn(DEVICE_TYPES, tile.kind)
export const isDoor = tile => isDevice(tile) && DEVICE_TYPES[tile.kind].role === 'door'
const fields = ['pulses', 'cooldown', 'pulseTicks', 'globalCooldown', 'portalMode']
const integer = (v, min, max, label) => {
  if (!Number.isSafeInteger(v) || v < min || v > max) throw new RangeError(`${label}超出范围 (${min}–${max})`)
  return v
}
export function deviceSize(tile) {
  if (!isDevice(tile)) return null
  const def = DEVICE_TYPES[tile.kind]
  return { width: tile.kind === 'door' && tile.on ? 2 : def.width,
    height: tile.kind === 'trapdoor' && tile.on ? 2 : def.height }
}
export function deviceCooldown(tile) {
  if (tile.kind === 'snowballLauncher') return 60
  return tile.kind === 'cannon' ? [480, 3600, 30, 30][tile.style] : 0
}
export function launcherGroup(tile) {
  return tile.kind === 'snowballLauncher' ? 'snow' : tile.kind === 'cannon' && tile.style < 2 ? `cannon-${tile.style}` : null
}
export function launcherGlobalTicks(tile) {
  return tile.kind === 'snowballLauncher' ? 15 : tile.kind === 'cannon' ? [120, 480, 0, 0][tile.style] : 0
}
export function readDeviceState(spec, tile) {
  if (!isDevice(tile)) {
    if (spec.globalCooldown !== undefined || spec.portalMode !== undefined) throw new TypeError('此元件不支持炮台参数')
    return
  }
  const def = DEVICE_TYPES[tile.kind]
  if (!def.styles.includes(tile.style)) throw new TypeError('此样式没有原版物品放置定义')
  if (tile.inactive || tile.color !== '#ffffff' || spec.spent || spec.faulty || spec.actuator) throw new TypeError('门与炮台不支持虚构材质、消耗或独立制动状态')
  if (['contact', 'occupants', 'liquid', 'actor', 'sensorReady', 'offDelay'].some(k => spec[k] !== undefined)) throw new TypeError('只模拟物品状态，不接受人物或环境参数')
  if (!isDoor(tile) && tile.on) throw new TypeError('炮台没有常亮或门开关状态')
  Object.assign(tile, {
    pulses: integer(spec.pulses ?? 0, 0, Number.MAX_SAFE_INTEGER - 1, '累计触发数'),
    cooldown: integer(spec.cooldown ?? 0, 0, deviceCooldown(tile), '自身冷却'),
    pulseTicks: integer(spec.pulseTicks ?? 0, 0, 45, '反馈帧'),
    globalCooldown: integer(spec.globalCooldown ?? 0, 0, launcherGlobalTicks(tile), '同类炮台共享冷却'),
    portalMode: integer(spec.portalMode ?? 0, 0, tile.kind === 'cannon' && tile.style === 3 ? 1 : 0, '传送枪站模式'),
  })
}
export const deviceJSON = tile => fromEntries(fields.map(k => [k, tile[k]]))
/** x/y remain the current top-left, while the hinge stays fixed across shape changes. */
export function devicePatch(tile, changes) {
  const next = { ...tile, ...changes }
  if (tile.kind === 'door') {
    const hingeX = tile.x + (tile.on && tile.orientation === 1 ? 1 : 0)
    next.x = hingeX - (next.on && next.orientation === 1 ? 1 : 0)
  } else if (tile.kind === 'trapdoor') {
    const hingeY = tile.y + (tile.on && tile.orientation === 1 ? 1 : 0)
    next.y = hingeY - (next.on && next.orientation === 1 ? 1 : 0)
  }
  return reshapeNativeTileData(tile, Object.assign(next, deviceSize(next)))
}
export function deviceCells(tile) {
  const result = []
  for (let x = 0; x < tile.width; x++) for (let y = 0; y < tile.height; y++) result.push({ x: tile.x + x, y: tile.y + y })
  return result
}
export function fitsDevice(world, previous, next) {
  return deviceCells(next).every(p => world.contains(p.x, p.y) && (!world.tileAt(p.x, p.y) || world.tileAt(p.x, p.y) === previous))
}
function feedback(engine, world, tile, message) {
  if (tile.pulses >= Number.MAX_SAFE_INTEGER - 1) throw new RangeError('累计触发数达到安全上限')
  engine.mutate(tile, 'pulses', tile.pulses + 1)
  engine.mutate(tile, 'pulseTicks', 45)
  engine.log(world, tile.x, tile.y, 'device', message)
}
const skip = (cells, skipped) => cells.forEach(p => skipped.add(`${p.x},${p.y}`))
function toggleDoor(engine, world, tile, skipped) {
  const old = deviceCells(tile)
  // Wiring.OpenDoor picks a random side, then tries the other; trapdoors try down then up.
  const first = tile.on ? tile.orientation : tile.kind === 'door' ? engine.random.next(2) : tile.kind === 'trapdoor' ? 0 : tile.orientation
  const candidates = !tile.on && tile.kind !== 'tallGate' ? [first, 1 - first] : [first]
  for (const orientation of candidates) {
    const next = devicePatch(tile, { on: !tile.on, orientation })
    if (!fitsDevice(world, tile, next)) continue
    engine.reshape(world, tile, next)
    skip(old, skipped); skip(deviceCells(tile), skipped)
    feedback(engine, world, tile, tile.on ? '打开；原版占格已更新' : '关闭；原版占格已更新')
    return true
  }
  engine.log(world, tile.x, tile.y, 'blocked', '打开空间越界或被其他元件占用；未覆盖任何元件')
  return true
}
function registerShot(engine, world, tile, fire = true) {
  if (tile.cooldown > 0) return
  const group = launcherGroup(tile)
  if (group && engine.globalCooldowns[group] > 0) return
  // Native CheckMech also registers portal mode-only activations.
  if (!engine.registerCooldown(world, tile, deviceCooldown(tile))) return
  if (!fire) return
  if (group) engine.mutate(engine.globalCooldowns, group, launcherGlobalTicks(tile))
  engine.mutate(tile, 'globalCooldown', launcherGlobalTicks(tile))
  feedback(engine, world, tile, '发射 +1；仅方向闪光，不创建弹幕、伤害或传送门')
}
export function hitDevice(engine, world, tile, point, skipped) {
  if (!isDevice(tile)) return false
  if (isDoor(tile)) return toggleDoor(engine, world, tile, skipped)
  const col = point.x - tile.x, row = point.y - tile.y
  if (tile.kind === 'snowballLauncher') {
    if (col === 1) registerShot(engine, world, tile)
    else {
      const direction = col === 0 ? 0 : 1
      if (tile.orientation !== direction) { engine.mutate(tile, 'orientation', direction); skip(deviceCells(tile), skipped) }
    }
    return true
  }
  if (col === 0 || col === 3) {
    const orientation = Math.max(0, Math.min(8, tile.orientation + (col === 0 ? 1 : -1)))
    if (orientation !== tile.orientation) { engine.mutate(tile, 'orientation', orientation); skip(deviceCells(tile), skipped) }
    return true
  }
  const modeOnly = tile.style === 3 && row < 2
  if (modeOnly) { engine.mutate(tile, 'portalMode', 1 - tile.portalMode); skip(deviceCells(tile), skipped) }
  registerShot(engine, world, tile, !modeOnly)
  return true
}
