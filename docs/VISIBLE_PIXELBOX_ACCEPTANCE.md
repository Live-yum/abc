# Visible PixelBox and saved WLD acceptance

This is a small functional acceptance case, not a performance benchmark. It
closes two holes in the earlier evidence: the large public-world profile could
select an empty pixel region, while the responsive visual test used a simulated
backend. This case mounts the full production app with the production
`NativeEngine`, production workspace, and a real original WLD. Only the operating
system's pick/save dialogs are replaced with a test gateway backed by local
files. It does not verify an OS file dialog or rendering on a physical device.

## Original fixture and independent expectations

`tool/generate_visible_pixelbox_fixture.py` hand-encodes
`test/fixtures/generic-circuit/synthetic-visible-pixelbox.wld` using the existing original fixture
writer. The fixture is 20 by 32 tiles, 1,110 bytes, with SHA-256
`5bccdba4f0d4db4eda3a11020cdfaed7ccde019ab12016fb150254df23e295d7`.
It contains one ordinary switch, one PixelBox, and one isolated timer. The red
and blue paths reach both axes of the PixelBox through an external bypass; each
colour's horizontal and vertical networks are connected, so both modes support
this topology. There are no game assets, programs, ROMs, public-world coordinates,
or application-specific layout assumptions.

The OFF oracle is `Wiring.cs` at source commit
`8255d34616c780af12079425ac92a0a7aed87d71`, blob
`d67d9c378834c771915e83fe987793f85ea2830b`. `TripWire` (lines 525–666)
processes the colours before `PixelBoxPass` (668–679); traversal (929–942)
accumulates the horizontal and vertical hits. A crossing in one TripWire toggles
the PixelBox. The ON contract intentionally uses cross-colour wave pairing,
already covered by `native/circuit_wld_pixel_contract.c`. These expectations are
different by design:

- OFF, red only: dark becomes lit.
- ON, red only: dark remains dark.
- Either mode, red plus blue: dark becomes lit.

The fixture was probed through the actual native C ABI before writing the UI
assertions. The test must still run against the final candidate engine in CI.
No decompiled source is included in this fixture or test.

## Mounted application coverage

`test/visible_pixelbox_persistence_test.dart` runs both modes at 1440×1000 and
390×844 with the shared product theme and fonts. The test clicks the actual app
navigation, imports through visible buttons, derives the pixel location from
decoded world records, enters its region using the coordinate fields, discovers
the ordinary switch and timer in the UI, selects wire colours, and operates the
selected devices. It does not inject a direct pulse or call workspace dispatch
to substitute for a user action.

Assertions require exactly one real PixelBox, transparent gaps, the expected
native tile frame, and an actual `ComputerDisplay` decoded RGBA image matching
the current frame. The PNG's visible PixelBox centre must also be black or white
as expected, so the screenshot check is not just a comparison of source buffers.
Both modes capture dark and lit states, then reopen the
actual saved file in a new Workspace and capture its persistent lit state.
The saved WLD must differ from the original, and the original hash must remain
unchanged. The restarted VM must have zero ticks, its timer stopped, and
optimization OFF. Tick phase and optimization mode are not persisted WLD state.

Interrupted/repeated flows include cancelling a file picker, cancelling save
confirmation, cancelling the OS save seam, retrying and saving, cancelling and
confirming reset, closing, reopening the saved file, and cancelling and confirming
dirty close. Cancelled exports must release their actual native output lease
while retaining the dirty session and visible pixels. Successful exports must
also release their lease and protect the original path.

## Official CI execution and artifacts

The `visible-pixelbox-persistence` job in
`.github/workflows/generic-circuit-compile.yml` builds the real native library,
checks that the fixture is reproducible, and runs:

```sh
TERRAFORGE_ENGINE_LIBRARY="$PWD/build/native-visible/libabc_engine.so" \
ABC_VISIBLE_PIXELBOX_DIR=build/visible-pixelbox-review \
flutter test --no-pub --concurrency=1 --update-goldens \
  test/visible_pixelbox_persistence_test.dart
```

The artifact contains twelve full-app PNGs, four small JSON reports and the test
log. The screenshots are synthetic WLD observations from the same Flutter test
rasterizer for desktop and mobile layouts. They are not a visual baseline pass,
physical-device capture, FPS measurement, or runtime performance result. JSON
records the source commit, engine/fixture/saved-file hashes, font hashes, decoded
RGBA hashes, dimensions, mode, persistent frame and lifecycle checks.
