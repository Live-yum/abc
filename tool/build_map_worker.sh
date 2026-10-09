#!/usr/bin/env bash
set -euo pipefail
# Uses the same pinned Dart/Flutter SDK as the application, with no downloads.
cd "$(dirname "$0")/.."
dart --suppress-analytics compile js -O2 --no-source-maps tool/map_worker.dart -o web/engine/map_worker.js
