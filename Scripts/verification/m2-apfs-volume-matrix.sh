#!/usr/bin/env bash
set -euo pipefail

readonly PYTHON_BIN=/usr/bin/python3
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/Scripts/verification/m2-evidence-common.sh"
HEAD_OID="$(git -C "$ROOT" rev-parse HEAD)"
RUN_ID="${RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)-$$}"
OUT="${1:-$ROOT/.build/verification/$HEAD_OID/m2-apfs/$RUN_ID}"
SCRATCH="$ROOT/.build/verification-scratch/$HEAD_OID/m2-apfs/$RUN_ID"
TEMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/rascal-m2-apfs.XXXXXX")"
mkdir -p "$OUT" "$SCRATCH"

SOURCE_MOUNT=""
DESTINATION_MOUNT=""
cleanup() {
    local status=$?
    trap - EXIT
    if [[ -n "$DESTINATION_MOUNT" ]]; then
        hdiutil detach "$DESTINATION_MOUNT" -force >/dev/null 2>&1 || true
    fi
    if [[ -n "$SOURCE_MOUNT" ]]; then
        hdiutil detach "$SOURCE_MOUNT" -force >/dev/null 2>&1 || true
    fi
    rm -rf "$TEMP_ROOT"
    if ! m2_capture_end_and_compare "$ROOT" "$OUT"; then
        echo "M2 evidence source state changed during APFS lane" >&2
        status=1
    fi
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
printf '%q ' swift test --disable-sandbox --scratch-path "$SCRATCH" \
    --filter NativeCopyIntegrationTests/testConfiguredDistinctAPFSVolumeMatrix \
    > "$OUT/apfs-test.command"
printf '\n' >> "$OUT/apfs-test.command"
printf '%q ' swift test --disable-sandbox --scratch-path "$SCRATCH" \
    --filter NativeCopyIntegrationTests/testConfiguredRealAPFSNoSpaceLeavesNoPartialFinal \
    > "$OUT/enospc-test.command"
printf '\n' >> "$OUT/enospc-test.command"

mount_image() {
    local image="$1" plist="$2"
    hdiutil attach -nobrowse -owners on -plist "$image" > "$plist"
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

hdiutil create -size 256m -fs APFS -volname RASCAL_M2_SOURCE \
    "$TEMP_ROOT/source.dmg" > "$OUT/source-create.txt"
hdiutil create -size 256m -fs APFS -volname RASCAL_M2_DESTINATION \
    "$TEMP_ROOT/destination.dmg" > "$OUT/destination-create.txt"

SOURCE_MOUNT="$(mount_image "$TEMP_ROOT/source.dmg" "$OUT/source-attach.plist")"
DESTINATION_MOUNT="$(mount_image "$TEMP_ROOT/destination.dmg" "$OUT/destination-attach.plist")"

diskutil info -plist "$SOURCE_MOUNT" > "$OUT/source-info.plist"
diskutil info -plist "$DESTINATION_MOUNT" > "$OUT/destination-info.plist"
"$PYTHON_BIN" - "$OUT/source-info.plist" "$OUT/destination-info.plist" \
    "$OUT/volume-identities.tsv" <<'PY'
import pathlib
import plistlib
import sys

records = []
for label, path in zip(("source", "destination"), sys.argv[1:3]):
    with open(path, "rb") as handle:
        info = plistlib.load(handle)
    filesystem = info.get("FilesystemType") or info.get("Type (Bundle)")
    uuid = info.get("VolumeUUID")
    if filesystem != "apfs" or not uuid:
        raise SystemExit(f"{label} is not identified APFS: fs={filesystem} uuid={uuid}")
    records.append((label, uuid, filesystem, info.get("MountPoint", "")))
if records[0][1] == records[1][1]:
    raise SystemExit("source and destination APFS UUIDs are identical")
pathlib.Path(sys.argv[3]).write_text(
    "label\tuuid\tfilesystem\tmount\n" +
    "\n".join("\t".join(record) for record in records) + "\n"
)
PY

cd "$ROOT"
RASCAL_M2_APFS_SOURCE="$SOURCE_MOUNT" \
RASCAL_M2_APFS_DESTINATION="$DESTINATION_MOUNT" \
RASCAL_M2_METADATA_EVIDENCE_DIR="$OUT" \
swift test --disable-sandbox --scratch-path "$SCRATCH" \
    --filter NativeCopyIntegrationTests/testConfiguredDistinctAPFSVolumeMatrix \
    > "$OUT/swift-test.stdout" 2> "$OUT/swift-test.stderr"

grep -F "Executed 1 test, with 0 failures" "$OUT/swift-test.stdout" >/dev/null
if grep -F "skipped" "$OUT/swift-test.stdout" >/dev/null; then
    echo "APFS matrix test reported a skip" >&2
    exit 1
fi

[[ -s "$OUT/metadata-paths.tsv" ]] || {
    echo "APFS matrix did not emit metadata proof paths" >&2
    exit 1
}
metadata_count=0
while IFS=$'\t' read -r label source_path destination_path; do
    [[ -n "$label" && -n "$source_path" && -n "$destination_path" ]] || {
        echo "invalid metadata proof row" >&2
        exit 1
    }
    bash "$ROOT/Scripts/verification/metadata-manifest.sh" \
        "$source_path" "$destination_path" "$OUT/metadata-$label" \
        > "$OUT/metadata-$label.stdout" 2> "$OUT/metadata-$label.stderr"
    grep -Fxq 'M2-META-001 PASS' "$OUT/metadata-$label/comparison.txt"
    ((metadata_count += 1))
done < "$OUT/metadata-paths.tsv"
[[ "$metadata_count" == 6 ]] || {
    echo "expected six independent metadata comparisons, got $metadata_count" >&2
    exit 1
}

RASCAL_M2_APFS_SOURCE="$SOURCE_MOUNT" \
RASCAL_M2_APFS_DESTINATION="$DESTINATION_MOUNT" \
RASCAL_M2_REAL_ENOSPC=1 \
swift test --disable-sandbox --scratch-path "$SCRATCH" \
    --filter NativeCopyIntegrationTests/testConfiguredRealAPFSNoSpaceLeavesNoPartialFinal \
    > "$OUT/enospc-test.stdout" 2> "$OUT/enospc-test.stderr"
grep -F "Executed 1 test, with 0 failures" "$OUT/enospc-test.stdout" >/dev/null
if grep -F "skipped" "$OUT/enospc-test.stdout" >/dev/null; then
    echo "real ENOSPC test reported a skip" >&2
    exit 1
fi
echo "M2-APFS-001 M2-ENOSPC-001 PASS evidence=$OUT"
