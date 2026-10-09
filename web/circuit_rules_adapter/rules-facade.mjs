// Original bounded host facade. All circuit/editor behavior comes from the
// attributed, pinned source. No copied catalog is stored in this adapter.
import { CircuitEditor, createDemo } from 'authoritative:editor';
import { DEFINITIONS, PALETTE, TARGET, LIMITS, WIRE_COLORS, WIRE_NAMES } from 'authoritative:catalog';
import { newDocument, parseDocument, serializeDocument } from 'authoritative:model';
import { createCircuitComputation } from 'authoritative:computation-session';
import { circuitEditorBytes } from 'authoritative:memory';
import { traceNetwork } from 'authoritative:routing';

const SOURCE_COMMIT = __CIRCUIT_SOURCE_COMMIT__;
const MAX_REPLY = 16 * 1024 * 1024;
const MAX_RETAINED = 256 * 1024 * 1024;
const MAX_EDIT_AREA = 250000;
const MAX_PREVIEW_CELLS = 60000;
const DEMOS = Object.freeze(['hello', 'register', 'logic', 'timer', 'pixel', 'gallery', 'lighting', 'lighting-extra', 'mechanisms', 'devices', 'effects', 'pulse', 'remaining', 'support', 'storage']);
const fail = (code, message) => Object.assign(new Error(message), { code });
const arity = (args, min, max = min) => {
  if (!Array.isArray(args) || args.length < min || args.length > max) throw fail('CIRCUIT_COMMAND', 'Invalid circuit argument count');
};
const object = value => value !== null && typeof value === 'object' && !Array.isArray(value);
function boundedString(value, maximum, label) {
  if (typeof value !== 'string' || value.length > maximum) throw fail('CIRCUIT_LIMIT', `${label} exceeds its limit`);
  // Count UTF-8 without requiring TextEncoder in embedded JS runtimes.
  let bytes = 0;
  for (let i = 0; i < value.length; i++) {
    const c = value.charCodeAt(i);
    bytes += c < 0x80 ? 1 : c < 0x800 ? 2 : c >= 0xd800 && c <= 0xdbff && i + 1 < value.length && value.charCodeAt(i + 1) >= 0xdc00 && value.charCodeAt(i + 1) <= 0xdfff ? (i++, 4) : 3;
    if (bytes > maximum) throw fail('CIRCUIT_LIMIT', `${label} exceeds its byte limit`);
  }
  return value;
}
const documentText = value => boundedString(value, LIMITS.bytes, 'Circuit document');

export function createRulesFacade(tx) {
  const editors = new Map();
  let nextId = 0, activeId = null, generation = 0, disposed = false;
  function admitBytes(bytes) {
    let retained = computation.memoryBytes();
    for (const session of editors.values()) retained += editorBytes(session);
    if (!Number.isFinite(bytes) || bytes + retained > MAX_RETAINED) throw fail('CIRCUIT_LIMIT', 'Circuit owner memory budget exceeded');
  }
  const computation = createCircuitComputation(tx, { admitBytes });
  function editorBytes(session) {
    return circuitEditorBytes({ editor: session.editor, world: session.editor.world, baseline: session.baseline, trace: [], events: [] })
      + (session.preview?.cells.length || 0) * 128;
  }
  function sessionFor(id = activeId) {
    if (!Number.isSafeInteger(id) || !editors.has(id)) throw fail('STALE_OPERATION', 'Circuit editor is closed or unavailable');
    return editors.get(id);
  }
  function releaseSimulation(session) {
    if (session.computationId !== null) computation.invoke('close', [session.computationId]);
    session.computationId = null;
  }
  function snapshot(id = activeId) {
    const s = sessionFor(id), editor = s.editor;
    return { id, generation: s.generation, document: documentText(serializeDocument(editor.document)),
      dirty: editor.dirty, revision: editor.revision, canUndo: editor.undoStack.length > 0,
      canRedo: editor.redoStack.length > 0, selection: editor.selection,
      clipboardAvailable: editor.clipboard !== null, canReset: s.baseline !== null,
      preview: s.preview ? { kind: s.preview.kind, token: s.preview.token, editorId: id,
        generation: s.preview.generation, revision: s.preview.revision,
        cells: s.preview.cells, count: s.preview.cells.length, colourCounts: s.preview.colourCounts } : null };
  }
  function openEditor(document, replaceActive) {
    // Validate completely before releasing the existing, recoverable document.
    const text = documentText(typeof document === 'string' ? document : serializeDocument(document));
    admitBytes(32768 + text.length * 32);
    const validated = parseDocument(text);
    const editor = new CircuitEditor(validated);
    admitBytes(editorBytes({ editor, baseline: null }));
    if (!replaceActive && editors.size >= 4) throw fail('CIRCUIT_LIMIT', 'At most four editors may be retained');
    if (replaceActive && activeId !== null) closeEditor(activeId);
    if (nextId >= Number.MAX_SAFE_INTEGER) throw fail('CIRCUIT_LIMIT', 'Circuit editor IDs exhausted');
    const id = ++nextId;
    editors.set(id, { editor, baseline: null, computationId: null, generation: ++generation, preview: null });
    activeId = id;
    return snapshot(id);
  }
  function closeEditor(id) {
    const session = editors.get(id);
    if (session) { releaseSimulation(session); editors.delete(id); }
    if (activeId === id) activeId = null;
    return null;
  }
  function point(p, world) {
    if (!object(p) || !world.contains(p.x, p.y)) throw fail('CIRCUIT_COMMAND', 'Editor point is outside the document');
  }
  function area(r, world) {
    if (!object(r) || !Number.isSafeInteger(r.width) || !Number.isSafeInteger(r.height) || r.width < 1 || r.height < 1 || r.width * r.height > MAX_EDIT_AREA) throw fail('CIRCUIT_LIMIT', 'Editor selection exceeds the operation budget');
    point(r, world); point({ x: r.x + r.width - 1, y: r.y + r.height - 1 }, world);
  }
  function wireMask(mask) {
    if (!Number.isSafeInteger(mask) || mask < 1 || mask > 15) throw fail('CIRCUIT_COMMAND', 'Select at least one of the four wire colours');
  }
  function preview(id, method, args) {
    const s = sessionFor(id), e = s.editor, route = method === 'previewRoute';
    // A failed or newer preview must never leave an older plan confirmable.
    s.preview = null;
    arity(args, route ? 4 : 3);
    const start = args[0], end = route ? args[1] : null,
      mask = args[route ? 2 : 1], token = args[route ? 3 : 2];
    point(start, e.world); if (route) point(end, e.world); wireMask(mask);
    if (typeof token !== 'string' || token.length === 0 || token.length > 128) throw fail('CIRCUIT_COMMAND', 'Invalid preview request token');
    if (route && Math.abs(start.x - end.x) + Math.abs(start.y - end.y) + 1 > MAX_PREVIEW_CELLS) throw fail('CIRCUIT_LIMIT', 'Route preview exceeds 60000 cells; shorten the route');
    // Reserve temporary traversal/A* state before entering the unchanged
    // reference functions. Their operation limits also bound sparse worlds.
    admitBytes(LIMITS.operations * 256 + (route ? LIMITS.route * 1536 : 0));
    // The reference search tracks incoming direction, so a legal path may
    // revisit a router. Transport each wire cell once without changing its path.
    const network = route
      ? new Map(e.route(start, end, mask).map(p => [`${p.x},${p.y}`, mask]))
      : traceNetwork(e.world, [start], mask);
    const cells = [...network].map(([key, bits]) => [...key.split(',').map(Number), bits]);
    if (cells.length === 0) throw fail('CIRCUIT_COMMAND', 'No wires of the selected colours at this point');
    if (cells.length > MAX_PREVIEW_CELLS) throw fail('CIRCUIT_LIMIT', 'Network preview exceeds 60000 cells; use a smaller network or fewer colours');
    admitBytes(cells.length * 128);
    const colourCounts = [0, 0, 0, 0];
    for (const cell of cells) for (let colour = 0; colour < 4; colour++) if (cell[2] & (1 << colour)) colourCounts[colour]++;
    s.preview = { kind: route ? 'route' : 'removeNetwork', token, generation: s.generation,
      revision: e.revision, start, mask, cells, colourCounts };
    try {
      const result = snapshot(id);
      boundedString(JSON.stringify(result), MAX_REPLY, 'Circuit preview reply');
      return result;
    } catch (error) { s.preview = null; throw error; }
  }
  function commitPreview(id, args) {
    arity(args, 1);
    const s = sessionFor(id), e = s.editor, plan = s.preview;
    if (!plan || args[0] !== plan.token || plan.generation !== s.generation || plan.revision !== e.revision) throw fail('STALE_OPERATION', 'Circuit preview is stale; preview the operation again');
    admitBytes(serializeDocument(e.document).length * 8 + plan.cells.length * 1024
      + (plan.kind === 'removeNetwork' ? LIMITS.operations * 256 : 0));
    // Consume before the transaction: repeated confirmation or a failed
    // transaction must require a fresh preview, never apply an old plan twice.
    s.preview = null;
    releaseSimulation(s);
    e.change(plan.kind, () => {
      if (plan.kind === 'removeNetwork') e.removeNetwork(plan.start, plan.mask);
      else for (const [x, y, bits] of plan.cells) e.world.paintWire(x, y, bits);
      e.settleGates();
    });
    s.baseline = null; s.generation = ++generation;
    return snapshot(id);
  }
  function command(id, input) {
    const s = sessionFor(id), e = s.editor, world = e.world;
    if (!object(input) || Object.keys(input).some(k => !['method', 'args'].includes(k))) throw fail('CIRCUIT_COMMAND', 'Invalid editor command');
    const { method, args } = input;
    if (!Array.isArray(args)) throw fail('CIRCUIT_COMMAND', 'Editor command args must be an array');
    if (method === 'previewRoute' || method === 'previewNetwork') return preview(id, method, args);
    if (method === 'commitPreview') return commitPreview(id, args);
    if (method === 'cancelPreview') { arity(args, 0); s.preview = null; return snapshot(id); }
    s.preview = null;
    let run, changes = true, atomic = true;
    switch (method) {
      case 'paint':
        arity(args, 3); point(args[0], world); point(args[1], world);
        if (Math.max(Math.abs(args[0].x - args[1].x), Math.abs(args[0].y - args[1].y)) + 1 > MAX_EDIT_AREA) throw fail('CIRCUIT_LIMIT', 'Paint stroke exceeds the operation budget');
        if (!object(args[2]) || !['wire', 'wire-erase', 'erase', 'tile', 'actuator-on', 'actuator-off'].includes(args[2].tool || 'wire')) throw fail('CIRCUIT_COMMAND', 'Invalid paint tool');
        run = () => e.paint(...args); break;
      case 'placeTile': arity(args, 1, 2); point(args[1] || args[0], world); run = () => { if (!e.canPlace(args[0], args[1] || args[0])) throw fail('CIRCUIT_COMMAND', 'Tile cannot be placed here'); e.placeTile(...args); }; break;
      case 'select': arity(args, 1); area(args[0], world); changes = false; run = () => e.select(args[0]); break;
      case 'copy': arity(args, 0); changes = false; run = () => e.copy(); break;
      case 'cut': arity(args, 0); atomic = false; run = () => e.cut(); break;
      case 'paste': arity(args, 1, 2); point(args[0], world); run = () => e.paste(...args); break;
      case 'transformClipboard': arity(args, 1); changes = false; run = () => e.transformClipboard(args[0]); break;
      case 'fill': arity(args, 0, 1); area(e.selection, world); run = () => e.fill(...args); break;
      case 'erase': arity(args, 0, 2); area(args[0] || e.selection, world); run = () => e.erase(...args); break;
      case 'applyActuators': arity(args, 1, 2); if (typeof args[0] !== 'boolean') throw fail('CIRCUIT_COMMAND', 'Actuator state must be boolean'); area(args[1] || e.selection, world); run = () => e.applyActuators(...args); break;
      case 'removeNetwork': arity(args, 2); point(args[0], world); run = () => e.removeNetwork(...args); break;
      case 'updateTile': arity(args, 3); point({ x: args[0], y: args[1] }, world); if (!object(args[2])) throw fail('CIRCUIT_COMMAND', 'Tile properties must be an object'); run = () => e.updateTile(...args); break;
      case 'rearm': arity(args, 0); atomic = false; run = () => e.rearm([...world.tiles.values()]); break;
      case 'undo': arity(args, 0); atomic = false; run = () => e.undo(); break;
      case 'redo': arity(args, 0); atomic = false; run = () => e.redo(); break;
      case 'markSaved': arity(args, 0); changes = false; run = () => e.markSaved(); break;
      default: throw fail('CIRCUIT_COMMAND', `Unsupported editor method: ${String(method)}`);
    }
    let affected = 0;
    if (method === 'paint') affected = Math.max(Math.abs(args[0].x - args[1].x), Math.abs(args[0].y - args[1].y)) + 1;
    if (method === 'fill') affected = e.selection.width * e.selection.height;
    if (method === 'paste') affected = (e.clipboard?.tiles?.length || 0) + (e.clipboard?.wires?.length || 0) + (e.clipboard?.background?.length || 0);
    // Reserve both history strings and mutable graph growth across every
    // retained editor, instead of admitting each editor in isolation.
    admitBytes(serializeDocument(e.document).length * 8 + affected * 1024 + JSON.stringify(args).length * 32);
    if (changes) releaseSimulation(s);
    if (changes && atomic) e.change(method, () => { run(); e.settleGates(); });
    else run();
    if (changes) { s.baseline = null; s.generation = ++generation; }
    return snapshot(id);
  }
  function simulate(command) {
    const s = sessionFor(), before = documentText(serializeDocument(s.editor.document));
    s.preview = null;
    if (s.computationId === null) s.computationId = computation.invoke('open', [before]).id;
    const response = computation.invoke('execute', [s.computationId, command]);
    boundedString(response.packet, MAX_REPLY, 'Circuit execution packet');
    const packet = JSON.parse(response.packet);
    if (packet.version !== 1 || packet.id !== s.computationId) throw fail('STALE_OPERATION', 'Circuit packet belongs to another session');
    // Patches only transport already-computed state; parseDocument remains the
    // authority for the entire schema, tile validation, and structural changes.
    let text;
    if (packet.structureChanged) {
      if (typeof packet.document !== 'string') throw fail('CIRCUIT_PACKET', 'Structural packet has no replacement document');
      text = packet.document;
    } else {
      const raw = JSON.parse(before), replacements = new Map(packet.tiles.map(tile => [`${tile.x},${tile.y}`, tile]));
      raw.world.tiles = raw.world.tiles.map(tile => {
        const key = `${tile.x},${tile.y}`, update = replacements.get(key);
        if (!update) return tile;
        if (update.kind !== tile.kind || update.width !== tile.width || update.height !== tile.height) throw fail('CIRCUIT_PACKET', 'Circuit patch does not match the editor document');
        replacements.delete(key); return update;
      });
      if (replacements.size) throw fail('CIRCUIT_PACKET', 'Circuit patch refers to a missing tile');
      Object.assign(raw, { tick: packet.tick, randomState: packet.randomState, mechanicalState: packet.mechanicalState, circuitContext: packet.circuitContext });
      text = JSON.stringify(raw);
    }
    const updated = parseDocument(documentText(text));
    s.baseline ||= before;
    s.editor.document = updated;
    s.generation = ++generation;
    return { ...snapshot(), packet };
  }
  function invokeRaw(method, args) {
    if (disposed) throw fail('COMPUTATION_OWNER_LOST', 'Circuit rules owner is closed');
    switch (method) {
      case 'capabilities': arity(args, 0); return { available: true, apiVersion: 1, sourceCommit: SOURCE_COMMIT, limits: { documentBytes: LIMITS.bytes, replyBytes: MAX_REPLY, sessions: 4, triggerPoints: 8192, stepTicks: 60, operations: LIMITS.operations, previewCells: MAX_PREVIEW_CELLS, routeVisits: LIMITS.route }, methods: ['catalog', 'editor.new', 'editor.open', 'editor.demo', 'editor.snapshot', 'editor.command', 'editor.close', 'simulation.command', 'simulation.reset', 'simulation.cancel', 'open', 'execute', 'close'], demos: DEMOS };
      case 'catalog': arity(args, 0); return { target: TARGET, definitions: DEFINITIONS, palette: PALETTE, demos: DEMOS, wireColors: WIRE_COLORS, wireNames: WIRE_NAMES, limits: LIMITS };
      case 'editor.new': arity(args, 0, 1); return openEditor(newDocument(args[0]), true);
      case 'editor.open': arity(args, 1); return openEditor(documentText(args[0]), true);
      case 'editor.demo': arity(args, 1); return openEditor(createDemo(args[0]), true);
      case 'editor.snapshot': arity(args, 0); return snapshot();
      case 'editor.command': arity(args, 1); return command(activeId, args[0]);
      case 'editor.close': arity(args, 0); return activeId === null ? null : closeEditor(activeId);
      case 'simulation.command': arity(args, 1); return simulate(args[0]);
      case 'simulation.cancel': { arity(args, 0); const s = sessionFor(); s.preview = null; releaseSimulation(s); s.generation = ++generation; return snapshot(); }
      case 'simulation.reset': { arity(args, 0); const s = sessionFor(); s.preview = null; releaseSimulation(s); if (s.baseline !== null) { s.editor.document = parseDocument(s.baseline); s.baseline = null; } s.generation = ++generation; return snapshot(); }
      case 'createDemo': arity(args, 1); return openEditor(createDemo(args[0]), false);
      case 'openDocument': arity(args, 1); return openEditor(documentText(args[0]), false);
      case 'snapshot': arity(args, 1); return snapshot(args[0]);
      case 'editorCommand': arity(args, 2); return command(args[0], args[1]);
      case 'closeDocument': arity(args, 1); return closeEditor(args[0]);
      case 'open': arity(args, 1); documentText(args[0]); return computation.invoke(method, args);
      case 'execute': case 'close': return computation.invoke(method, args);
      case 'dispose': arity(args, 0); for (const id of [...editors.keys()]) closeEditor(id); computation.dispose(); disposed = true; return null;
      default: throw fail('CIRCUIT_COMMAND', `Unsupported circuit method: ${String(method)}`);
    }
  }
  return Object.freeze({ invoke(method, args = []) {
    arity(args, 0, 8);
    // JSON round-trip ensures prototypes/functions never cross the public API.
    const value = invokeRaw(method, JSON.parse(boundedString(JSON.stringify(args), MAX_REPLY, 'Circuit request')));
    return JSON.parse(boundedString(JSON.stringify(value ?? null), MAX_REPLY, 'Circuit reply'));
  } });
}
