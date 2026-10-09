# Map layers and bounded terrain conversion

## Actual map overlays

The map reads a user-selected visible viewport from the authoritative region engine. Red, blue, green and yellow wire masks and water, lava, honey and shimmer are decoded from actual tile records. The diagram shows liquid amount as a partial-height fill, with separate wire lanes, plus per-layer counts and the exact loaded rectangle.

Loading is explicit. Pan/zoom does not start repeated background parsing. A viewport larger than 262,144 cells requests more zoom; out-of-world or fractional coordinates are rejected before the engine call. The parser validates one unique record per tile, supported liquid-kind/amount combinations, reserved bytes and wire masks. Snapshot arrays are immutable.

Only the sampled rectangle has overlay information. Absence of marks outside it is not evidence of absent wires/liquids. Read again after moving to another area. Editing, switching or closing the world discards the snapshot. The application serializes temporary singleton-engine release, keeps the display metadata and unmodified base PNG, and reopens the source world even after a layer-read failure. This avoids resetting map zoom while loading.

## Environment rules

The environment tab accepts explicit foreground-block or background-wall source/target IDs. No undocumented biome preset table is assumed. Users can build biome conversion schemes by combining known block and wall rules from their supported resource/version data.

1. Read a complete bounded region in Fusion.
2. Add environment rules in Mapping. Block target 0 means active Dirt; wall target 0 removes a wall and its wall paint.
3. Preview counts. Source records are unchanged.
4. Confirm applying to the Fusion canvas. This is one undo step, not a world write.
5. Use the existing write workflow to preview/read-back and confirm a separate WLD candidate.

Rules match original layer IDs simultaneously: swaps work and replacements never cascade into later rules. Duplicate source IDs within one layer are rejected. Inactive foreground cells are not matched. Unrelated flags, frames, paint, liquids, wiring and object companion bytes are preserved. Removing a wall clears only that wall's paint. The plan is invalidated if its region, revision or rules change before confirmation.

The model bounds rules to 65,535 and tile records to 262,144. Atomic replacement validates all records and coordinates before modifying history. World-level safety still belongs to the authoritative core: unsupported tile IDs, target versions and structural furniture changes may be rejected during candidate generation. A converted canvas is not proof of a safe world write.

## Evidence

Model/widget/pixel tests cover all four liquid kinds, partial-height paint alignment, wire lanes/masks, viewport inverse transforms, narrow controls, exact budgets and malformed records. Application tests cover failed-read recovery, stable visible metadata during engine release and unchanged save exports. A real native WLD test reads preserved wire/lava layers.

Terrain tests cover simultaneous swaps, no cascading, Dirt 0, inactive cells, wall-paint removal, companion preservation, duplicate rejection, atomic rollback, stale confirmation, undo/redo and bounded history. Native application tests exercise preview → confirmation → canvas undo/redo → real world write/read-back → exact original world undo.
