#!/bin/bash
# Xcode build phase. No signing, downloads, or remote access.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
source_dir="${ABC_TERRA_SOURCE:-$root/native/vendor/TerraWasm}"
if [[ ! -f "$source_dir/include/terra_world.h" ]]; then
  echo "error: Authorized TerraWasm source missing: $source_dir. Set ABC_TERRA_SOURCE for local development." >&2
  exit 1
fi
command -v cmake >/dev/null || { echo 'error: CMake 3.27 or later is required.' >&2; exit 1; }
platform="${PLATFORM_NAME:?Xcode PLATFORM_NAME required}"
configuration="${CONFIGURATION:-Release}"
build_dir="$root/build/native-apple/$platform/$configuration"
archs="${ARCHS// /;}"
args=(-S "$root/native" -B "$build_dir" -DABC_TERRA_SOURCE="$source_dir" -DCMAKE_BUILD_TYPE="$configuration" -DCMAKE_OSX_ARCHITECTURES="$archs" -DCMAKE_OSX_SYSROOT="$SDKROOT")
case "$platform" in
  iphoneos|iphonesimulator)
    args+=(-DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_DEPLOYMENT_TARGET="${IPHONEOS_DEPLOYMENT_TARGET:-13.0}")
    cmake "${args[@]}"
    cmake --build "$build_dir" --target abc_engine --parallel 2
    mkdir -p "$BUILT_PRODUCTS_DIR"
    /usr/bin/libtool -static -o "$BUILT_PRODUCTS_DIR/libabc_engine.a" "$build_dir/libabc_engine.a" "$build_dir/terra/libterrax_world_static.a"
    ;;
  macosx)
    args+=(-DCMAKE_OSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-10.15}")
    cmake "${args[@]}"
    cmake --build "$build_dir" --target abc_engine --parallel 2
    destination="$TARGET_BUILD_DIR/$FRAMEWORKS_FOLDER_PATH"
    mkdir -p "$destination"
    cp "$build_dir/libabc_engine.dylib" "$destination/libabc_engine.dylib"
    /usr/bin/install_name_tool -id '@rpath/libabc_engine.dylib' "$destination/libabc_engine.dylib"
    ;;
  *) echo "error: Unsupported Apple platform $platform" >&2; exit 1 ;;
esac
