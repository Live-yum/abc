# Whole-world circuit fragment transfer

`WorldCircuitSession.fragments` sends the real native command 7, with bounded
pages of at most 32,768 eight-word descriptors. Terminal `READY.resultCount`
is the total descriptor count, not the current page size. The result preserves
`resultKind`, `resultCount`, and `reserved`; the latter carries native rule flags
except for SAVE, where it reports TWLD output bytes.

`WorldCircuitSession.extract` pauses the scheduler and waits for earlier commands
before sending command 8. It captures a distinct source-6 COB1 output, validates
its sequential writes and 4 MiB/32,768-object budgets, and publishes cells and
companion together only after READY. Failed extraction cancels the native command
and discards its companion. Subsequent queries cannot modify a captured result.

Extraction uses local coordinates for `AdvancedRegionDocument.records` and keeps
the original x/y in the COB1 header. Set the document's `sourceX` and `sourceY`
from the descriptor. These query results never replace the viewport's four-word
records or mark simulation state dirty. Reset invalidates previous descriptors.

Before world placement require both `extraction.canStamp` and, when using an
imported geometry index, `geometry.supportsVerifiedFor(extraction)`. Incomplete
footprints, modded cells, unresolved supports, and missing required COB1 records
must not be treated as safe transfers. Close the compiled world before adopting
a normal, validated `stamp_tiles` candidate.

`WorldCircuitGeometry.fromCatalog` accepts matching WLD 326 / game 1.4.5.8 local
metadata. It preserves unequal coordinate heights and exact frame offsets,
deduplicates cell layouts, removes conflicting layouts, and bounds the expanded
index to 65,536 records. The current imported rows do not contain anchor rules.
A narrow documented support set is supplied for common devices and object
sections. Nonzero placement alternates remain unverified unless an explicit
frame-specific rule covers them. Other frames remain support-unverified. The adapter does
not claim procedural-frame, electrical-state, or full standalone catalog parity.

## Reproducible local checks

All generated fixture contents are original. No private game save or artwork is
required for the native/WASM transfer proof:

```sh
python3 native/generate_circuit_fragment_fixture.py /tmp/abc-circuit-fragments.wld
TERRAFORGE_ENGINE_LIBRARY=/path/to/libabc_engine.so \
  TERRAFORGE_FRAGMENT_FIXTURE=/tmp/abc-circuit-fragments.wld \
  TERRAFORGE_FRAGMENT_PROOF_DIR=/tmp/abc-circuit-fragment-proof \
  flutter test --no-pub native/circuit_integration_test.dart
node test/web/world_circuit_fragments_smoke.cjs /path/to/world.js \
  /path/to/world.wasm /tmp/abc-circuit-fragments.wld
# Optional exact native/WASM byte comparison uses the native proof directory:
node test/web/world_circuit_fragments_smoke.cjs /path/to/world.js \
  /path/to/world.wasm /tmp/abc-circuit-fragment-proof
node test/web/world_circuit_fragments_contract.cjs
flutter test test/world_circuit_fragments_test.dart test/world_circuit_session_test.dart
```

The real-engine proof covers pagination, complete supported chest/sign/entity
footprints, sparse wire-only fragments, exact cross-platform tile/COB1 bytes,
immutable capture, budget rejection and recovery, companion-preserving stamp,
occupied-target rejection, and unchanged source bytes. The protocol fake adds
malformed batch lengths, terminal counts, and nonsequential companion writes.
Engine artifacts remain separately supplied and authorized.
