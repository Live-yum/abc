/** Original WLD attributes accompany a decoded editor object. They are never
 * interpreted as atlas coordinates or used to invent a placement variant. */
import { validateObjectData } from './object-records.mjs'

export const WORLD_TILE_TYPES = Object.freeze({ worldTile: Object.freeze({
  name: '原世界物件', group: '世界片段', family: 'world', role: 'static', tileId: -1,
  width: 1, height: 1, styleMax: 753,
}) })

export function worldTileSize(spec) {
  const width = spec.width ?? 1, height = spec.height ?? 1
  if (![width, height].every(n => Number.isInteger(n) && n > 0 && n <= 32)) throw new RangeError('原世界物件占格无效')
  return { width, height }
}

export function nativeTileState(tile) {
  return [tile.kind, tile.style, Number(tile.on), Number(tile.faulty), tile.orientation || 0,
    tile.effectMode || 0, tile.portalMode || 0, tile.frontTrack ?? -1, tile.backTrack ?? -1].join(':')
}

export function readNativeTileData(spec, tile) {
  if (spec.nativeCells === undefined) {
    if (spec.nativeObject !== undefined) throw new TypeError('原世界物件附加数据缺少对应物块快照')
    if (tile.kind === 'worldTile') throw new TypeError('原世界物件缺少原始物块数据')
    return
  }
  const cells = spec.nativeCells
  if (!Array.isArray(cells) || cells.length !== tile.width * tile.height * 4
    || cells.some(n => !Number.isInteger(n) || n < 0 || n > 0xffffffff)
    || typeof spec.nativeState !== 'string' || spec.nativeState.length > 160) throw new TypeError('原世界物块快照无效')
  for (let i = 0; i < cells.length; i += 4) {
    if (cells[i] >>> 16 & ~127 || (cells[i + 2] >>> 16 & 255) > 31 || cells[i + 2] >>> 24 > 31
      || (cells[i + 3] >>> 8 & 255) > 4 || (cells[i + 3] >>> 16 & 255) > 5 || cells[i + 3] >>> 24 > 15) throw new TypeError('原世界物块属性无效')
    if (tile.kind === 'worldTile' && (!(cells[i] & 65536) || (cells[i] & 65535) !== tile.style)) throw new TypeError('原世界物件类型不匹配')
  }
  if (tile.kind === 'worldTile' && spec.nativeState !== nativeTileState(tile)) throw new TypeError('原世界静态物件不能修改原版样式或方向')
  tile.nativeCells = [...cells]
  tile.nativeState = spec.nativeState
  if (spec.nativeObject !== undefined) tile.nativeObject = validateObjectData(spec.nativeObject, cells[0] & 65535)
}

export function nativeTileJSON(tile, out) {
  if (tile.nativeCells) { out.nativeCells = [...tile.nativeCells]; out.nativeState = tile.nativeState }
  if (tile.nativeObject) out.nativeObject = tile.nativeObject
  return out
}

/** A door's paint/coatings follow its hinge. Walls and liquid live separately
 * in world.background and therefore stay at their original world coordinates. */
export function reshapeNativeTileData(before, after) {
  if (!before.nativeCells || before.width === after.width && before.height === after.height && before.x === after.x && before.y === after.y) return after
  const cells = []
  for (let y = 0; y < after.height; y++) for (let x = 0; x < after.width; x++) {
    const oldX = Math.max(0, Math.min(before.width - 1, after.x + x - before.x))
    const oldY = Math.max(0, Math.min(before.height - 1, after.y + y - before.y))
    const offset = (oldY * before.width + oldX) * 4
    cells.push(...before.nativeCells.slice(offset, offset + 4))
  }
  return { ...after, nativeCells: cells, nativeState: '' }
}

export function readBackground(world, rows = []) {
  if (!Array.isArray(rows) || rows.length > 32768) throw new RangeError('世界片段背景数据过大')
  for (const row of rows) {
    if (!Array.isArray(row) || row.length !== 5 || row.some(n => !Number.isInteger(n) || n < 0 || n > 0xffffffff)
      || !world.contains(row[0], row[1]) || row[2] & 65536 || row[2] >>> 16 & ~127
      || (row[3] >>> 16 & 255) > 31 || row[3] >>> 24 > 31 || (row[4] >>> 8 & 255) > 4 || (row[4] >>> 16 & 255) > 5 || row[4] >>> 24 > 15) throw new TypeError('世界片段背景属性无效')
    const key = `${row[0]},${row[1]}`
    if (world.background.has(key)) throw new TypeError('世界片段背景坐标重复')
    world.background.set(key, row.slice(2))
  }
}
