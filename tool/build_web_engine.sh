#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE="${ABC_TERRA_SOURCE:-$ROOT/native/vendor/TerraWasm}"
OUTPUT="${ABC_WEB_OUTPUT:-$ROOT/build/engine-web}"
REVISION=e2c3c817b2b482a535763695d19945971e19e41c
if [[ ! -f "$SOURCE/include/terra_world.h" ]]; then
  echo 'Missing authorized TerraWasm source. Set ABC_TERRA_SOURCE.' >&2
  exit 1
fi
command -v emcmake >/dev/null || { echo 'Install official Emscripten 5.0.7 and activate its environment.' >&2; exit 1; }
mkdir -p "$OUTPUT"
for KIND in wld plr; do
  NAME=world; [[ "$KIND" == plr ]] && NAME=player
  BUILD="$ROOT/build/wasm-$KIND"
  emcmake cmake -S "$SOURCE" -B "$BUILD" -DCMAKE_BUILD_TYPE=Release \
    -DABC_HOST_WRAPPERS="$ROOT/native" -DTERRAWASM_FEATURE_SET="$KIND" -DTERRAX_BUILD_COMMIT="$REVISION" -DTERRAX_BUILD_DIRTY=true
  cmake --build "$BUILD" --target terrax_world_wasm_web --parallel 4
  cp "$BUILD/terrax_world_wasm_web.js" "$OUTPUT/$NAME.js"
  cp "$BUILD/terrax_world_wasm_web.wasm" "$OUTPUT/$NAME.wasm"
done
python3 - "$OUTPUT" "$REVISION" "$SOURCE" <<'PY'
import hashlib,json,pathlib,sys
root=pathlib.Path(sys.argv[1])
source=pathlib.Path(sys.argv[3])
result={'sourceCommit':sys.argv[2],'emscripten':'5.0.7','localPatches':['64-bit-pointer-safety','persistent-allocation-lifetime','native-zlib-bridge','abc-host-integration'],'artifacts':{}}
source_manifest=source/'SOURCE_MANIFEST.json'
if source_manifest.is_file():
    result['sourceManifestSha256']=hashlib.sha256(source_manifest.read_bytes()).hexdigest()
for name in ['world.js','world.wasm','player.js','player.wasm']:
    data=(root/name).read_bytes(); result['artifacts'][name]={'bytes':len(data),'sha256':hashlib.sha256(data).hexdigest()}
(root/'manifest.json').write_text(json.dumps(result,indent=2)+'\n')
PY
printf 'Engine outputs: %s\n' "$OUTPUT"
