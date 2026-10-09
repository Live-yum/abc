// A five-state ring built entirely from Terraria's deterministic one-data-lamp
// faulty gates. Four real transition relays encode the display's colour parity.
export const HELLO_FRAMES = Object.freeze([
  ['10001','10001','11111','10001','10001'],
  ['11111','10000','11110','10000','11111'],
  ['10000','10000','10000','10000','11111'],
  ['10000','10000','10000','10000','11111'],
  ['01110','10001','10001','10001','01110'],
].map(Object.freeze))
export const HELLO_LAYOUT = Object.freeze({
  screen:Object.freeze({x:3,y:3,width:10,height:10,columns:5,rows:5,pitch:2,pixelSize:2}),
  switch:Object.freeze({x:18,y:8}),timer:Object.freeze({x:22,y:8,style:3}),
  periodTicks:30,sequence:Object.freeze(['H','E','L','L','O']),
  states:Object.freeze([2,6,10,14,18].map(x=>Object.freeze({x,y:18}))),
})

export function createHelloExample() {
  const tiles=[],wires=new Map(),screen=HELLO_LAYOUT.screen
  const tile=(kind,x,y,fields={})=>tiles.push({kind,x,y,...fields})
  const wire=(x,y,mask)=>{const k=`${x},${y}`;wires.set(k,(wires.get(k)||0)|mask)}
  const h=(x0,x1,y,mask)=>{for(let x=x0;x<=x1;x++)wire(x,y,mask)}
  const v=(x,y0,y1,mask)=>{for(let y=y0;y<=y1;y++)wire(x,y,mask)}
  // Emit masks 3,5,0,9,15 for H->E->L->L->O->H. Gemspark toggles once
  // per colour, so mask 15 is an unchanged bridge under every 2/4-colour
  // pulse. This connects interior strokes without empty wire lanes.
  const outputs=[1,2,1,4,8],reads=[2,4,4,2,1]
  for(let row=0;row<5;row++)for(let col=0;col<5;col++) {
    let mask=0
    for(const [frame,colour] of [[0,2],[1,4],[3,8]])if(HELLO_FRAMES[frame][row][col]!==HELLO_FRAMES[frame+1][row][col])mask|=colour
    for(let dy=0;dy<screen.pixelSize;dy++)for(let dx=0;dx<screen.pixelSize;dx++) {
      const x=screen.x+col*screen.pitch+dx,y=screen.y+row*screen.pitch+dy
      tile('gemspark',x,y,{style:5,on:HELLO_FRAMES[0][row][col]==='1'})
      wire(x,y,mask||15)
    }
  }
  h(2,13,2,15);h(2,13,13,15);v(2,2,13,15);v(13,2,13,15)
  h(0,2,2,15);v(0,0,2,15);h(0,28,0,15);v(28,0,20,15)
  // All five read pulses finish before gate outputs write the next state.
  // The quiet L->L transition still advances its own isolated red network.
  h(2,22,15,15)
  HELLO_LAYOUT.states.forEach(({x,y},i)=>{
    tile('lamp',x,y-1,{faulty:true});tile('lamp',x,y,{on:i===0})
    tile('gate',x,y+1,{faulty:true});tile('material',x,y+2,{style:54})
    v(x,y-2,y-1,reads[i]);v(x,y,y+1,outputs[i])
    if(i<4)h(x,x+4,y,outputs[i])
    if(i!==2){v(x,y+1,22,outputs[i]);h(0,x,22,outputs[i])}
  })
  h(0,2,18,8);v(0,18,22,8) // O->H also writes the first state.
  // Keep the one-colour state ring separate from the multi-colour display.
  // Only a relay's faulty lamp receives its read; its constant data stays on.
  v(24,3,22,15);h(0,24,22,15)
  for(const [y,read,output] of [[3,1,3],[8,2,5],[13,4,9],[18,8,15]]) {
    h(24,26,y,read)
    tile('lamp',26,y,{faulty:true});tile('lamp',26,y+1,{on:true})
    tile('gate',26,y+2,{faulty:true});tile('material',26,y+3,{style:54})
    h(26,28,y+2,output)
  }
  // Timer input is red; output is blue. A constant-true faulty relay fans the
  // clock out to four colours without advancing the ring on the start click.
  tile('switch',18,8);tile('material',18,9,{style:54})
  tile('timer',22,8,{style:3});tile('material',22,9,{style:54})
  h(18,22,8,1);v(22,8,13,2)
  tile('lamp',22,13,{faulty:true});tile('lamp',22,14,{on:true})
  tile('gate',22,15,{faulty:true});tile('material',22,16,{style:54})
  return {raw:{
    format:'viewer-terralogic',version:1,target:'1.4.5.8',
    source:'8255d34616c780af12079425ac92a0a7aed87d71',title:'HELLO 像素屏',
    palette:['#ef5350','#42a5f5','#66bb6a','#ffee58'],seed:1,randomState:1,tick:0,
    viewport:{x:0,y:0,zoom:1.25},
    notes:'点右侧开关启动／停止：H → E → L → L → O，每个时隙30 tick（60 tick/s、1×时为0.5秒）。两个L保留两个独立时隙。停止保留当前字，再开继续；同tick快速关开遵守原版定时器剩余相位。100块白色宝石火花块满铺10×10连续屏，5×5字模每点占2×2格。五个故障灯锁存器、四个转场中继与四色电线实际驱动，显示线默认隐藏，可打开观察。',
    world:{width:30,height:24,tiles,wires:[...wires].map(([k,mask])=>[...k.split(',').map(Number),mask])},
  }}
}
