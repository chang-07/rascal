#!/usr/bin/env bash
# Runs Rascal's in-process test runner. The app is launched with
# FT_RUN_TESTS=1 (which makes it skip opening the default window and
# instead execute the TestRunner harness) and FT_HEADLESS_TESTING=1
# (which keeps any windows the harness creates far off-screen, so this
# never disrupts your foreground work).
#
# Exit code = number of failed assertions.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/build/Rascal.app"
BIN="$APP/Contents/MacOS/FinderTwo"

if [[ ! -x "$BIN" ]]; then
    echo "Binary not built. Run ./build.sh first."
    exit 1
fi

pkill -f "$BIN" 2>/dev/null || true
sleep 0.3

FT_RUN_TESTS=1 FT_HEADLESS_TESTING=1 "$BIN"
