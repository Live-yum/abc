import { isIndirect, REMAINING_FEEDBACK_TICKS } from './remaining-state.mjs'
import { solidAt, boulderHeldAbove, isInactive, hasActuator } from './actuation.mjs'
import { gameTileId } from './catalog.mjs'
const holders = new Set([21,467,441,468,88,470,475])

/** Four neighbouring cells at most; never retains inventories or a board copy. */
export function captureOneShotSupports(world, t, mutate = (o,k,v) => { o[k] = v }) {
  // A ready cycle keeps its original feet, including initially inactive ones.
  // A later pulse changing only the other foot must not replace that baseline.
  if (!isIndirect(t) || t.spent || t.oneShotRecovery || !supportPresent(world,t)) return
  const supports = []
  for (const dy of [t.height, -1]) for (let dx=0; dx<t.width; dx++) {
    const x=t.x+dx, y=t.y+dy, s=world.tileAt(x,y)
    if (!s || s.spent || dy === -1 && (t.kind === 'tntBarrel' || !holders.has(gameTileId(s)))) continue
    const row = { dx,dy,rx:s.x-t.x,ry:s.y-t.y,kind:s.kind,style:s.style,width:s.width,height:s.height,
      on:s.on,inactive:isInactive(s,x,y),actuator:hasActuator(s,x,y),color:s.color }
    if (s.width === 1 && s.height === 1 && s.nativeCells) { row.nativeCells=[...s.nativeCells]; row.nativeState=s.nativeState }
    supports.push(row)
  }
  const next = { version:1, supports }
  if (JSON.stringify(next) !== JSON.stringify(t.oneShotRecovery)) mutate(t,'oneShotRecovery',next)
}
export function supportPresent(world,t) {
  if (boulderHeldAbove(world,t)) return true
  const tests=Array.from({length:t.width},(_,x)=>solidAt(world,t.x+x,t.y+t.height,t.kind==='tntBarrel'))
  // WorldGen.Check2x2: boulders need at least one solid bottom cell; TNT needs both.
  return t.kind==='tntBarrel'?tests.every(Boolean):tests.some(Boolean)
}
function evaluate(world,t,mutate,budget) {
  budget()
  if(t.spent)return false
  if(supportPresent(world,t)){if(!t.supportArmed)mutate(t,'supportArmed',true);return false}
  if(!t.supportArmed)return false // Unconnected drawing remains editable; it is not an invisible world simulation.
  if(t.pulses>=Number.MAX_SAFE_INTEGER-1)throw new RangeError('释放计数达到安全上限')
  mutate(t,'spent',true);mutate(t,'pulses',t.pulses+1);mutate(t,'pulseTicks',REMAINING_FEEDBACK_TICKS)
  return true
}
/** Called within the simulation/editor transaction: a failure rolls back the whole release chain. */
export function settleSupports(world,mutate=(t,k,v)=>{t[k]=v},budget=()=>{}) {
  for (const t of world.tiles.values()) if (isIndirect(t)) captureOneShotSupports(world,t,mutate)
  let changed=true
  while(changed){changed=false;for(const t of world.tiles.values())if(isIndirect(t))changed=evaluate(world,t,mutate,budget)||changed}
}
/** Capture before a wire changes either foot, once across all colour passes. */
export function supportCellsWillChange(engine,world,points) {
  const queue=[...points],done=engine.transaction?.oneShots || new Set()
  for(let i=0;i<queue.length;i++) {
    engine.budget()
    const p=queue[i],t=world.tileAt(p.x,p.y-1)
    if(!isIndirect(t)||t.y+t.height!==p.y||done.has(t))continue
    done.add(t);captureOneShotSupports(world,t,(o,k,v)=>engine.mutate(o,k,v))
    for(let x=t.x;x<t.x+t.width;x++)queue.push({x,y:t.y})
  }
}
export function supportCellsChanged(engine,world,points) {
  const queue=[...points],done=new Set()
  for(let i=0;i<queue.length;i++){
    engine.budget()
    const p=queue[i],t=world.tileAt(p.x,p.y-1)
    if(!isIndirect(t)||t.y+t.height!==p.y||done.has(t))continue
    // Revisit after a later wire/colour pass; dedupe only this support-change chain.
    done.add(t)
    if(evaluate(world,t,(o,k,v)=>engine.mutate(o,k,v),()=>engine.budget())){
      engine.log(world,t.x,t.y,'release','支撑解除：仅物品高亮／已释放，无滚动、伤害或实体')
      for(let x=t.x;x<t.x+t.width;x++)queue.push({x,y:t.y})
    }
  }
}
