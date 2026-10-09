import { makeTile } from './model.mjs'
import { isIndirect } from './remaining-state.mjs'
import { cellIndex, isInactive } from './actuation.mjs'
import { supportPresent } from './support-state.mjs'
import { canRearmOneShot } from './one-shot-state.mjs'
export { canRearmOneShot } from './one-shot-state.mjs'

const simple = new Set(['block','material','activeStone'])
const key = (x,y) => `${x},${y}`

/** Plan against a sparse overlay first. A conflict never partly restores a
 * group, and the bounded snapshots never overwrite later material edits. */
export function planOneShotRearm(world, candidates) {
  const patches=new Map(), additions=new Map(), restored=new Set(), visiting=new Set()
  const view={ tileAt(x,y) { const t=world.tileAt(x,y); return t ? patches.get(t)||t : additions.get(key(x,y))||null } }
  const draft = t => {
    if (!patches.has(t)) patches.set(t,{...t,cellInactive:[...t.cellInactive]})
    return patches.get(t)
  }
  const blocked = t => { throw new Error(`无法恢复 ${t.x}, ${t.y} 的机关：所需支撑已移除或被其他物件替换，请先调整支撑`) }
  function rearm(t) {
    if (!canRearmOneShot(t) || restored.has(t)) return
    if (visiting.has(t)) blocked(t)
    visiting.add(t)
    const next=draft(t)
    next.spent=false;next.pulseTicks=0;next.cooldown=0;next.mechanicalOrder=0
    if(t.kind==='pressurePlate')next.on=false
    if(isIndirect(t)) {
      // Restore the complete original ready cycle, even if a later pulse has
      // reactivated just one foot. Otherwise the next switch swaps the two
      // inactive masks and the mechanism can never release again.
      if(t.oneShotRecovery || !supportPresent(view,next)) {
        const saved=t.oneShotRecovery?.supports
        // Older files lack snapshots. Existing installed actuators/active
        // stone can still be rearmed without guessing a missing material.
        const rows=saved || Array.from({length:t.width},(_,dx)=>{
          const s=world.tileAt(t.x+dx,t.y+t.height)
          return s && {dx,dy:t.height,rx:s.x-t.x,ry:s.y-t.y,kind:s.kind,style:s.style,width:s.width,height:s.height,on:true,inactive:false}
        }).filter(Boolean)
        for(const s of rows) {
          const x=t.x+s.dx,y=t.y+s.dy,old=world.tileAt(x,y)
          if(!old) {
            if(!saved||!simple.has(s.kind)||s.width!==1||s.height!==1||!world.contains(x,y))continue
            if(!additions.has(key(x,y))) additions.set(key(x,y),makeTile({...s,x,y}))
            continue
          }
          if(old.kind!==s.kind||old.style!==s.style||old.x!==t.x+s.rx||old.y!==t.y+s.ry||old.width!==s.width||old.height!==s.height)continue
          if(canRearmOneShot(old))rearm(old)
          const current=patches.get(old)||old
          // A removed actuator is a subsequent edit, not permission to
          // recreate it. A currently valid replacement is already accepted.
          const i=cellIndex(old,x,y)
          if(saved || old.cellActuators.includes(i) || old.kind==='activeStone') {
            const changedInactive=isInactive(current,x,y)!==s.inactive
            if(changedInactive || old.kind==='activeStone'&&current.on!==s.on) {
              const foot=draft(old)
              foot.cellInactive=foot.cellInactive.filter(n=>n!==i)
              if(s.inactive)foot.cellInactive.push(i)
              foot.cellInactive.sort((a,b)=>a-b)
              foot.inactive=foot.cellInactive.length===foot.width*foot.height
              if(old.kind==='activeStone')foot.on=s.on
            }
          }
        }
        if(!supportPresent(view,next))blocked(t)
      }
      next.supportArmed=true
      next.oneShotRecovery=null // Commit captures this new, stable ready cycle.
    }
    visiting.delete(t);restored.add(t)
  }
  for(const t of candidates)rearm(t)
  for(const t of restored)if(isIndirect(t)&&!supportPresent(view,patches.get(t)))blocked(t)
  return { count:restored.size, apply(document) {
    for(const [t,next] of patches)Object.assign(t,next)
    for(const t of additions.values())world.putTile(t,{replace:false})
    if(restored.size && document.mechanicalState) {
      const positions=new Set([...restored].map(t=>key(t.x,t.y)))
      document.mechanicalState={...document.mechanicalState,records:document.mechanicalState.records.filter(r=>!positions.has(key(r.x,r.y)))}
    }
    return restored.size
  } }
}
