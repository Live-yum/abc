# Limit circuit updates to the active editor

This is historical evidence for the former sample-specific CPU interface.
The generic-WLD revision removes those controls and changes the workload.
Notification isolation requires fresh generic tests; these timing pairs do
not establish the revised application's performance.


The physical computer clock used to notify the entire application shell for every published runtime batch. The shell rebuilt its complete workspace view, including unrelated editor state. This change gives the shell a separate workspace-change channel and listens to routine circuit updates only inside the circuit editor. Ordinary state changes, first dirty transitions, errors, pause, save, close and controller replacement still notify the shell. Existing broad controller listeners keep receiving updates.

The desktop and mobile application use the same components, theme and controller contract. This change does not alter their visual design, circuit simulation strategy or default optimization setting.

## Measured scope

[Fixed same-runner experiment](https://github.com/Live-yum/abc/actions/runs/38014205727), diagnostic commit `c938c936c0c833fed4091f844ac96ac1df941e45`, compares five explicitly inventoried files against `cf36cd2bf1d447a887d3ea4d19611020368de22c`. Two profile builds ran in six fresh processes in **B A A B B A** order. The runner used Flutter 3.47.6, Dart 3.13.5, Linux x64 and the llvmpipe software renderer. Refresh-rate calibration was unavailable.

Every process loaded the public 405,983,441-byte Computerraria WLD, used the optimized physical circuit and original Pong program, checked the same 5,120-pulse display state, and ran a 30-second observation window with four explicit framework key events. No screenshots, full-state snapshots or memory probes ran inside that window. These key timestamps do not measure input-to-presentation latency.

| Metric | A: existing shell | B: isolated updates |
| --- | ---: | ---: |
| Complete workspace-view reads, three processes | 514 / 539 / 580 | 4 / 4 / 4 |
| Median of three build-time p95 values | 10.599 ms | 7.255 ms |
| Median of three raster-time p95 values | 30.004 ms | 27.996 ms |
| Median of three total-span p95 values | 53.670 ms | 48.542 ms |
| Median observed frame callbacks per second | 35.685 | 32.265 |

Build-time p95 improved in each adjacent pair by 2.343, 3.682 and 2.777 ms. This supports adopting the reduction in unrelated snapshot and build work. It does **not** establish that every visible interaction is smoother. Frame callback rate fell in two pairs and rose in one; physical pulses and display reads increased in the first two pairs and fell in the third. Fewer callbacks can include fewer redundant redraws, but this experiment cannot distinguish those from slower presentation. Pulse and display-read counts include the pause/drain boundary and are not exact 30-second throughput measurements.

All six fixed-pulse pixel hashes matched (`aaf5f2b5ac6db8ca72da41e9bd1a44ab9c7fa2e4d002f267646ba7d9630774bd`, 12,288 RGBA bytes). All six windows contained real frame timings and the complete key sequence, and each process closed its session. The CI verified identical native-library bytes between arms. The compact artifact contains source and binary manifests rather than the executable bytes; independently reading that compact package alone cannot rehash the binaries.

## Validation and limits

- Static analysis, 119 targeted Flutter regression tests and five Python pairing/report contracts passed in the diagnostic run. Tests cover the desktop and mobile layouts, precise notification counts, dirty transitions, synchronous reentrancy, errors, save, close/reopen and controller replacement.
- The frame recorder's `droppedFrames: 0` means its bounded recording buffer did not overflow. It is not a statement that no screen frames were dropped.
- This experiment did not measure process RSS, heap retention or a long-duration memory plateau. It does not resolve the existing memory acceptance gaps.
- Linux software-renderer observations do not establish Android, iOS, macOS or browser hardware performance. The application still has outstanding smoothness and memory acceptance work.
- Earlier unsuccessful harness runs remain in Actions history. They exposed test-zone timing, synchronous matcher and profile-mode key-simulation mistakes. Their partial reports are not successful performance measurements.

## Reproduce and inspect

The diagnostic workflow, runner and input preparation are preserved at the pinned diagnostic commit. `.github/workflows/computer-shell-paired.yml` installs the pinned toolchain and dependencies, prepares the public fixture and runs:

```sh
xvfb-run -a -s '-screen 0 1440x1000x24' \
  python3 tool/perf/computer_shell_paired.py "$RUNNER_TEMP/shell-paired-results"
```

Use a new output directory and the workflow's `COMPUTERRARIA_WLD` environment. The runner builds both arms before observation, validates the exact five-file difference and native-library identity, retains every process, and rejects incomplete windows or mismatched checkpoints. Its output status describes measurement completion, not performance acceptance.

The compact artifact `full-shell-paired-logs-c938c936c0c833fed4091f844ac96ac1df941e45` has SHA-256 `0c50f5e6cb3caa8272f65e67db1733f9cefb0a3f1fd379dcf8c6b680dbf501b0`. The complete archive, including both built applications and formatted source, has SHA-256 `810234d95c3a7a8464d747a07a522aa7c0e3729a518e20aa62e4f01185d820cd`.
