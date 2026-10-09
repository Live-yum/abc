/** Conservative retained JS estimates; the shared Wasm heap is counted by its
 * existing owner. These are admission estimates, not browser heap measurements.
 */
function nativeSnapshotBytes(tile, seen) {
  let bytes = (tile.nativeCells?.length || 0) * 16 + (tile.nativeState?.length || 0) * 2
    + (tile.oneShotRecovery?.supports?.length || 0) * 768
    + (tile.message?.length || 0) * 2 + (tile.announcementText?.length || 0) * 2
  if (tile.nativeObject && !seen.has(tile.nativeObject)) {
    seen.add(tile.nativeObject)
    bytes += (tile.nativeObject.data?.length || 0) * 2 + 128
  }
  return bytes
}

export function circuitWorldBytes(world, seen = new WeakSet()) {
  let nativeBytes = (world.background?.size || 0) * 192
  for (const tile of world.tiles.values()) nativeBytes += nativeSnapshotBytes(tile, seen)
  return 16384 + world.wires.size * 160 + world.occupancy.size * 96 + world.tiles.size * 512 + nativeBytes
}

export function circuitEditorBytes(controller) {
  const editor = controller.editor
  const seen = new WeakSet()
  let bytes = circuitWorldBytes(controller.world, seen)
    + (controller.baseline?.length || 0) * 2
    + (editor.saved?.length || 0) * 2
    + controller.trace.length * 96 + controller.events.length * 160
  for (const entry of [...editor.undoStack, ...editor.redoStack]) bytes += (entry.before.length + entry.after.length) * 2
  bytes += (editor.pending?.before?.length || 0) * 2
  if (editor.clipboard) {
    bytes += (editor.clipboard.wires?.length || 0) * 160 + (editor.clipboard.tiles?.length || 0) * 512 + (editor.clipboard.background?.length || 0) * 192
    for (const tile of editor.clipboard.tiles || []) bytes += nativeSnapshotBytes(tile, seen)
  }
  return bytes
}
