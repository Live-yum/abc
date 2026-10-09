// A native Terraria storage primitive: one faulty trigger lamp, one data lamp,
// one gate, and an isolated pulse output per bit. It does not emulate a CPU in
// JavaScript; every read/write reaches these cells through the wiring engine.
// The one-data-lamp faulty stack is deterministic, avoiding an RNG comparison.
// Source: Terraria/Wiring.cs CheckLogicGate, commit 8255d346...; WireHead calls
// this arrangement IsStandardFaulty. This is a generated workload, not a claim
// that the 13.6 million gate Computerraria world has been run.
export function createRegisterExample({ bits = 32, words = 64, clock = false } = {}) {
  if (!Number.isInteger(bits) || bits < 1 || bits > 32) throw new RangeError('bits must be 1..32')
  if (!Number.isInteger(words) || words < 1 || words > 96) throw new RangeError('words must be 1..96')
  if (clock && words !== 1) throw new RangeError('clock fixture requires one word')
  const tiles = [], wires = new Map(), rows = [], values = []
  const tile = (kind, x, y, fields = {}) => tiles.push({ kind, x, y, ...fields })
  const wire = (x, y, mask) => { const k = `${x},${y}`; wires.set(k, (wires.get(k) || 0) | mask) }
  const hline = (x0, x1, y, mask) => { for (let x = x0; x <= x1; x++) wire(x, y, mask) }
  const vline = (x, y0, y1, mask) => { for (let y = y0; y <= y1; y++) wire(x, y, mask) }
  for (let row = 0; row < words; row++) {
    const y = 6 + row * 10
    const value = (Math.imul(row + 1, 0x9e3779b9) ^ 0xa5a5a5a5) >>> 0
    values.push(value & (bits === 32 ? 0xffffffff : (1 << bits) - 1))
    rows.push({ x: 1, y })
    tile(clock ? 'timer' : 'switch', 1, y, clock ? { style: 4 } : {})
    hline(1, 4 + (bits - 1) * 4, y, 2)
    for (let bit = 0; bit < bits; bit++) {
      const x = 4 + bit * 4
      tile('lamp', x, y, { faulty: true })
      tile('lamp', x, y + 1, { on: !!((value >>> bit) & 1) })
      tile('gate', x, y + 2, { style: 0, faulty: true })
      tile('gemspark', x, y + 4, { on: false })
      tile('switch', x + 2, y - 3)
      vline(x + 2, y - 3, y + 1, 1)
      hline(x, x + 2, y + 1, 1)
      vline(x, y + 2, y + 4, 4)
    }
  }
  return {
    raw: {
      format: 'viewer-terralogic', version: 1, target: '1.4.5.8',
      source: '8255d34616c780af12079425ac92a0a7aed87d71',
      title: `${words} × ${bits} bit 故障灯寄存器${clock ? ' · 15 tick 时钟' : ''}`,
      palette: ['#ef5350', '#42a5f5', '#66bb6a', '#ffee58'],
      seed: 1, randomState: 1, tick: 0, viewport: { x: 0, y: 0, zoom: 2 },
      notes: '蓝线读脉冲；每位右侧红线开关翻转存储位；绿线输出脉冲。输出宝石火花块是脉冲累积显示，两次读取相同字会复位显示。仅使用原版物品。',
      world: { width: 4 * bits + 8, height: words * 10 + 8, tiles,
        wires: [...wires].map(([k, mask]) => [...k.split(',').map(Number), mask]) },
    },
    rows, values: values.map(x => x >>> 0), bits, words,
  }
}

