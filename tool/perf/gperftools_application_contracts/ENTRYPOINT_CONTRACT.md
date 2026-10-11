# Prebuilt integration entrypoint contract

The helper is offline-only and has no subprocess/SDK entrypoint. It constructs the explicit Linux profile build of `integration_test/computer_memory_ownership_test.dart`, then the same pinned `flutter drive` invocation with a sealed launcher as `--use-application-binary`. The build and drive retain the original ABC_MEMORY_OWNERSHIP and PERF defines; the original driver remains `test_driver/ui_profile_driver.dart`.

Pinned SDK: 3.47.6, commit 5fc346839b5d0eef006ed8404392afb4dfae428d. Official LinuxApp.fromPrebuiltApp and DesktopDevice.startApp allow this path and skip rebuilding for the prebuilt executable. Therefore a drive target argument alone is insufficient: the explicit build target, sealed source bytes, built ELF, loaded owned-process ELF, and original integration hello all must agree.

`bind_source_target` explicitly reports `runtimeEntryExecuted=false`. `bind_runtime_entry` is a validator of independently acquired, fd-pinned evidence; it cannot acquire or fabricate that evidence, and a returned bound handshake never reports completed workload. There has been no actual Flutter startup in these offline tests. A future CI launch must wait for the original integration hello from its unique owned PID before releasing the original ready gate. Missing hello, wrong binary, production main, wrong source/head, or a second launch must fail; no fallback is permitted.

The source of truth for emitted hello is the original integration target around lines 94–127 in the frozen 5a161bf overlay. The proposed diagnostic hook must not move the original workload before that gate. Both arms must use identical compiled bytes. Existing product/cycle/schedule/ROI/GC and image-coverage validation remain unchanged.

The nine offline test cases exercise explicit build vs ignored prebuilt-drive target, changed defines/SDK, loader environment isolation, source mismatch, wrong hello/PID/arm/base/head, mismatched loaded ELF, and malformed argv inputs. They use labeled synthetic evidence, not a live integration result.
