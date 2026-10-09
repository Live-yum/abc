import { hasOwn, fromEntries } from './compat.mjs'
import { REMAINING_TYPES, TRACK_FRAMES } from './remaining-catalog.mjs'
export const isRemaining = t => !!t && hasOwn(REMAINING_TYPES, t.kind)
export const REMAINING_FEEDBACK_TICKS = 45
export const isIndirect = t => isRemaining(t) && REMAINING_TYPES[t.kind].role === 'indirect'
export const isRemainingInput = t => t && (['gemLock', 'golfHole'].includes(t.kind) || t.kind === 'track' && t.style === 1)
const int = (v, min, max, label) => { if (!Number.isSafeInteger(v) || v < min || v > max) throw new RangeError(`${label}超出范围`); return v }
export function readCircuitContext(raw = {}) {
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) throw new TypeError('机关共享状态无效')
  const out = { manualParty: false, sundialCooldownDays: 0, moondialCooldownDays: 0, sundialActive: false, moondialActive: false }
  for (const key of Object.keys(raw)) if (!hasOwn(out, key)) throw new TypeError('不支持此世界／人物状态字段')
  for (const key of ['manualParty', 'sundialActive', 'moondialActive']) {
    if (raw[key] !== undefined && typeof raw[key] !== 'boolean') throw new TypeError('机关状态必须是布尔值')
    out[key] = raw[key] ?? false
  }
  for (const key of ['sundialCooldownDays', 'moondialCooldownDays']) out[key] = int(raw[key] ?? 0, 0, 8, '日晷／月晷共享剩余日数')
  return out
}
export function readRemainingState(spec, t) {
  if (!isRemaining(t)) return
  const d = REMAINING_TYPES[t.kind]
  if (!d.styles.includes(t.style)) throw new TypeError('没有此原版物品／材质样式')
  if (t.color !== '#ffffff' || spec.faulty) throw new TypeError('机关不能使用任意材质颜色或故障灯标志')
  if (['actor', 'contact', 'occupants', 'liquid', 'projectiles', 'damage', 'inventory', 'chest', 'blastRadius'].some(k => spec[k] !== undefined)) throw new TypeError('此工具只接受物品状态，不模拟人物、容器或世界物理')
  t.pulses = int(spec.pulses ?? 0, 0, Number.MAX_SAFE_INTEGER - 1, '累计触发数')
  t.cooldown = int(spec.cooldown ?? 0, 0, d.cooldown, '自身冷却')
  t.pulseTicks = int(spec.pulseTicks ?? 0, 0, REMAINING_FEEDBACK_TICKS, '反馈时间')
  for (const key of ['spent', 'supportArmed']) {
    if (spec[key] !== undefined && typeof spec[key] !== 'boolean') throw new TypeError('支撑／消耗状态必须是布尔值')
    t[key] = spec[key] ?? false
    if (t[key] && !isIndirect(t)) throw new TypeError('此机关不是间接释放物品')
  }
  if (t.kind === 'track') {
    t.frontTrack = int(spec.frontTrack ?? [1, 21, 30][t.style], 0, 35, '前轨帧')
    t.backTrack = int(spec.backTrack ?? -1, -1, 35, '后轨帧')
    if (TRACK_FRAMES[t.frontTrack].type !== t.style || t.backTrack >= 0 && (t.style !== 0 || TRACK_FRAMES[t.backTrack].type !== 0 || t.backTrack === t.frontTrack)) throw new TypeError('前后轨帧与轨道类型不符')
    if (t.backTrack >= 0) {
      const f = TRACK_FRAMES[t.frontTrack], b = TRACK_FRAMES[t.backTrack]
      if (!((f.left >= 0 && f.left === b.left) || (f.right >= 0 && f.right === b.right))) throw new TypeError('岔道两轨至少共享一个连接端')
    }
  } else if (spec.frontTrack !== undefined || spec.backTrack !== undefined) throw new TypeError('非轨道不接受轨道帧')
  if (t.on && !(t.kind==='gemLock' || ['toggle','time-control','party'].includes(d.role))) throw new TypeError('此物品没有持续开关状态')
}
export function remainingJSON(t) {
  const out = fromEntries(['pulses','cooldown','pulseTicks','spent','supportArmed'].map(k => [k,t[k]]))
  if (t.kind === 'track') Object.assign(out, { frontTrack: t.frontTrack, backTrack: t.backTrack })
  return out
}
export function remainingStatus(t) {
  if (isIndirect(t)) return t.spent ? '已释放' : t.supportArmed ? '支撑已连接' : '等待支撑'
  if (t.kind === 'track') return `前轨 ${t.frontTrack ?? [1,21,30][t.style || 0]} / 后轨 ${t.backTrack ?? -1}`
  if (t.kind === 'conveyor') return t.on ? '逆时针' : '顺时针'
  if (t.kind === 'gemLock') return t.on ? '已嵌入' : '未嵌入'
  if (t.cooldown) return `冷却 ${t.cooldown} tick`
  return t.on ? '开启' : '就绪'
}
export function remainingFeedback(engine, world, t, detail) {
  if (t.pulses >= Number.MAX_SAFE_INTEGER - 1) throw new RangeError('累计触发数达到上限')
  engine.mutate(t, 'pulses', t.pulses + 1); engine.mutate(t, 'pulseTicks', REMAINING_FEEDBACK_TICKS)
  engine.log(world, t.x, t.y, 'remaining', detail)
}
const cells = t => Array.from({ length: t.width * t.height }, (_, i) => ({ x:t.x+i%t.width, y:t.y+Math.floor(i/t.width) }))
function register(engine, world, t) {
  return engine.registerCooldown(world, t, REMAINING_TYPES[t.kind].cooldown)
}
export function triggerRemainingInput(engine, world, t) {
  if (!isRemainingInput(t)) return false
  if (t.kind === 'gemLock') engine.mutate(t,'on',!t.on)
  remainingFeedback(engine,world,t,'手动测试脉冲；不模拟人物、球或背包')
  engine.trip(world,cells(t));return true
}
export function syncSharedRemaining(engine) {
  const c = engine.document.circuitContext
  for (const t of engine.document.world.tiles.values()) {
    if (t.kind === 'partyCenter') engine.mutate(t,'on',c.manualParty)
    if (t.kind === 'sundial' || t.kind === 'moondial') engine.mutate(t,'on',c[t.kind+'Active'])
  }
}
/** Explicit test boundary, not elapsed ticks pretending to be a Terraria day. */
export function advanceCircuitBoundary(engine, boundary) {
  if (!['dawn','dusk'].includes(boundary)) throw new TypeError('只接受黎明／黄昏测试边界')
  const c=engine.document.circuitContext,kind=boundary==='dawn'?'sundial':'moondial'
  engine.mutate(c,kind+'Active',false)
  engine.mutate(c,kind+'CooldownDays',Math.max(0,c[kind+'CooldownDays']-1))
  if (boundary==='dusk') engine.mutate(c,'manualParty',false)
  syncSharedRemaining(engine)
}
export function hitRemaining(engine, world, t, point, skipped) {
  if (!isRemaining(t)) return false
  const d=REMAINING_TYPES[t.kind]
  if (d.role==='material' || d.role==='indirect' || isRemainingInput(t) && t.kind!=='track') return true
  // PartyCenter has no SkipWire in native Wiring.cs; each reached cell toggles the shared flag.
  if (t.kind!=='partyCenter') for (const p of cells(t)) skipped.add(`${p.x},${p.y}`)
  if (d.cooldown && !register(engine,world,t)) return true
  if (t.kind==='track') {
    if (t.style===0 && t.backTrack>=0) {
      const front=t.frontTrack;engine.mutate(t,'frontTrack',t.backTrack);engine.mutate(t,'backTrack',front)
    } else if (t.style===2) {
      engine.mutate(t,'frontTrack',({30:31,31:30,32:34,34:32,33:35,35:33})[t.frontTrack])
    } else return true
  } else if (t.kind==='conveyor') {
    if (t.actuator) return true // Native dedicated actuation path must not also reverse the belt.
    engine.mutate(t,'on',!t.on)
  } else if (d.role==='time-control') {
    const c=engine.document.circuitContext
    if (c[t.kind+'Active'] || c[t.kind+'CooldownDays']) return true
    engine.mutate(c,t.kind+'CooldownDays',8);engine.mutate(c,t.kind+'Active',true);syncSharedRemaining(engine)
  } else if (d.role==='party') {
    const c=engine.document.circuitContext;engine.mutate(c,'manualParty',!c.manualParty);syncSharedRemaining(engine)
  } else if (d.role==='toggle') engine.mutate(t,'on',!t.on)
  remainingFeedback(engine,world,t,d.role==='request'?'有效提炼请求；未执行容器／掉落物逻辑':'原版自身状态切换')
  return true
}
/** Native rail state mirrors retain connection geometry. Rails cannot be turned vertical. */
export function transformRemaining(t, operation) {
  if (!isRemaining(t)) return
  if (t.kind==='material' || t.kind==='grate') return
  if(t.kind==='conveyor') { if(operation==='rotate')throw new Error('传送带无竖直原版方向'); if(operation==='flipX')t.on=!t.on; return }
  if(t.kind==='track') {
    if(operation==='rotate')throw new Error('轨道不能旋转为竖直轨道')
    for(const key of ['frontTrack','backTrack'])if(t[key]>=0){
      const f=TRACK_FRAMES[t[key]],flip=v=>v<0?v:2-v
      const left=operation==='flipX'?f.right:flip(f.left),right=operation==='flipX'?f.left:flip(f.right)
      const candidates=TRACK_FRAMES.filter(x=>x.type===f.type&&x.left===left&&x.right===right&&(f.type!==2||x.boostLeft===(operation==='flipX'?!f.boostLeft:f.boostLeft)))
      // Match the same cap style by symmetry, instead of choosing arbitrary equivalent endpoints.
      const mirrorX=[0,1,3,2,5,4,7,6,9,8,11,10,13,12,15,14,17,16,19,18,20,21,23,22,25,24,27,26,29,28,31,30,33,32,35,34]
      const mirrorY=[0,1,2,3,7,6,5,4,9,8,12,13,10,11,14,15,18,19,16,17,20,21,22,23,24,25,28,29,26,27,30,31,35,34,33,32]
      const preferred=(operation==='flipX'?mirrorX:mirrorY)[f.id]
      const match=candidates.find(x=>x.id===preferred)
      if(!match)throw new Error('轨道没有此镜像原版帧')
      t[key]=match.id
    }
    return
  }
  if(operation!=='flipX')throw new Error('此机关没有倒置／旋转安装样式')
  if(t.kind==='bastStatue')t.orientation=1-(t.orientation??0)
}
