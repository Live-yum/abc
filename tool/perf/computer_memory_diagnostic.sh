#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
# Invoke once, in the existing Xvfb UI job after its original bundle is archived.
exec python3 tool/perf/computer_memory_run.py "${1:?A new diagnostic report path is required}"
