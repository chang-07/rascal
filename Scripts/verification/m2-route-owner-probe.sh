#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/Scripts/verification/m2-evidence-common.sh"
HEAD_OID="$(git -C "$ROOT" rev-parse HEAD)"
RUN_ID="${RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)-$$}"
OUT="${1:-$ROOT/.build/verification/$HEAD_OID/m2-route-owner/$RUN_ID}"
SCRATCH="$ROOT/.build/verification-scratch/$HEAD_OID/m2-route-owner/$RUN_ID"
mkdir -p "$OUT" "$SCRATCH"

finish() {
    local status=$?
    trap - EXIT
    if ! m2_capture_end_and_compare "$ROOT" "$OUT"; then
        echo "M2 evidence source state changed during route-owner lane" >&2
        status=1
    fi
    printf '%s\n' "$status" > "$OUT/lane.exit"
    find "$OUT" -type f -not -name evidence.sha256 -print0 \
        | sort -z | xargs -0 shasum -a 256 > "$OUT/evidence.sha256"
    exit "$status"
}
trap finish EXIT

git -C "$ROOT" rev-parse HEAD > "$OUT/head.txt"
git -C "$ROOT" status --porcelain=v2 --untracked-files=all > "$OUT/git-status-v2.txt"
git -C "$ROOT" diff --binary > "$OUT/unstaged.diff"
git -C "$ROOT" diff --cached --binary > "$OUT/staged.diff"
shasum -a 256 "$OUT/unstaged.diff" > "$OUT/unstaged-diff.sha256"
shasum -a 256 "$OUT/staged.diff" > "$OUT/staged-diff.sha256"
: > "$OUT/untracked-content.sha256"
while IFS= read -r -d '' path; do
    shasum -a 256 "$ROOT/$path" >> "$OUT/untracked-content.sha256"
done < <(git -C "$ROOT" ls-files --others --exclude-standard -z | sort -z)
sw_vers > "$OUT/os.txt"
xcodebuild -version > "$OUT/xcode.txt"
swift --version > "$OUT/swift.txt"

SWIFT_SCRATCH_PATH="$SCRATCH/app-build" bash "$ROOT/build.sh" debug \
    > "$OUT/app-build.stdout" 2> "$OUT/app-build.stderr"
APP="$ROOT/build/Rascal.app"
codesign --verify --deep --strict --verbose=2 "$APP" \
    > "$OUT/app-codesign.stdout" 2> "$OUT/app-codesign.stderr"
shasum -a 256 "$APP/Contents/MacOS/FinderTwo" > "$OUT/app-binary.sha256"

set +e
m2_run_timed "$OUT" ui-probe 180 \
    /usr/bin/env \
    FT_M2_ROUTE_PROBE=1 \
    FT_HEADLESS_TESTING=1 \
    RASCAL_ENABLE_M2_NATIVE_COPY=1 \
    "$APP/Contents/MacOS/FinderTwo"
status=$?
set -e
if [[ "$status" != 0 ]]; then
    cat "$OUT/ui-probe.stdout" >&2
    cat "$OUT/ui-probe.stderr" >&2
    exit "$status"
fi

grep -Fxq '  ✓ M2 six copy routes complete' "$OUT/ui-probe.stdout"
grep -Fxq '  ✓ M2 one unique OperationID per route' "$OUT/ui-probe.stdout"
grep -Fxq '  ✓ M2 native routes enqueue zero legacy operations' "$OUT/ui-probe.stdout"
grep -Fxq '  ✓ M2 fast terminal registers then converges one refresh' "$OUT/ui-probe.stdout"
grep -Fxq '  ✓ M2 partial commit failure refreshes exactly once' "$OUT/ui-probe.stdout"
grep -Fxq '  ✓ M2 stale snapshot cannot regress terminal projection' "$OUT/ui-probe.stdout"
grep -Fxq '  ✓ M2 unavailable copy has one bridge presentation owner' "$OUT/ui-probe.stdout"
grep -Fxq '=== 7 passed, 0 failed ===' "$OUT/ui-probe.stdout"
if grep -Eiq '(^|[^[:alpha:]])skip(ped)?([^[:alpha:]]|$)' "$OUT/ui-probe.stdout"; then
    echo "M2 route-owner probe reported a skip" >&2
    exit 1
fi

echo "M2-ROUTE-OWNER-001 M2-REFRESH-001 PASS evidence=$OUT"
