#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."

# Run inside xvfb-run on a CI Linux host, or name a connected physical device.
# Never substitute flutter test: its fake clock cannot measure UI fluidity.
device="${1:-linux}"
output="${2:-build/perf/ui-profile.json}"
flutter_bin="${FLUTTER_BIN:-flutter}"
iterations="${TERRA_PERF_ITERATIONS:-8}"
warmup="${TERRA_PERF_WARMUP:-2}"
expected_version="$(cat .flutter-version)"
version="$("$flutter_bin" --no-version-check --suppress-analytics --version --machine | python3 -c 'import json,sys; print(json.load(sys.stdin)["frameworkVersion"])')"
if [[ "$version" != "$expected_version" ]]; then
  printf 'Flutter version mismatch: expected %s, observed %s\n' "$expected_version" "$version" >&2
  exit 1
fi
if ! checked_out_head="$(git rev-parse --verify HEAD 2>/dev/null)"; then
  printf '%s\n' 'Profile acceptance requires a committed Git snapshot; an unborn local tree is debug-smoke only.' >&2
  exit 1
fi
commit="${ABC_PERF_COMMIT:-${GITHUB_SHA:-$checked_out_head}}"
worktree_dirty=false
if [[ -n "$(git status --porcelain --untracked-files=normal)" ]]; then
  worktree_dirty=true
fi
renderer="${TERRA_PERF_RENDERER:-unspecified}"
runner="${TERRA_PERF_RUNNER:-local-$device}"
mkdir -p "$(dirname "$output")"
export TERRA_UI_PROFILE_OUTPUT="$output"

"$flutter_bin" --no-version-check --suppress-analytics drive \
  --no-pub --profile -d "$device" \
  --driver=test_driver/ui_profile_driver.dart \
  --target=integration_test/ui_profile_test.dart \
  --dart-define="PERF_ITERATIONS=$iterations" \
  --dart-define="PERF_WARMUP=$warmup" \
  --dart-define="PERF_TRACE_TIMELINE=${TERRA_PERF_TRACE_TIMELINE:-false}" \
  --dart-define="PERF_FLUTTER_VERSION=$version" \
  --dart-define="PERF_COMMIT=$commit" \
  --dart-define="PERF_CHECKED_OUT_HEAD=$checked_out_head" \
  --dart-define="PERF_WORKTREE_DIRTY=$worktree_dirty" \
  --dart-define="PERF_RENDERER=$renderer" \
  --dart-define="PERF_RUNNER=$runner"

python3 tool/perf/ui_validate.py "$output"
