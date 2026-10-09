import flags from './actuation-data.mjs'
import { gameTileId, ITEM_PLACEMENT_PALETTE, tileLabel } from './catalog.mjs'
import { MATERIAL_PALETTE } from './remaining-catalog.mjs'
import { NATIVE_PALETTE, nativeTileVariant } from './native-tiles.mjs'
import { makeTile } from './model.mjs'
import { cellIndex, isInactive, boulderHeldAbove } from './actuation.mjs'
import { nativeTileState } from './world-tile.mjs'
import { PLACEMENT_ANCHORS, NO_ATTACH_TILES, FALLING_TILES, PLATFORM_TILES, MOSS_TILES } from './placement-support-data.mjs'

export const DEFAULT_SUPPORT_TILE_ID = 54
// WallID.Glass, not TileID.Glass. A background wall cannot be substituted with
// a foreground block occupying a wall-mounted object's own footprint.
export const DEFAULT_SUPPORT_WALL_ID = 21
const solid = new Set(flags.tileSolid), solidTop = new Set(flags.tileSolidTop), tables = new Set(flags.tileTable)
const noAttach = new Set(NO_ATTACH_TILES), falling = new Set(FALLING_TILES), platforms = new Set(PLATFORM_TILES)
const boulders = new Set(flags.Boulders), notReallySolid = new Set(flags.NotReallySolid)
const treeTrunks = new Set([5, 72, 583, 584, 585, 586, 587, 588, 589, 596, 616, 634])
const beams = [124, 561, 574, 575, 576, 577, 578]
// WorldGen.AllowsSandfall checks active(), including actuated foreground,
// whereas BlockBelowMakesSandFall checks nactive() for the lower cells.
const sandHolders = new Set([21, 467, 441, 468, 323, 88, 80, 77, 26, 475, 470, 597])
const boulderHolders = new Set([21, 467, 441, 468, 88, 470, 475])
// WorldGen.GetDesiredStalagtiteStyle rejects ordinary building blocks, even
// when they are solid. CheckStalactite also requires the matching floor/ceiling.
const stalactiteMaterials = [1, ...MOSS_TILES, 200, 164, 163, 117, 402, 403, 25, 398, 400, 203, 399, 401, 396, 397, 367, 368, 147, 161]
const sides = ['bottom', 'top', 'left', 'right']
const key = (x, y) => `${x},${y}`

// Share item identity, labels and artwork with the existing material palette.
// Falling sand/silt and no-attach blocks cannot be durable automatic bases.
const seenMaterials = new Set()
const preferred = [54, 1, 30, 38, 39]
export const SUPPORT_MATERIALS = Object.freeze([...MATERIAL_PALETTE, ...ITEM_PLACEMENT_PALETTE].filter(item => {
  const id = gameTileId(item)
  if (seenMaterials.has(id) || !solid.has(id) || solidTop.has(id) || noAttach.has(id) || falling.has(id)) return false
  seenMaterials.add(id); return true
}).map(item => Object.freeze({ ...item, tileId: gameTileId(item) })).sort((a, b) => {
  const rank = id => preferred.includes(id) ? preferred.indexOf(id) : preferred.length
  return rank(a.tileId) - rank(b.tileId)
}))
const materials = new Map(SUPPORT_MATERIALS.map(item => [item.tileId, item]))
const glassPlatform = NATIVE_PALETTE.find(item => item.itemName === 'GlassPlatform')

export function supportMaterial(tileId = DEFAULT_SUPPORT_TILE_ID) {
  const material = materials.get(tileId)
  if (!material) throw new RangeError('请选择可稳定支撑物品的实心底座方块')
  return material
}

const anchor = (types, count, start = 0) => [types, count, start]
const onlySide = (base, side, types = ['SolidTile', 'SolidSide']) => ({
  ...base, bottom: null, top: null, left: null, right: null, wall: false,
  [side]: anchor(types, side === 'top' || side === 'bottom' ? base.size[0] : base.size[1]),
})
function originalFrame(tile) {
  if (!tile.nativeCells || tile.nativeState !== nativeTileState(tile)) return null
  const word = tile.nativeCells[1]
  return { x: word & 65535, y: word >>> 16 }
}
function sourceRule(tile) {
  const id = gameTileId(tile), base = PLACEMENT_ANCHORS[id]
  if (falling.has(id)) return { size: [1, 1], bottom: anchor(['SandStop'], 1) }
  if (id === 165) {
    const frame = originalFrame(tile), y = frame?.y
    if (![0, 36, 72, 90].includes(y) || tile.width !== 1 || tile.height !== (y < 72 ? 2 : 1)) return null
    return { size: [1, tile.height], [y === 0 || y === 72 ? 'top' : 'bottom']: anchor(['SolidTile'], 1),
      valid: tile.height === 1 ? [...stalactiteMaterials, 225] : stalactiteMaterials, fallbackTileId: 1 }
  }
  if (!base) return null
  const style = tile.kind === 'nativeTile' ? nativeTileVariant(tile.style).placeStyle : tile.style
  const rule = base.styles?.[style] || base
  if (rule.size[0] !== tile.width || rule.size[1] !== tile.height) return null
  return rule
}

/** FRAGMENTS geometry word 3 ABI, shared with TerraWasm's anchor planner:
 * 0 none, 1 floor, 2 ceiling, 3 both, 4 ceiling centre, 5 switch alternatives,
 * 6 wall, 7 lever alternatives, 8 logic lamp, 9/10 door hinge, 11/12 trapdoor
 * sides, 13 torch alternatives, 14 table, 15 left, 16 right, 17 cannon centre.
 * This accepts a root frame, never the local frame of an arbitrary object cell.
 */
export function nativePlacementSupportCode(type, frameX = 0, frameY = 0, width, height) {
  if (type === 165) return frameY === 0 || frameY === 72 ? 2 : frameY === 36 || frameY === 90 ? 1 : 0
  if (type === 136) return 5
  if (type === 132) return 7
  if (type === 419) return 8
  if (type === 4) return 13
  if (type === 11) return frameX % 72 >= 36 ? 10 : 9
  if (type === 386) return frameX % 72 < 36 ? 12 : 11
  if (type === 387) return 11
  if (type === 209) return 17
  if (type === 149) return [1, 16, 2, 15][Math.floor(frameY / 18) % 4]
  if (type === 442) return [1, 2, 15, 16][Math.floor(frameX / 22) % 4]
  if ([55, 425, 573].includes(type)) return [1, 2, 15, 16, 6][Math.floor(frameX / 36) % 5]
  if (type === 443) return Math.floor(frameX / 36) % 4 >= 2 ? 2 : 1
  const rule = PLACEMENT_ANCHORS[type]
  if (!rule) return 0
  if (width && (rule.size[0] !== width || rule.size[1] !== height)) return 0
  if (rule.wall) return 6
  if (rule.top && rule.bottom) return 3
  if (rule.bottom) return rule.bottom[0].length === 1 && rule.bottom[0][0] === 'Table' ? 14 : 1
  if (rule.top) return rule.top[1] === 1 && rule.top[2] === 1 ? 4 : 2
  if (rule.left && rule.right) return 11
  if (rule.left) return 15
  if (rule.right) return 16
  return 0
}

export function placementSupportCode(tile) {
  const t = makeTile(tile), frame = originalFrame(t), id = gameTileId(t)
  if (frame) return nativePlacementSupportCode(id, frame.x, frame.y, t.width, t.height)
  if (id === 11) return t.orientation === 1 ? 10 : 9
  if (id === 386) return t.orientation === 1 ? 12 : 11
  if (id === 149) return [1, 16, 2, 15][t.orientation || 0]
  if (id === 442) return [1, 2, 15, 16][t.orientation || 0]
  if (id === 425) return [1, 2, 15, 16, 6][t.orientation || 0]
  if (id === 443) return (t.orientation || 0) >= 2 ? 2 : 1
  const rule = sourceRule(t)
  if (rule?.wall) return 6
  return nativePlacementSupportCode(id, 0, 0, t.width, t.height)
}

function rulesFor(tile) {
  const base = sourceRule(tile)
  if (!base || tile.spent) return []
  const id = gameTileId(tile), frame = originalFrame(tile)
  const floor = onlySide(base, 'bottom', base.bottom?.[0] || ['SolidTile', 'SolidWithTop', 'SolidSide'])
  const wall = { ...base, bottom: null, top: null, left: null, right: null, wall: true }
  if (falling.has(id)) return isInactive(tile) ? [] : [base, onlySide(base, 'top', ['SandHold'])]
  if (boulders.has(id)) return [onlySide(base, 'bottom', ['BoulderStop'])]
  // Check2x2 keeps TNT only while BOTH feet are active solid/table tiles.
  // Unlike boulders, actuator inActive does not remove that support.
  if (id === 654) return [onlySide(base, 'bottom', ['BarrelStop'])]
  // CheckChest accepts existing active solid support, including the boulder a
  // chest holds above a trap. AnchorInvalidTiles governs initially placing a
  // new chest, so keep it for brushes but use the survival rule for saved ones.
  if (frame && (id === 21 || id === 467)) return [onlySide(base, 'bottom', ['ChestStop'])]
  if (id === 136) {
    const left = { ...onlySide(base, 'left', ['SolidTile', 'SolidSide', 'Tree', 'AlternateTile']), alternate: beams }
    const right = { ...left, left: null, right: left.left }
    const all = [floor, left, right, wall], selected = frame ? Math.floor(frame.x / 18) % 4 : 0
    return [all[selected], ...all.filter((_, index) => index !== selected)]
  }
  if (id === 132) return frame && frame.x % 144 >= 72 ? [wall, floor] : [floor, wall]
  if (id === 4) {
    const orientation = frame ? Math.floor(frame.x / 22) % 3 : tile.orientation || 0
    const all = ['bottom', 'left', 'right'].map(side => ({
      ...onlySide(base, side, side === 'bottom' ? ['SolidTile', 'SolidWithTop', 'SolidSide'] : ['SolidTile', 'SolidSide', 'Tree', 'AlternateTile']),
      alternate: beams,
    }))
    // CheckTorch can reframe to any remaining valid floor/side anchor. Reuse
    // that source support before filling the brush's preferred orientation.
    return [all[orientation], ...all.filter((_, index) => index !== orientation), wall]
  }
  if (id === 11) {
    const hinge = (frame ? frame.x % 72 >= 36 : tile.orientation === 1) ? 1 : 0
    return [{ ...base, top: anchor(['SolidTile'], 1, hinge), bottom: anchor(['SolidTile'], 1, hinge) }]
  }
  if (id === 386) {
    // WorldGen.CheckTrapDoor: frameX 0 opens upward; frameX 36 downward.
    const row = (frame ? frame.x % 72 < 36 : tile.orientation === 1) ? 1 : 0
    return [{ ...base, left: anchor(['SolidTile'], 1, row), right: anchor(['SolidTile'], 1, row) }]
  }
  if (id === 149) {
    const orientation = frame ? Math.floor(frame.y / 18) % 4 : tile.orientation || 0
    return [onlySide(base, ['bottom', 'right', 'top', 'left'][orientation], ['SolidTile'])]
  }
  if (id === 442) {
    // TileObjectData's EmptyTile flag is constrained by the custom WorldGen
    // CanPlaceProjectilePressurePad hook; a floating pad is not valid.
    const orientation = frame ? Math.floor(frame.x / 22) % 4 : tile.orientation || 0
    return [onlySide(base, ['bottom', 'top', 'left', 'right'][orientation], orientation ? ['SolidTile', 'SolidSide'] : ['SolidTile', 'SolidWithTop', 'SolidSide'])]
  }
  if ([55, 425, 573].includes(id)) {
    const orientation = frame ? Math.floor(frame.x / 36) % 5 : tile.orientation || 0
    return [orientation === 4 ? wall : onlySide(base, sides[orientation], orientation ? ['SolidTile', 'SolidSide'] : floor.bottom[0])]
  }
  if (id === 443) {
    const orientation = frame ? Math.floor(frame.x / 36) % 4 : tile.orientation || 0
    return [orientation >= 2 ? onlySide(base, 'top', ['SolidTile', 'SolidBottom']) : floor]
  }
  // Lanterns have a platform alternate with the same saved style. Preserve a
  // real platform when importing it instead of replacing it with a solid block.
  if ([42, 91, 270, 271, 572, 581, 660, 698].includes(id) && base.top) {
    return [base, { ...base, top: anchor(['Platform'], base.top[1], base.top[2]) }]
  }
  return [base]
}

function cellsFor(tile, rule) {
  const cells = []
  for (const side of sides) {
    const spec = rule[side]
    if (!spec || !spec[1]) continue
    for (let n = spec[2]; n < spec[2] + spec[1]; n++) {
      const dx = side === 'left' ? -1 : side === 'right' ? tile.width : n
      const dy = side === 'top' ? -1 : side === 'bottom' ? tile.height : n
      cells.push({ x: tile.x + dx, y: tile.y + dy, side, types: spec[0], rule })
    }
  }
  if (rule.wall) for (let y = tile.y; y < tile.y + tile.height; y++) for (let x = tile.x; x < tile.x + tile.width; x++) cells.push({ x, y, side: 'wall', rule })
  return cells
}

function blockType(tile, x, y) {
  return tile.nativeCells ? tile.nativeCells[cellIndex(tile, x, y) * 4 + 3] >>> 16 & 255 : 0
}
function platformProperTopFrame(tile, x, y) {
  const frame = tile.nativeCells ? tile.nativeCells[cellIndex(tile, x, y) * 4 + 1] << 16 >> 16 : 0
  const variant = Math.trunc(frame / 18) // WorldGen.PlatformProperTopFrame / TileObjectData.PlatformFrameWidth
  return variant >= 0 && variant <= 7 || variant >= 12 && variant <= 16 || variant >= 25 && variant <= 26
}
function validTile(rule, id) { return !rule.invalid?.includes(id) && (!rule.valid || rule.valid.includes(id)) }
function supportAt(world, point, added, beforeTrigger = false) {
  const { x, y, side, types = [], rule } = point
  if (side === 'wall') {
    const values = world.background.get(key(x, y)), id = values ? values[1] & 65535 : 0
    return rule.validWalls ? rule.validWalls.includes(id) : id > 0
  }
  const tile = added.get(key(x, y)) || world.tileAt(x, y)
  if (!tile || tile.spent && !beforeTrigger) return types.includes('EmptyTile')
  const currentId = gameTileId(tile), id = beforeTrigger && currentId === 131 ? 130 : currentId
  const shape = blockType(tile, x, y), ordinary = solid.has(id) && !solidTop.has(id)
  if (types.includes('SandHold')) return sandHolders.has(id)
  if (types.includes('ChestStop')) return solid.has(id)
  if (types.includes('BarrelStop')) return (solid.has(id) || tables.has(id)) && shape !== 1
  if (!beforeTrigger && isInactive(tile, x, y)) return types.includes('EmptyTile')
  if (types.includes('SandStop')) {
    const next = added.get(key(x, y + 1)) || world.tileAt(x, y + 1)
    return id !== 165 && (solid.has(id) || !!next && !next.spent && !isInactive(next, x, y + 1))
  }
  if (types.includes('BoulderStop')) return (solid.has(id) || solidTop.has(id)) && shape !== 1 &&
    (![2, 3].includes(shape) || platforms.has(id) && platformProperTopFrame(tile, x, y))
  if (types.includes('AlternateTile') && rule.alternate?.includes(id)) return true
  if (types.includes('Tree') && treeTrunks.has(id)) {
    return [-1, 1].every(dy => {
      const next = world.tileAt(x, y + dy)
      return next && !isInactive(next, x, y + dy) && treeTrunks.has(gameTileId(next))
    })
  }
  if (side === 'bottom') {
    if (types.includes('SolidTile') && ordinary && !noAttach.has(id) && (rule.flatten || shape === 0) && validTile(rule, id)) return true
    if (types.includes('SolidWithTop') || types.includes('Table')) {
      if (platforms.has(id)) {
        if (shape !== 1 && platformProperTopFrame(tile, x, y)) return true
      } else if (solid.has(id) && solidTop.has(id)) return true
    }
    if (types.includes('Table') && !platforms.has(id) && tables.has(id) && shape === 0) return true
    return types.includes('SolidSide') && ordinary && [4, 5].includes(shape) && validTile(rule, id)
  }
  if (ordinary && !noAttach.has(id) && (rule.flatten || shape === 0) && validTile(rule, id)) return true
  if (side === 'top') {
    if ((types.includes('Platform') || types.includes('PlatformNonHammered') && shape === 0) && platforms.has(id) && validTile(rule, id)) return true
    if (types.includes('PlanterBox') && id === 380) return true
    if (types.includes('SolidBottom') && !notReallySolid.has(id) && (ordinary || platforms.has(id) && [1, 2, 3].includes(shape)) && ![4, 5].includes(shape) && validTile(rule, id)) return true
  }
  const shapes = side === 'top' ? [2, 3] : side === 'left' ? [3, 5] : [2, 4]
  return types.includes('SolidSide') && ordinary && shapes.includes(shape) && validTile(rule, id)
}

// A triggered support is still part of the current design. Testing its former
// solidity only identifies that dependency; it never changes the exported tile.
function triggeredSupportAt(world, point) {
  if (point.side === 'wall') return false
  const tile = world.tileAt(point.x, point.y)
  return !!tile && (tile.spent || isInactive(tile, point.x, point.y) || gameTileId(tile) === 131) &&
    supportAt(world, point, new Map(), true)
}

/** Keep only the dependency branch an object actually uses. A selection can
 * exclude a door's lintel or a candle's table without losing that original
 * material, its full multi-cell footprint, paint or actuator state on export.
 * This is read-only: missing supports are left to ensurePlacementSupports.
 * preserveState also carries original triggered supports without restoring them.
 */
export function collectPlacementSupports(world, tiles, { preserveState = false } = {}) {
  const roots = [...tiles], selected = new Set(roots.map(tile => key(tile.x, tile.y)))
  const queue = [...roots], visited = new Set(), dependencies = new Map(), background = new Map(), added = new Map()
  const include = tile => {
    if (!tile) return
    const cell = key(tile.x, tile.y)
    if (!selected.has(cell)) dependencies.set(cell, tile)
    if (!visited.has(cell)) queue.push(tile)
  }
  for (let index = 0; index < queue.length; index++) {
    const tile = queue[index], cell = key(tile.x, tile.y)
    if (visited.has(cell)) continue
    visited.add(cell)
    const candidates = rulesFor(tile).map(rule => cellsFor(tile, rule))
    if (!candidates.length) continue
    const satisfied = point => supportAt(world, point, added)
    // Falling foreground can have both a lower stop and an upper holding
    // object. Keep both when present: losing the holder changes what happens
    // when the original lower actuator later opens the falling path.
    let chosen = falling.has(gameTileId(tile)) ? candidates.flat().filter(satisfied) : candidates.find(cells => cells.every(satisfied))
    if (boulders.has(gameTileId(tile))) {
      // Check2x2 also permits a single surviving bottom anchor, or a holding
      // container directly above. Like sand, keep every actual hold so an
      // actuator opening one foot cannot unexpectedly release the boulder.
      chosen = candidates[0].filter(satisfied)
      for (const dx of [0, 1]) {
        const above = world.tileAt(tile.x + dx, tile.y - 1)
        if (above && !above.spent && boulderHolders.has(gameTileId(above))) include(above)
      }
    }
    // For an incomplete object, retain valid portions of the same repairable
    // branch that the placement planner will fill. Never copy an invalid block
    // merely because it happens to occupy an anchor coordinate.
    chosen ||= candidates.find(cells => cells.every(point => satisfied(point) ||
      world.contains(point.x, point.y) && (point.side === 'wall' || !world.tileAt(point.x, point.y))))
    const triggered = preserveState ? candidates.flat().filter(point => triggeredSupportAt(world, point)) : []
    // Carry the surviving feet of the same interrupted branch as well. Omitting
    // an inactive foot from a tight selection would turn it into a repairable
    // empty cell and silently re-arm the exported mechanism.
    chosen ||= candidates.find(cells => cells.some(point => triggered.includes(point)))
    if (triggered.length) chosen = [...(chosen || []), ...triggered]
    if (!chosen) continue
    for (const point of chosen) {
      if (!satisfied(point) && !triggered.includes(point)) continue
      if (point.side === 'wall') {
        const values = world.background.get(key(point.x, point.y))
        if (values) background.set(key(point.x, point.y), [point.x, point.y, ...values])
        continue
      }
      const support = world.tileAt(point.x, point.y)
      include(support)
      if (support && point.types.includes('SandStop') && !solid.has(gameTileId(support))) {
        // A non-solid foreground cell stops sand only while the next cell is
        // active too. Preserve that second dependency before following chains.
        include(world.tileAt(point.x, point.y + 1))
      }
      if (support && point.types.includes('Tree') && treeTrunks.has(gameTileId(support))) {
        // A lateral tree anchor is valid only while its adjoining trunk cells
        // above and below survive as well (TileObject.CanPlace).
        include(world.tileAt(point.x, point.y - 1)); include(world.tileAt(point.x, point.y + 1))
      }
    }
  }
  return { tiles: [...dependencies.values()], background: [...background.values()] }
}

function platformFor(material) {
  const itemName = `${material.itemName.replace(/Block$/, '')}Platform`
  return NATIVE_PALETTE.find(item => item.nativeTileId === 19 && item.itemName === itemName) || glassPlatform
}

/** Plan first so a late collision cannot leave half of a base in the world.
 * Existing valid material, paint, actuators and background are never replaced.
 * `tiles` can restrict a placement gesture to its newly inserted objects.
 * `preserveState` keeps previously armed/triggered paths open during transfers.
 */
export function planPlacementSupports(world, { supportTileId = DEFAULT_SUPPORT_TILE_ID, tiles = [...world.tiles.values()], preserveState = false } = {}) {
  const material = supportMaterial(supportTileId), added = new Map(), walls = new Map(), issues = [], fallingChecks = []
  for (const raw of tiles) {
    const tile = makeTile(raw), rules = rulesFor(tile)
    if (!rules.length) continue
    const candidates = rules.map(rule => cellsFor(tile, rule))
    // Placement may supply an initial base, but exporting is not a reset.
    // Armed mechanisms can have removed feet, and occupied inactive/spent feet
    // must never cause a new floor or alternate wall to close their fall path.
    if (preserveState && (tile.supportArmed || tile.cellInactive?.length ||
      candidates.some(cells => cells.some(point => triggeredSupportAt(world, point))))) continue
    if (falling.has(gameTileId(tile))) { fallingChecks.push({ tile, candidates }); continue }
    const satisfied = point => point.side === 'wall' && walls.has(key(point.x, point.y)) || supportAt(world, point, added)
    if (candidates.some(cells => cells.every(satisfied))) continue
    if (boulders.has(gameTileId(tile)) && (boulderHeldAbove(world, tile) || candidates[0].some(satisfied))) continue
    if (gameTileId(tile) === 419) {
      issues.push(`逻辑灯 (${tile.x}, ${tile.y}) 需要下方逻辑灯或逻辑门，底座方块不能替代`)
      continue
    }
    let chosen = null
    // Prefer the frame's anchor and reuse complete existing alternatives. If a
    // default floor is blocked, a valid alternate wall can be added safely.
    for (const cells of candidates) {
      if (cells.every(point => satisfied(point) || world.contains(point.x, point.y) && (point.side === 'wall' || !world.tileAt(point.x, point.y) && !added.has(key(point.x, point.y))))) { chosen = cells; break }
    }
    if (!chosen) throw new RangeError(`${tileLabel(tile)}的支撑位置被占用或超出画布，放置已取消`)
    for (const point of chosen) {
      if (satisfied(point)) continue
      const { x, y, side, types = [], rule } = point
      if (side === 'wall') {
        const values = [...(world.background.get(key(x, y)) || [0, 0, 0])]
        if (rule.validWalls && !rule.validWalls.includes(DEFAULT_SUPPORT_WALL_ID)) { issues.push(`${tileLabel(tile)}需要指定类型的背景墙，未擅自替换`); continue }
        values[1] = (values[1] & 0xffff0000 | DEFAULT_SUPPORT_WALL_ID) >>> 0
        walls.set(key(x, y), values)
      } else {
        const tableOnly = types.includes('Table') && !types.includes('SolidTile')
        const spec = tableOnly ? platformFor(material) : rule.fallbackTileId && !validTile(rule, gameTileId(material)) ? supportMaterial(rule.fallbackTileId) : material
        const support = makeTile({ ...spec, x, y, actuator: false, inactive: false })
        added.set(key(x, y), support)
        if (!supportAt(world, point, added)) {
          added.delete(key(x, y))
          issues.push(`${tileLabel(tile)}需要特定原版支撑材质，${material.label}不能替代`)
          continue
        }
      }
    }
  }
  // Validate after other legitimate placement supports have been planned, so
  // object insertion order cannot change the result. Never close a sand trap's
  // original falling path by inventing a floor just for falling foreground.
  for (const { tile, candidates } of fallingChecks) if (!candidates.some(cells => cells.every(point => supportAt(world, point, added)))) {
    issues.push(`${tileLabel(tile)} (${tile.x}, ${tile.y}) 缺少稳定支撑或上方阻落物，请先修复原下落路径`)
  }
  return { tiles: [...added.values()], background: [...walls].map(([cell, values]) => [...cell.split(',').map(Number), ...values]), issues }
}

export function ensurePlacementSupports(world, options = {}) {
  const plan = planPlacementSupports(world, options)
  for (const tile of plan.tiles) world.putTile(tile, { replace: false })
  for (const [x, y, ...values] of plan.background) world.background.set(key(x, y), values)
  if (plan.background.length) world.revision++
  return { addedTiles: plan.tiles.length, addedWalls: plan.background.length, issues: plan.issues }
}
