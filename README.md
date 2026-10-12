# TerraForge · 泰拉工坊

Flutter reconstruction of the TerraForge desktop/mobile prototype, targeting Android, iOS, macOS and Web. Flutter **3.47.6** / Dart **3.13.5** is pinned to official Flutter revision `5fc346839b5d0eef006ed8404392afb4dfae428d`.

## Current delivery status

This is a substantial local implementation, **not a completed feature-equivalent release**. Real WLD/PLR parsing, edits and candidate read-back use TerraWasm. Binary exploration MAP import/edit/export has a separate bounded codec and owner. See [the capability and evidence matrix](docs/feature-matrix.md) for what works and what remains unverified.

[PR #1](https://github.com/Live-yum/abc/pull/1) was merged. Follow-up development is tracked in [draft PR #2](https://github.com/Live-yum/abc/pull/2). Functional build success does not establish complete performance, memory stability or real-device frame-rate acceptance.

The circuit laboratory imports supported WLD files as generic wiring worlds. It locates actual wiring, exposes ordinary device/line controls, and displays a selected native PixelBox region. No sample CPU, ROM program, fixed monitor coordinates or keyboard mapping is selected by a file hash. Computerraria is an explicit [test fixture](docs/COMPUTERRARIA.md), not an application mode. The [generic circuit contract](docs/WORLD_CIRCUIT_SUPPORT.md) explains supported operations and missing game simulation.

The repository includes the authorized minimal TerraWasm source, required embedded compatibility tables, the retained viewer circuit rules source and verified generated JavaScript/WASM runtimes. A fresh checkout builds without access to the upstream private repositories. Source revisions, local engine patches and integrity manifests are documented in [third-party notices](THIRD_PARTY_NOTICES.md); inclusion grants no new upstream license. Game textures, game executables and personal saves are excluded.

## Development

```sh
flutter pub get --enforce-lockfile
npm ci
npm run verify:sources
flutter analyze
flutter test --no-pub
flutter run -d chrome
```

Use the pinned Flutter version, not a floating stable channel. Local file import/export follows the platform picker; mobile exports use the system share sheet. Always verify the final destination. Originals are retained separately and edits are validated before becoming the active save.

### Authorized native engine

The pointer-safe patched TerraWasm source is included at `native/vendor/TerraWasm`, the default source path for every native target. An optional `ABC_TERRA_SOURCE` override can select another authorized development checkout. The original upstream WASM-oriented pointer ABI is not safe to reuse unchanged on 64-bit native platforms.

```sh
cmake -S native -B build/native -DCMAKE_BUILD_TYPE=Release
cmake --build build/native --parallel
TERRAFORGE_ENGINE_LIBRARY="$PWD/build/native/libabc_engine.so" flutter test --no-pub
```

### Authorized Web engine

Install and activate official Emscripten 5.0.7, then:

```sh
ABC_WEB_OUTPUT="$PWD/web/engine" bash tool/build_web_engine.sh
npm run build:circuit-rules
flutter build web --release --no-pub --no-web-resources-cdn
```

The approved `web/engine` artifacts are included with integrity provenance. The build also writes `web/engine/manifest.json`; rebuilds use the vendored engine and circuit source subsets. Run `npm run build:circuit-rules` to regenerate native and Web rules using pinned esbuild 0.20.1. Serve `build/web` over HTTP, not `file://`. `tool/preview_server.mjs` is a loopback-only development server. No deployment is performed.

## Resources and cloud

[Local resource packs](docs/LOCAL_RESOURCE_PACKS.md) are imported explicitly. The repository includes no Terraria atlas images or private catalog dumps. Missing resources are represented explicitly, never silently downloaded. [Cloud clients](docs/cloud-provider.md) implement the source-verified private-save, recommendation, profile, help and generation contracts, including durable local adoption and account-scoped recovery. A supported cross-platform initial login and live service verification remain unavailable; no credentials or production endpoint are embedded. Mock contracts do not establish compatibility with an actual account.

[Approved online resources](docs/ONLINE_RESOURCES.md) can be installed from an explicitly configured HTTPS resource origin. Downloads are manifest-pinned, recoverable, and activated atomically; offline caches retain approval and revocation checks. Public manifests are normalized into ABCPACK1 without inventing missing supplemental catalogs.

## Safety and verification

- Separate immutable original bytes, bounded undo history, detached candidate read-back and failed-operation recovery.
- Version changes require a verified compatibility profile, difference review and explicit confirmation. Generic JSON version edits are blocked.
- Complete region objects carry chest inventories, signs and supported tile-entity records. Unsafe partial-object and structural replacements are rejected.
- World-map viewports can load real wire/liquid overlays; environment rules preview and confirm an undoable Fusion transformation before world writing.
- Searchable typed world properties protect structural fields and unsupported versions.
- Full-world circuit sessions use the actual engine; the small circuit sandbox is a separate feature.
- [Binary MAP](docs/MAP_FORMAT.md) supports legacy versions 135–319 and chunked version 315, bounded light/paint editing and verified export. Native isolates and Web workers retain full grids; MAP generated from a real WLD is distinct from a user's original exploration save.
- [Web computation workers](docs/web-computation-workers.md) own the document, whole-world circuit and traversal engines alongside the existing region/rules/MAP workers. Node worker contracts do not establish browser frame rate.
- Persistent local vault, recoverable trash, explicit restore; no permanent purge operation.
- Synthetic QA fixtures are generated by this project. QA buttons require `--dart-define=TERRAFORGE_QA=true`; production defaults off.

See [platform build notes](docs/platform-builds.md), [migration plan](docs/migration-plan.md), [region contracts](docs/REGION_ENGINE.md), and [world circuit support](docs/WORLD_CIRCUIT_SUPPORT.md). CI checks the distributed sources, native ASan/UBSan contracts, source/Web/native JavaScript parity, and unsigned platform builds. Only a completed run verifies its named commit; platform builds do not verify target-device behavior. [Performance harnesses](tool/perf/README.md) record diagnostic workloads, with profile/release browser and physical-device acceptance still pending. Private-resource tests may skip in public CI because personal saves and game resources are excluded. A passing read-back test is not an in-game compatibility certification.
