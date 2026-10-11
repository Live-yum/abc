# Visible PixelBox and saved WLD acceptance

This is a small functional acceptance case, not a performance benchmark. It
closes two holes in the earlier evidence: the large public-world profile could
select an empty pixel region, while the responsive visual test used a simulated
backend. This case mounts the full production app with the production
`NativeEngine`, production workspace, and a real original WLD. Only the operating
system's pick/save dialogs are replaced with a test gateway backed by local
files. It does not verify an OS file dialog or rendering on a physical device.

## Verified execution

On 2026-10-10, commit `a0caf5b5a8bc964b8f11f459e825219cc5754b5a`
passed all four jobs in [official run 38075765501](https://github.com/Live-yum/abc/actions/runs/38075765501).
The real-native UI job passed all four named cases: 1440×1000 OFF and ON,
390×844 OFF and ON. Its test step completed in about 42 seconds; this is a CI
execution duration, not a rendering or simulation performance measurement.
The same run analyzed without issues and formatted 314 Dart files with zero
changes. The production core and UI were unchanged by the final test correction.

The passing test assertions verified real native pixel frames, the rendered
PNG centre colour, changed save-file hashes, unchanged original-file hashes,
new-Workspace reopen, and the cancellation/close checks described below. The
official [artifact 11678920082](https://github.com/Live-yum/abc/actions/runs/38075765501/artifacts/11678920082)
contains 12 PNGs, four JSON records and a log. On 2026-10-11, its 985,848-byte ZIP
was independently checked against SHA-256
`69034a8571765f0091225fcab2b219cd4521447fba68c5256e718c88a34619ec`,
and all twelve original captures were visually inspected. Each desktop/mobile
OFF/ON sequence visibly changes the selected PixelBox from black to white and
retains white after reopening. The pixel region is fully visible, its labels
and ordinary controls are readable, and the mobile navigation does not cover it.
The shared theme is consistent across these two layouts; the wiring area above
the selected region is partly outside the scrolled capture.

All PNG hashes and dimensions match their four JSON records and the exact
commit above. The records confirm a changed saved WLD and unchanged original
hash in each case; the reopened RGBA matches the lit frame, with zero ticks,
no dirty state and optimization OFF. This inspection covers an original
synthetic WLD through the real native backend using one Flutter test rasterizer.
It does not add physical-device, OS file-dialog, FPS or performance evidence.

Earlier failures remain part of the evidence:

- `93487694372f5a254374ad9108b3c0ac6a781227`, run `38073530903`, failed to
  compile the new test because `Endian` was not imported; no UI cases executed.
  The explicit import and a JSON string-composition lint were corrected.
- `6907202f15f1588bae8bd74611d9c8d9d0e27222`, run `38074484596`, passed the
  core, Web and analysis jobs. The desktop-OFF UI case reached the final dialog
  dismissal assertion after its visible/save/reopen steps, but asserted before
  the route's reverse animation settled. Later cases timed out and teardown
  attempted reentrant `runAsync`. This run is not a UI acceptance pass.
- The final test waits for route dismissal while retaining the no-dialog
  assertion, initializes the process-owned native listener outside per-test
  fake clocks, and drains workspace close with bounded pumping while preserving
  errors. No functional assertion or test timeout was relaxed.

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
assertions. Those probes supplement the executed mounted-app checks above.
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
