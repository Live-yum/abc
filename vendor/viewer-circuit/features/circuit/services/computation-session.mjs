import { CircuitEngine } from '../domain/engine.mjs'
import { LIMITS } from '../domain/catalog.mjs'
import { parseDocument, serializeDocument, tileJSON } from '../domain/model.mjs'
import { createNativeTraversal, supportsNativeTraversal } from '../runtime/native-traversal.mjs'
import { circuitWorldBytes } from './memory.mjs'

const MAX_SESSIONS = 4
const MAX_INPUT_POINTS = 8192
const failure = (code, message) => Object.assign(new Error(message), { code })
const commandError = message => failure('COMPUTATION_COMMAND', message)
const plain = value => value !== null && typeof value === 'object' && !Array.isArray(value)
const identity = id => {
  if (!Number.isSafeInteger(id) || id <= 0) throw commandError('电路会话编号无效')
  return id
}
const arity = (args, min, max = min) => {
  if (!Array.isArray(args) || args.length < min || args.length > max) throw commandError('电路命令参数数量无效')
}

function validateExecution(command, world) {
  if (!plain(command) || Object.keys(command).some(key => !['method', 'args', 'debug'].includes(key))) throw commandError('电路执行命令无效')
  const { method, args } = command
  if (command.debug !== undefined && typeof command.debug !== 'boolean') throw commandError('电路调试选项必须为布尔值')
  const position = (x, y) => {
    if (!world.contains(x, y)) throw commandError('电路输入坐标越界或不是整数')
  }
  switch (method) {
    case 'interact':
    case 'emitInput':
      arity(args, 2)
      position(args[0], args[1])
      break
    case 'trigger':
      arity(args, 1, 2)
      if (!Array.isArray(args[0]) || args[0].length < 1 || args[0].length > MAX_INPUT_POINTS) throw commandError(`单次电路输入必须为 1–${MAX_INPUT_POINTS} 个占格`)
      for (const point of args[0]) {
        if (!plain(point) || Object.keys(point).some(key => !['x', 'y'].includes(key))) throw commandError('电路输入点必须只包含 x 和 y')
        position(point.x, point.y)
      }
      if (args.length === 2 && (!Number.isInteger(args[1]) || args[1] < 1 || args[1] > 15)) throw commandError('电路输入只接受原版四色电线')
      break
    case 'step':
      arity(args, 1)
      if (!Number.isInteger(args[0]) || args[0] < 1 || args[0] > 60) throw commandError('单次电路步进范围为 1–60 tick')
      break
    case 'advanceBoundary':
      arity(args, 1)
      if (args[0] !== 'dawn' && args[0] !== 'dusk') throw commandError('电路边界只接受 dawn 或 dusk')
      break
    default:
      throw commandError(`不支持的电路执行方法：${String(method)}`)
  }
  return { method, args, debug: command.debug === true }
}

function diagnostics(session) {
  const result = { available: session.nativeAvailable, backend: session.nativeAvailable ? 'wasm' : 'javascript',
    passes: 0, visits: 0, calls: 0, rebuilds: 0, cells: 0, peakBytes: 0, fallback: false }
  for (const traversal of session.engine.traversals.values()) {
    if (!traversal) { result.fallback = true; continue }
    const values = traversal.diagnostics || {}
    for (const key of ['passes', 'visits', 'calls', 'rebuilds', 'cells']) result[key] += values[key] || 0
    result.peakBytes += values.peakBytes || 0
  }
  if (result.fallback) result.backend = 'javascript'
  return result
}

function packetFor(id, session, before) {
  const engine = session.engine, document = engine.document, patch = engine.lastPatch
  const native = diagnostics(session)
  native.commandPasses = native.passes - before.passes
  native.commandVisits = native.visits - before.visits
  const clean = rows => rows.map(({ world, ...row }) => row)
  return JSON.stringify({ version: 1, id,
    tiles: (patch?.tiles || []).map(tileJSON), structureChanged: patch?.structureChanged === true,
    tick: document.tick, randomState: document.randomState,
    circuitContext: document.circuitContext, mechanicalState: document.mechanicalState,
    visualRevision: engine.visualRevision, operations: engine.operations,
    trace: clean(engine.trace), events: clean(engine.events), traceTruncated: engine.traceTruncated,
    native,
    ...(patch?.structureChanged ? { document: serializeDocument(document) } : {}),
  })
}

/**
 * Retained circuit state inside the shared computation owner. This module never
 * creates a Worker or another Wasm runtime. The owner serializes commands and
 * yields between complete atomic executions.
 */
export function createCircuitComputation(tx, { admitBytes = () => {} } = {}) {
  const sessions = new Map()
  let nextId = 0, disposed = false
  function invoke(method, args = []) {
    if (disposed) throw failure('COMPUTATION_OWNER_LOST', '电路计算服务已关闭')
    switch (method) {
      case 'open': {
        arity(args, 1)
        if (typeof args[0] !== 'string' || args[0].length > LIMITS.bytes) throw commandError('电路会话需要容量限制内的序列化文档')
        if (sessions.size >= MAX_SESSIONS) throw failure('COMPUTATION_CONTROL_BUDGET', '同时最多保留 4 个电路会话；请先关闭旧会话')
        if (nextId >= Number.MAX_SAFE_INTEGER) throw failure('COMPUTATION_CONTROL_BUDGET', '电路会话编号已用尽')
        // Parse every boundary before constructing a native owner. A malformed or
        // rejected fifth open therefore cannot leak a Wasm allocation.
        // Reserve parsing/Map expansion before constructing the large graph,
        // then check its actual occupancy before creating any native owner.
        admitBytes(32768 + args[0].length * 32)
        const document = parseDocument(args[0]), nativeAvailable = supportsNativeTraversal(tx)
        admitBytes(circuitWorldBytes(document.world) + args[0].length * 2)
        let engine
        try {
          engine = new CircuitEngine(document, { collectTrace: false, traversalFactory: world => createNativeTraversal(tx, world) })
          const id = ++nextId
          sessions.set(id, { engine, nativeAvailable, sourceBytes: args[0].length * 2 })
          return { id, backend: nativeAvailable ? 'wasm' : 'javascript' }
        } catch (error) {
          engine?.close()
          throw error
        }
      }
      case 'execute': {
        arity(args, 2)
        const id = identity(args[0]), session = sessions.get(id)
        if (!session) throw failure('STALE_OPERATION', '电路会话已关闭或失效')
        const engine = session.engine, world = engine.document.world
        const command = validateExecution(args[1], world), before = diagnostics(session)
        // Atomic rollback snapshots, gate queues and the JSON delta/replacement
        // coexist with the retained world until a complete reply is acknowledged.
        admitBytes(world.wires.size * 64 + world.tiles.size * 640 + session.sourceBytes * 2
          + (command.debug ? LIMITS.trace * 96 : 0) + 500 * 160 + 131136)
        engine.collectTrace = command.debug
        // Explicit dispatch prevents calling close/constructor/rebuild or a
        // caller-supplied property. step(count) is one rollback boundary.
        switch (command.method) {
          case 'interact': engine.interact(world, ...command.args); break
          case 'trigger': engine.trigger(world, ...command.args); break
          case 'step': engine.step(command.args[0]); break
          case 'emitInput': engine.emitInput(world, ...command.args); break
          case 'advanceBoundary': engine.advanceBoundary(command.args[0]); break
        }
        return { packet: packetFor(id, session, before) }
      }
      case 'close': {
        arity(args, 1)
        const id = identity(args[0]), session = sessions.get(id)
        if (session) { sessions.delete(id); session.engine.close() }
        return null
      }
      default:
        throw commandError(`不支持的电路会话方法：${String(method)}`)
    }
  }
  function memoryBytes() {
    let bytes = 0
    for (const { engine, sourceBytes } of sessions.values()) {
      const world = engine.document.world
      // Conservative JS object/Map/string estimate; native allocations and
      // shared HEAP growth are already tracked by tx and must not be counted twice.
      bytes += circuitWorldBytes(world) + sourceBytes
      bytes += engine.trace.length * 96 + engine.events.length * 160 + engine.scheduled.length * 192
      bytes += (engine.lastPatch?.tiles.length || 0) * 8
      for (const traversal of engine.traversals.values()) if (traversal) bytes += world.wires.size * 32 + 1024
      for (const state of engine.states.values()) bytes += (state.lamps.length + state.next.length + state.current.length) * 8 + state.done.size * 32 + state.pixels.size * 48
    }
    return bytes
  }
  function dispose() {
    if (disposed) return
    disposed = true
    let firstError
    for (const session of sessions.values()) {
      try { session.engine.close() } catch (error) { firstError ||= error }
    }
    sessions.clear()
    if (firstError) throw firstError
  }
  return { invoke, dispose, memoryBytes }
}
