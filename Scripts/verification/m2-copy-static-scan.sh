#!/usr/bin/env bash
set -euo pipefail

readonly PYTHON_BIN=/usr/bin/python3
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HEAD_OID="$(git -C "$ROOT" rev-parse HEAD)"
RUN_ID="${RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)-$$}"
OUT="${1:-$ROOT/.build/verification/$HEAD_OID/m2-copy-static/$RUN_ID}"
RELEASE_TARGET="${2:-}"
mkdir -p "$OUT"

finish() {
    local status=$?
    trap - EXIT
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

"$PYTHON_BIN" - "$ROOT" "$OUT/report.tsv" <<'PY'
import pathlib
import re
import sys

root = pathlib.Path(sys.argv[1])
report = pathlib.Path(sys.argv[2])

def read(relative):
    return (root / relative).read_text()

def uncomment(text):
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    return re.sub(r"//.*", "", text)

composition = read("Sources/FinderTwo/Integration/FileOperationCompositionRoot.swift")
bridge = read("Sources/FinderTwo/Integration/FileOperationBridge.swift")
file_ops = read("Sources/FinderTwo/FS/FileOps.swift")
pane = read("Sources/FinderTwo/UI/PaneController.swift")
file_list = read("Sources/FinderTwo/UI/FileListController.swift")
panes = read("Sources/FinderTwo/Window/PanesContainerController.swift")
drop_stack = read("Sources/FinderTwo/UI/DropStackController.swift")
browser = read("Sources/FinderTwo/Window/BrowserWindowController.swift")
app = read("Sources/FinderTwo/AppDelegate.swift")
legacy_gate = read("Sources/FinderTwo/FS/LegacyWriteGate.swift")

checks = []
def require(label, condition, detail):
    if not condition:
        raise SystemExit(f"{label} FAIL: {detail}")
    checks.append((label, "PASS", detail))

clean_composition = uncomment(composition)
require("M2-RELEASE-DISABLED-001",
        "#if DEBUG" in composition and
        'environment["RASCAL_ENABLE_M2_NATIVE_COPY"] == "1"' in composition and
        re.search(r"#else\s*false\s*#endif", composition) is not None,
        "native copy gate is exact debug-only env=1")
require("M2-COMPOSITION-001",
        clean_composition.count("FileOperationService.makeVolatileNativeCopy()") == 1 and
        sum(text.count("FileOperationCompositionRoot(") for text in [app]) == 1 and
        "try? FileOperationCompositionRoot()" not in app,
        "one mandatory native factory and one AppDelegate composition root")

all_finder = "\n".join(
    path.read_text() for path in (root / "Sources/FinderTwo").rglob("*.swift")
)
require("M2-INJECTION-001",
        all(token in app + browser + panes + pane + file_list + drop_stack for token in [
            "fileOperationBridge", "dropStackController"
        ]) and "DropStackController.shared" not in all_finder,
        "constructor injection reaches browser/panes/pane/list/drop stack without singleton")

route_checks = {
    "paste-copy": "fileOperationBridge: fileOperationBridge" in file_ops,
    "list-drag-copy": "FileOps.transfer(" in file_list and "fileOperationBridge: fileOperationBridge" in file_list,
    "icon-drag-copy": "FileOps.transfer(" in pane and "fileOperationBridge: self.fileOperationBridge" in pane,
    "pane-to-pane-copy": "transferSelectionToOtherPane" in panes and "fileOperationBridge: fileOperationBridge" in panes,
    "drop-stack-copy": "copyAllHere" in drop_stack and "fileOperationBridge: fileOperationBridge" in drop_stack,
    "duplicate": "duplicateSelection" in pane and "submitCopy(" in pane,
}
require("M2-ROUTE-001", all(route_checks.values()), ",".join(sorted(route_checks)))

submit_index = file_ops.find("fileOperationBridge.submitCopy")
legacy_index = file_ops.find("TransferQueue.shared.enqueue")
injected_copy = re.search(
    r"if\s+!move,\s+let\s+fileOperationBridge\s*\{([\s\S]*?)\n\s*\}\n\s*if\s+move",
    file_ops,
)
injected_duplicate = re.search(
    r"func\s+duplicateSelection\(\)\s*\{([\s\S]*?)\n\s*func\s+showGoToFolderSheet",
    pane,
)
require("M2-NO-FALLBACK-001",
        submit_index >= 0 and legacy_index > submit_index and
        injected_copy is not None and
        "if fileOperationBridge.submitCopy(" in injected_copy.group(1) and
        "LegacyWriteGate.allows(" in injected_copy.group(1) and
        ".transferCopy" in injected_copy.group(1) and
        injected_duplicate is not None and
        "if let fileOperationBridge" in injected_duplicate.group(1) and
        "if fileOperationBridge.submitCopy(" in injected_duplicate.group(1) and
        "LegacyWriteGate.allows(" in injected_duplicate.group(1) and
        ".transferCopy" in injected_duplicate.group(1) and
        "case transferCopy" in legacy_gate and
        "#if DEBUG" in legacy_gate and
        'environment["RASCAL_ENABLE_LEGACY_WRITES"] == "1"' in legacy_gate and
        re.search(r"#else\s*false\s*#endif", legacy_gate) is not None and
        "TransferQueue" not in bridge,
        "native route submits once; only the exact debug legacy compatibility gate may fall through")

native_text = "\n".join(
    path.read_text()
    for base in (root / "Sources/RascalFileOperations/Native", root / "Sources/RascalFileOperations/Copy")
    for path in base.rglob("*.swift")
)
clean_native = uncomment(native_text)
forbidden_flags = ["COPYFILE_MOVE", "COPYFILE_UNLINK", "COPYFILE_SKIP"]
require("M2-NATIVE-PRIMITIVES-001",
        not any(flag in clean_native for flag in forbidden_flags) and
        "FileManager.default.copyItem" not in clean_native and
        "renameatx_np" in clean_native and "RENAME_EXCL" in clean_native and
        "COPYFILE_NOFOLLOW" in clean_native and "fcopyfile" in clean_native and
        all(primitive in clean_native for primitive in ["openat", "mkdirat", "linkat"]),
        "directory-FD anchored fcopyfile/traversal plus exclusive rename; no forbidden flags")

core_text = "\n".join(
    path.read_text() for path in (root / "Sources/RascalFileOperations").rglob("*.swift")
)
require("M2-CORE-UI-BOUNDARY-001",
        not re.search(r"(?m)^\s*import\s+AppKit\b", core_text),
        "RascalFileOperations contains no AppKit import")

package = read("Package.swift")
require("M2-PACKAGE-001",
        'sources: ["Core", "Interfaces", "Native", "Copy"]' in package,
        "Native and Copy are explicit library sources")

report.write_text("\n".join("\t".join(row) for row in checks) + "\n")
for row in checks:
    print("\t".join(row))
PY

shasum -a 256 "$OUT/report.tsv" > "$OUT/report.sha256"
if [[ -n "$RELEASE_TARGET" ]]; then
    RELEASE_BINARY="$RELEASE_TARGET"
    if [[ -d "$RELEASE_TARGET" ]]; then
        RELEASE_BINARY="$RELEASE_TARGET/Contents/MacOS/FinderTwo"
    fi
    [[ -x "$RELEASE_BINARY" ]] || {
        echo "M2-RELEASE-DISABLED-001 FAIL: release executable is unavailable: $RELEASE_BINARY" >&2
        exit 66
    }
    if [[ -d "$RELEASE_TARGET" ]]; then
        codesign --verify --deep --strict --verbose=2 "$RELEASE_TARGET" \
            > "$OUT/release-codesign.stdout" 2> "$OUT/release-codesign.stderr"
        printf 'open -n -W -o %q --stderr %q --env FT_M2_RELEASE_PROBE=1 --env FT_HEADLESS_TESTING=1 --env RASCAL_ENABLE_M2_NATIVE_COPY=1 --env RASCAL_ENABLE_LEGACY_WRITES=1 %q\n' \
            "$OUT/release-probe.stdout" "$OUT/release-probe.stderr" "$RELEASE_TARGET" \
            > "$OUT/release-probe.command"
    else
        printf 'RASCAL_ENABLE_M2_NATIVE_COPY=1 RASCAL_ENABLE_LEGACY_WRITES=1 FT_M2_RELEASE_PROBE=1 FT_HEADLESS_TESTING=1 %q\n' \
            "$RELEASE_BINARY" > "$OUT/release-probe.command"
    fi
    set +e
    if [[ -d "$RELEASE_TARGET" ]]; then
        open -n -W \
            -o "$OUT/release-probe.stdout" \
            --stderr "$OUT/release-probe.stderr" \
            --env FT_M2_RELEASE_PROBE=1 \
            --env FT_HEADLESS_TESTING=1 \
            --env RASCAL_ENABLE_M2_NATIVE_COPY=1 \
            --env RASCAL_ENABLE_LEGACY_WRITES=1 \
            "$RELEASE_TARGET"
    else
        RASCAL_ENABLE_M2_NATIVE_COPY=1 RASCAL_ENABLE_LEGACY_WRITES=1 \
            FT_M2_RELEASE_PROBE=1 FT_HEADLESS_TESTING=1 \
            "$RELEASE_BINARY" > "$OUT/release-probe.stdout" 2> "$OUT/release-probe.stderr"
    fi
    status=$?
    set -e
    printf '%s\n' "$status" > "$OUT/release-probe.exit"
    [[ "$status" == 0 ]] || {
        cat "$OUT/release-probe.stderr" >&2
        exit "$status"
    }
    grep -Fxq 'M2_RELEASE_PROBE PASS routes=6 native=0 legacy=0 finals=0' \
        "$OUT/release-probe.stderr" || {
        cat "$OUT/release-probe.stderr" >&2
        echo "M2-RELEASE-DISABLED-001 FAIL: release probe did not prove zero writes" >&2
        exit 67
    }
    shasum -a 256 "$RELEASE_BINARY" > "$OUT/release-binary.sha256"
    echo "M2-RELEASE-DISABLED-001 dynamic PASS target=$RELEASE_TARGET"
fi
echo "M2-STATIC PASS evidence=$OUT"
