#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="${1:-$ROOT/.build/verification/local/m1-ad-hoc/$(date -u +%Y%m%dT%H%M%SZ)-$$}"
SCRATCH="${M1_AD_HOC_SCRATCH:-$OUT/swiftpm}"
APP="$ROOT/build/Rascal.app"
BIN="$APP/Contents/MacOS/FinderTwo"
mkdir -p "$OUT"
cd "$ROOT"

[[ ! -e "$SCRATCH" ]] || {
    echo "M1-BUILD-001 requires a fresh scratch path: $SCRATCH" >&2
    exit 1
}

printf 'RASCAL_SECURITY_TOOL=/usr/bin/false SWIFT_SCRATCH_PATH=%q ./build.sh debug\n' "$SCRATCH" \
    > "$OUT/build.command"
set +e
RASCAL_SECURITY_TOOL=/usr/bin/false SWIFT_SCRATCH_PATH="$SCRATCH" ./build.sh debug \
    > "$OUT/build.stdout" 2> "$OUT/build.stderr"
BUILD_STATUS=$?
set -e
printf '%s\n' "$BUILD_STATUS" > "$OUT/build.exit"
if [[ "$BUILD_STATUS" != 0 ]]; then
    cat "$OUT/build.stdout" >&2
    cat "$OUT/build.stderr" >&2
    echo "M1-BUILD-001 build failed with exit $BUILD_STATUS" >&2
    exit "$BUILD_STATUS"
fi

[[ -d "$APP" && -x "$BIN" ]] || {
    echo "M1-BUILD-001 build returned success without a runnable bundle/binary" >&2
    exit 1
}

set +e
codesign --verify --deep --strict --verbose=4 "$APP" \
    > "$OUT/codesign-verify.stdout" 2> "$OUT/codesign-verify.stderr"
VERIFY_STATUS=$?
set -e
printf '%s\n' "$VERIFY_STATUS" > "$OUT/codesign-verify.exit"
[[ "$VERIFY_STATUS" == 0 ]] || {
    cat "$OUT/codesign-verify.stderr" >&2
    echo "M1-BUILD-001 codesign verification failed" >&2
    exit 1
}

codesign --display --verbose=4 "$APP" \
    > "$OUT/codesign-details.stdout" 2> "$OUT/codesign-details.stderr"
cat "$OUT/codesign-details.stdout" "$OUT/codesign-details.stderr" > "$OUT/codesign-details.txt"

grep -Fxq 'Signature=adhoc' "$OUT/codesign-details.txt" || {
    echo "M1-BUILD-001 expected Signature=adhoc" >&2
    exit 1
}
grep -Fxq 'TeamIdentifier=not set' "$OUT/codesign-details.txt" || {
    echo "M1-BUILD-001 expected TeamIdentifier=not set" >&2
    exit 1
}
grep -Fq 'ad-hoc signed' "$OUT/build.stdout" || {
    echo "M1-BUILD-001 build did not report the ad-hoc fallback" >&2
    exit 1
}

{
    shasum -a 256 "$BIN"
    find "$APP" -type f -print0 | sort -z | xargs -0 shasum -a 256
} > "$OUT/bundle-content.sha256"
find "$OUT" -type f -not -name evidence.sha256 -print0 | sort -z | xargs -0 shasum -a 256 \
    > "$OUT/evidence.sha256"

echo "M1-BUILD-001 PASS binary=$(shasum -a 256 "$BIN" | awk '{print $1}') evidence=$OUT"
