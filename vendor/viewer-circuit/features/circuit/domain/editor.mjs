import { hasOwn } from './compat.mjs'
import { isStorage, isStorageInput, transformStorage } from './storage-state.mjs'
import { canActuate, cellIndex, transformActuation } from './actuation.mjs'
import { settleSupports } from './support-state.mjs'
import { planOneShotRearm } from './one-shot.mjs'
import { mirrorOneShotRecovery } from './one-shot-state.mjs'
import { DEFAULT_SUPPORT_TILE_ID, ensurePlacementSupports, planPlacementSupports } from './placement-supports.mjs'
import { isRemaining, transformRemaining } from './remaining-state.mjs'
import { isPulseDevice } from './pulse-state.mjs'
import { isEffect } from './effect-state.mjs'
import { EFFECT_TYPES } from './effects-catalog.mjs'
import { isDevice, devicePatch, fitsDevice } from './device-state.mjs'
import { LIMITS, BASE_PALETTE, PALETTE, gateValue } from './catalog.mjs'
import { CircuitWorld, makeTile, assertVanillaDocument, newDocument, parseDocument, serializeDocument, tileJSON } from './model.mjs'
import { findWirePath, lineCells, traceNetwork } from './routing.mjs'
import { createRegisterExample } from './register-example.mjs'
import { createHelloExample } from './hello-example.mjs'

export function rectangle(a, b) {
  return { x: Math.min(a.x, b.x), y: Math.min(a.y, b.y), width: Math.abs(a.x - b.x) + 1, height: Math.abs(a.y - b.y) + 1 }
}
export const inRect = (r, x, y) => x >= r.x && y >= r.y && x < r.x + r.width && y < r.y + r.height
const overlap = (a, b) => a.x < b.x + b.width && a.x + a.width > b.x && a.y < b.y + b.height && a.y + a.height > b.y
function checkArea(r) {
  if (![r.x, r.y, r.width, r.height, r.width * r.height].every(Number.isSafeInteger) || r.width < 1 || r.height < 1) throw new RangeError('选区为空或坐标范围无效')
}
// makeTile validates and copies mutable cell state while sharing the immutable
// object payload. JSON round-trips would duplicate large inventory/sign data.
const materialize = t => makeTile(t)

/** History owns whole documents. A pointer stroke is one undoable, atomic command. */
export class CircuitEditor {
  constructor(document = newDocument()) {
    assertVanillaDocument(document)
    this.document = document
    this.supportTileId = DEFAULT_SUPPORT_TILE_ID
    this.path = []
    this.selection = null
    this.clipboard = null
    this.undoStack = []; this.redoStack = []
    this.pending = null
    this.revision = 0
    this.saved = serializeDocument(document)
  }
  get world() { return this.document.world }
  rearm(tiles) {
    const plan=planOneShotRearm(this.world,tiles)
    if(!plan.count)return 0
    if(this.pending)return plan.apply(this.document)
    this.change('恢复一次性机关',()=>plan.apply(this.document))
    return plan.count
  }
  get dirty() { return serializeDocument(this.document) !== this.saved }
  markSaved() { this.saved = serializeDocument(this.document) }
  replace(document, { saved = true } = {}) {
    assertVanillaDocument(document)
    this.document = document; this.path = []; this.selection = null; this.clipboard = null
    this.undoStack = []; this.redoStack = []; this.pending = null; this.revision++
    this.saved = saved ? serializeDocument(document) : ''
  }
  begin(label = '编辑') {
    if (this.pending) return
    this.pending = { label, before: serializeDocument(this.document), path: [...this.path] }
  }
  commit() {
    if (!this.pending) return false
    const entry = this.pending
    this.pending = null
    // Validate edited graphs too: all editing entry points must enforce native-only data.
    let after
    try { settleSupports(this.world); after = serializeDocument(this.document); parseDocument(after) }
    catch (e) { this.document = parseDocument(entry.before); this.path = entry.path; this.revision++; throw e }
    if (entry.before === after) return false
    entry.after = after
    this.undoStack.push(entry); this.redoStack = []
    let bytes = this.undoStack.reduce((n, e) => n + (e.before.length + e.after.length) * 2, 0)
    while (this.undoStack.length > LIMITS.history || bytes > LIMITS.historyBytes) {
      const removed = this.undoStack.shift()
      bytes -= (removed.before.length + removed.after.length) * 2
    }
    this.revision++
    return true
  }
  cancel() {
    if (!this.pending) return
    this.document = parseDocument(this.pending.before); this.path = this.pending.path
    this.pending = null; this.revision++
  }
  change(label, fn) {
    this.begin(label)
    try { const value = fn(); this.commit(); return value }
    catch (e) { this.cancel(); throw e }
  }
  undo() {
    this.cancel()
    const e = this.undoStack.pop()
    if (!e) return false
    this.document = parseDocument(e.before); this.path = [...e.path]; this.selection = null
    this.redoStack.push(e); this.revision++; return true
  }
  redo() {
    const e = this.redoStack.pop()
    if (!e) return false
    this.document = parseDocument(e.after); this.path = [...e.path]; this.selection = null
    this.undoStack.push(e); this.revision++; return true
  }
  /** Establish an edited design's initial gate display without emitting a pulse. */
  settleGates(world = this.world) {
    for (const t of world.tiles.values()) if (t.kind === 'gate') {
      let total = 0, on = 0, faulty = false
      for (let y = t.y - 1; y >= 0; y--) {
        const l = world.tileAt(t.x, y)
        if (l?.kind !== 'lamp') break
        if (l.faulty) { faulty = true; break }
        total++; if (l.on) on++
      }
      t.faulty = faulty; t.on = !faulty && gateValue(t.style, total, on)
    }
  }
  paint(a, b, { tool = 'wire', mask = 1, tile = null } = {}) {
    const world = this.world
    if (tile) tile = makeTile(tile)
    for (const p of lineCells(a, b)) {
      if (!world.contains(p.x, p.y)) continue
      if (tool === 'actuator-on' || tool === 'actuator-off') this.paintActuator(p, tool === 'actuator-on')
      else if (tool === 'wire') world.paintWire(p.x, p.y, mask)
      else if (tool === 'wire-erase') world.paintWire(p.x, p.y, mask, true)
      else if (tool === 'erase') { world.removeTile(p.x, p.y); world.setWire(p.x, p.y, 0) }
      else if (tool === 'tile' && tile) {
        if (this.canPlace(tile, p)) this.placeTile(tile, p)
      }
    }
  }
  /** A placed multi-cell object may only replace one complete, identical-sized
   * footprint. A brush cannot silently delete a neighbour by touching one cell. */
  canPlace(spec, at) {
    const tile = makeTile(spec), world = this.world
    if (!world.contains(at?.x, at?.y) || !world.contains(at.x + tile.width - 1, at.y + tile.height - 1)) return false
    for (let y = at.y; y < at.y + tile.height; y++) for (let x = at.x; x < at.x + tile.width; x++) {
      const old = world.tileAt(x, y)
      if (old && (old.x !== at.x || old.y !== at.y || old.width !== tile.width || old.height !== tile.height)) return false
    }
    try { planPlacementSupports(world, { tiles: [{ ...tile, ...at }], supportTileId: this.supportTileId }) }
    catch { return false }
    return true
  }
  placeTile(spec, at = spec) {
    const tile = this.world.putTile({ ...spec, x: at.x, y: at.y })
    ensurePlacementSupports(this.world, { tiles: [tile], supportTileId: this.supportTileId })
    return tile
  }
  paintActuator(p, enabled) {
    const tile = this.world.tileAt(p.x,p.y)
    if (!canActuate(tile)) return false
    const cells = new Set(tile.cellActuators), index = cellIndex(tile,p.x,p.y)
    if (enabled) cells.add(index); else cells.delete(index)
    this.world.putTile({...tileJSON(tile), cellActuators: [...cells].sort((a,b)=>a-b)})
    return true
  }
  applyActuators(enabled, rect = this.selection) {
    if (!rect) throw new Error('请先框选电路')
    checkArea(rect)
    for (let y=rect.y;y<rect.y+rect.height;y++) for(let x=rect.x;x<rect.x+rect.width;x++)this.paintActuator({x,y},enabled)
  }
  select(rect) {
    const world = this.world
    let r = { ...rect }, changed = true
    checkArea(r)
    // Never copy half of a lever. Expand the rectangle to complete footprints.
    while (changed) {
      changed = false
      for (const t of world.tiles.values()) if (overlap(r, t)) {
        const x = Math.min(r.x, t.x), y = Math.min(r.y, t.y)
        const right = Math.max(r.x + r.width, t.x + t.width), bottom = Math.max(r.y + r.height, t.y + t.height)
        if (x !== r.x || y !== r.y || right !== r.x + r.width || bottom !== r.y + r.height) {
          r = { x, y, width: right - x, height: bottom - y }; changed = true; checkArea(r)
        }
      }
    }
    this.selection = r
    return r
  }
  copy() {
    if (!this.selection) throw new Error('请先框选电路')
    const r = this.selection, world = this.world
    checkArea(r)
    const wires = [...this.world.wires].filter(([k]) => inRect(r, ...k.split(',').map(Number)))
      .map(([k, mask]) => { const [x, y] = k.split(',').map(Number); return [x - r.x, y - r.y, mask] })
    const tiles = [...world.tiles.values()].filter(t => inRect(r, t.x, t.y))
      .map(t => ({ ...tileJSON(t), x: t.x - r.x, y: t.y - r.y }))
    const background = [...world.background].filter(([key]) => inRect(r, ...key.split(',').map(Number)))
      .map(([key, values]) => { const [x, y] = key.split(',').map(Number); return [x - r.x, y - r.y, ...values] })
    this.clipboard = { width: r.width, height: r.height, wires, tiles, ...(background.length ? { background } : {}) }
    return this.clipboard
  }
  erase(rect = this.selection, mask = null) {
    if (!rect) throw new Error('请先框选电路')
    checkArea(rect)
    for (const [k, value] of [...this.world.wires]) {
      const [x, y] = k.split(',').map(Number)
      if (inRect(rect, x, y)) this.world.setWire(x, y, mask === null ? 0 : value & ~mask)
    }
    if (mask === null) for (const t of [...this.world.tiles.values()]) if (overlap(rect, t)) this.world.removeTile(t.x, t.y)
    if (mask === null) for (const key of this.world.background.keys()) if (inRect(rect, ...key.split(',').map(Number))) this.world.background.delete(key)
  }
  cut() { this.copy(); this.change('剪切', () => this.erase()) }
  paste(at, { merge = false } = {}) {
    const clip = this.clipboard
    if (!clip) throw new Error('剪贴板为空')
    const rect = { ...at, width: clip.width, height: clip.height }
    checkArea(rect)
    if (!this.world.contains(at.x, at.y) || !this.world.contains(at.x + clip.width - 1, at.y + clip.height - 1)) throw new RangeError('粘贴区域越界')
    if (!merge) this.erase(rect)
    for (const [x, y, mask] of clip.wires) {
      if (merge) this.world.paintWire(at.x + x, at.y + y, mask)
      else this.world.setWire(at.x + x, at.y + y, mask)
    }
    const placed = []
    for (const t of clip.tiles) placed.push(this.world.putTile({ ...materialize(t, this.document.palette.length), x: at.x + t.x, y: at.y + t.y }))
    for (const [x, y, ...values] of clip.background || []) this.world.background.set(`${at.x + x},${at.y + y}`, [...values])
    ensurePlacementSupports(this.world, { tiles: placed, supportTileId: this.supportTileId, preserveState: true })
    this.selection = rect
  }
  transformClipboard(operation = 'rotate') {
    if (!this.clipboard) throw new Error('请先复制选区')
    this.clipboard = transformWorld(this.clipboard, operation)
    return this.clipboard
  }
  fill({ mask, tile } = {}) {
    const r = this.selection
    if (!r) throw new Error('请先框选电路')
    checkArea(r)
    if (!tile) {
      for (let x = r.x; x < r.x + r.width; x++) for (let y = r.y; y < r.y + r.height; y++) this.world.paintWire(x, y, mask || 1)
      return
    }
    tile = makeTile(tile)
    if (!this.world.contains(r.x, r.y) || !this.world.contains(r.x + r.width - 1, r.y + r.height - 1)) throw new RangeError('填充选区超出画布')
    // Lay out whole supported units. Floor, ceiling and lateral anchors all
    // reserve their own row/column instead of being overwritten by the next
    // object. Every new cell stays inside the selection; existing anchors may
    // be reused unchanged. Occupied object slots are skipped, never replaced.
    const probe = new CircuitWorld(tile.width + 2, tile.height + 2)
    probe.putTile({ ...tile, x: 1, y: 1 })
    ensurePlacementSupports(probe, { supportTileId: this.supportTileId })
    const unit = probe.bounds(), offsetX = 1 - unit.x, offsetY = 1 - unit.y
    if (unit.width > r.width || unit.height > r.height) throw new RangeError('选区不足以容纳元件及所需支撑，请扩大选区')
    let count = 0
    for (let left = r.x; left + unit.width <= r.x + r.width; left += unit.width) for (let top = r.y; top + unit.height <= r.y + r.height; top += unit.height) {
      const x = left + offsetX, y = top + offsetY
      let occupied = false
      for (let dx = 0; dx < tile.width && !occupied; dx++) for (let dy = 0; dy < tile.height; dy++) if (this.world.tileAt(x + dx, y + dy)) { occupied = true; break }
      if (occupied || !this.canPlace(tile, { x, y })) continue
      const plan = planPlacementSupports(this.world, { tiles: [{ ...tile, x, y }], supportTileId: this.supportTileId })
      if (plan.tiles.some(support => !inRect(r, support.x, support.y) || !inRect(r, support.x + support.width - 1, support.y + support.height - 1))
        || plan.background.some(([px, py]) => !inRect(r, px, py))) continue
      this.placeTile(tile, { x, y }); count++
    }
    return count
  }
  route(a, b, mask) { return findWirePath(this.world, a, b, mask) }
  removeNetwork(point, mask) {
    const network = traceNetwork(this.world, [point], mask)
    for (const [k, bits] of network) this.world.paintWire(...k.split(',').map(Number), bits, true)
    return network.size
  }
  updateTile(x, y, changes) {
    const t = this.world.tileAt(x, y)
    if (!t) throw new Error('未找到元件')
    const spec = isDevice(t) ? devicePatch(tileJSON(t), changes) : { ...tileJSON(t), ...changes }
    if (hasOwn(changes,'actuator') && !hasOwn(changes,'cellActuators')) delete spec.cellActuators
    if (hasOwn(changes,'inactive') && !hasOwn(changes,'cellInactive')) delete spec.cellInactive
    const validated = makeTile(spec)
    if (isDevice(t)) {
      if (!fitsDevice(this.world, t, validated)) throw new RangeError('门的目标空间被占用或越界；编辑已取消')
      this.world.removeTile(t.x, t.y)
    }
    const placed = this.world.putTile(validated)
    ensurePlacementSupports(this.world, { tiles: [placed], supportTileId: this.supportTileId })
    this.settleGates()
  }
}

function transformWorld(raw, operation) {
  if (!['rotate', 'flipX', 'flipY'].includes(operation)) throw new Error('未知的变换')
  if (raw.tiles.some(tile => tile.kind === 'worldTile')) throw new Error('原世界静态物件保留原始帧，暂不支持旋转或镜像；原剪贴板未修改')
  const out = { ...raw }, w = raw.width, h = raw.height
  const rect = (x, y, width = 1, height = 1) => operation === 'rotate'
    ? { x: h - y - height, y: x, width: height, height: width }
    : operation === 'flipX' ? { x: w - x - width, y, width, height } : { x, y: h - y - height, width, height }
  out.width = operation === 'rotate' ? h : w; out.height = operation === 'rotate' ? w : h
  out.wires = raw.wires.map(([x, y, mask]) => { const p = rect(x, y); return [p.x, p.y, mask] })
  if (raw.background) out.background = raw.background.map(([x, y, ...values]) => { const p = rect(x, y); return [p.x, p.y, ...values] })
  out.tiles = raw.tiles.map(t => {
    if (operation === 'rotate' && t.width !== t.height) throw new Error('长方形原版元件不支持横置；请移动或镜像选区，原剪贴板未修改')
    const tile = { ...makeTile(t), ...rect(t.x, t.y, t.width, t.height) }
    if (tile.kind === 'torch') {
      const maps = { rotate: [1, -1, 0], flipX: [0, 2, 1], flipY: [-1, 1, 2] }
      tile.orientation = maps[operation][tile.orientation ?? 0]
      if (tile.orientation < 0) throw new Error('火把没有倒挂原版朝向；变换已取消，原剪贴板未修改')
    } else if (tile.kind === 'holidayLight') {
      const maps = { rotate: [3, 0, 1, 2], flipX: [0, 3, 2, 1], flipY: [2, 1, 0, 3] }
      tile.orientation = maps[operation][tile.orientation ?? 0]
    }
    if (tile.kind === 'projectilePad') {
      const maps={rotate:[2,3,1,0],flipX:[0,1,3,2],flipY:[1,0,2,3]}
      tile.orientation=maps[operation][tile.orientation ?? 0]
    }
    if (tile.kind === 'trap') {
      const maps={rotate:[2,3,1,0],flipX:[1,0,2,3],flipY:[0,1,3,2]}
      tile.orientation=maps[operation][tile.orientation ?? 0]
    }
    if (isDevice(tile)) {
      if (operation === 'flipX' && ['door', 'snowballLauncher'].includes(tile.kind)) tile.orientation = 1 - (tile.orientation ?? 0)
      if (operation === 'flipY' && tile.kind === 'trapdoor') tile.orientation = 1 - (tile.orientation ?? 0)
      if (operation === 'flipX' && tile.kind === 'cannon') tile.orientation = 8 - (tile.orientation ?? 0)
      if (operation === 'rotate' || operation === 'flipY' && ['door', 'tallGate', 'cannon', 'snowballLauncher'].includes(tile.kind)) throw new Error('此元件没有对应原版安装方向；原剪贴板未修改')
    }
    if (isEffect(tile) && EFFECT_TYPES[tile.kind].orientations) {
      if (tile.kind === 'announcementBox') {
        const maps = { rotate: [2, 3, 1, 0, 4], flipX: [0, 1, 3, 2, 4], flipY: [1, 0, 2, 3, 4] }
        tile.orientation = maps[operation][tile.orientation ?? 0]
      } else {
        if (operation !== 'flipX') throw new Error('此环境物品只有左右朝向；变换已取消，原剪贴板未修改')
        tile.orientation = 1 - (tile.orientation ?? 0)
      }
    }
    if (isStorage(tile)) transformStorage(tile, operation)
    if (isPulseDevice(tile)) {
      if (tile.kind === 'geyser') tile.orientation = (tile.orientation ?? 0) ^ (operation === 'flipX' ? 1 : 2)
      else if (operation !== 'flipX' && !['explosives', 'landMine'].includes(tile.kind)) throw new Error('此机关没有对应原版安装方向；原剪贴板未修改')
    }
    transformRemaining(tile, operation)
    if(operation==='flipX')mirrorOneShotRecovery(tile)
    transformActuation(t, tile, operation)
    if (t.nativeCells) {
      tile.nativeCells = Array(t.nativeCells.length)
      for (let i = 0; i < t.width * t.height; i++) {
        const x = i % t.width, y = Math.floor(i / t.width)
        const nx = operation === 'rotate' ? t.height - 1 - y : operation === 'flipX' ? t.width - 1 - x : x
        const ny = operation === 'rotate' ? x : operation === 'flipY' ? t.height - 1 - y : y
        for (let k = 0; k < 4; k++) tile.nativeCells[(ny * tile.width + nx) * 4 + k] = t.nativeCells[i * 4 + k]
      }
      tile.nativeState = '' // The new orientation needs fresh native frame coordinates.
    }
    if (tile.kind === 'junction' && tile.style) tile.style = 3 - tile.style
    return tile
  })
  return out
}

export function createDemo(name = 'logic') {
  if (name === 'hello') return parseDocument(JSON.stringify(createHelloExample().raw))
  if (name === 'register') return parseDocument(JSON.stringify(createRegisterExample().raw))
  if (!['logic', 'timer', 'pixel', 'gallery', 'lighting', 'lighting-extra', 'mechanisms', 'devices', 'effects', 'pulse', 'remaining', 'support', 'storage'].includes(name)) throw new Error('该示例含非原版模块或不存在，未加载')
  const doc = newDocument(name === 'lighting-extra' ? '照明状态实验 II' : name === 'lighting' ? '照明接线实验' : name === 'gallery' ? '原版元件图鉴' : name === 'timer' ? '五档定时器' : name === 'pixel' ? '像素盒交汇' : '逻辑门实验台')
  const w = doc.world
  const wire = (a, b, mask) => lineCells(a, b).forEach(p => w.paintWire(p.x, p.y, mask))
  if (name === 'storage') {
    doc.title = '容器与马桶接线实验'
    const specs = [{kind:'trappedChest',style:0},{kind:'trappedChest2',style:37},{kind:'container',style:5},{kind:'container',style:6},{kind:'container2',style:4},{kind:'container2',style:37},{kind:'classicToilet',style:20},{kind:'toilet',style:64}]
    specs.forEach((spec,i) => {
      const x=3+Math.floor(i/4)*22,y=5+i%4*7
      w.putTile({kind:'switch',x,y}); const t=w.putTile({...spec,x:x+7,y})
      for(let wx=x;wx<=x+7;wx++)w.setWire(wx,y,1)
      if(isStorageInput(t)) { w.putTile({kind:'gemspark',style:5,x:x+13,y});for(let wx=x+7;wx<=x+13;wx++)w.setWire(wx,y,1) }
    })
    doc.viewport={x:0,y:0,zoom:1};doc.notes='机关宝箱点击直接发出测试脉冲并使用原版开盖帧；普通容器和马桶接线显示局部高亮。死人宝箱支持直接输入和受电请求两条路径。不创建库存、掉落物或冲水弹幕。'
  } else if (name === 'remaining') {
    doc.title = '剩余机关状态实验'
    const rows=[{kind:'conveyor'}, {kind:'grate'}, {kind:'track',frontTrack:1,backTrack:4}, {kind:'track',style:2}, {kind:'gemLock',style:6}, {kind:'sundial'}, {kind:'partyCenter'}, {kind:'extractinator'}, {kind:'bastStatue'}, {kind:'radioMonolith'}]
    rows.forEach((item,i)=>{const x=3+Math.floor(i/5)*22,y=4+(i%5)*7;w.putTile({kind:'switch',x,y});w.putTile({...item,x:x+8,y});wire({x,y},{x:x+8,y},1<<(i%4))})
    doc.viewport={x:0,y:0,zoom:1};doc.notes='宝石锁点击直接输出。日晷／月晷共享就绪状态，在属性里显式推进黎明／黄昏边界，不将 tick 冒充游戏日。提炼仅高亮请求；不模拟容器库存或真实掉落物。轨道属性可设置原版前／后轨帧；没有矿车。'
  } else if (name === 'support') {
    doc.title='致动支撑与间接释放实验'
    const kinds=['boulder','rollingCactus','tntBarrel','bouncyBoulder','lifeCrystalBoulder','rainbowBoulder','poulder','lavaBoulder','spiderBoulder','ghoulder']
    kinds.forEach((kind,i)=>{const x=3+Math.floor(i/5)*22,y=3+i%5*7;w.putTile({kind:'switch',x,y:y+2});w.putTile({kind,x:x+8,y});for(let dx=0;dx<2;dx++)w.putTile({kind:kind==='tntBarrel'?'activeStone':'block',x:x+8+dx,y:y+2,...(kind==='tntBarrel'?{on:true}:{actuator:true})});wire({x,y:y+2},{x:x+9,y:y+2},1<<(i%4))})
    settleSupports(w);doc.viewport={x:0,y:0,zoom:1};doc.notes='巨石通过致动器虚化支撑释放；TNT桶按原版使用活动石块切换支撑，普通石块仅虚化不会释放TNT。间接物品只在贴图内增亮，保留已释放状态。巨石仅一个底格支撑仍可保持；TNT桶需要两个底格。点击已释放物件可单独恢复，“恢复机关”可批量恢复并暂停，支持撤销与重做；保留其他电路状态，未恢复的物件不会随世界导出复活。不生成弹幕。'
  } else if (name === 'pulse') {
    doc.title = '烟花与爆破触发实验'
    const rows = [{kind:'fireworkRocket',style:3}, {kind:'fireworksBox'}, {kind:'fireworkFountain'}, {kind:'geyser'}, {kind:'explosives'}, {kind:'landMine'}, {kind:'boulderStatue'}, {kind:'detonator'}]
    rows.forEach((item, i) => {
      const x = 3 + Math.floor(i / 4) * 20, y = 5 + (i % 4) * 7
      if (item.kind === 'detonator') { w.putTile({...item,x,y});w.putTile({kind:'gemspark',x:x+7,y,on:false}) }
      else { w.putTile({kind:'switch',x,y});w.putTile({...item,x:x+7,y}) }
      wire({x,y},{x:x+7,y},1<<(i%4))
    })
    doc.viewport = {x:0,y:0,zoom:1}
    doc.notes = '烟花／爆破只在当前物品内高亮。彩色火箭、炸药与地雷触发后保留已消耗标记，不破坏画布；点击已消耗物件可单独恢复，“恢复机关”可批量恢复并暂停，保留其他电路状态；世界导出保留当前消耗状态。烟花盒／喷泉保留 30 tick 冷却，热喷泉 200 tick，巨石雕像 900 tick。引爆器直接点击输出脉冲并安排回弹，收到电线信号仅切换外观，不再次发射。无弹幕、伤害、音效或世界物理。'
  } else if (name === 'effects') {
    doc.title = '环境高亮与广播实验'
    const rows = [{kind:'fountain',style:9}, {kind:'lunarMonolith'}, {kind:'aetherMonolith'}, {kind:'bubbleMachine'}, {kind:'fogMachine'}, {kind:'wireBulb'}, {kind:'announcementBox',message:'电路已触发！\n机关状态正常。'}, {kind:'projector'}]
    rows.forEach((item, i) => {
      const x = 3 + Math.floor(i / 4) * 20, y = 5 + (i % 4) * 7
      w.putTile({kind:'switch',x,y});w.putTile({...item,x:x+7,y})
      wire({x,y},{x:x+7,y},1<<(i%4))
    })
    doc.viewport = {x:0,y:0,zoom:1}
    doc.notes = '点击开关：环境元件只显示高亮；以太天塔柱按三个源码档位循环，彩线灯泡按四色分别翻转。广播盒保留文字数据，但触发仅在自身范围内高亮。所有反馈随模拟 tick 推进，不模拟环境、滤镜、水、粒子或音乐。'
  } else if (name === 'devices') {
    doc.title = '门与炮台接线实验'
    const rows = [{kind:'door'}, {kind:'trapdoor'}, {kind:'tallGate'}, {kind:'cannon',style:0}, {kind:'cannon',style:1}, {kind:'cannon',style:2}, {kind:'cannon',style:3}, {kind:'snowballLauncher'}]
    rows.forEach((item, i) => {
      const x = 3 + Math.floor(i / 4) * 20, y = 3 + (i % 4) * 7
      const launcher = ['cannon','snowballLauncher'].includes(item.kind), col = launcher ? 1 : 0
      const row = item.kind === 'cannon' ? 2 : 0
      w.putTile({kind:'switch',x,y:y+row});w.putTile({...item,x:x+7,y,orientation:item.kind==='cannon'?4:0})
      // Route below the cannon to reach its firing cell without crossing an angle-control column.
      if (item.kind === 'cannon') {
        wire({x,y:y+row},{x,y:y+4},1<<(i%4));wire({x,y:y+4},{x:x+7+col,y:y+4},1<<(i%4));wire({x:x+7+col,y:y+4},{x:x+7+col,y:y+row},1<<(i%4))
      } else if (launcher) {
        wire({x,y},{x,y:y+4},1<<(i%4));wire({x,y:y+4},{x:x+7+col,y:y+4},1<<(i%4));wire({x:x+7+col,y:y+4},{x:x+7+col,y},1<<(i%4))
      } else wire({x,y},{x:x+7,y},1<<(i%4))
    })
    doc.viewport={x:0,y:0,zoom:1}
    doc.notes='点击开关：门改变实际占格；炮台发射只在自身范围内高亮。炮台边列用于瞄准，中间列发射；传送枪站中列上两行切换模式、底行发射。只模拟物品状态，不创建角色、弹幕或世界地形。'
  } else if (name === 'mechanisms') {
    doc.title = '实用机关触发实验'
    const inputs = [{kind:'pressurePlate',style:2}, {kind:'weightedPlate'}, {kind:'logicSensor',style:2}, {kind:'projectilePad'}]
    inputs.forEach((input, i) => {
      const y = 3 + i * 6; w.putTile({ ...input, x:2, y }); w.putTile({kind:'gemspark',x:7,y,on:false})
      wire({x:2,y},{x:7,y},1<<i)
    })
    const outputs = [{kind:'statue',style:4},{kind:'trap',style:0},{kind:'inletPump'}, {kind:'teleporter'}]
    outputs.forEach((output,i) => {
      const y=3+i*6; w.putTile({kind:'switch',x:13,y});w.putTile({...output,x:18,y})
      wire({x:13,y},{x:18,y},1<<i)
      if (i===2 || i===3) { w.putTile({kind:i===2?'outletPump':'teleporter',x:25,y});wire({x:18,y:y+3},{x:25,y:y+3},1<<i);wire({x:18,y},{x:18,y:y+3},1<<i);wire({x:25,y:y+3},{x:25,y},1<<i) }
    })
    doc.notes = '左侧点击压力板／感应器直接输出一次电路脉冲；不模拟人物或环境条件。右侧点击开关：雕像、陷阱和泵只在自身范围内高亮，传送机有效配对后各自在自身范围内高亮。不生成 NPC、弹幕或液体；运行或单步推进冷却。Shift+点击可查看属性和冷却。'
    doc.viewport={x:0,y:0,zoom:1}
  } else if (name === 'lighting-extra') {
    const lights = ['torch', 'chandelier', 'campfire', 'lampPost', 'fireplace', 'shadowCandle', 'holidayLight', 'plasmaLamp']
    lights.forEach((kind, i) => {
      const x = 2 + Math.floor(i / 4) * 18, y = 3 + i % 4 * 8
      w.putTile({ kind: 'switch', x, y })
      w.putTile({ kind, x: x + 6, y, on: true })
      wire({ x, y }, { x: x + 6, y }, 1 << (i % 4))
    })
    doc.viewport = { x: 0, y: 0, zoom: 1 }
    doc.notes = '每行开关切换旁边物品本身的亮灭。火把与节日灯可在属性中切换原版朝向。营火、蜡烛的环境增益、火焰粒子和光照传播不参与模拟。'
  } else if (name === 'lighting') {
    const lights = ['candle', 'hangingLantern', 'floorLamp', 'candelabra']
    for (let i = 0; i < lights.length; i++) {
      const y = 3 + i * 5
      w.putTile({ kind: 'switch', x: 2, y })
      w.putTile({ kind: lights[i], x: 8, y, on: true })
      wire({ x: 2, y }, { x: 8, y }, 1 << i)
    }
    doc.notes = '每行开关控制一种原版照明负载。多格灯具每条颜色只切换一次；不同颜色分别切换。照明传播、火焰粒子和环境增益不是本批模拟内容。'
  } else if (name === 'timer') {
    for (let i = 0; i < 5; i++) {
      w.putTile({ kind: 'timer', x: 3, y: 3 + i * 3, style: i })
      w.putTile({ kind: 'gemspark', x: 12, y: 3 + i * 3, style: i })
      wire({ x: 3, y: 3 + i * 3 }, { x: 12, y: 3 + i * 3 }, 1 << (i % 4))
    }
  } else if (name === 'gallery') {
    BASE_PALETTE.forEach((tile, index) => w.putTile({ ...tile, x: 3 + (index % 8) * 4, y: 3 + Math.floor(index / 8) * 4 }))
    doc.notes = '仅展示游戏内已有元件；贴图来自固定的 TConvert 1.4.5.8 资源。七种宝石材质、所有逻辑门和定时器样式均有对应 TileID 与游戏帧。'
  } else if (name === 'pixel') {
    w.putTile({ kind: 'switch', x: 3, y: 3 })
    w.putTile({ kind: 'pixel', x: 10, y: 10 })
    wire({ x: 3, y: 3 }, { x: 10, y: 3 }, 1)
    wire({ x: 10, y: 3 }, { x: 10, y: 14 }, 1)
    wire({ x: 3, y: 3 }, { x: 3, y: 10 }, 2)
    wire({ x: 3, y: 10 }, { x: 15, y: 10 }, 2)
  } else {
    for (let g = 0; g < 6; g++) {
      const x = 5 + g * 6
      w.putTile({ kind: 'lamp', x, y: 5 })
      w.putTile({ kind: 'lamp', x, y: 6 })
      w.putTile({ kind: 'gate', x, y: 7, style: g })
      w.putTile({ kind: 'gemspark', x: x + 2, y: 10, style: g })
      wire({ x, y: 7 }, { x, y: 10 }, 4)
      wire({ x, y: 10 }, { x: x + 2, y: 10 }, 4)
    }
    w.putTile({ kind: 'switch', x: 2, y: 5 })
    w.putTile({ kind: 'switch', x: 2, y: 6 })
    wire({ x: 2, y: 5 }, { x: 35, y: 5 }, 1)
    wire({ x: 2, y: 6 }, { x: 35, y: 6 }, 2)
    new CircuitEditor(doc).settleGates()
    doc.notes = '触发左侧两个开关分别切换输入 A / B；逻辑门从左到右为 AND、OR、NAND、NOR、XOR、XNOR。下方宝石块记录输出脉冲奇偶，不直接表示门的布尔值。'
  }
  return doc
}
