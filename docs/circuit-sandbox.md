# Circuit component sandbox

TerraForge's version-1 `terraforge.circuit` JSON project is a separate, bounded editor document. It is not a Terraria `.wld` file or a whole-world circuit format.

## Implemented

- Up to 256 × 256 coordinates, four independent wire masks: red 1, blue 2, green 4, yellow 8.
- Original project serialization, strict shape/version/coordinate validation, 50-entry editing undo/redo, stroke coalescing.
- Actual TerraWasm sparse FIFO wire traversal through native `terra_circuit_*` and WebAssembly. No Dart or JavaScript traversal fallback.
- Switch pulses; wired lamps toggle when reached; timers toggle enablement and emit at configurable intervals measured in 60 Hz simulation ticks.
- AND, OR, and exactly-one XOR gates read a contiguous vertical stack of lamps immediately above the gate. A gate-state change emits a pulse at its own coordinate. Repeated gate activation is suppressed within a pulse and exposed as smoke.
- Transactional simulation: traversal failure restores device state, timer ages, tick count and visual trace. Editing during an asynchronous activation rejects and rolls it back.
- Native calls run in the existing serialized engine isolate. WASM circuit work uses a separate module instance and a serialized request queue. No native address is truncated into a 32-bit record.

## Boundaries

The host implements only the explicitly listed sandbox devices. It does not claim full Terraria wiring equivalence, whole-world import/execution, faulty lamps, actuators, junction boxes, pixel boxes, pumps, teleporters, NPCs, object framing or placement rules. WLD/TWLD streaming descriptors are not used by this editor bridge. The graph is compiled afresh per color pulse; this favors simple ownership and safety over large-world performance.

Run/pause scheduling advances simulation ticks. Device state is never synthesized from a UI animation timer. A paused manual Step advances exactly one tick; a switch must be triggered to emit a pulse. The default timer interval is 60 ticks.

## Verification

- `flutter test test/circuit_document_test.dart` validates editing, serialization, device rules and rollback using an explicitly named test stub.
- `TERRAFORGE_ENGINE_LIBRARY=/path/libabc_engine.so dart run native/circuit_smoke.dart` verifies actual native connectivity, lamp parity and a broken wire.
- `TERRA_WORLD_RUNTIME=/path/verified-world.js node tool/test_web_circuit.mjs` verifies actual WASM traversal on all four colors, a broken wire, duplicate-coordinate rejection and subsequent recovery.

Tests generate their own geometry and do not include user saves, proprietary textures or engine implementation source. A compatible, authorized TerraWasm engine must be supplied separately.
