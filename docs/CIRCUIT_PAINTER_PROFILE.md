# Visible circuit painter allocation reduction

The candidate reuses one wire `Paint` within each repaint. The frozen c61
reference allocates one per wire color per tile. For the measured 48 × 32
four-color fixture, that changes 6,144 wire Paint constructions to one.
Geometry, draw order, selection and theme behavior stay identical. This is a
construction-count reduction, not a measured process-memory saving.

## Reproducible observation

[CI run 38059252327](https://github.com/Live-yum/abc/actions/runs/38059252327)
ran commit `d0d3e91af233c7788bb795463d85d9a68fa8f723`. One Linux profile
binary contains the exact frozen c61 painter (A) and the candidate extracted
from the mounted production panel (B). Each actual owned X11 window size runs
six fresh processes in BAABBA order, with five seconds of warmup and twenty
seconds of measurement. All twelve observations are retained.

The renderer was llvmpipe (LLVM 20.1.2, 256 bits). The 390-pixel window is a
narrow Linux layout, not an Android/iOS device. The synthetic four-wire scene
is static; fixed 16 ms invalidations request repaint. The measured visible
CustomPaint isolates painting, not world simulation, scrolling, input latency,
or the complete controller. No heap/RSS probe was used.

The fixture SHA-256 is
`fb159a71b949453a6da80642737c77c48b4b3fa8bba43a0fc00cbb97358f6e9c`.
The raw artifact `11672652557` is 3,842,172 bytes, SHA-256
`36d60e77f4c91b07714aa8e56f24ddb7be7314c76c1c0636e9ee646735b9c734`.
It preserves source/build manifests, raw paint/frame samples, exact window
identity and dimensions, and validation outputs. Eighteen static pixel cases
and every profile before/after capture match their baseline.

## Results

Each cell below is the median across the three independent process summaries,
in milliseconds. A process p95 is computed before taking this across-process
median; samples are not pooled or selected.

| Window | Metric | A median | B median | A p95 | B p95 |
| --- | --- | ---: | ---: | ---: | ---: |
| 1440 | Paint callback | 9.003 | 8.601 | 13.398 | 12.806 |
| 1440 | Frame build | 9.329 | 8.971 | 14.022 | 13.222 |
| 1440 | Frame raster | 99.397 | 99.279 | 102.665 | 102.595 |
| 1440 | Frame total span | 190.973 | 191.362 | 202.256 | 200.686 |
| 390 | Paint callback | 6.307 | 5.123 | 12.577 | 11.955 |
| 390 | Frame build | 6.587 | 5.723 | 13.068 | 12.687 |
| 390 | Frame raster | 89.951 | 89.800 | 94.348 | 93.633 |
| 390 | Frame total span | 173.780 | 173.376 | 183.558 | 181.834 |

Paint callback medians fell approximately 4.5% for the wide layout and 18.8%
for the narrow layout. All three candidate process medians are below all
three corresponding reference medians. Tail observations overlap: wide
candidate maximum paint time reaches 19.434 ms, above the reference maximum
18.964 ms. Raster medians are essentially unchanged, and wide total-span
median increases by 0.389 ms. This supports the small local allocation
reduction, not a claim that full application responsiveness has passed.

The dominant 90–100 ms software raster times and approximately 174–192 ms
total spans remain. Frame callback/paint counts are not calibrated presented
FPS. No real-device fluidity, input-to-display, large-world loading, memory
plateau, or absence-of-leaks acceptance follows from this experiment.

## All twelve observations

Times are milliseconds. Preserve individual maxima and scheduling variation.

| Run | Window | Arm | Paint median | Paint p95 | Paint max | Raster median | Total median | Paint count |
| --- | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 1440 | B | 8.100 | 12.778 | 16.250 | 98.616 | 190.304 | 203 |
| 2 | 1440 | A | 9.210 | 15.117 | 17.994 | 99.397 | 191.923 | 200 |
| 3 | 1440 | A | 9.003 | 12.890 | 15.575 | 98.481 | 190.759 | 203 |
| 4 | 1440 | B | 8.609 | 13.434 | 19.434 | 99.279 | 191.362 | 202 |
| 5 | 1440 | B | 8.601 | 12.806 | 17.896 | 99.559 | 192.880 | 200 |
| 6 | 1440 | A | 8.928 | 13.398 | 18.964 | 99.719 | 190.973 | 200 |
| 7 | 390 | B | 5.123 | 11.955 | 13.642 | 89.800 | 173.376 | 221 |
| 8 | 390 | A | 6.636 | 13.190 | 14.710 | 90.446 | 174.773 | 219 |
| 9 | 390 | A | 6.307 | 12.272 | 15.379 | 89.869 | 173.780 | 220 |
| 10 | 390 | B | 5.324 | 12.592 | 14.637 | 90.703 | 175.080 | 219 |
| 11 | 390 | B | 4.889 | 11.590 | 14.103 | 89.783 | 173.319 | 221 |
| 12 | 390 | A | 5.542 | 12.577 | 14.817 | 89.951 | 173.294 | 220 |

## Checks and reproduction

The final diagnostic passed analyzer, 13 Python validator/host-control tests,
and 21 pixel/confirmation/widget tests. Two preceding diagnostic heads failed
static analysis (missing `ui.` prefixes, then one duplicate import); neither
performed measurements and neither replaces a measured sample.

In the official CI environment, the dedicated
`.github/workflows/circuit-painter-paired.yml` uses the repository-pinned
Flutter toolchain, installs Linux renderer/window tools from the runner’s
package repositories, uses the existing performance setup and invokes:

```sh
xvfb-run -a -s '-screen 0 1600x1200x24' \
  python3 tool/perf/circuit_painter_paired.py NEW_OUTPUT_DIRECTORY
```

The runner rejects source/fixture mismatch, an unowned or incorrectly sized
window, missing or malformed reports, buffer overflow, changed pixels and
incomplete process sequences. The two-second timing drain does not prove that
every engine frame was delivered to the callback. The runner records
observations without converting a successful run into a global
performance-acceptance verdict.
