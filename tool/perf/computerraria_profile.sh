#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."

# This process owns an actual Flutter profile app. A widget/debug test cannot
# replace its engine FrameTiming, VM heap or wall-clock observations.
output="${1:?A new report path is required}"
flutter_bin="${FLUTTER_BIN:-flutter}"
: "${COMPUTERRARIA_WLD:?Explicit pinned public WLD is required}"
: "${COMPUTERRARIA_TWLD:?Explicit pinned public TWLD is required}"
: "${TERRA_PERF_RENDERER:?Observed glxinfo renderer is required}"
version="$("$flutter_bin" --no-version-check --suppress-analytics --version --machine | python3 -c 'import json,sys; print(json.load(sys.stdin)["frameworkVersion"])')"
test "$version" = "$(cat .flutter-version)"
head="$(git rev-parse --verify HEAD)"
commit="${ABC_PERF_COMMIT:-$head}"
test "$commit" = "$head"
test -z "$(git status --porcelain --untracked-files=normal)"
test ! -e "$output"
mkdir -p "$(dirname "$output")"
export TERRA_UI_PROFILE_OUTPUT="$output"
export TERRA_UI_PROFILE_STANDALONE_OUTPUT="${output%.json}.standalone.json"

"$flutter_bin" --no-version-check --suppress-analytics drive \
  --no-pub --profile -d linux \
  --driver=test_driver/ui_profile_driver.dart \
  --target=integration_test/computer_world_profile_test.dart \
  --dart-define=COMPUTERRARIA_PROFILE_CYCLES=2 \
  --dart-define=COMPUTERRARIA_PROFILE_SECONDS=30 \
  --dart-define="PERF_FLUTTER_VERSION=$version" \
  --dart-define="PERF_COMMIT=$commit" \
  --dart-define="PERF_CHECKED_OUT_HEAD=$head" \
  --dart-define=PERF_WORKTREE_DIRTY=false \
  --dart-define="PERF_RENDERER=$TERRA_PERF_RENDERER" \
  --dart-define="PERF_RUNNER=${TERRA_PERF_RUNNER:-local-linux-xvfb}"

python3 tool/perf/computerraria_provenance.py \
  --artifact build/linux/x64/profile/bundle/terraforge \
  --artifact build/linux/x64/profile/bundle/lib/libabc_engine.so \
  --artifact build/linux/x64/profile/bundle/lib/libapp.so \
  --cmake-cache build/linux/x64/profile/CMakeCache.txt \
  --ninja-build build/linux/x64/profile/build.ninja \
  --output "${output%.json}.build.json"
