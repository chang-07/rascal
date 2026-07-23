#!/usr/bin/env bash
set -euo pipefail

readonly PYTHON_BIN=/usr/bin/python3
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HEAD_OID="$(git -C "$ROOT" rev-parse HEAD)"
RUN_ID="${RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)-$$}"
OUT="${1:-$ROOT/.build/verification/$HEAD_OID/m2-deferred-disabled/$RUN_ID}"
SCRATCH="$ROOT/.build/verification-scratch/$HEAD_OID/m2-deferred-disabled/$RUN_ID"
TEMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/rascal-m2-deferred.XXXXXX")"
mkdir -p "$OUT" "$SCRATCH"

CASE_MOUNT=""
EXFAT_MOUNT=""
cleanup() {
    local status=$?
    trap - EXIT
    if [[ -n "$EXFAT_MOUNT" ]]; then
        hdiutil detach "$EXFAT_MOUNT" -force >/dev/null 2>&1 || true
    fi
    if [[ -n "$CASE_MOUNT" ]]; then
        hdiutil detach "$CASE_MOUNT" -force >/dev/null 2>&1 || true
    fi
    rm -rf "$TEMP_ROOT"
    printf '%s\n' "$status" > "$OUT/lane.exit"
    find "$OUT" -type f -not -name evidence.sha256 -print0 \
        | sort -z | xargs -0 shasum -a 256 > "$OUT/evidence.sha256"
    exit "$status"
}
trap cleanup EXIT

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

mount_image() {
    local image="$1" plist="$2" owners="$3"
    hdiutil attach -nobrowse -owners "$owners" -plist "$image" > "$plist"
    "$PYTHON_BIN" - "$plist" <<'PY'
import plistlib
import sys
with open(sys.argv[1], "rb") as handle:
    payload = plistlib.load(handle)
mounts = [entity.get("mount-point") for entity in payload.get("system-entities", [])]
mounts = [mount for mount in mounts if mount]
if len(mounts) != 1:
    raise SystemExit(f"expected one mount point, got {mounts}")
print(mounts[0])
PY
}

hdiutil create -size 96m -fs "Case-sensitive APFS" -volname RASCAL_M2_CASE_SENSITIVE \
    "$TEMP_ROOT/case-sensitive.dmg" > "$OUT/case-sensitive-create.txt"
hdiutil create -size 256m -fs ExFAT -volname RASCALM2 \
    "$TEMP_ROOT/exfat.dmg" > "$OUT/exfat-create.txt"

CASE_MOUNT="$(mount_image "$TEMP_ROOT/case-sensitive.dmg" "$OUT/case-sensitive-attach.plist" on)"
EXFAT_MOUNT="$(mount_image "$TEMP_ROOT/exfat.dmg" "$OUT/exfat-attach.plist" off)"
diskutil info -plist "$CASE_MOUNT" > "$OUT/case-sensitive-info.plist"
diskutil info -plist "$EXFAT_MOUNT" > "$OUT/exfat-info.plist"

"$PYTHON_BIN" - "$CASE_MOUNT" "$EXFAT_MOUNT" \
    "$OUT/case-sensitive-info.plist" "$OUT/exfat-info.plist" \
    "$OUT/volume-proofs.tsv" <<'PY'
import os
import pathlib
import plistlib
import sys

case_root = pathlib.Path(sys.argv[1])
exfat_root = pathlib.Path(sys.argv[2])
with open(sys.argv[3], "rb") as handle:
    case_info = plistlib.load(handle)
with open(sys.argv[4], "rb") as handle:
    exfat_info = plistlib.load(handle)
if (case_info.get("FilesystemType") or case_info.get("Type (Bundle)")) != "apfs":
    raise SystemExit("case-sensitive fixture is not APFS")
if (exfat_info.get("FilesystemType") or exfat_info.get("Type (Bundle)")) != "exfat":
    raise SystemExit("ExFAT fixture is not ExFAT")

lower = case_root / "rascal-case-proof"
upper = case_root / "RASCAL-CASE-PROOF"
lower.write_text("lower")
upper.write_text("upper")
if lower.read_text() != "lower" or upper.read_text() != "upper":
    raise SystemExit("APFS fixture did not preserve distinct case-only names")

pathlib.Path(sys.argv[5]).write_text(
    "label\tfilesystem\truntime_proof\n"
    "case-sensitive-apfs\tapfs\tcase-only sibling files are distinct\n"
    "exfat\texfat\tdiskutil filesystem identity\n"
)
PY

cd "$ROOT"
printf '%q ' swift test --disable-sandbox --scratch-path "$SCRATCH/swift-tests" \
    --filter NativeCopyIntegrationTests/testConfiguredDeferredVolumesRemainDisabled \
    > "$OUT/swift-test.command"
printf '\n' >> "$OUT/swift-test.command"
RASCAL_M2_CASE_SENSITIVE_SOURCE="$CASE_MOUNT" \
RASCAL_M2_EXFAT_SOURCE="$EXFAT_MOUNT" \
swift test --disable-sandbox --scratch-path "$SCRATCH/swift-tests" \
    --filter NativeCopyIntegrationTests/testConfiguredDeferredVolumesRemainDisabled \
    > "$OUT/swift-test.stdout" 2> "$OUT/swift-test.stderr"
grep -F "Executed 1 test, with 0 failures" "$OUT/swift-test.stdout" >/dev/null
if grep -F "skipped" "$OUT/swift-test.stdout" >/dev/null; then
    echo "deferred-disabled runtime test reported a skip" >&2
    exit 1
fi

SWIFT_SCRATCH_PATH="$SCRATCH/app-build" bash "$ROOT/build.sh" debug \
    > "$OUT/app-build.stdout" 2> "$OUT/app-build.stderr"
APP="$ROOT/build/Rascal.app"
codesign --verify --deep --strict --verbose=2 "$APP" \
    > "$OUT/app-codesign.stdout" 2> "$OUT/app-codesign.stderr"
shasum -a 256 "$APP/Contents/MacOS/FinderTwo" > "$OUT/app-binary.sha256"

printf 'open -n -W -o %q --stderr %q --env FT_M2_DEFERRED_PROBE=1 --env FT_HEADLESS_TESTING=1 --env RASCAL_ENABLE_M2_NATIVE_COPY=1 --env RASCAL_ENABLE_LEGACY_WRITES=1 --env RASCAL_M2_CASE_SENSITIVE_SOURCE=%q --env RASCAL_M2_EXFAT_SOURCE=%q %q\n' \
    "$OUT/ui-probe.stdout" "$OUT/ui-probe.stderr" \
    "$CASE_MOUNT" "$EXFAT_MOUNT" "$APP" > "$OUT/ui-probe.command"
open -n -W \
    -o "$OUT/ui-probe.stdout" \
    --stderr "$OUT/ui-probe.stderr" \
    --env FT_M2_DEFERRED_PROBE=1 \
    --env FT_HEADLESS_TESTING=1 \
    --env RASCAL_ENABLE_M2_NATIVE_COPY=1 \
    --env RASCAL_ENABLE_LEGACY_WRITES=1 \
    --env RASCAL_M2_CASE_SENSITIVE_SOURCE="$CASE_MOUNT" \
    --env RASCAL_M2_EXFAT_SOURCE="$EXFAT_MOUNT" \
    "$APP"

grep -Fxq 'M2_DEFERRED_PROBE PASS volumes=2 routes=12 native=12 legacy=0 finals=0' \
    "$OUT/ui-probe.stderr"

echo "M2-CSAPFS-001 M2-EXFAT-001 deferred-disabled PASS evidence=$OUT"
