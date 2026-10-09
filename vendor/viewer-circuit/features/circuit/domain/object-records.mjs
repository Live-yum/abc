import { decodeObjectBytes, encodeObjectBytes, objectBase64Size, encodeObjectText, decodeObjectText } from './object-text.mjs'
import { CIRCUIT_OBJECT_BYTES, CIRCUIT_OBJECT_LIMIT, CIRCUIT_OBJECT_MAGIC, CIRCUIT_OBJECT_HEADER,
  CIRCUIT_OBJECT_WORLD_VERSION as VERSION, objectSection, objectEntityType, matchesObjectType } from '../../../shared/circuit-object-protocol.mjs'
export { CIRCUIT_OBJECT_BYTES, CIRCUIT_OBJECT_LIMIT, CIRCUIT_OBJECT_MAGIC, CIRCUIT_OBJECT_HEADER,
  objectSection, readObjectHeader, readObjectBundle } from '../../../shared/circuit-object-protocol.mjs'

const validated = new WeakSet()
const bad = () => new TypeError('原世界物件附加数据不完整或不匹配，已取消整个导入')
const tooLarge = () => new RangeError('物件附加数据超过 4 MiB，请缩小选区')
const uint = n => Number.isSafeInteger(n) && n >= 0 && n <= 0x7fffffff

export function objectData(record) {
  return validateObjectData({ version: record.version, section: record.section, entityType: record.entityType,
    tileType: record.tileType, data: encodeObjectBytes(record.payload) }, record.tileType)
}

/** Immutable strings let copy/history share large payloads without repeatedly
 * cloning inventory arrays. Malformed user documents still fail before edits. */
export function validateObjectData(value, tileType) {
  if (!value || value.tileType !== tileType) throw bad()
  if (validated.has(value)) return value
  if (value.version !== VERSION || !matchesObjectType(value.section, value.entityType, value.tileType)
    || Object.keys(value).sort().join(',') !== 'data,entityType,section,tileType,version') throw bad()
  const size = objectBase64Size(value.data, CIRCUIT_OBJECT_BYTES - CIRCUIT_OBJECT_HEADER * 2)
  if (!size && !(value.section === 5 && value.entityType === 7)) throw bad()
  const result = Object.freeze({ ...value })
  validated.add(result)
  return result
}

export function objectPayload(value) {
  validateObjectData(value, value?.tileType)
  return decodeObjectBytes(value.data, CIRCUIT_OBJECT_BYTES - CIRCUIT_OBJECT_HEADER * 2)
}

/** Bundle creation accepts relative anchors, so moving, copying or selecting a
 * subset never reuses an old world coordinate or a target's global entity ID. */
export function writeObjectBundle(objects, { x = 0, y = 0, version = VERSION } = {}) {
  if (!Array.isArray(objects) || objects.length > CIRCUIT_OBJECT_LIMIT || !uint(x) || !uint(y)
    || !uint(version) || !version || version > VERSION || objects.length && version !== VERSION) throw bad()
  let length = CIRCUIT_OBJECT_HEADER
  const anchors = new Set()
  for (const object of objects) {
    const key = `${object.x},${object.y}`
    if (!uint(object.x) || !uint(object.y) || anchors.has(key) || !matchesObjectType(object.section, object.entityType, object.tileType)
      || !(object.payload instanceof Uint8Array) || !object.payload.length && !(object.section === 5 && object.entityType === 7)
      || object.version !== VERSION) throw bad()
    anchors.add(key)
    length += CIRCUIT_OBJECT_HEADER + object.payload.byteLength
    if (length > CIRCUIT_OBJECT_BYTES) throw tooLarge()
  }
  const bytes = new Uint8Array(length), view = new DataView(bytes.buffer)
  const write = (at, words) => words.forEach((word, i) => view.setUint32(at + i * 4, word, true))
  write(0, [CIRCUIT_OBJECT_MAGIC, 1, version, objects.length, length, x, y, 0])
  let at = CIRCUIT_OBJECT_HEADER
  for (const object of objects) {
    write(at, [object.section, object.entityType, object.x, object.y, object.tileType, object.payload.length, 0, 0])
    at += CIRCUIT_OBJECT_HEADER; bytes.set(object.payload, at); at += object.payload.length
  }
  return bytes
}

export function tileObjectRecord(tile, tileType, maxPayloadBytes = CIRCUIT_OBJECT_BYTES - CIRCUIT_OBJECT_HEADER * 2) {
  const section = objectSection(tileType)
  if (!section) {
    if (tile.nativeObject) throw bad()
    return null
  }
  if (!Number.isSafeInteger(maxPayloadBytes) || maxPayloadBytes < 0) throw tooLarge()
  let payload
  const entityType = section === 5 ? objectEntityType(tileType) : 0
  if (tile.nativeObject) {
    validateObjectData(tile.nativeObject, tileType)
    if (objectBase64Size(tile.nativeObject.data, CIRCUIT_OBJECT_BYTES) > maxPayloadBytes) throw tooLarge()
    payload = objectPayload(tile.nativeObject)
    if (tile.kind === 'announcementBox' && decodeObjectText(payload, 500) !== tile.message) payload = encodeObjectText(tile.message, maxPayloadBytes)
    if (tile.kind === 'logicSensor') {
      if (payload.length !== 2 || payload[0] < 1 || payload[0] > 7 || payload[1] > 1) throw bad()
      if (payload[0] !== tile.style + 1) payload = Uint8Array.of(tile.style + 1, 0)
    }
  } else if (section === 2 && ['container', 'container2'].includes(tile.kind)) {
    if (maxPayloadBytes < 85) throw tooLarge()
    payload = new Uint8Array(1 + 4 + 40 * 2) // Empty name, explicit 40-slot empty inventory.
    new DataView(payload.buffer).setUint32(1, 40, true)
  } else if (tile.kind === 'announcementBox') payload = encodeObjectText(tile.message, maxPayloadBytes)
  else if (tile.kind === 'logicSensor') { if (maxPayloadBytes < 2) throw tooLarge(); payload = Uint8Array.of(tile.style + 1, 0) }
  else throw new Error('物件缺少完整的原世界记录，请重新提取后导入')
  return { version: VERSION, section, entityType, tileType, payload }
}
