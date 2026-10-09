#!/usr/bin/env bash
set -euo pipefail
# Use a Flutter 3.47.6 installation on PATH; the repository never downloads SDKs implicitly.
exec flutter "$@"
