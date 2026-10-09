# TerraForge migration and acceptance plan

## Product scope

The supplied TerraForge prototype defines an original dark, mint-accented workspace with twelve areas. The implementation target is Android, iOS, macOS and Web, preserving the original viewer application's capabilities rather than embedding its Vue interface. Linux is an additional development/test host.

The prototype's sample save files, account, task counters and completion messages are illustrative, not runtime data. This implementation must not treat choosing a filename as parsing a save, display a fake cloud account, or report a write that never occurred.

## Architecture

- Flutter presentation and shared, bounded domain models.
- Platform file picker and user-directed export. Originals remain immutable; successful edits become separate candidates.
- Native C engine behind pointer-safe FFI, serialized in one background isolate.
- Web JS/WASM engine behind the same Dart contract.
- Explicit capabilities and error states for not-yet-supported operations.
- The engine permits one active WLD workspace. Transactions close the active workspace before opening a candidate and restore the last validated bytes after failure.

## Milestones and acceptance

1. Responsive workspace: all twelve destinations, desktop sidebar, mobile navigation and drawer, dialogs, empty/loading/error states, no overflow at narrow widths.
2. Save engine: real WLD/PLR import, metadata, PNG preview, edits, untouched byte-preserving export, edited candidate read-back, unsupported version protection, cancelled file selection, failed edit recovery.
3. Creative tools: image import, pixel painting/fill/erase, grouped-stroke undo/redo, bounded canvas resize, PNG/project export, mapping, typed fusion and circuit documents.
4. Advanced editing: chest/bestiary/inventory/equipment/stats/research/buffs, tile/wall/liquid/wiring preservation, circuit simulation, world-stamp collision checks, unknown entity retention, version-boundary tests.
5. Achievement codec: encrypted import, BSON unknown-field preservation, safe edits and export, original bytes retained for untouched documents.
6. Save vault: persistent local projects, journal/recovery, cloud request contracts and explicit session requirements.
7. Platform validation: Flutter analysis/tests and Web/Android/macOS/iOS builds; signed installations and live account integration require the corresponding authorized environment.

## External constraints

- Existing upstream authentication is a WeChat mini-app code exchange. A verified cross-platform login contract is required for real private-cloud and world-generation requests. No token is embedded in source.
- Game textures, executables and personal save fixtures are not redistributed.
- Upstream private engine material is excluded until explicit public-publication approval. Attribution and any upstream licensing restrictions must remain intact; the app does not claim a new license for third-party code.
- Native pointer truncation must be repaired and tested under ASan/UBSan before using the upstream WASM-oriented ABI on 64-bit devices.
- A passing compile is not an in-game save validation or a physical-device test.
