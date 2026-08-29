#!/usr/bin/env bash
set -euo pipefail

readonly PYTHON_BIN=/usr/bin/python3
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/Scripts/verification/m2-evidence-common.sh"
HEAD_OID="$(git -C "$ROOT" rev-parse HEAD)"
RUN_ID="${RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)-$$}"
OUT="${1:-$ROOT/.build/verification/$HEAD_OID/m2-copy-static/$RUN_ID}"
RELEASE_TARGET="${2:-}"
mkdir -p "$OUT"

finish() {
    local status=$?
    trap - EXIT
    if ! m2_capture_end_and_compare "$ROOT" "$OUT"; then
        echo "M2 evidence source state changed during static lane" >&2
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
test_runner = read("Sources/FinderTwo/Tests/TestRunner.swift")

checks = []
def require(label, condition, detail):
    if not condition:
        raise SystemExit(f"{label} FAIL: {detail}")
    checks.append((label, "PASS", detail))

clean_composition = uncomment(composition)
require("M2-RELEASE-GATE-STATIC-001",
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
        ]) and
        "DropStackController.shared" not in all_finder and
        "snapshot.latestSequence >= current.latestSequence" in bridge and
        "Self.isTerminal(current.state)" in bridge and
        "snapshots.removeAll()" not in bridge,
        "constructor injection reaches all owners; projection rejects stale or terminal-regressing snapshots")

route_checks = {
    "paste-copy": "func pasteHere()" in pane and "m2ProbeSubmitPasteCopy" in pane,
    "list-drag-copy": "submitDrop(urls:" in file_list and "m2ProbeSubmitListCopy" in file_list,
    "icon-drag-copy": "submitIconDrop(urls:" in pane and "m2ProbeSubmitIconCopy" in pane,
    "pane-to-pane-copy": "submitPaneTransfer(" in panes and "m2ProbeSubmitPaneToPaneCopy" in panes,
    "drop-stack-copy": "submitStackTransfer(" in drop_stack and "m2ProbeSubmitDropStackCopy" in drop_stack,
    "duplicate": "submitDuplicate(" in pane and "m2ProbeSubmitDuplicate" in pane,
}
require("M2-ROUTE-001", all(route_checks.values()), ",".join(sorted(route_checks)))

debug_probe = re.search(
    r"private\s+func\s+runM2NativeCopyRouteTrace[\s\S]*?"
    r"\n\s*private\s+func\s+runM2BridgeProjectionTests",
    test_runner,
)
release_probe = re.search(
    r"private\s+func\s+runM2ReleaseProbe[\s\S]*?"
    r"\n\s*private\s+func\s+runM2DeferredProbe",
    app,
)
probe_methods = [
    "m2ProbeSubmitPasteCopy", "m2ProbeSubmitListCopy",
    "m2ProbeSubmitIconCopy", "m2ProbeSubmitPaneToPaneCopy",
    "m2ProbeSubmitDropStackCopy", "m2ProbeSubmitDuplicate",
]
require("M2-ROUTE-PROBE-001",
        debug_probe is not None and release_probe is not None and
        all(name in debug_probe.group(0) for name in probe_methods) and
        all(name in release_probe.group(0) for name in probe_methods) and
        "FileOps.transfer(" not in debug_probe.group(0) and
        "bridge.submitCopy(" not in debug_probe.group(0) and
        "FileOps.transfer(" not in release_probe.group(0) and
        "bridge.submitCopy(" not in release_probe.group(0),
        "debug and release probes invoke six concrete UI owners without forged route labels")

submit_index = file_ops.find("fileOperationBridge.submitCopy")
legacy_index = file_ops.find("TransferQueue.shared.enqueue")
injected_duplicate = re.search(
    r"private\s+func\s+submitDuplicate[\s\S]*?"
    r"\n\s*func\s+showGoToFolderSheet",
    pane,
)
require("M2-NO-FALLBACK-001",
        submit_index >= 0 and legacy_index > submit_index and
        "if !move {" in file_ops and
        "fileOperationBridge.submitCopy(" in file_ops and
        "LegacyWriteGate.allowsM1CopyCompatibility(" in file_ops and
        "notifyDenial: false" in file_ops and
        "fileOperationBridge?.presentCopyUnavailable()" in file_ops and
        injected_duplicate is not None and
        "fileOperationBridge.submitCopy(" in injected_duplicate.group(0) and
        "LegacyWriteGate.allowsM1CopyCompatibility(" in injected_duplicate.group(0) and
        "notifyDenial: false" in injected_duplicate.group(0) and
        "fileOperationBridge?.presentCopyUnavailable()" in injected_duplicate.group(0) and
        "case transferCopy" in legacy_gate and
        "#if DEBUG" in legacy_gate and
        'environment["RASCAL_ENABLE_LEGACY_WRITES"] == "1"' in legacy_gate and
        'environment["FT_M1_LEGACY_COPY_COMPATIBILITY"] == "1"' in legacy_gate and
        'environment["FT_HEADLESS_TESTING"] == "1"' in legacy_gate and
        'environment["FT_RUN_TESTS"] == "1"' in legacy_gate and
        "beginM1CopyCompatibilityFixture()" in test_runner and
        all_finder.count("beginM1CopyCompatibilityFixture()") == 2 and
        re.search(r"#else\s*false\s*#endif", legacy_gate) is not None and
        "TransferQueue" not in bridge,
        "normal UI fails closed; only TestRunner can activate the exact M1 fixture lease")

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
        "copyfile(source.path" not in clean_native and
        re.search(r"(?<!f)setattrlist\(", clean_native) is None and
        "renameatx_np" in clean_native and "RENAME_EXCL" in clean_native and
        "COPYFILE_NOFOLLOW" in clean_native and "fcopyfile" in clean_native and
        all(primitive in clean_native for primitive in ["openat", "mkdirat", "linkat"]),
        "directory-FD anchored fcopyfile/traversal plus exclusive rename; no forbidden flags")
require("M2-DEFERRED-DISABLED-001",
        "volumeSupportsCaseSensitiveNamesKey" in native_text and
        "case-sensitive APFS remains disabled until its M8 volume lane" in native_text and
        'sourceFS.type != "apfs" || destinationFS.type != "apfs"' in native_text and
        "M2 native copy is limited to verified APFS volumes" in native_text and
        '"FT_M2_RELEASE_PROBE"' in composition and
        '"FT_M2_ROUTE_PROBE"' in composition and
        '"FT_M2_DEFERRED_PROBE"' in composition and
        "presentsAlerts: !isHeadlessM2Probe" in composition and
        'environment["FT_M2_DEFERRED_PROBE"] == "1"' in app and
        "guard presentsAlerts" in bridge and
        "TransferQueue" not in bridge,
        "case-sensitive APFS and non-APFS runtime gates fail closed; the explicit probe suppresses alerts without enabling fallback")

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
    fi
    set +e
    m2_run_timed "$OUT" release-probe 120 \
        /usr/bin/env \
        FT_M2_RELEASE_PROBE=1 \
        FT_HEADLESS_TESTING=1 \
        FT_M1_LEGACY_COPY_COMPATIBILITY=1 \
        RASCAL_ENABLE_M2_NATIVE_COPY=1 \
        RASCAL_ENABLE_LEGACY_WRITES=1 \
        "$RELEASE_BINARY"
    status=$?
    set -e
    [[ "$status" == 0 ]] || {
        cat "$OUT/release-probe.stderr" >&2
        exit "$status"
    }
    grep -Fxq 'M2_RELEASE_PROBE PASS routes=6 native=0 legacy=0 fixture=unchanged' \
        "$OUT/release-probe.stderr" || {
        cat "$OUT/release-probe.stderr" >&2
        echo "M2-RELEASE-DISABLED-001 FAIL: release probe did not prove zero writes" >&2
        exit 67
    }
    shasum -a 256 "$RELEASE_BINARY" > "$OUT/release-binary.sha256"
    echo "M2-RELEASE-DISABLED-001 dynamic PASS target=$RELEASE_TARGET"
fi
echo "M2-STATIC PASS evidence=$OUT"
