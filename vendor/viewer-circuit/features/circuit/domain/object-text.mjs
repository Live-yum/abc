// Persistent object bytes stay opaque in the editor. These small codecs work
// without Buffer, atob/btoa, TextEncoder or TextDecoder in the WeChat runtime.
const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
const digits = new Uint8Array(128).fill(255)
for (let i = 0; i < alphabet.length; i++) digits[alphabet.charCodeAt(i)] = i
const invalid = () => new TypeError('原世界物件数据编码无效')

export function objectBase64Size(text, limit) {
  if (!Number.isSafeInteger(limit) || limit < 0 || typeof text !== 'string' || text.length % 4 || text.length > Math.ceil(limit / 3) * 4
    || !/^[A-Za-z0-9+/]*={0,2}$/.test(text)) throw invalid()
  const padding = text.endsWith('==') ? 2 : text.endsWith('=') ? 1 : 0
  const size = text.length / 4 * 3 - padding
  const last = digits[text.charCodeAt(text.length - padding - 1)]
  if (size > limit || padding === 2 && last & 15 || padding === 1 && last & 3) throw invalid()
  return size
}

export function encodeObjectBytes(bytes) {
  const chunks = []
  let chunk = ''
  for (let at = 0; at < bytes.length; at += 3) {
    const n = bytes[at] << 16 | (bytes[at + 1] || 0) << 8 | (bytes[at + 2] || 0)
    chunk += alphabet[n >>> 18 & 63] + alphabet[n >>> 12 & 63]
      + (at + 1 < bytes.length ? alphabet[n >>> 6 & 63] : '=') + (at + 2 < bytes.length ? alphabet[n & 63] : '=')
    if (chunk.length >= 8192) { chunks.push(chunk); chunk = '' }
  }
  if (chunk) chunks.push(chunk)
  return chunks.join('')
}

export function decodeObjectBytes(text, limit) {
  const bytes = new Uint8Array(objectBase64Size(text, limit))
  let out = 0
  for (let at = 0; at < text.length; at += 4) {
    const n = digits[text.charCodeAt(at)] << 18 | digits[text.charCodeAt(at + 1)] << 12
      | (text[at + 2] === '=' ? 0 : digits[text.charCodeAt(at + 2)]) << 6
      | (text[at + 3] === '=' ? 0 : digits[text.charCodeAt(at + 3)])
    bytes[out++] = n >>> 16
    if (out < bytes.length) bytes[out++] = n >>> 8
    if (out < bytes.length) bytes[out++] = n
  }
  return bytes
}

/** Terraria BinaryWriter strings use a 7-bit UTF-8 byte count. Count before
 * allocation; lone UTF-16 surrogates become U+FFFD, matching the game writer. */
export function encodeObjectText(text, limit) {
  if (!Number.isSafeInteger(limit) || limit < 0 || typeof text !== 'string' || text.length > limit) throw invalid()
  let length = 0
  const point = (at) => {
    const first = text.charCodeAt(at)
    if (first < 0xd800 || first > 0xdfff) return first
    if (first <= 0xdbff && at + 1 < text.length) {
      const second = text.charCodeAt(at + 1)
      if (second >= 0xdc00 && second <= 0xdfff) return 0x10000 + (first - 0xd800) * 1024 + second - 0xdc00
    }
    return 0xfffd
  }
  for (let i = 0; i < text.length; i++) {
    const cp = point(i)
    length += cp < 0x80 ? 1 : cp < 0x800 ? 2 : cp < 0x10000 ? 3 : 4
    if (cp > 0xffff) i++
    if (length + 1 > limit) throw new RangeError('物件文字超过单次复制上限')
  }
  let prefix = 1
  for (let value = length; value >= 128; value >>>= 7) prefix++
  if (prefix + length > limit) throw new RangeError('物件文字超过单次复制上限')
  const bytes = new Uint8Array(prefix + length)
  let at = 0, remaining = length
  while (remaining >= 128) { bytes[at++] = remaining & 127 | 128; remaining >>>= 7 }
  bytes[at++] = remaining
  for (let i = 0; i < text.length; i++) {
    const cp = point(i)
    if (cp < 0x80) bytes[at++] = cp
    else {
      if (cp < 0x800) bytes[at++] = 0xc0 | cp >>> 6
      else if (cp < 0x10000) { bytes[at++] = 0xe0 | cp >>> 12; bytes[at++] = 0x80 | cp >>> 6 & 63 }
      else { bytes[at++] = 0xf0 | cp >>> 18; bytes[at++] = 0x80 | cp >>> 12 & 63; bytes[at++] = 0x80 | cp >>> 6 & 63; i++ }
      bytes[at++] = 0x80 | cp & 63
    }
  }
  return bytes
}

/** Read a sign only when it fits the editable message limit. Longer text stays
 * as the original bytes on a static object, with no truncation or UTF-8 rewrite. */
export function decodeObjectText(bytes, maxChars) {
  let length = 0, at = 0, shift = 0
  for (;;) {
    if (at >= bytes.length || at === 5) throw invalid()
    const next = bytes[at++]
    if (at === 5 && next > 7) throw invalid()
    length += (next & 127) * 2 ** shift
    if (!(next & 128)) break
    shift += 7
  }
  if (length !== bytes.length - at) throw invalid()
  if (length > maxChars * 3) return null
  let result = ''
  while (at < bytes.length) {
    const first = bytes[at++]
    let cp = first, need = 0, min = 0
    if (first >= 0xc2 && first <= 0xdf) { cp &= 31; need = 1; min = 0x80 }
    else if (first >= 0xe0 && first <= 0xef) { cp &= 15; need = 2; min = 0x800 }
    else if (first >= 0xf0 && first <= 0xf4) { cp &= 7; need = 3; min = 0x10000 }
    else if (first >= 0x80) throw invalid()
    if (at + need > bytes.length) throw invalid()
    for (let n = 0; n < need; n++) { const next = bytes[at++]; if ((next & 0xc0) !== 0x80) throw invalid(); cp = cp << 6 | next & 63 }
    if (cp < min || cp > 0x10ffff || cp >= 0xd800 && cp <= 0xdfff) throw invalid()
    result += String.fromCodePoint(cp)
    if (result.length > maxChars) return null
  }
  return result
}
