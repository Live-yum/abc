# TerraForge migration and acceptance plan

## Product scope

The supplied TerraForge prototype defines an original dark, mint-accented workspace with twelve areas. The implementation target is Android, iOS, macOS and Web, preserving the original viewer application's capabilities rather than embedding its Vue interface. Linux is an additional development/test host.

The prototype's sample save files, account, task counters and completion messages are illustrative, not runtime data. This implementation must not treat choosing a filename as parsing a save, display a fake cloud account, or report a write that never occurred.

## Architecture

- Flutter presentation and shared, bounded domain models.
- Platform file picker and user-directed export. Originals remain immutable; successful edits become separate candidates.
- Native C engine behind pointer-safe FFI, serialized in one background isolate.
- Web JS/WASM engines behind the same Dart contract, owned by dedicated workers; document, region, full circuit rules and whole-world circuit handles remain separate.
- Binary exploration MAP codec with native isolate/Web worker ownership, bounded edit history and full candidate reopen verification.
- Explicit capabilities and error states for not-yet-supported operations.
- The engine permits one active WLD workspace. Transactions close the active workspace before opening a candidate and restore the last validated bytes after failure.

## Milestones and acceptance

1. Responsive workspace: all twelve destinations, desktop sidebar, mobile navigation and drawer, dialogs, empty/loading/error states, no overflow at narrow widths.
2. Save engine: real WLD/PLR import, metadata, PNG preview, edits, untouched byte-preserving export, edited candidate read-back, unsupported version protection, cancelled file selection, failed edit recovery.
3. Creative tools: image import, pixel painting/fill/erase, grouped-stroke undo/redo, bounded canvas resize, PNG/project export, mapping, typed fusion and circuit documents.
4. Advanced editing: chest/bestiary/inventory/equipment/stats/research/buffs, tile/wall/liquid/wiring preservation, circuit simulation, world-stamp collision checks, unknown entity retention, version-boundary tests.
5. Achievement codec: encrypted import, BSON unknown-field preservation, safe edits and export, original bytes retained for untouched documents.
6. Save vault and online services: persistent local projects, durable cloud adoption, account-scoped receipt/transfer recovery, source-verified cloud/profile/help/generation requests, manifest-pinned resource installation/cache/revocation and explicit session requirements.
7. Platform validation: Flutter analysis/tests and Web/Android/macOS/iOS builds; signed installations and live account integration require the corresponding authorized environment.
8. Performance validation: action-level correctness and timing diagnostics, clean comparable baselines, Flutter profile/release frames and repeated lifecycle/soak runs. Debug timings, Node WASM and generated MAP fixtures do not certify device/browser responsiveness.

## External constraints

- Source-verified cloud clients and recovery paths are implemented. Existing upstream initial MEMBER authentication is a WeChat mini-app code exchange; no supported portable initial login has been verified. A supported account session and live service checks are required for private-cloud and world-generation acceptance. No token is embedded in source.
- Game textures, executables and personal save fixtures are not redistributed.
- Public inclusion of the minimal engine/rules source, required tables and derived runtimes was authorized on 2026-10-09. Included source subsets retain attribution, integrity records and upstream licensing restrictions; this does not grant a new third-party license.
- Included native source repairs the upstream pointer-width ABI and has local ASan/UBSan evidence. This does not replace Android/iOS/macOS runtime validation; local LeakSanitizer remains unverified.
- A passing compile is not an in-game save validation or a physical-device test.

The current capability, historical evidence, last verified public CI head and remaining acceptance gaps are recorded in [the evidence matrix](feature-matrix.md). Do not carry an earlier passing aggregate forward across later implementation changes.
