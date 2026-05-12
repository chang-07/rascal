#!/usr/bin/env bash
# Build then launch the .app
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
"$ROOT/build.sh" debug
open -n "$ROOT/build/FinderTwo.app"
