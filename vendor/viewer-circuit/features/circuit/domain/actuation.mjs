import flags from './actuation-data.mjs'
import { DEFINITIONS, gameTileId } from './catalog.mjs'
const solid = new Set(flags.tileSolid), top = new Set(flags.tileSolidTop), tables = new Set(flags.tileTable)
const excluded = new Set([...flags.NotReallySolid, ...flags.DeActiveExcluded])
const protectedAbove = new Set(flags.PreventsActuationUnder)
const platforms = new Set([19,427,435,436,437,438,439]) // TileID.Sets.Platforms
export function canActuate(tile) {
  if (!tile || !DEFINITIONS[tile.kind]) return false
  // Inactive stone (131) can retain an installed actuator, even while the
  // game's current solidity check prevents another deactivation.
  const id = tile.kind === 'activeStone' ? 130 : gameTileId(tile)
  return solid.has(id) && !excluded.has(id)
}
export function cellIndex(tile, x, y) { return (y - tile.y) * tile.width + x - tile.x }
export function hasActuator(tile, x = tile.x, y = tile.y) {
  const index = cellIndex(tile, x, y)
  return tile.cellActuators ? tile.cellActuators.includes(index) : tile.actuator === true
}
export function isInactive(tile, x = tile.x, y = tile.y) {
  return tile.cellInactive ? tile.cellInactive.includes(cellIndex(tile, x, y)) : tile.inactive === true
}
export function readActuation(spec, tile) {
  const n = tile.width * tile.height
  function cells(raw, fallback, label) {
    const value = raw === undefined ? (fallback ? Array.from({ length: n }, (_, i) => i) : []) : raw
    if (!Array.isArray(value) || value.length > n || value.some(i => !Number.isInteger(i) || i < 0 || i >= n) || new Set(value).size !== value.length) throw new TypeError(`无效的逐格${label}`)
    return [...value].sort((a, b) => a - b)
  }
  const installed = cells(spec.cellActuators, spec.actuator, '制动器'), inactive = cells(spec.cellInactive, spec.inactive, '虚化状态')
  if ((installed.length || inactive.length) && !canActuate(tile)) throw new TypeError('此原版物块不可制动虚化')
  tile.cellActuators = installed; tile.cellInactive = inactive
  tile.actuator = installed.length > 0; tile.inactive = inactive.length === n
}
/** Tile flags stay at local cell coordinates, rather than disappearing in clipboard operations. */
export function transformActuation(before, after, operation) {
  for (const key of ['cellActuators', 'cellInactive']) if (before[key]) {
    after[key] = before[key].map(i => {
      const x = i % before.width, y = Math.floor(i / before.width)
      const [nx, ny] = operation === 'rotate' ? [before.height - 1 - y, x] : operation === 'flipX' ? [before.width - 1 - x, y] : [x, before.height - 1 - y]
      return ny * after.width + nx
    }).sort((a, b) => a - b)
  }
}
/** Native Check2x2 uses two DIFFERENT support predicates. TNT checks active
 * tileSolid/tileTable, not inActive; boulders use SolidTileAllowBottomSlope.
 * Imported cells retain half-bricks, slopes and native platform frames.
 */
export function solidAt(world, x, y, allowTable = false) {
  const t = world.tileAt(x, y)
  if (!t || t.spent) return false
  const id = gameTileId(t)
  const offset=cellIndex(t,x,y)*4,shape=t.nativeCells ? t.nativeCells[offset+3]>>>16&255 : 0
  if (allowTable) return (solid.has(id) || tables.has(id)) && shape!==1
  if (shape===1 || isInactive(t,x,y) || !(solid.has(id)||top.has(id))) return false
  if (![2,3].includes(shape)) return true
  const frame=t.nativeCells ? t.nativeCells[offset+1]<<16>>16 : 0,variant=Math.trunc(frame/18)
  return platforms.has(id) && (variant>=0&&variant<=7 || variant>=12&&variant<=16 || variant>=25&&variant<=26)
}
const containers = new Set([21, 467, 441, 468, 88, 470, 475])
const removalProtected = new Set([5,323,72,488,26,583,584,585,586,587,588,589,596,616,470,475,634])
const boulders = new Set([138,484,664,665,711,712,713,714,715,716])
/** WorldGen.Check2x2: a container immediately ABOVE either boulder cell holds it. */
export function boulderHeldAbove(world, tile) {
  if (!boulders.has(gameTileId(tile))) return false
  return [0,1].some(dx => {
    const above = world.tileAt(tile.x + dx, tile.y - 1)
    return !!above && !above.spent && containers.has(gameTileId(above))
  })
}
/** CanKillTile / CheckBoulderChest for the represented full-cell catalog.
 * Inventory, walls, slopes, tree frames and progression are not editable here.
 * Container inventory is empty in this circuit-only world.
 */
export function canKillCell(world, tile, point) {
  if (!tile || tile.spent) return false
  const id = gameTileId(tile), above = world.tileAt(point.x, point.y - 1)
  if (above && !above.spent && [21,26,72,77,88,467,488].includes(gameTileId(above)) && id !== gameTileId(above)) return false
  if (boulders.has(id)) for (const dx of [0,1]) {
    const t = world.tileAt(tile.x + dx, tile.y - 1)
    if (t && !t.spent && (containers.has(gameTileId(t)) || removalProtected.has(gameTileId(t)))) return false
  }
  if (id === 235) for (let dx=0; dx<3; dx++) {
    const t = world.tileAt(tile.x + dx, tile.y - 1)
    if (t && !t.spent && (containers.has(gameTileId(t)) || removalProtected.has(gameTileId(t)))) return false
  }
  return true
}
export function canDeactivateCell(world, tile, point) {
  if (!tile || tile.spent) return false
  const above = world.tileAt(point.x, point.y - 1)
  return !above || above.spent || (!protectedAbove.has(gameTileId(above)) && canKillCell(world, tile, point))
}
export function actuateCell(engine, world, tile, point) {
  if (tile.spent || !hasActuator(tile, point.x, point.y)) return false
  const i = cellIndex(tile, point.x, point.y), old = [...tile.cellInactive]
  if (old.includes(i)) old.splice(old.indexOf(i), 1)
  else {
    const id = gameTileId(tile), above = world.tileAt(point.x, point.y - 1)
    if (!solid.has(id) || excluded.has(id) || !canDeactivateCell(world, tile, point)) return false
    old.push(i); old.sort((a, b) => a - b)
  }
  engine.mutate(tile, 'cellInactive', old)
  engine.mutate(tile, 'inactive', old.length === tile.width * tile.height)
  engine.log(world, point.x, point.y, 'actuator', old.includes(i) ? '此格虚化' : '此格恢复实心')
  return true
}
