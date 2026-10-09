import { hasOwn, fromEntries } from './compat.mjs'
import { NATIVE_TILE_ROWS, NATIVE_TILE_SHEETS } from './native-tile-data.mjs'

export { NATIVE_TILE_SHEETS }
export const NATIVE_TILE_VARIANTS = Object.freeze(fromEntries(NATIVE_TILE_ROWS.map(row => {
  const [itemId, nativeTileId, placeStyle, width, height, label, itemName, atlas, x, y, w, h, drawYOffset] = row
  return [itemId, Object.freeze({ itemId, nativeTileId, placeStyle, width, height, label, itemName,
    atlas, frame: Object.freeze([x, y, w, h]), drawYOffset })]
})))

export function nativeTileVariant(style) {
  return Number.isInteger(style) && hasOwn(NATIVE_TILE_VARIANTS, style) ? NATIVE_TILE_VARIANTS[style] : null
}

/** Imported documents identify a verified variant; they cannot choose arbitrary geometry. */
export function nativeTileSize(spec) {
  const variant = nativeTileVariant(spec?.style)
  if (!variant) throw new RangeError('没有此原版物品的已核验静态方块样式')
  return { width: variant.width, height: variant.height }
}

export const NATIVE_TILE_TYPES = Object.freeze({ nativeTile: Object.freeze({
  name: '原版静态物件', group: '原版摆设', family: 'native', role: 'static',
  tileId: -1, width: 1, height: 1, styleMax: 6195,
  styles: Object.freeze(NATIVE_TILE_ROWS.map(row => row[0])),
}) })

export const NATIVE_PALETTE = Object.freeze(NATIVE_TILE_ROWS.map(row => {
  const variant = NATIVE_TILE_VARIANTS[row[0]]
  return Object.freeze({ id: `native-tile-${variant.itemId}`, kind: 'nativeTile', style: variant.itemId,
    itemId: variant.itemId, itemName: variant.itemName, nativeTileId: variant.nativeTileId,
    width: variant.width, height: variant.height, label: variant.label, static: true })
}))
