import { LIMITS, hasWire, keyOf } from './catalog.mjs'
const DIRS = [[0, 1], [0, -1], [1, 0], [-1, 0]]
const ROUTES = [[0, 1, 2, 3], [3, 2, 1, 0], [2, 3, 0, 1]]
const router = t => t?.kind === 'junction' || t?.kind === 'pixel'
const exits = (t, incoming, outgoing) => incoming < 0 || !router(t) || (t.kind === 'pixel' ? incoming : ROUTES[t.style][incoming]) === outgoing

/** Grand Design style: one bend, integer coordinates, preview independent of
 * world edits. Bounded storage prevents a corrupt pointer spanning a huge world. */
export function orthogonalCells(a, b, order = 'horizontal', limit = 8192) {
  if (![a?.x, a?.y, b?.x, b?.y].every(Number.isSafeInteger)) throw new RangeError('笔画端点坐标无效')
  if (!['horizontal', 'vertical'].includes(order)) throw new RangeError('布线方向无效')
  const count = Math.abs(a.x - b.x) + Math.abs(a.y - b.y) + 1
  if (!Number.isSafeInteger(count) || count > limit) throw new RangeError('单次布线最多 8192 格，请分段绘制')
  const points = [{ x: a.x, y: a.y }]
  let x = a.x, y = a.y
  const horizontal = () => { const step = Math.sign(b.x - x); while (x !== b.x) { x += step; points.push({ x, y }) } }
  const vertical = () => { const step = Math.sign(b.y - y); while (y !== b.y) { y += step; points.push({ x, y }) } }
  if (order === 'horizontal') { horizontal(); vertical() } else { vertical(); horizontal() }
  return points
}

/** A Manhattan-connected stroke; a diagonal mouse motion must not leave isolated wires. */
export function lineCells(a, b, limit = Infinity) {
  if (![a.x, a.y, b.x, b.y].every(Number.isSafeInteger)) throw new RangeError('笔画端点坐标无效')
  let x = a.x, y = a.y
  const dx = Math.abs(b.x - x), dy = Math.abs(b.y - y), sx = Math.sign(b.x - x), sy = Math.sign(b.y - y)
  if (!Number.isSafeInteger(dx + dy + 1) || dx + dy + 1 > limit) throw new RangeError('笔画跨度超出可表示范围或调用方内存预算')
  const points = [{ x, y }]
  let ix = 0, iy = 0
  while (ix < dx || iy < dy) {
    if (ix < dx && (iy === dy || (ix + 0.5) * dy <= (iy + 0.5) * dx)) { x += sx; ix++ }
    else { y += sy; iy++ }
    points.push({ x, y })
  }
  return points
}

/** Read-only connectivity tracing for probes and whole-network wire removal. */
export function traceNetwork(world, starts, mask, limit = LIMITS.operations) {
  if (!Number.isInteger(mask) || mask < 1 || mask > 15) throw new RangeError('原版四色电线位掩码无效')
  const result = new Map(), visited = new Set(), queue = []
  for (let c = 0; c < 4; c++) if (hasWire(mask, c)) {
    for (const p of starts) if (hasWire(world.wireAt(p.x, p.y), c)) queue.push({ ...p, c, d: -1 })
  }
  for (let i = 0; i < queue.length; i++) {
    if (i > limit) throw new RangeError('网络追踪超过安全上限')
    const p = queue[i], t = world.tileAt(p.x, p.y), k = keyOf(p.x, p.y)
    const state = `${k}:${p.c}:${router(t) ? p.d : -1}`
    if (visited.has(state)) continue
    visited.add(state)
    result.set(k, ((result.get(k) || 0) | (1 << p.c)) >>> 0)
    for (let d = 0; d < 4; d++) {
      if (!exits(t, p.d, d)) continue
      const x = p.x + DIRS[d][0], y = p.y + DIRS[d][1]
      if (world.contains(x, y) && hasWire(world.wireAt(x, y), p.c)) queue.push({ x, y, c: p.c, d })
    }
  }
  return result
}

class Heap {
  constructor() { this.items = []; this.serial = 0 }
  push(node) {
    node.order = this.serial++
    let i = this.items.length
    this.items.push(node)
    while (i) {
      const p = (i - 1) >> 1
      if (!this.less(node, this.items[p])) break
      this.items[i] = this.items[p]; i = p
    }
    this.items[i] = node
  }
  less(a, b) { return a.f < b.f || a.f === b.f && a.order < b.order }
  pop() {
    const first = this.items[0], last = this.items.pop()
    if (this.items.length) {
      let i = 0
      while (i * 2 + 1 < this.items.length) {
        let c = i * 2 + 1
        if (c + 1 < this.items.length && this.less(this.items[c + 1], this.items[c])) c++
        if (!this.less(this.items[c], last)) break
        this.items[i] = this.items[c]; i = c
      }
      this.items[i] = last
    }
    return first
  }
}

/** Bounded A*: never silently joins an unrelated same-colour net or crosses a load. */
export function findWirePath(world, start, end, mask, { margin = 64, limit = LIMITS.route } = {}) {
  if (!mask) throw new Error('请先选择电线颜色')
  if (!world.contains(start.x, start.y) || !world.contains(end.x, end.y)) throw new RangeError('布线端点越界')
  const endpoints = new Set([keyOf(start.x, start.y), keyOf(end.x, end.y)])
  const allowed = traceNetwork(world, [start, end], mask)
  const bounds = { x0: Math.max(0, Math.min(start.x, end.x) - margin), y0: Math.max(0, Math.min(start.y, end.y) - margin),
    x1: Math.min(world.width - 1, Math.max(start.x, end.x) + margin), y1: Math.min(world.height - 1, Math.max(start.y, end.y) + margin) }
  const safe = (x, y) => {
    const k = keyOf(x, y), t = world.tileAt(x, y)
    if (endpoints.has(k)) return true
    if (t && !router(t) && !allowed.has(k)) return false
    if ((world.wireAt(x, y) & mask & ~(allowed.get(k) || 0)) !== 0) return false
    if (!router(t)) for (const [dx, dy] of DIRS) {
      const adjacent = keyOf(x + dx, y + dy)
      if ((world.wireAt(x + dx, y + dy) & mask & ~(allowed.get(adjacent) || 0)) !== 0) return false
    }
    return true
  }
  const heap = new Heap(), best = new Map()
  const distance = p => Math.abs(end.x - p.x) + Math.abs(end.y - p.y)
  heap.push({ ...start, d: -1, g: 0, f: distance(start), parent: null })
  let count = 0
  while (heap.items.length) {
    if (++count > limit) throw new RangeError('自动布线搜索达到上限；请缩短距离或分段布线')
    const p = heap.pop(), t = world.tileAt(p.x, p.y), k = `${p.x},${p.y}:${p.d}`
    if ((best.get(k) ?? Infinity) < p.g) continue
    if (p.x === end.x && p.y === end.y) {
      const path = []
      for (let n = p; n; n = n.parent) path.push({ x: n.x, y: n.y })
      return path.reverse()
    }
    for (let d = 0; d < 4; d++) {
      if (!exits(t, p.d, d)) continue
      const x = p.x + DIRS[d][0], y = p.y + DIRS[d][1]
      if (x < bounds.x0 || y < bounds.y0 || x > bounds.x1 || y > bounds.y1 || !safe(x, y)) continue
      const cost = p.g + 1 + (p.d >= 0 && p.d !== d ? 0.15 : 0), nk = `${x},${y}:${d}`
      if (cost >= (best.get(nk) ?? Infinity)) continue
      best.set(nk, cost)
      heap.push({ x, y, d, g: cost, f: cost + distance({ x, y }), parent: p })
    }
  }
  throw new Error('未找到不会短接其他网络的路径；请调整端点或使用手工布线')
}
