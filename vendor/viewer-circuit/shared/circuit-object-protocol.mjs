/** Shared COB1 wire format. Kept outside either feature so main-package world
 * writes never load an optional WeChat circuit subpackage. No editor, codec,
 * resource catalogue or platform dependency belongs in this reader. */
export const CIRCUIT_OBJECT_BYTES = 4 * 1024 * 1024
export const CIRCUIT_OBJECT_LIMIT = 32768
export const CIRCUIT_OBJECT_MAGIC = 0x31424f43 // COB1, independent of WLD tile records.
export const CIRCUIT_OBJECT_HEADER = 32
export const CIRCUIT_OBJECT_WORLD_VERSION = 326
const VERSION = CIRCUIT_OBJECT_WORLD_VERSION
const tileEntities = [378, 395, 423, 470, 471, 475, 520, 597, 698, 723, 724]
const chests = new Set([21, 88, 467]), signs = new Set([55, 85, 425, 573])
const bad = () => new TypeError('原世界物件附加数据不完整或不匹配，已取消整个导入')
const uint = n => Number.isSafeInteger(n) && n >= 0 && n <= 0x7fffffff

export function objectEntityType(tileType) { return tileEntities.indexOf(tileType) }

export function objectSection(tileType) {
  return chests.has(tileType) ? 2 : signs.has(tileType) ? 3 : tileEntities.includes(tileType) ? 5 : 0
}
export function matchesObjectType(section, entityType, tileType) {
  return [2, 3, 5].includes(section) && uint(entityType) && uint(tileType) && objectSection(tileType) === section
    && (section === 5 ? tileEntities[entityType] === tileType : entityType === 0)
}

export function readObjectHeader(bytes, { complete = true } = {}) {
  if (!(bytes instanceof Uint8Array) || bytes.length < CIRCUIT_OBJECT_HEADER || bytes.length > CIRCUIT_OBJECT_BYTES) throw bad()
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength)
  const words = Array.from({ length: 8 }, (_, i) => view.getUint32(i * 4, true))
  const [magic, schema, version, count, size, originX, originY, reserved] = words
  if (magic !== CIRCUIT_OBJECT_MAGIC || schema !== 1 || !version || version > VERSION || count > CIRCUIT_OBJECT_LIMIT
    || size < CIRCUIT_OBJECT_HEADER + count * CIRCUIT_OBJECT_HEADER || size > CIRCUIT_OBJECT_BYTES
    || complete && size !== bytes.length || !uint(originX) || !uint(originY) || reserved || count && version !== VERSION) throw bad()
  return { version, count, size, originX, originY }
}

/** Each result references a bounded slice of one bundle. Only an object's
 * payload is persisted; its anchor belongs to its editor tile, not the source. */
export function readObjectBundle(bytes, { width = 0x7fffffff, height = 0x7fffffff, x, y } = {}) {
  const header = readObjectHeader(bytes)
  if (!uint(width) || !width || !uint(height) || !height
    || x !== undefined && x !== header.originX || y !== undefined && y !== header.originY) throw bad()
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength), objects = [], anchors = new Set()
  let at = CIRCUIT_OBJECT_HEADER
  for (let i = 0; i < header.count; i++) {
    if (at + CIRCUIT_OBJECT_HEADER > bytes.length) throw bad()
    const [section, entityType, objectX, objectY, tileType, size, flags, reserved] = Array.from({ length: 8 }, (_, word) => view.getUint32(at + word * 4, true))
    at += CIRCUIT_OBJECT_HEADER
    const key = `${objectX},${objectY}`
    if (!size && !(section === 5 && entityType === 7) || size > bytes.length - at || flags || reserved || !matchesObjectType(section, entityType, tileType)
      || objectX >= width || objectY >= height || anchors.has(key)) throw bad()
    anchors.add(key)
    objects.push({ x: objectX, y: objectY, version: header.version, section, entityType, tileType, payload: bytes.subarray(at, at + size) })
    at += size
  }
  if (at !== bytes.length) throw bad()
  return { ...header, objects }
}

