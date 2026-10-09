# Platform builds

Toolchain: Flutter **3.47.6** / Dart **3.13.5**. CI verifies Flutter revision
`5fc346839b5d0eef006ed8404392afb4dfae428d` against the official repository.

## Engine source prerequisite

Every native build uses the included, authorized pointer-safe TerraWasm source
subset at `native/vendor/TerraWasm`. Its manifest records the upstream base commit
and hashes of the locally patched files. For local development, an optional
`ABC_TERRA_SOURCE` absolute path selects another authorized checkout. A fresh
clone needs no private repository access. The build fails when sources are absent;
it never substitutes a no-op engine. Personal saves, private real-save fixtures,
artwork atlases and game programs remain excluded. See `THIRD_PARTY_NOTICES.md`.

Node 22 and `npm ci` install esbuild 0.20.1 from the root lockfile. Run
`npm run verify:sources` to check both vendored closures and the prebuilt runtime
provenance, then `npm run build:circuit-rules` to regenerate the native/Web rules.
The 40-module viewer subset is pinned to commit
`366ebc57751cadfb077f968f4d5069028b3bf9a6`. No private checkout is consulted.

CMake 3.27 or newer and a C17 compiler are required. Desktop builds need zlib
headers/libraries. Android uses its NDK zlib. Engine source patches must preserve
pointer-width correctness; a Wasm-only 32-bit pointer ABI is not valid on mobile
or desktop 64-bit processes.

## Android

`flutter build apk --release --no-pub` invokes the NDK through Gradle's externalNativeBuild,
using CMake 3.31.1. Gradle packages `libabc_engine.so` for the selected ABIs.
CI installs the pinned CMake distribution in an isolated Python environment and
sets Android's `cmake.dir` explicitly, so it does not depend on an SDK image
already containing that exact CMake version.
The release build has no signing configuration and produces an unsigned APK; no
production signing or Play Store publishing is configured. A local debug build
uses Android's normal development tooling.

## Linux

`flutter build linux --release` builds the engine and installs `libabc_engine.so`
in the application bundle's `lib` folder. The generated runner uses `$ORIGIN/lib`.
Install clang, CMake, Ninja, pkg-config, GTK 3 development files, and zlib development
files before building.

## macOS

The Runner's engine build phase calls `tool/build_apple_engine.sh`, builds each
architecture in Xcode's `ARCHS`, and copies `libabc_engine.dylib` to the app's
Frameworks folder. The Dart adapter loads that explicit bundle path.

CI uses `flutter build macos --release --config-only`, followed by `xcodebuild`
with `CODE_SIGNING_ALLOWED=NO`. It does not produce a signed distribution.
Sandbox access is limited to files selected by the user. The standard debug
Flutter JIT and debugger entitlements remain; release adds no network access.

## iOS

`flutter build ios --release --no-codesign` runs the CMake engine build for the
selected iOS SDK. The shim and TerraWasm static archives are merged into
`libabc_engine.a`, then force-loaded into Runner. The Dart adapter uses
`DynamicLibrary.process()`. The Xcode engine phase declares the archive as an
output, allowing the linker to wait for its producer. These unsigned builds
cannot be installed as App Store or signed device distributions without a
separately authorized signing workflow.

## Verification status

The CI workflow checks source/runtime integrity, formatting, static analysis,
Flutter tests, actual Web WLD/PLR, region and circuit contracts, and synthetic
native WLD/PLR and region round trips under ASan/UBSan. It regenerates the rules
from the distributed source, runs authoritative-source/Web parity, and replays
the same generated corpus through `flutter_js` 0.8.7 QuickJS plus the native FFI
engine. The Linux runtime smoke and full 15-demo bundle tests are mandatory.

Android, unsigned iOS/macOS, Linux and Web compilation are separate CI jobs.
Successful build jobs retain downloadable artifacts for 14 days, named with the
source head commit. Web and Linux are tar archives; Apple archives preserve app
bundle permissions and links. Android and Apple outputs remain unsigned. These
are CI build artifacts, not GitHub Releases or deployed applications.
Configured checks do not establish that a remote run has passed. A successful
compilation alone does not prove real-device FFI loading, sandbox dialogs, or game
save round trips; those need platform runtime testing. Public CI uses generated
synthetic fixtures and may skip explicitly private-resource tests. Local tests
with authorized real saves are separate evidence; their inputs and proof output
are not uploaded, and public CI must not be reported as a zero-skip private run.

Launcher icons are original generated TerraForge artwork; display names use
TerraForge. No production deployment, release publication, or signing credentials
are configured by this scaffold.
