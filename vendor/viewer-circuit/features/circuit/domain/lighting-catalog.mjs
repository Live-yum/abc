import { LIGHTING_TYPES as BATCH1_TYPES, LIGHTING_ROWS as BATCH1_ROWS } from './lighting-batch1-catalog.mjs'
import { EXTRA_LIGHTING_TYPES, EXTRA_LIGHTING_ROWS } from './lighting-extra-catalog.mjs'

// Append-only catalog: existing palette indices and serialized kind/style pairs are stable.
export const LIGHTING_TYPES = Object.freeze({ ...BATCH1_TYPES, ...EXTRA_LIGHTING_TYPES })
export const LIGHTING_ROWS = Object.freeze([...BATCH1_ROWS, ...EXTRA_LIGHTING_ROWS])
export const LIGHTING_PALETTE = Object.freeze(LIGHTING_ROWS.map(([kind, style, itemId, label, itemName]) =>
  Object.freeze({ id: `lighting-${itemId}`, kind, style, itemId, label, itemName, on: true })))
export function lightingVariant(kind, style = 0) { return LIGHTING_PALETTE.find(v => v.kind === kind && v.style === style) }
