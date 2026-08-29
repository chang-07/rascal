#!/usr/bin/env bash
set -euo pipefail

readonly PYTHON_BIN=/usr/bin/python3
[[ -x "$PYTHON_BIN" ]] || {
    echo "required system Python is unavailable: $PYTHON_BIN" >&2
    exit 65
}

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="${1:-$ROOT/.build/verification/local/m1-core-boundary/manual}"
SCRATCH="$OUT/swiftpm"
mkdir -p "$OUT"
cd "$ROOT"

swift package --disable-sandbox --scratch-path "$SCRATCH" describe --type json \
    > "$OUT/package-describe.json"

"$PYTHON_BIN" - "$ROOT" "$OUT/package-describe.json" <<'PY'
import json
import pathlib
import re
import sys

root = pathlib.Path(sys.argv[1])
description = json.loads(pathlib.Path(sys.argv[2]).read_text())

products = {product["name"]: product for product in description["products"]}
targets = {target["name"]: target for target in description["targets"]}

expected_products = {"FinderTwo", "RascalFileOperations", "FileOpsCrashProbe"}
if set(products) != expected_products:
    raise SystemExit(f"unexpected products: {sorted(products)}")
if products["FinderTwo"]["targets"] != ["FinderTwo"]:
    raise SystemExit("FinderTwo product must contain only the FinderTwo target")
if products["RascalFileOperations"]["targets"] != ["RascalFileOperations"]:
    raise SystemExit("library product must contain only RascalFileOperations")
if products["FileOpsCrashProbe"]["targets"] != ["FileOpsCrashProbe"]:
    raise SystemExit("CrashProbe must remain an independent executable product")

finder = targets["FinderTwo"]
if finder.get("target_dependencies") != ["RascalFileOperations"]:
    raise SystemExit(f"FinderTwo dependency graph changed: {finder.get('target_dependencies')}")
if finder.get("product_memberships") != ["FinderTwo"]:
    raise SystemExit(f"FinderTwo has unexpected product memberships: {finder.get('product_memberships')}")
for forbidden_source in ("TestSupport", "FileOpsCrashProbe"):
    if any(forbidden_source in source for source in finder.get("sources", [])):
        raise SystemExit(f"FinderTwo product graph includes forbidden source: {forbidden_source}")

support = targets["RascalFileOperationsTestSupport"]
if support.get("target_dependencies") != ["RascalFileOperations"]:
    raise SystemExit("TestSupport may depend only on RascalFileOperations")
if "FinderTwo" in support.get("product_memberships", []):
    raise SystemExit("TestSupport entered the FinderTwo product membership")

for test_name in ("RascalFileOperationsTests", "RascalFileOperationsIntegrationTests"):
    test = targets[test_name]
    if test.get("type") != "test":
        raise SystemExit(f"{test_name} is not a test target")
    if set(test.get("target_dependencies", [])) != {"RascalFileOperations", "RascalFileOperationsTestSupport"}:
        raise SystemExit(f"{test_name} has unexpected dependencies")
    if "FinderTwo" in test.get("product_memberships", []):
        raise SystemExit(f"{test_name} entered the FinderTwo product membership")

probe = targets["FileOpsCrashProbe"]
if probe.get("target_dependencies") != ["RascalFileOperations"]:
    raise SystemExit("CrashProbe may depend only on RascalFileOperations")
if probe.get("product_memberships") != ["FileOpsCrashProbe"]:
    raise SystemExit("CrashProbe must not enter FinderTwo product membership")


def uncomment(text):
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    return re.sub(r"//.*", "", text)


domain_paths = list((root / "Sources/RascalFileOperations/Core").rglob("*.swift"))
domain_paths += list((root / "Sources/RascalFileOperations/Interfaces").rglob("*.swift"))
if not domain_paths:
    raise SystemExit("Core/Interfaces sources are missing")

allowed_imports = {"Foundation", "Darwin"}
for path in domain_paths:
    clean = uncomment(path.read_text())
    imports = set(re.findall(r"(?m)^\s*import\s+(\w+)", clean))
    unexpected = imports - allowed_imports
    if unexpected:
        raise SystemExit(f"{path.relative_to(root)} imports forbidden modules {sorted(unexpected)}")
    forbidden = re.search(
        r"\b(AppKit|SQLite3|CommonCrypto|FileOps|TransferQueue|NSApplication|NSAlert|"
        r"NSPasteboard|PaneController|BrowserWindowController|FileListController|DirectoryModel)\b",
        clean,
    )
    if forbidden:
        raise SystemExit(f"{path.relative_to(root)} references forbidden type {forbidden.group(1)}")

test_paths = list((root / "Tests").rglob("*.swift"))
test_paths += list((root / "Sources/RascalFileOperations/TestSupport").rglob("*.swift"))
for path in test_paths:
    clean = uncomment(path.read_text())
    forbidden = re.search(r"\b(import\s+AppKit|NSApplication|NSApp|FileOps|TransferQueue|RunLoop\.current\.run)\b", clean)
    if forbidden:
        raise SystemExit(f"Core test graph depends on App runtime: {path.relative_to(root)}")

finder_root = root / "Sources/FinderTwo"
finder_sources = list(finder_root.rglob("*.swift"))
constructor_hits = []
composition_hits = []
for path in finder_sources:
    clean = uncomment(path.read_text())
    constructor_hits.extend((path, match.start()) for match in re.finditer(r"FileOperationService\s*\(\s*configuration:", clean))
    composition_hits.extend((path, match.start()) for match in re.finditer(r"FileOperationCompositionRoot\s*\(\s*\)", clean))

composition_file = root / "Sources/FinderTwo/Integration/FileOperationCompositionRoot.swift"
app_delegate = root / "Sources/FinderTwo/AppDelegate.swift"
if len(constructor_hits) != 1 or constructor_hits[0][0] != composition_file:
    raise SystemExit(f"expected one service construction in composition root, got {[str(p.relative_to(root)) for p, _ in constructor_hits]}")
if len(composition_hits) != 1 or composition_hits[0][0] != app_delegate:
    raise SystemExit(f"expected AppDelegate to construct one composition root, got {[str(p.relative_to(root)) for p, _ in composition_hits]}")

new_boundary_text = "\n".join(
    path.read_text()
    for base in (root / "Sources/RascalFileOperations", root / "Sources/FinderTwo/Integration")
    for path in base.rglob("*.swift")
)
if re.search(r"\bstatic\s+(?:let|var)\s+shared\b", uncomment(new_boundary_text)):
    raise SystemExit("new Core/Integration boundary introduced a singleton")

print("SwiftPM product/dependency graph PASS")
print("Core/Interfaces import and legacy-reference scan PASS")
print("Core test App-independence scan PASS")
print("single composition root and no-new-singleton scan PASS")
PY

shasum -a 256 "$OUT/package-describe.json" > "$OUT/boundary-evidence.sha256"
echo "M1-CORE-001 PASS"
