#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
exec "${NODE_BIN:-node}" tool/preview_server.mjs build/web
