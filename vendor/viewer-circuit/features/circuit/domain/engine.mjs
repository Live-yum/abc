import { readMechanicalState, migrateMechanicalState } from './mechanical-state.mjs'
import { isStorage, triggerStorageInput, hitStorage } from './storage-state.mjs'
import { actuateCell, canDeactivateCell, canKillCell, hasActuator } from './actuation.mjs'
import { settleSupports, supportCellsChanged, supportCellsWillChange } from './support-state.mjs'
import { isOneShot } from './one-shot-state.mjs'
import { isRemaining, triggerRemainingInput, hitRemaining, readCircuitContext, syncSharedRemaining, advanceCircuitBoundary } from './remaining-state.mjs'
import { isPulseDevice, interactPulseDevice, triggerDetonator, hitPulseDevice } from './pulse-state.mjs'
import { hitEffect } from './effect-state.mjs'
import { isDevice, deviceCells, hitDevice, fitsDevice } from './device-state.mjs'
import { isMechanism, interactMechanism, triggerMechanismInput, newMechanismPass, hitMechanism, finishMechanismTeleports } from './mechanism-state.mjs'
import { assertVanillaDocument } from './model.mjs'
import { DEFINITIONS, GATE_NAMES, LIMITS, TIMER_TICKS, allWires, gateValue, hasWire, keyOf } from './catalog.mjs'

const DIRS = [[0, 1], [0, -1], [1, 0], [-1, 0]]
const ROUTES = [[0, 1, 2, 3], [3, 2, 1, 0], [2, 3, 0, 1]]

/** Reproducible local random stream. The distribution, not Terraria's global RNG stream, is reproduced. */
export class SeededRandom {
  constructor(seed = 1) { this.state = seed | 0 }
  next(max) {
    if (!max) return 0
    let t = this.state = (this.state + 0x6D2B79F5) | 0
    t = Math.imul(t ^ t >>> 15, t | 1)
    t ^= t + Math.imul(t ^ t >>> 7, t | 61)
    return Math.floor(((t ^ t >>> 14) >>> 0) / 4294967296 * max)
  }
}

/**
 * Event-driven circuit subset of Wiring.cs at 8255d346 (1.4.5.8).
 * This is not a physics/NPC/world simulator. A TripWire completes in one game tick.
 * Traversal direction/order, colour passes, gate waves and pixel passes are deliberate.
 */
export class CircuitEngine {
  constructor(document, { random, operationLimit = LIMITS.operations, collectTrace = true, traversalFactory = null } = {}) {
    assertVanillaDocument(document)
    this.document = document
    this.document.circuitContext = readCircuitContext(document.circuitContext)
    this.random = random || new SeededRandom(document.randomState ?? document.seed)
    this.operationLimit = operationLimit
    this.collectTrace = collectTrace
    this.traceLimit = LIMITS.trace
    this.traversalFactory = traversalFactory
    this.traversals = new Map()
    this.lastPatch = { tiles: [], structureChanged: false }
    this.tick = document.tick || 0
    this.mechanics = []
    this.states = new Map()
    this.trace = []
    this.events = []
    this.operations = 0
    this.traceTruncated = false
    this.active = false
    this.transaction = null
    this.rebuild()
  }
  rebuild() {
    for (const traversal of this.traversals.values()) traversal?.close()
    this.traversals.clear()
    settleSupports(this.document.world)
    syncSharedRemaining(this)
    this.mechanics = []
    this.states = new Map()
    this.cooling = new Set()
    this.scheduled = []
    this.feedbackTiles = new Set()
    this.globalCooldownTiles = new Set()
    this.hasNativeTileAnimation = false
    this.oneShotTiles = new Set()
    this.nextOrder = 0
    this.supportRevision = this.document.world.revision
    this.visualRevision = (this.visualRevision || 0) + 1
    const saved = readMechanicalState(this.document.mechanicalState, this.document.world) || migrateMechanicalState(this.document.world)
    this.globalCooldowns = saved.globals
    this.nextOrder = saved.nextOrder
    this.scheduled = saved.records.map(r => ({ ...r, world: this.document.world, tile: this.document.world.tileAt(r.x, r.y) }))
    this.refreshMechanicalViews()
    // Runtime fields in copied/moved tiles are projections, not new registrations.
    for (const tile of this.document.world.tiles.values()) {
      if (isOneShot(tile)) this.oneShotTiles.add(tile)
      const r = this.mechanicalByPosition.get(keyOf(tile.x, tile.y))
      if (tile.kind === 'teleporter') this.hasNativeTileAnimation = true
      if (tile.pulseTicks > 0 || tile.lidTicks > 0) this.feedbackTiles.add(tile)
      if (tile.globalCooldown > 0) this.globalCooldownTiles.add(tile)
      if (tile.kind === 'timer' || tile.cooldown !== undefined) tile.mechanicalOrder = r?.order ?? 0
      // Native CheckMech can outlive a removed object; a replacement can have a
      // different cooldown maximum, so the authoritative duration stays in r.
      if (tile.cooldown !== undefined) tile.cooldown = r ? Math.min(tile.cooldown || 0, r.remaining) : 0
      if (tile.kind === 'timer' && r) tile.remaining = r.remaining
    }
    this.persistMechanics()
  }
  refreshMechanicalViews() {
    this.mechanics = this.scheduled.filter(r => r.world.tileAt(r.x, r.y)?.kind === 'timer')
    this.cooling = new Set(this.scheduled.filter(r => r.world.tileAt(r.x, r.y)?.kind !== 'timer').map(r => r.tile || r))
    this.mechanicalByPosition = new Map(this.scheduled.map(r => [keyOf(r.x, r.y), r]))
  }
  persistMechanics() {
    this.document.mechanicalState = { version: 1, globals: { ...this.globalCooldowns }, nextOrder: this.nextOrder,
      records: this.scheduled.map(({ x, y, remaining, order }) => ({ x, y, remaining, order })) }
  }

  walk(fn, world = this.document.world) {
    fn(world)
  }
  state(world) {
    if (!this.states.has(world)) this.states.set(world, { lamps: [], next: [], current: [], done: new Set(), pixels: new Map() })
    return this.states.get(world)
  }
  budget(count = 1) {
    this.operations += count
    if (this.operations > this.operationLimit) throw new RangeError('信号传播超过安全上限；可能存在接线盒闭环。此次操作已回滚。')
  }
  close() { for (const traversal of this.traversals.values()) traversal?.close(); this.traversals.clear() }
  log(world, x, y, type, detail = '') {
    if (this.events.length < 500) this.events.push({ world, x, y, type, detail, tick: this.tick })
  }
  mutate(tile, property, value) {
    if (this.transaction && !this.transaction.tiles.has(tile)) this.transaction.tiles.set(tile, { ...tile })
    tile[property] = value
    if (property === 'pulseTicks' || property === 'lidTicks') {
      if (tile.pulseTicks > 0 || tile.lidTicks > 0) this.feedbackTiles?.add(tile)
      else this.feedbackTiles?.delete(tile)
    }
    if (property === 'globalCooldown') {
      if (value > 0) this.globalCooldownTiles?.add(tile)
      else this.globalCooldownTiles?.delete(tile)
    }
    if (['on', 'effectMode', 'gemInserted', 'cellActuators', 'faulty', 'orientation', 'portalMode', 'frontTrack', 'backTrack', 'spent', 'cellInactive', 'inactive', 'lidTicks', 'pulseTicks'].includes(property)) this.visualDirty = true
  }
  /** Shape-changing native objects retain identity and never overwrite adjacent components. */
  reshape(world, tile, next) {
    if (!fitsDevice(world, tile, next)) throw new RangeError('门的目标占格被占用或越界')
    if (this.transaction && !this.transaction.worlds.has(world)) this.transaction.worlds.set(world, { tiles: new Map(world.tiles), occupancy: new Map(world.occupancy), revision: world.revision })
    world.tiles.delete(keyOf(tile.x, tile.y))
    for (const p of deviceCells(tile)) world.occupancy.delete(keyOf(p.x, p.y))
    for (const property of ['x', 'y', 'width', 'height', 'on', 'orientation']) this.mutate(tile, property, next[property])
    if (next.nativeCells) {
      this.mutate(tile, 'nativeCells', next.nativeCells)
      this.mutate(tile, 'nativeState', next.nativeState)
    }
    world.tiles.set(keyOf(tile.x, tile.y), tile)
    for (const p of deviceCells(tile)) world.occupancy.set(keyOf(p.x, p.y), tile)
    world.revision++
  }
  /** Atomic activation: watchdog failures never leave half-toggled circuits. */
  atomic(fn) {
    if (this.active) return fn()
    this.active = true
    this.operations = 0
    this.trace = []; this.events = []; this.traceTruncated = false
    const before = { worlds: new Map(), tiles: new Map(), mechanics: this.mechanics.map(m => ({ ...m })), tick: this.tick, randomState: this.random.state, nextOrder: this.nextOrder, cooling: new Set(this.cooling), scheduled: this.scheduled.map(r => ({ ...r })), globalState: { ...this.globalCooldowns }, feedback: new Set(this.feedbackTiles), globals: new Set(this.globalCooldownTiles), supportRevision: this.supportRevision }
    before.oneShots = new Set()
    this.transaction = before
    this.visualDirty = false
    try {
      // Edits can change supports; idle ticks and ordinary wire traversal cannot.
      if (this.supportRevision !== this.document.world.revision) {
        settleSupports(this.document.world, (t,k,v)=>this.mutate(t,k,v), ()=>this.budget())
        this.supportRevision = this.document.world.revision
      }
      const result = fn()
      this.lastPatch = { tiles: [...before.tiles.keys()].filter(tile => tile.kind && this.document.world.tileAt(tile.x, tile.y) === tile), structureChanged: before.worlds.size > 0 }
      return result
    }
    catch (error) {
      this.lastPatch = { tiles: [], structureChanged: false }
      for (const traversal of this.traversals.values()) traversal?.cancel()
      for (const [tile, old] of before.tiles) Object.assign(tile, old)
      for (const [world, old] of before.worlds) { world.tiles = old.tiles; world.occupancy = old.occupancy; world.revision = old.revision }
      // Restore records as well as tiles: live timer records mutate their remaining field.
      this.scheduled = before.scheduled
      this.globalCooldowns = before.globalState
      this.refreshMechanicalViews()
      this.feedbackTiles = before.feedback; this.globalCooldownTiles = before.globals
      this.supportRevision = before.supportRevision
      this.tick = before.tick
      this.random.state = before.randomState
      this.nextOrder = before.nextOrder
      this.trace = []; this.events = []
      for (const s of this.states.values()) { s.lamps = []; s.next = []; s.current = []; s.done.clear(); s.pixels.clear() }
      throw error
    } finally {
      if (Number.isInteger(this.random.state)) this.document.randomState = this.random.state
      this.document.tick = this.tick
      this.persistMechanics()
      if (this.visualDirty) this.visualRevision++
      this.active = false; this.transaction = null
    }
  }
  checkMech(world, tile, remaining = 18000, restoring = false) {
    return this.registerMechanical(world, tile, remaining || 18000, true)
  }
  registerMechanical(world, tile, ticks, timer = false) {
    if (!Number.isInteger(ticks) || ticks <= 0 || ticks > 18000) throw new RangeError('机械冷却必须为正整数 tick')
    if (this.mechanicalByPosition.has(keyOf(tile.x, tile.y))) return false
    if (this.scheduled.length >= 999 || this.mechanics.length + this.cooling.size >= 999) {
      this.log(world, tile.x, tile.y, 'limit', '机械冷却队列已满'); return false
    }
    if (this.nextOrder >= Number.MAX_SAFE_INTEGER - 1) throw new RangeError('机械调度顺序达到安全上限')
    this.mutate(tile, 'mechanicalOrder', ++this.nextOrder)
    this.mutate(tile, timer ? 'remaining' : 'cooldown', ticks)
    const record = { world, tile, x: tile.x, y: tile.y, remaining: ticks, order: tile.mechanicalOrder }
    this.scheduled.push(record); this.mechanicalByPosition.set(keyOf(tile.x, tile.y), record)
    if (timer) this.mechanics.push(record); else this.cooling.add(tile)
    if (!this.active) this.persistMechanics()
    return true
  }
  toggleTimer(world, tile) {
    this.mutate(tile, 'on', !tile.on)
    if (tile.on) this.checkMech(world, tile)
    this.log(world, tile.x, tile.y, 'timer', tile.on ? '启动' : '停止')
  }
  interact(world, x, y) {
    return this.atomic(() => {
      const t = world.tileAt(x, y)
      if (!t) return this.trip(world, [{ x, y }])
      if (triggerStorageInput(this, world, t)) return
      if (triggerRemainingInput(this, world, t)) return
      if (interactPulseDevice(this, world, t)) return
      if (interactMechanism(this, world, t)) return
      if (t.kind === 'timer') return this.toggleTimer(world, t)
      if (t.kind === 'switch' || t.kind === 'lever') {
        this.mutate(t, 'on', !t.on)
        return this.trip(world, footprint(t))
      }
      // The trigger tool can stimulate wires at any tile; it skips that origin tile,
      // just like TripWire. Lamp state editing is a separate editor operation.
      return this.trip(world, [{ x, y }])
    })
  }
  emitInput(world, x, y) {
    return this.atomic(() => {
      const tile = world.tileAt(x, y)
      if (triggerStorageInput(this, world, tile)) return
      if (triggerRemainingInput(this, world, tile)) return
      return tile?.kind === 'detonator' ? triggerDetonator(this, world, tile) : triggerMechanismInput(this, world, tile)
    })
  }
  advanceBoundary(boundary) { return this.atomic(() => advanceCircuitBoundary(this, boundary)) }
  trigger(world, points, mask = allWires(this.document.palette.length)) {
    return this.atomic(() => this.trip(world, points, mask))
  }
  /** Native Wiring.CheckMech: one position, one non-restarting timer, one shared capacity. */
  registerCooldown(world, tile, ticks) {
    return this.registerMechanical(world, tile, ticks)
  }
  stepFeedback() {
    // Display-only clocks run separately from CheckMech; no full-world per-family scans.
    for (const tile of this.feedbackTiles) {
      this.budget()
      if (tile.pulseTicks > 0) {
        this.mutate(tile, 'pulseTicks', tile.pulseTicks - 1)
        if (!tile.pulseTicks && tile.kind === 'announcementBox') this.mutate(tile, 'announcementText', '')
        if (!tile.pulseTicks && isMechanism(tile) && DEFINITIONS[tile.kind].role === 'input') this.mutate(tile, 'on', false)
      }
      if (tile.lidTicks > 0) this.mutate(tile, 'lidTicks', tile.lidTicks - 1)
      if (!tile.pulseTicks && !tile.lidTicks) this.feedbackTiles.delete(tile)
    }
  }
  step(count = 1) {
    if (!Number.isSafeInteger(count) || count < 1 || count > 600) throw new RangeError('单次步进范围为 1–600 tick')
    return this.atomic(() => {
      for (let n = 0; n < count; n++) {
        this.tick++
        if (this.hasNativeTileAnimation && this.tick % 21 === 0) this.visualDirty = true
        this.stepFeedback()
        // Wiring's three globals survive deletion, replacement and world reconstruction.
        for (const key of Object.keys(this.globalCooldowns)) if (this.globalCooldowns[key] > 0) {
          this.budget(); this.mutate(this.globalCooldowns, key, this.globalCooldowns[key] - 1)
        }
        // Deprecated per-item values are display/legacy projections only.
        for (const tile of this.globalCooldownTiles) this.mutate(tile, 'globalCooldown', tile.globalCooldown - 1)
        // A registration is bound to its original coordinates, not to an object.
        // Native UpdateMech observes whatever is currently at those coordinates.
        // Match UpdateMech's reverse index loop. New registrations append and
        // start on the next tick; expired entries cannot shift earlier entries.
        // No per-tick array copy or per-expiry search is needed.
        for (let index = this.scheduled.length - 1; index >= 0; index--) {
          const record = this.scheduled[index]
          this.budget()
          const { world, x, y } = record, tile = world.tileAt(x, y)
          record.remaining--
          if (tile?.kind === 'timer') {
            if (!tile.on) record.remaining = 0
            else if (record.remaining % TIMER_TICKS[tile.style] === 0) {
              record.remaining = 18000
              this.log(world, x, y, 'timer-pulse', `定时器第 ${this.tick} tick 输出脉冲`)
              this.trip(world, [{ x, y }])
            }
            this.mutate(tile, 'remaining', Math.max(0, record.remaining))
          } else if (tile?.cooldown > 0) this.mutate(tile, 'cooldown', Math.max(0, tile.cooldown - 1))
          if (record.remaining > 0) continue
          if (tile?.kind === 'timer') this.mutate(tile, 'on', false)
          if (tile?.kind === 'detonator') this.mutate(tile, 'on', !tile.on)
          if (tile && (tile.kind === 'timer' || tile.cooldown !== undefined)) this.mutate(tile, 'mechanicalOrder', 0)
          this.scheduled.splice(index, 1)
          this.mechanicalByPosition.delete(keyOf(x, y))
          this.cooling.delete(record.tile || record)
          const timerIndex = this.mechanics.indexOf(record)
          if (timerIndex >= 0) this.mechanics.splice(timerIndex, 1)
        }
      }
    })
  }
  trip(world, input, mask = allWires(this.document.palette.length)) {
    if (!Number.isInteger(mask) || mask < 1 || mask > 15) throw new RangeError('原版四色电线位掩码无效')
    this.budget()
    const points = [...new Map(input.filter(p => world.contains(p.x, p.y)).map(p => [keyOf(p.x, p.y), p])).values()]
      .sort((a, b) => a.x - b.x || a.y - b.y)
    const state = this.state(world), mechanismPasses = []
    for (let colour = 0; colour < this.document.palette.length; colour++) {
      if (!hasWire(mask, colour)) continue
      const seeds = points.filter(p => hasWire(world.wireAt(p.x, p.y), colour))
      if (seeds.length) mechanismPasses.push(this.hitWire(world, seeds, colour))
    }
    finishMechanismTeleports(this, world, mechanismPasses)
    for (const [tile, axes] of state.pixels) if (axes === 3) {
      this.mutate(tile, 'on', !tile.on)
      this.log(world, tile.x, tile.y, 'pixel', '同一脉冲横纵交汇')
    }
    state.pixels.clear()
    this.gatePass(world)
  }
  hitWire(world, seeds, colour) {
    if (this.traversalFactory) {
      if (!this.traversals.has(world)) this.traversals.set(world, this.traversalFactory(world))
      const native = this.traversals.get(world)
      if (native) return native.run(this, seeds, colour, newMechanismPass())
    }
    return this.hitWireJavaScript(world, seeds, colour)
  }
  hitWireJavaScript(world, seeds, colour) {
    const state = this.state(world), mechanismPass = newMechanismPass()
    const queue = seeds.map(p => ({ ...p, direction: 0 }))
    const skipped = new Set(seeds.map(p => keyOf(p.x, p.y)))
    const toProcess = new Map(seeds.map(p => [keyOf(p.x, p.y), 4]))
    for (let cursor = 0; cursor < queue.length; cursor++) {
      this.budget()
      const p = queue[cursor], k = keyOf(p.x, p.y), t = world.tileAt(p.x, p.y)
      if (this.collectTrace && this.trace.length < LIMITS.trace) this.trace.push({ world, x: p.x, y: p.y, colour, direction: p.direction, tick: this.tick })
      else if (this.collectTrace) this.traceTruncated = true
      if (!skipped.has(k) && t) this.hitTile(world, t, p, colour, skipped, mechanismPass)
      for (let direction = 0; direction < 4; direction++) {
        const [dx, dy] = DIRS[direction], x = p.x + dx, y = p.y + dy
        if (!world.contains(x, y)) continue
        if (t?.kind === 'junction' && ROUTES[t.style][p.direction] !== direction) continue
        if (t?.kind === 'pixel') {
          if (direction !== p.direction) continue
          state.pixels.set(t, (state.pixels.get(t) || 0) | (direction < 2 ? 2 : 1))
        }
        if (!hasWire(world.wireAt(x, y), colour)) continue
        const nextKey = keyOf(x, y)
        if (toProcess.has(nextKey)) {
          const remaining = toProcess.get(nextKey) - 1
          if (remaining === 0) toProcess.delete(nextKey)
          else toProcess.set(nextKey, remaining)
          continue
        }
        queue.push({ x, y, direction })
        const nextTile = world.tileAt(x, y)
        if (!['junction', 'pixel'].includes(nextTile?.kind)) toProcess.set(nextKey, 3)
      }
    }
    return mechanismPass
  }
  hitTile(world, t, point, colour, skipped, mechanismPass) {
    this.budget()
    if (hasActuator(t,point.x,point.y)) supportCellsWillChange(this,world,[point])
    if (actuateCell(this, world, t, point)) supportCellsChanged(this, world, [point])
    if (hitStorage(this, world, t, skipped)) return
    if (hitRemaining(this, world, t, point, skipped)) return
    if (hitPulseDevice(this, world, t, skipped)) return
    if (hitEffect(this, world, t, colour, skipped)) return
    if (hitDevice(this, world, t, point, skipped)) return
    if (hitMechanism(this, world, t, point, skipped, mechanismPass)) return
    if (DEFINITIONS[t.kind]?.family === 'lighting') {
      // Wiring.ToggleLamp / ToggleHangingLantern / Toggle2x2Light skip every cell
      // for this colour pass. A different colour is a separate toggle.
      if (t.width * t.height > 1) for (const p of footprint(t)) skipped.add(keyOf(p.x, p.y))
      this.mutate(t, 'on', !t.on)
      this.log(world, t.x, t.y, 'light', t.on ? '开启照明' : '关闭照明')
      return
    }
    switch (t.kind) {
      case 'timer': this.toggleTimer(world, t); break
      case 'lamp':
        skipped.add(keyOf(t.x, t.y))
        if (!t.faulty) this.mutate(t, 'on', !t.on)
        this.state(world).lamps.push(t)
        break
      case 'gemspark':
        if (!t.actuator) this.mutate(t, 'on', !t.on)
        break
      case 'activeStone':
        if (!t.actuator && (!t.on || canDeactivateCell(world, t, point) && canKillCell(world, t, point))) { supportCellsWillChange(this,world,footprint(t)); this.mutate(t, 'on', !t.on); supportCellsChanged(this, world, footprint(t)) }
        break
      default: break // Switches/levers are sources, not wire-driven loads.
    }
  }
  gatePass(world) {
    const s = this.state(world)
    if (s.current.length) return
    s.done.clear()
    while (s.lamps.length) {
      for (let i = 0; i < s.lamps.length; i++) this.checkGate(world, s.lamps[i])
      s.lamps = []
      while (s.next.length) {
        s.current = s.next; s.next = []
        for (let cursor = 0; cursor < s.current.length; cursor++) {
          const gate = s.current[cursor]
          if (!s.done.has(gate)) {
            s.done.add(gate)
            this.log(world, gate.x, gate.y, 'gate', GATE_NAMES[gate.style])
            this.trip(world, [{ x: gate.x, y: gate.y }])
          }
        }
        s.current = []
      }
    }
    s.done.clear()
  }
  checkGate(world, lamp) {
    this.budget()
    let y = lamp.y, t
    while ((t = world.tileAt(lamp.x, y))?.kind === 'lamp') { this.budget(); y++ }
    if (t?.kind !== 'gate') return
    let total = 0, on = 0, hasFaulty = false
    for (let scan = y - 1; scan >= 0; scan--) {
      this.budget()
      const l = world.tileAt(lamp.x, scan)
      if (l?.kind !== 'lamp') break
      if (l.faulty) { hasFaulty = true; break }
      total++; if (l.on) on++
    }
    const value = gateValue(t.style, total, on)
    const removedFaulty = !hasFaulty && t.faulty
    const faultyTriggered = hasFaulty && lamp.faulty
    // The displayed faulty gate corresponds to frameX=36, not frameX=18.
    const oldOn = t.on && !t.faulty
    if (value === oldOn && !removedFaulty && !faultyTriggered) return
    this.mutate(t, 'on', hasFaulty ? false : value)
    this.mutate(t, 'faulty', hasFaulty)
    let emit = !hasFaulty || faultyTriggered
    if (faultyTriggered) emit = this.random.next(total) < on
    if (removedFaulty) emit = false
    if (emit) {
      const s = this.state(world)
      if (!s.done.has(t)) s.next.push(t)
      else this.log(world, t.x, t.y, 'smoke', '逻辑门在同一连锁中已触发，阻止回触发')
    }
  }
}
export function footprint(t) {
  const points = []
  for (let x = t.x; x < t.x + t.width; x++) for (let y = t.y; y < t.y + t.height; y++) points.push({ x, y })
  return points
}
