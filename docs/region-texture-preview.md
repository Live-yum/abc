# Static region texture preview

The original Flutter renderer uses `RegionTextureCanvas` and local `ABCPACK1`
resources. It never downloads game textures and contains no game PNGs.

The private resource builder verifies the content hashes in the user-supplied
fusion packaged-texture manifest and writes independent `tile-atlases` and
`wall-atlases` families. Inventory item icons are never substituted for placed
world tiles. Tile importance and ordinary-frame eligibility come from the
version-pinned source metadata. Multi-cell furniture crops use TileObjectData
coordinate widths, individual row heights, spacing and draw Y offset.

Supported static layers:
- Frame-important furniture with an exact metadata-known stored frame
- Source-defined ordinary 18-pixel atlas layout, 16-pixel cells, same-type
  four-neighbor selection (approximate material merging)
- Walls using 32-pixel source rectangles on the 36-pixel atlas grid, extending
  eight pixels behind each cell (approximate neighbor/center variation)
- Alpha compositing, invisible layers, inactive tile opacity, half-blocks and
  four triangular slope masks
- Paint color multiplication, liquid amount/type, four wire channels and actuator
  overlays as explicitly labeled editor diagnostics
- Zoom/pan, tap selection and draw callbacks, dark mint editor background

Not a game renderer: special furniture state rules, animation, lighting,
fullbright lighting effects, liquid sprites, paint shaders, world-context merges,
wall center randomness, trees and bespoke sprite rules are not reproduced.
Unrecognized metadata frames and unavailable/oversized atlases receive visible
crossed-cell markers, rather than fabricated texture coordinates.

PNG decoding is limited to referenced atlases, at most 256 distinct requests and
16 million resident pixels. Atlas changes evict unused images. Layout caching
uses the mutable region's monotonic revision so undo/redo/edit repaint correctly.

Public tests use generated synthetic PNGs. To run the additional real private
Dirt source-cell pixel comparison, set `ABC_PRIVATE_PACK` to a locally generated
pack and run `flutter test test/region_texture_canvas_test.dart`. The test compares
rendered pixels to the exact source rectangle and does not write source pixels or
screenshots into the repository.
