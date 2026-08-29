#!/usr/bin/env bash
set -euo pipefail

readonly PYTHON_BIN=/usr/bin/python3
[[ -x "$PYTHON_BIN" ]] || {
    echo "required system Python is unavailable: $PYTHON_BIN" >&2
    exit 65
}

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="${1:?usage: m1-feature-gates.sh OUT DEBUG_FINDER_TWO RELEASE_FINDER_TWO}"
DEBUG_BIN="${2:?missing debug FinderTwo binary path}"
RELEASE_BIN="${3:?missing release FinderTwo binary path}"
mkdir -p "$OUT"
cd "$ROOT"

for spec in "debug:$DEBUG_BIN" "release:$RELEASE_BIN"; do
    kind="${spec%%:*}"
    path="${spec#*:}"
    [[ -f "$path" && -x "$path" ]] || {
        echo "$kind FinderTwo binary is missing or not executable: $path" >&2
        exit 1
    }
    resolved="$("$PYTHON_BIN" - "$path" <<'PY'
import os
import sys
print(os.path.realpath(sys.argv[1]))
PY
)"
    case "$resolved" in
        /usr/bin/true|/usr/bin/false|/bin/true|/bin/false)
            echo "$kind FinderTwo binary points to a system utility: $resolved" >&2
            exit 65
            ;;
    esac
    case "$(basename "$path")" in
        FinderTwo|FinderTwo-debug|FinderTwo-release) ;;
        *) echo "$kind binary has non-FinderTwo basename: $path" >&2; exit 65 ;;
    esac
done

verify_build_root() {
    local kind="$1" root="$2" supplied="$3"
    local configuration="$kind" matched=""
    [[ -d "$root" ]] || { echo "$kind build root is missing: $root" >&2; return 1; }
    case "$root" in
        /|/tmp|/private/tmp|"$ROOT"|"$ROOT/.build")
            echo "$kind build root is too broad to prove a fresh attributable build: $root" >&2
            return 1
            ;;
    esac
    while IFS= read -r -d '' candidate; do
        if cmp -s "$candidate" "$supplied"; then
            [[ -z "$matched" ]] || {
                echo "$kind binary matches multiple build products" >&2
                return 1
            }
            matched="$candidate"
        fi
    done < <(find "$root" -type f -path "*/$configuration/FinderTwo" -print0)
    [[ -n "$matched" ]] || {
        echo "$kind supplied binary is not attributable to $root" >&2
        return 1
    }
    case "$matched" in
        */"$configuration"/FinderTwo) ;;
        *) echo "$kind product is outside its configuration directory: $matched" >&2; return 1 ;;
    esac
    "$PYTHON_BIN" - "$ROOT" "$matched" <<'PY'
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
binary = pathlib.Path(sys.argv[2])
inputs = [root / "Package.swift", root / "build.sh"]
inputs.extend((root / "Sources").rglob("*.swift"))
newest = max(path.stat().st_mtime_ns for path in inputs if path.is_file())
if binary.stat().st_mtime_ns < newest:
    raise SystemExit(f"build product predates current source: {binary}")
PY
    local file_details architectures code_details
    file_details="$(file -b "$matched")"
    [[ "$file_details" == *"Mach-O"* && "$file_details" == *"executable"* &&
       "$file_details" == *"arm64"* ]] || {
        echo "$kind product is not an arm64 Mach-O executable: $file_details" >&2
        return 1
    }
    otool -hv "$matched" | grep -Eq '(^|[[:space:]])EXECUTE([[:space:]]|$)' || {
        echo "$kind product Mach header is not MH_EXECUTE" >&2
        return 1
    }
    architectures="$(lipo -archs "$matched")"
    [[ " $architectures " == *" arm64 "* ]] || {
        echo "$kind product lacks arm64 architecture: $architectures" >&2
        return 1
    }
    codesign --verify --strict --verbose=2 "$matched" \
        > "$OUT/$kind-codesign-verify.stdout" \
        2> "$OUT/$kind-codesign-verify.stderr" || {
            cat "$OUT/$kind-codesign-verify.stderr" >&2
            return 1
        }
    code_details="$(codesign --display --verbose=4 "$matched" 2>&1)"
    grep -Fxq 'Signature=adhoc' <<<"$code_details" || {
        echo "$kind product is not ad-hoc signed" >&2
        return 1
    }
    printf '%s\n' "$code_details" > "$OUT/$kind-codesign-details.txt"
    printf '%s\t%s\t%s\t%s\n' "$kind" "$file_details" "$architectures" \
        "$(shasum -a 256 "$supplied" | awk '{print $1}')" \
        >> "$OUT/binary-inspection.tsv"
    printf '%s\t%s\t%s\t%s\n' "$kind" "$root" "$matched" \
        "$(shasum -a 256 "$supplied" | awk '{print $1}')" \
        >> "$OUT/binary-provenance-input.tsv"
}

printf 'configuration\tbuild_root\tbuilt_binary\tsha256\n' > "$OUT/binary-provenance-input.tsv"
printf 'configuration\tfile_details\tarchitectures\tsha256\n' > "$OUT/binary-inspection.tsv"
[[ -n "${M1_DEBUG_BUILD_ROOT:-}" && -n "${M1_RELEASE_BUILD_ROOT:-}" ]] || {
    echo "both fresh M1 debug/release build roots are mandatory" >&2
    exit 65
}
[[ "$("$PYTHON_BIN" -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$M1_DEBUG_BUILD_ROOT")" != \
   "$("$PYTHON_BIN" -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$M1_RELEASE_BUILD_ROOT")" ]] || {
    echo "debug and release provenance roots must be distinct" >&2
    exit 65
}
verify_build_root debug "$M1_DEBUG_BUILD_ROOT" "$DEBUG_BIN"
verify_build_root release "$M1_RELEASE_BUILD_ROOT" "$RELEASE_BIN"

"$PYTHON_BIN" - "$ROOT" "$OUT" <<'PY'
import json
import pathlib
import re
import sys

root = pathlib.Path(sys.argv[1])
out = pathlib.Path(sys.argv[2])
cfg_path = root / "Scripts/verification/mutation-allowlist.json"
cfg = json.loads(cfg_path.read_text())
if cfg.get("schemaVersion") != 2:
    raise SystemExit("mutation inventory schemaVersion must be 2")

required = {
    "stableID", "classification", "file", "symbol", "scope", "primitive",
    "sourceAnchor", "expectedOccurrences", "entryPoints", "releasePolicy",
    "guardCapability", "targetMilestone", "ownerChange", "reason",
}
classes = {
    "core-authorized", "legacy-user-content", "app-state",
    "external-nontransactional", "test-demo",
}
pattern = re.compile(cfg["mutationPattern"])
ids = set()
files = {}
spans = {}


def uncomment(text):
    """Blank comments while preserving offsets used by the ownership report."""
    result = []
    in_block = False
    for line in text.splitlines(keepends=True):
        chars = list(line)
        i = 0
        while i < len(chars):
            if in_block:
                end = line.find("*/", i)
                if end < 0:
                    for j in range(i, len(chars)):
                        if chars[j] not in "\r\n":
                            chars[j] = " "
                    break
                for j in range(i, end + 2):
                    chars[j] = " "
                i = end + 2
                in_block = False
                continue
            block = line.find("/*", i)
            slash = line.find("//", i)
            if slash >= 0 and (block < 0 or slash < block):
                for j in range(slash, len(chars)):
                    if chars[j] not in "\r\n":
                        chars[j] = " "
                break
            if block < 0:
                break
            end = line.find("*/", block + 2)
            if end < 0:
                for j in range(block, len(chars)):
                    if chars[j] not in "\r\n":
                        chars[j] = " "
                in_block = True
                break
            for j in range(block, end + 2):
                chars[j] = " "
            i = end + 2
        result.append("".join(chars))
    return "".join(result)


def mutation_matches(text):
    clean = uncomment(text)
    return list(pattern.finditer(clean))


positive_canaries = {
    "foundation": "try fm.copyItem(at: source, to: destination)",
    "user-default-alias-set": "d.set(value, forKey: key)",
    "user-default-alias-remove": "defaults.removeObject(forKey: key)",
    "workspace-eject": "try NSWorkspace.shared.unmountAndEjectDevice(at: url)",
    "workspace-default-app": "NSWorkspace.shared.setDefaultApplication(at: app, toOpen: type) { _ in }",
    "rename": "rename(source, destination)",
    "renameat": "renameat(sourceFD, source, destinationFD, destination)",
    "renameatx": "renameatx_np(sourceFD, source, destinationFD, destination, 0)",
    "open-create": "open(path, O_WRONLY | O_CREAT, 0o644)",
    "openat-truncate": "openat(directoryFD, name, O_WRONLY | O_TRUNC)",
    "filehandle-instance": "let handle = try FileHandle(forWritingTo: url)",
    "outputstream-instance": "let stream = OutputStream(url: url, append: false)!",
    "creat": "creat(path, 0o600)",
    "mkstemp": "mkstemp(&template)",
    "unlinkat": "unlinkat(directoryFD, name, 0)",
    "copyfile": "copyfile(source, destination, nil, 0)",
    "clonefile": "clonefile(source, destination, 0)",
    "renamex": "renamex_np(source, destination, RENAME_EXCL)",
    "setattrlist": "setattrlist(path, &attributes, &buffer, size, 0)",
    "filemanager-link": "try fm.linkItem(at: source, to: destination)",
    "darwin-write": "Darwin.write(fd, bytes, count)",
    "glibc-write": "Glibc.write(fd, bytes, count)",
    "pwrite": "pwrite(fd, bytes, count, offset)",
    "truncate": "ftruncate(fd, length)",
    "mkdir": "mkdirat(directoryFD, name, 0o755)",
    "rmdir": "rmdir(path)",
    "remove": "remove(path)",
    "link": "linkat(sourceFD, source, destinationFD, destination, 0)",
    "symlink": "symlinkat(target, directoryFD, name)",
    "ownership-mode": "fchmod(fd, 0o600)",
    "fopen-write": "fopen(path, \"wb\")",
    "freopen-write": "freopen(path, \"wb\", stream)",
    "stdio-write": "fwrite(bytes, 1, count, stream)",
    "foundation-to-file": "try value.write(toFile: path, atomically: true)",
    "mmap-write": "mmap(nil, count, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0)",
    "image-destination": "CGImageDestinationFinalize(destination)",
    "posix-spawn": "posix_spawn(&pid, path, nil, nil, argv, envp)",
    "system": "system(command)",
    "darwin-system": "Darwin.system(command)",
    "glibc-system": "Glibc.system(command)",
    "popen": "popen(command, \"w\")",
    "darwin-popen": "Darwin.popen(command, \"w\")",
    "glibc-popen": "Glibc.popen(command, \"w\")",
    "exec": "execl(\"/bin/rm\", \"rm\", path, nil)",
    "darwin-exec": "Darwin.execl(\"/bin/rm\", \"rm\", path, nil)",
    "glibc-exec": "Glibc.execl(\"/bin/rm\", \"rm\", path, nil)",
    "process-run": "Process.run(executableURL, arguments: [])",
    "nstask": "NSTask()",
}
negative_canaries = {
    "foundation": "fm.fileExists(atPath: path)",
    "user-default-alias": "d.string(forKey: key)",
    "workspace": "NSWorkspace.shared.icon(forFile: path)",
    "rename": "let renameatResult = 0",
    "open-readonly": "open(path, O_RDONLY)",
    "filehandle-readonly": "let handle = try FileHandle(forReadingFrom: url)",
    "outputstream-memory": "let stream = OutputStream.toMemory()",
    "open-method": "stream.open()",
    "unlink": "func unlinkLater() {}",
    "copyfile": "let copyfileFlags = 0",
    "getattrlist": "getattrlist(path, &attributes, &buffer, size, 0)",
    "member-write": "writer.write(value)",
    "function-declaration": "private static func write(_ data: Data) {}",
    "fopen-read": "fopen(path, \"rb\")",
    "freopen-read": "freopen(path, \"rb\", stream)",
    "stdio-read": "fread(bytes, 1, count, stream)",
    "mmap-read": "mmap(nil, count, PROT_READ, MAP_PRIVATE, fd, 0)",
    "posix-spawn": "var posix_spawnattr = posix_spawnattr_t()",
}
for name, source in positive_canaries.items():
    if len(mutation_matches(source)) != 1:
        raise SystemExit(f"positive mutation canary failed: {name}: {source}")
for name, source in negative_canaries.items():
    if mutation_matches(source):
        raise SystemExit(f"negative mutation canary matched: {name}: {source}")


def symbol_span(text, anchor, scope, stable_id):
    if text.count(anchor) != 1:
        raise SystemExit(f"{stable_id}: sourceAnchor must occur exactly once")
    start = text.index(anchor)
    if scope == "file":
        return 0, len(text)
    if scope != "symbol":
        raise SystemExit(f"{stable_id}: invalid scope {scope!r}")
    brace = text.find("{", start + len(anchor))
    if brace < 0:
        raise SystemExit(f"{stable_id}: symbol has no body")
    depth = 0
    for index in range(brace, len(text)):
        if text[index] == "{":
            depth += 1
        elif text[index] == "}":
            depth -= 1
            if depth == 0:
                return start, index + 1
    raise SystemExit(f"{stable_id}: unterminated symbol body")


for entry in cfg.get("entries", []):
    missing = required - entry.keys()
    if missing:
        raise SystemExit(f"{entry.get('stableID')}: missing fields {sorted(missing)}")
    stable_id = entry["stableID"]
    if not re.fullmatch(r"MUT-[0-9]{4}", stable_id):
        raise SystemExit(f"invalid stable ID {stable_id}")
    if stable_id in ids:
        raise SystemExit(f"duplicate stable ID {stable_id}")
    ids.add(stable_id)
    if entry["classification"] not in classes:
        raise SystemExit(f"{stable_id}: invalid classification")
    if entry["scope"] == "file" and entry["classification"] != "test-demo":
        raise SystemExit(f"{stable_id}: only test-demo may use file scope")
    if not isinstance(entry["expectedOccurrences"], int) or entry["expectedOccurrences"] <= 0:
        raise SystemExit(f"{stable_id}: expectedOccurrences must be a positive integer")
    for field in ("symbol", "primitive", "sourceAnchor", "releasePolicy", "targetMilestone", "ownerChange", "reason"):
        if not isinstance(entry[field], str) or not entry[field].strip():
            raise SystemExit(f"{stable_id}: {field} must be non-empty")
    if not isinstance(entry["entryPoints"], list) or not entry["entryPoints"]:
        raise SystemExit(f"{stable_id}: entryPoints must be non-empty")

    if "Process" in entry["primitive"]:
        executables = entry.get("processExecutable")
        if not isinstance(executables, list) or not executables or not all(isinstance(v, str) and v for v in executables):
            raise SystemExit(f"{stable_id}: Process entry lacks identifiable processExecutable")
        if entry.get("processOwner") != entry["symbol"]:
            raise SystemExit(f"{stable_id}: Process entry processOwner must equal symbol")

    if entry["classification"] == "app-state":
        boundary = entry.get("appStateBoundary")
        allowed = ("UserDefaults:FinderTwo.", "Application Support:FinderTwo/")
        if not isinstance(boundary, str) or not boundary.startswith(allowed):
            raise SystemExit(f"{stable_id}: app-state lacks a fixed Rascal namespace")
        if "URL" in entry["sourceAnchor"]:
            raise SystemExit(f"{stable_id}: arbitrary URL accepting symbol cannot be app-state")

    path = root / entry["file"]
    if not path.is_file():
        raise SystemExit(f"{stable_id}: missing inventoried file {entry['file']}")
    text = path.read_text()
    span = symbol_span(text, entry["sourceAnchor"], entry["scope"], stable_id)
    count = sum(span[0] <= match.start() < span[1] for match in mutation_matches(text))
    if count != entry["expectedOccurrences"]:
        raise SystemExit(f"{stable_id}: expected {entry['expectedOccurrences']} mutation anchors, got {count}")
    files.setdefault(entry["file"], []).append(entry)
    spans.setdefault(entry["file"], []).append((span, stable_id))

if not ids:
    raise SystemExit("mutation inventory must not be empty")

positive_ids = set()
required_routes = {
    "ENTRY-PASTE", "ENTRY-LIST-DRAG", "ENTRY-ICON-DRAG", "ENTRY-PANE-COPY",
    "ENTRY-PANE-MOVE", "ENTRY-DUPLICATE", "ENTRY-FOLDER-SYNC",
    "ENTRY-BATCH-RENAME", "ENTRY-ARCHIVE-EXTRACT",
    "ENTRY-ARCHIVE-EXTRACT-ALL", "ENTRY-ARCHIVE-COMPRESS",
    "ENTRY-SFTP-DOWNLOAD", "ENTRY-SFTP-UPLOAD", "ENTRY-QUICK-ROTATE",
    "ENTRY-APP-UNINSTALL", "ENTRY-PERMANENT-DELETE",
}
for point in cfg.get("positiveEntryPoints", []):
    required_point = {"stableID", "file", "anchor", "expectedOccurrences", "route"}
    missing = required_point - point.keys()
    if missing:
        raise SystemExit(f"positive entry missing {sorted(missing)}")
    point_id = point["stableID"]
    if point_id in positive_ids:
        raise SystemExit(f"duplicate positive entry ID {point_id}")
    positive_ids.add(point_id)
    if not isinstance(point["expectedOccurrences"], int) or point["expectedOccurrences"] <= 0:
        raise SystemExit(f"{point_id}: expectedOccurrences must be positive")
    point_path = root / point["file"]
    if not point_path.is_file():
        raise SystemExit(f"{point_id}: missing file {point['file']}")
    actual = point_path.read_text().count(point["anchor"])
    if actual != point["expectedOccurrences"]:
        raise SystemExit(f"{point_id}: expected {point['expectedOccurrences']} entry anchors, got {actual}")
missing_routes = required_routes - positive_ids
if missing_routes:
    raise SystemExit(f"missing required positive entry routes: {sorted(missing_routes)}")

seen = {}
source_root = root / "Sources/FinderTwo"
for path in source_root.rglob("*.swift"):
    text = path.read_text(errors="ignore")
    matches = mutation_matches(text)
    if matches:
        seen[str(path.relative_to(root))] = (text, matches)

unknown_files = sorted(set(seen) - set(files))
vanished_files = sorted(set(files) - set(seen))
if unknown_files:
    raise SystemExit(f"unknown mutation files: {unknown_files}")
if vanished_files:
    raise SystemExit(f"inventoried files no longer contain a mutation: {vanished_files}")

owner_rows = []
for rel, (text, matches) in seen.items():
    for match in matches:
        owners = [stable_id for ((start, end), stable_id) in spans[rel] if start <= match.start() < end]
        line = text.count("\n", 0, match.start()) + 1
        if len(owners) != 1:
            snippet = text[match.start():match.end()].replace("\n", " ")
            raise SystemExit(f"{rel}:{line}: mutation {snippet!r} has owners {owners}")
        owner_rows.append((rel, line, match.group(0).replace("\n", " "), owners[0]))

must_be_user = {
    "Sources/FinderTwo/FS/Archive.swift", "Sources/FinderTwo/FS/SFTPClient.swift",
    "Sources/FinderTwo/FS/QuickActions.swift", "Sources/FinderTwo/FS/AppUninstaller.swift",
}
for rel in must_be_user:
    if not any(entry["classification"] == "legacy-user-content" for entry in files.get(rel, [])):
        raise SystemExit(f"misclassified user-content backend: {rel}")

owner_rows.sort()
(out / "mutation-owners.tsv").write_text(
    "file\tline\tprimitive\towner\n" +
    "".join(f"{rel}\t{line}\t{primitive}\t{owner}\n" for rel, line, primitive, owner in owner_rows)
)
(out / "positive-entry-points.json").write_text(json.dumps(cfg["positiveEntryPoints"], indent=2, sort_keys=True) + "\n")
print(f"mutation inventory PASS ({len(ids)} entries, {len(owner_rows)} owned matches)")
PY

"$PYTHON_BIN" - "$ROOT" <<'PY'
import pathlib
import re
import sys

root = pathlib.Path(sys.argv[1])


def uncomment(text):
    result = []
    in_block = False
    for line in text.splitlines(keepends=True):
        chars = list(line)
        i = 0
        while i < len(chars):
            if in_block:
                end = line.find("*/", i)
                if end < 0:
                    for j in range(i, len(chars)):
                        if chars[j] not in "\r\n": chars[j] = " "
                    break
                for j in range(i, end + 2): chars[j] = " "
                i = end + 2
                in_block = False
                continue
            block = line.find("/*", i)
            slash = line.find("//", i)
            if slash >= 0 and (block < 0 or slash < block):
                for j in range(slash, len(chars)):
                    if chars[j] not in "\r\n": chars[j] = " "
                break
            if block < 0: break
            end = line.find("*/", block + 2)
            if end < 0:
                for j in range(block, len(chars)):
                    if chars[j] not in "\r\n": chars[j] = " "
                in_block = True
                break
            for j in range(block, end + 2): chars[j] = " "
            i = end + 2
        result.append("".join(chars))
    return "".join(result)


def body(rel, anchor):
    text = uncomment((root / rel).read_text())
    if text.count(anchor) != 1:
        raise SystemExit(f"backend anchor must occur once: {rel}:{anchor}")
    start = text.index(anchor)
    brace = text.find("{", start + len(anchor))
    if brace < 0:
        raise SystemExit(f"backend lacks body: {rel}:{anchor}")
    depth = 0
    for index in range(brace, len(text)):
        if text[index] == "{": depth += 1
        elif text[index] == "}":
            depth -= 1
            if depth == 0: return text[start:index + 1]
    raise SystemExit(f"unterminated backend: {rel}:{anchor}")


def require_before(rel, anchor, capabilities, mutations):
    section = body(rel, anchor)
    positions = [section.find(value) for value in mutations if section.find(value) >= 0]
    if not positions:
        raise SystemExit(f"backend mutation/call vanished: {rel}:{anchor}")
    first_mutation = min(positions)
    for capability in capabilities:
        guard = re.compile(
            rf"guard\s+LegacyWriteGate\.allows\(\.{re.escape(capability)}\)\s+"
            rf"else\s*\{{\s*return(?:\s+(?:false|true|nil|[0-9]+))?\s*\}}"
        )
        match = guard.search(section)
        if not match:
            raise SystemExit(f"missing exact early-return guard {capability}: {rel}:{anchor}")
        if match.start() > first_mutation:
            raise SystemExit(f"late guard {capability}: {rel}:{anchor}")


checks = [
    ("Sources/FinderTwo/FS/FileOps.swift", "static func transfer(",
     ["crossVolumeMove", "merge", "replace"],
     ["trashItem"]),
    ("Sources/FinderTwo/FS/FileOps.swift", "static func mergeDirectory",
     ["merge"], ["trashItem", "moveItem", "copyItem", "removeItem"]),
    ("Sources/FinderTwo/FS/FileOps.swift", "static func deleteImmediately",
     ["permanentDelete"], ["removeItem"]),
    ("Sources/FinderTwo/Model/FolderSync.swift", "static func mirrorSourceToDestination",
     ["folderSync"], ["copyOverwrite", "trashItem"]),
    ("Sources/FinderTwo/Model/FolderSync.swift", "static func syncBothWays",
     ["folderSync"], ["copyOverwrite"]),
    ("Sources/FinderTwo/Model/FolderSync.swift", "static func copyOverwrite",
     ["folderSync"], ["createDirectory", "copyItem", "replaceItemAt", "removeItem"]),
    ("Sources/FinderTwo/UI/FolderSyncSheetController.swift", "@objc private func doApply()",
     ["folderSync"], ["FolderSync.syncBothWays", "FolderSync.mirrorSourceToDestination"]),
    ("Sources/FinderTwo/UI/BatchRenameSheetController.swift", "@objc private func commit()",
     ["batchRename"], ["moveItem"]),
    ("Sources/FinderTwo/FS/Archive.swift", "static func extract(_ entry:",
     ["archiveWrite"], ["createFile", "Process()", "removeItem"]),
    ("Sources/FinderTwo/FS/Archive.swift", "static func extractAll(",
     ["archiveWrite"], ["Process()"]),
    ("Sources/FinderTwo/FS/Archive.swift", "static func compress(",
     ["archiveWrite"], ["Process()"]),
    ("Sources/FinderTwo/FS/Archive.swift", "static func extractInPlace(",
     ["archiveWrite"], ["createDirectory", "extractAll", "removeItem"]),
    ("Sources/FinderTwo/FS/SFTPClient.swift", "static func download(",
     ["sftpWrite"], ["Process()"]),
    ("Sources/FinderTwo/FS/SFTPClient.swift", "static func upload(",
     ["sftpWrite"], ["Process()"]),
    ("Sources/FinderTwo/FS/QuickActions.swift", "static func rotate(",
     ["inPlaceQuickAction"], ["run("]),
    ("Sources/FinderTwo/FS/AppUninstaller.swift", "static func uninstall(",
     ["appUninstall"], ["trashItem"]),
]

for check in checks:
    require_before(*check)

transfer_run = body("Sources/FinderTwo/Model/TransferQueue.swift", "private func run(_ op:")
whole = re.search(r"guard\s+let\s+prepared\s*=\s*preflight\(op\)\s+else\s*\{[\s\S]*?return\s*\}", transfer_run)
per_item = re.search(r"guard\s+let\s+step\s*=\s*revalidate\(step,\s*for:\s*op\)\s+else\s*\{[\s\S]*?break\s*\}", transfer_run)
first_transfer_mutation = min(
    position for token in ("FileOps.mergeDirectory", "renameSameLocal", "copyTree", "copyFile", "fm.removeItem")
    if (position := transfer_run.find(token)) >= 0
)
if not whole or whole.start() > first_transfer_mutation:
    raise SystemExit("TransferQueue.run lacks whole-plan early-return preflight")
if not per_item or per_item.start() > first_transfer_mutation:
    raise SystemExit("TransferQueue.run lacks per-item pre-mutation revalidation")

transfer_preflight = body("Sources/FinderTwo/Model/TransferQueue.swift", "private func preflight(_ op:")
for capability in ("merge", "transferMove", "crossVolumeMove"):
    guard = re.compile(
        rf"guard\s+LegacyWriteGate\.allows\(\.{capability}\)\s+else\s*\{{\s*return\s+nil\s*\}}"
    )
    if not guard.search(transfer_preflight):
        raise SystemExit(f"TransferQueue.preflight lacks exact {capability} guard")

revalidation = body("Sources/FinderTwo/Model/TransferQueue.swift", "private func revalidate(")
for required in (
    "current == prepared.observation", "current.classification != .remoteOrProvider",
    "current.classification != .unknown", "current.source.operationalURL",
    "current.destination.operationalURL", "return nil"
):
    if required not in revalidation:
        raise SystemExit(f"TransferQueue.revalidate missing fail-closed shape: {required}")

preflight_canonical = body("Sources/FinderTwo/Model/TransferQueue.swift", "private func preflight(_ op:")
for required in (
    "LegacyTransferClassifier.observe", "observation.source.operationalURL ?? step.src",
    "observation.destination.operationalURL ?? step.dst"
):
    if required not in preflight_canonical:
        raise SystemExit(f"TransferQueue.preflight does not carry canonical observation: {required}")

fileops_transfer = body("Sources/FinderTwo/FS/FileOps.swift", "static func transfer(")
move_gate_position = fileops_transfer.find("LegacyWriteGate.allows(.transferMove)")
first_prompt_position = fileops_transfer.find("promptConflict")
if min(move_gate_position, first_prompt_position) < 0 or move_gate_position > first_prompt_position:
    raise SystemExit("FileOps transferMove gate must precede conflict planning")
trash_position = fileops_transfer.find("LegacyReplaceGuard.revalidateAndTrash")
replace_guard_position = fileops_transfer.find("guard LegacyReplaceGuard.revalidateAndTrash")
replace_revalidate_position = fileops_transfer.find("initial: candidate.1")
replace_limit_position = fileops_transfer.find("LegacyReplaceGuard.planIsExclusive")
enqueue_position = fileops_transfer.find("TransferQueue.shared.enqueue")
exact_replace_guard = re.search(
    r"guard\s+LegacyReplaceGuard\.revalidateAndTrash\([\s\S]*?\)\s+else\s*\{\s*return\s*\}",
    fileops_transfer,
)
if min(trash_position, replace_guard_position, replace_revalidate_position,
       replace_limit_position, enqueue_position) < 0:
    raise SystemExit("FileOps Replace lacks canonical adjacent revalidation/multi-item denial")
if exact_replace_guard is None:
    raise SystemExit("FileOps Replace lacks exact fail-closed revalidateAndTrash guard")
if not replace_limit_position < trash_position <= replace_revalidate_position < enqueue_position:
    raise SystemExit("FileOps Replace validation is not before the first Trash mutation")
if exact_replace_guard.start() != replace_guard_position or exact_replace_guard.end() > enqueue_position:
    raise SystemExit("FileOps Replace revalidation guard must dominate TransferQueue enqueue")

replace_helper = body("Sources/FinderTwo/FS/LegacyWriteGate.swift", "static func revalidateAndTrash(")
helper_revalidation = replace_helper.find("current == initial")
helper_trash = replace_helper.find("try trash(canonicalDestination)")
if min(helper_revalidation, helper_trash) < 0 or helper_revalidation > helper_trash:
    raise SystemExit("Replace helper does not revalidate before Trash")

classifier_source = (root / "Sources/FinderTwo/FS/LegacyWriteGate.swift").read_text()
for required in (
    'standardizedComponents.dropFirst().first == "var"',
    'target == Data("private/var".utf8)',
    'system.lstatPath("/private")', 'system.lstatPath("/private/var")',
    'aliasIdentity.owner == 0', 'aliasIdentity.group == 0',
    'privateIdentity.owner == 0', 'privateVarIdentity.owner == 0',
    'system.resourceFacts(factsURL)', 'requestedComponents.dropFirst().contains'
):
    if required not in classifier_source:
        raise SystemExit(f"classifier fixed-/var observation invariant missing: {required}")
if 'dropFirst().first == "tmp"' in classifier_source or 'dropFirst().first == "etc"' in classifier_source:
    raise SystemExit("classifier must not whitelist /tmp or /etc")

rename_body = body("Sources/FinderTwo/Model/TransferQueue.swift", "private func renameSameLocal(")
if "LegacyExclusiveRename.move" not in rename_body:
    raise SystemExit("same-local move must use the exclusive rename helper")
for forbidden in ("moveItem", "copyFile", "copyTree", "removeItem"):
    if forbidden in rename_body:
        raise SystemExit(f"same-local rename contains forbidden fallback: {forbidden}")

exclusive_rename = body("Sources/FinderTwo/FS/LegacyWriteGate.swift", "static func move(source:")
for required in ("Darwin.renameatx_np", "RENAME_EXCL", "AT_FDCWD"):
    if required not in exclusive_rename:
        raise SystemExit(f"exclusive rename helper missing {required}")
for forbidden in ("Darwin.rename(", "moveItem", "copyItem", "removeItem"):
    if forbidden in exclusive_rename:
        raise SystemExit(f"exclusive rename helper contains fallback {forbidden}")

for anchor in ("func performUndo()", "func performRedo()"):
    section = body("Sources/FinderTwo/Model/FileActionLog.swift", anchor)
    gate = section.find("LegacyWriteGate.allows(.fileUndoRedo)")
    closure = min(p for token in ("a.undo()", "a.redo()") if (p := section.find(token)) >= 0)
    if gate < 0 or gate > closure:
        raise SystemExit(f"FileActionLog {anchor} gate is missing or after its closure")

# Convert and PDF intentionally remain outside the rotate-only gate in M1.
for anchor in ("static func convert(", "static func createPDF("):
    section = body("Sources/FinderTwo/FS/QuickActions.swift", anchor)
    if "LegacyWriteGate.allows(.inPlaceQuickAction)" in section:
        raise SystemExit(f"QuickActions {anchor} was incorrectly put behind the rotate gate")

print(f"backend closed static scan PASS ({len(checks)} exact-guard symbols + transfer two-layer gate)")
PY

DEBUG_SHA="$(shasum -a 256 "$DEBUG_BIN" | awk '{print $1}')"
RELEASE_SHA="$(shasum -a 256 "$RELEASE_BIN" | awk '{print $1}')"
[[ "$DEBUG_SHA" != "$RELEASE_SHA" ]] || {
    echo "debug and release FinderTwo hashes must differ" >&2
    exit 1
}
{
    printf 'configuration\tpath\tsha256\n'
    printf 'debug\t%s\t%s\n' "$DEBUG_BIN" "$DEBUG_SHA"
    printf 'release\t%s\t%s\n' "$RELEASE_BIN" "$RELEASE_SHA"
} > "$OUT/app-binaries.tsv"
shasum -a 256 Sources/FinderTwo/FS/LegacyWriteGate.swift > "$OUT/production-gate-source.sha256"

PROBE_DIR="${M1_FEATURE_GATE_SCRATCH:-$OUT/production-source-probe}"
mkdir -p "$PROBE_DIR/module-cache"
cat > "$PROBE_DIR/main.swift" <<'SWIFT'
import Foundation

func facts(_ volume: String?, local: Bool?, provider: Bool = false,
           symlink: Bool? = false) -> LegacyTransferEndpointFacts {
    LegacyTransferEndpointFacts(volumeIdentity: volume.map { $0 as NSString },
                                isLocal: local, isProviderLike: provider,
                                hasSymlinkAncestor: symlink)
}

let classifierCases: [(String, LegacyTransferClassification)] = [
    ("same-local", LegacyTransferClassifier.classify(
        source: facts("A", local: true), destination: facts("A", local: true))),
    ("cross-volume", LegacyTransferClassifier.classify(
        source: facts("A", local: true), destination: facts("B", local: true))),
    ("remote", LegacyTransferClassifier.classify(
        source: facts("A", local: false), destination: facts("A", local: true))),
    ("provider-like", LegacyTransferClassifier.classify(
        source: facts("A", local: true, provider: true),
        destination: facts("A", local: true))),
    ("unknown-volume", LegacyTransferClassifier.classify(
        source: facts(nil, local: true), destination: facts("A", local: true))),
    ("symlink-ancestor", LegacyTransferClassifier.classify(
        source: facts("A", local: true, symlink: true),
        destination: facts("A", local: true))),
]
let expectedClassifications: [LegacyTransferClassification] = [
    .sameLocal, .crossVolume, .remoteOrProvider, .remoteOrProvider, .unknown, .unknown
]
guard zip(classifierCases.map(\.1), expectedClassifications).allSatisfy({ $0 == $1 }) else {
    FileHandle.standardError.write(Data("classifier result mismatch: \(classifierCases)\n".utf8))
    exit(66)
}

func identity(_ type: UInt32, inode: UInt64, owner: UInt32 = 0,
              group: UInt32 = 0, size: Int64 = 0,
              modificationSeconds: Int64 = 0, modificationNanoseconds: Int64 = 0,
              changeSeconds: Int64 = 0, changeNanoseconds: Int64 = 0) -> LegacyPathIdentity {
    LegacyPathIdentity(device: 1, inode: inode, mode: type | 0o755,
                       owner: owner, group: group, size: size,
                       modificationSeconds: modificationSeconds,
                       modificationNanoseconds: modificationNanoseconds,
                       changeSeconds: changeSeconds,
                       changeNanoseconds: changeNanoseconds)
}

let directory = UInt32(S_IFDIR)
let regular = UInt32(S_IFREG)
let symlink = UInt32(S_IFLNK)
let rootIdentity = identity(directory, inode: 1)
let varIdentity = identity(symlink, inode: 2)
let privateIdentity = identity(directory, inode: 3)
let privateVarIdentity = identity(directory, inode: 4)
let sourceIdentity = identity(regular, inode: 5)

func fakeSystem(
    overrides: [String: LegacyLStatResult] = [:],
    readlink: LegacyReadlinkResult = .value(Data("private/var".utf8)),
    sourceVolume: String? = "A",
    destinationVolume: String? = "A",
    providerLike: Bool = false,
    resourceFailure: Bool = false
) -> LegacyClassifierSystemCalls {
    let base: [String: LegacyLStatResult] = [
        "/": .present(rootIdentity),
        "/var": .present(varIdentity),
        "/private": .present(privateIdentity),
        "/private/var": .present(privateVarIdentity),
        "/private/var/source": .present(sourceIdentity),
    ]
    return LegacyClassifierSystemCalls(
        lstatPath: { path in overrides[path] ?? base[path] ?? .missing },
        readlinkPath: { path in path == "/var" ? readlink : .failed(EINVAL) },
        resourceFacts: { url in
            if resourceFailure { return .failed }
            let isSource = url.path == "/private/var/source"
            let volume = isSource ? sourceVolume : destinationVolume
            return .value(LegacyTransferEndpointFacts(
                volumeIdentity: volume.map { $0 as NSString },
                isLocal: true, isProviderLike: providerLike,
                hasSymlinkAncestor: false
            ))
        }
    )
}

func fakeObservation(
    source: URL = URL(fileURLWithPath: "/var/source"),
    destination: URL = URL(fileURLWithPath: "/var/new/leaf"),
    system: LegacyClassifierSystemCalls = fakeSystem()
) -> LegacyTransferObservation {
    LegacyTransferClassifier.observe(source: source, destination: destination, system: system)
}

if CommandLine.arguments[1] == "classifier" {
    let output = URL(fileURLWithPath: CommandLine.arguments[2])
    let fm = FileManager.default
    let varTemp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    guard varTemp.pathComponents.dropFirst().first == "var" else {
        FileHandle.standardError.write(Data("NSTemporaryDirectory is not rooted at /var\n".utf8))
        exit(67)
    }
    let fixture = varTemp.appendingPathComponent("Rascal.M1.alias.\(UUID().uuidString)")
    let privateFixture = URL(fileURLWithPath: "/private" + fixture.path, isDirectory: true)
    defer { try? fm.removeItem(at: privateFixture) }
    try fm.createDirectory(at: fixture.appendingPathComponent("real"),
                           withIntermediateDirectories: true)
    try Data("source".utf8).write(to: fixture.appendingPathComponent("source"))
    try Data("nested".utf8).write(to: fixture.appendingPathComponent("real/source"))

    let varObservation = LegacyTransferClassifier.observe(
        source: fixture.appendingPathComponent("source"),
        destination: fixture.appendingPathComponent("destination")
    )
    let privateObservation = LegacyTransferClassifier.observe(
        source: privateFixture.appendingPathComponent("source"),
        destination: privateFixture.appendingPathComponent("destination")
    )
    guard varObservation.classification == .sameLocal,
          privateObservation.classification == .sameLocal,
          varObservation.source.operationalURL?.path == privateFixture.appendingPathComponent("source").path,
          varObservation.destination.operationalURL?.path == privateFixture.appendingPathComponent("destination").path else {
        FileHandle.standardError.write(Data("real /var or /private/var classification failed\n".utf8))
        exit(68)
    }

    try fm.createSymbolicLink(at: fixture.appendingPathComponent("linked"),
                              withDestinationURL: fixture.appendingPathComponent("real"))
    let actualSymlink = LegacyTransferClassifier.classify(
        source: fixture.appendingPathComponent("linked/source"),
        destination: fixture.appendingPathComponent("destination")
    )
    guard actualSymlink == .unknown else {
        FileHandle.standardError.write(Data("actual deeper symlink ancestor did not fail closed\n".utf8))
        exit(69)
    }

    let fakeCases: [(String, LegacyTransferObservation, LegacyTransferClassification)] = [
        ("leaf-missing-tail", fakeObservation(), .sameLocal),
        ("various-not-alias", fakeObservation(
            source: URL(fileURLWithPath: "/various/source")), .unknown),
        ("dotdot-rejected", fakeObservation(
            source: URL(fileURLWithPath: "/var/../tmp/source")), .unknown),
        ("relative-rejected", fakeObservation(
            source: URL(string: "relative/source")!), .unknown),
        ("alias-wrong-target", fakeObservation(system: fakeSystem(
            readlink: .value(Data("/private/var".utf8)))), .unknown),
        ("alias-nonroot", fakeObservation(system: fakeSystem(overrides: [
            "/var": .present(identity(symlink, inode: 2, owner: 501))
        ])), .unknown),
        ("alias-not-symlink", fakeObservation(system: fakeSystem(overrides: [
            "/var": .present(identity(directory, inode: 2))
        ])), .unknown),
        ("alias-lstat-failed", fakeObservation(system: fakeSystem(overrides: [
            "/var": .failed(EACCES)
        ])), .unknown),
        ("alias-readlink-failed", fakeObservation(system: fakeSystem(
            readlink: .failed(EIO))), .unknown),
        ("target-missing", fakeObservation(system: fakeSystem(overrides: [
            "/private/var": .missing
        ])), .unknown),
        ("target-symlink", fakeObservation(system: fakeSystem(overrides: [
            "/private/var": .present(identity(symlink, inode: 4))
        ])), .unknown),
        ("target-not-directory", fakeObservation(system: fakeSystem(overrides: [
            "/private/var": .present(identity(regular, inode: 4))
        ])), .unknown),
        ("private-nonroot", fakeObservation(system: fakeSystem(overrides: [
            "/private": .present(identity(directory, inode: 3, group: 20))
        ])), .unknown),
        ("source-deeper-symlink", fakeObservation(
            source: URL(fileURLWithPath: "/var/deep/source"),
            system: fakeSystem(overrides: [
                "/private/var/deep": .present(identity(symlink, inode: 7))
            ])), .unknown),
        ("destination-deeper-symlink", fakeObservation(
            destination: URL(fileURLWithPath: "/var/deep/leaf"),
            system: fakeSystem(overrides: [
                "/private/var/deep": .present(identity(symlink, inode: 8))
            ])), .unknown),
        ("middle-permission-failure", fakeObservation(
            destination: URL(fileURLWithPath: "/var/blocked/leaf"),
            system: fakeSystem(overrides: [
                "/private/var/blocked": .failed(EACCES)
            ])), .unknown),
        ("resource-facts-failure", fakeObservation(system: fakeSystem(
            resourceFailure: true)), .unknown),
        ("provider-canonical-facts", fakeObservation(system: fakeSystem(
            providerLike: true)), .remoteOrProvider),
        ("ubiquitous-canonical-facts", fakeObservation(system: fakeSystem(
            providerLike: true)), .remoteOrProvider),
    ]
    for (name, observation, expected) in fakeCases where observation.classification != expected {
        FileHandle.standardError.write(Data(
            "fake classifier case \(name) expected \(expected) got \(observation.classification)\n".utf8
        ))
        exit(70)
    }

    let initial = fakeObservation()
    let classificationDrift = fakeObservation(system: fakeSystem(destinationVolume: "B"))
    var classificationDriftMutations = 0
    if classificationDrift == initial { classificationDriftMutations += 1 }
    guard initial.classification == .sameLocal,
          classificationDrift.classification == .crossVolume,
          classificationDriftMutations == 0 else { exit(71) }

    let identityDrift = fakeObservation(system: fakeSystem(overrides: [
        "/private/var/source": .present(identity(regular, inode: 99))
    ]))
    var identityDriftMutations = 0
    if identityDrift == initial { identityDriftMutations += 1 }
    guard identityDrift.classification == .sameLocal,
          identityDrift != initial,
          identityDriftMutations == 0 else { exit(72) }

    // Same object identity with changed leaf size/time must still invalidate the
    // observation. Ancestor time noise is deliberately ignored.
    let contentDrift = fakeObservation(system: fakeSystem(overrides: [
        "/private/var/source": .present(identity(
            regular, inode: 5, size: 9, modificationSeconds: 10,
            modificationNanoseconds: 11, changeSeconds: 12,
            changeNanoseconds: 13
        ))
    ]))
    var contentDriftMutations = 0
    if contentDrift == initial { contentDriftMutations += 1 }
    guard contentDrift.classification == .sameLocal,
          contentDrift != initial, contentDriftMutations == 0 else { exit(73) }
    let ancestorTimeDrift = fakeObservation(system: fakeSystem(overrides: [
        "/private/var": .present(identity(
            directory, inode: 4, size: 4096, modificationSeconds: 99,
            modificationNanoseconds: 7, changeSeconds: 100,
            changeNanoseconds: 8
        ))
    ]))
    guard ancestorTimeDrift == initial else { exit(74) }

    guard LegacyReplaceGuard.planIsExclusive(itemCount: 1, replacementCount: 1),
          !LegacyReplaceGuard.planIsExclusive(itemCount: 2, replacementCount: 1),
          LegacyReplaceGuard.planIsExclusive(itemCount: 2, replacementCount: 0)
    else { exit(75) }

    var replaceTrashMutations = 0
    let driftReplace = LegacyReplaceGuard.revalidateAndTrash(
        initial: initial, source: URL(fileURLWithPath: "/var/source"),
        destination: URL(fileURLWithPath: "/var/new/leaf"),
        system: fakeSystem(overrides: [
            "/private/var/source": .present(identity(regular, inode: 99))
        ]),
        trash: { _ in replaceTrashMutations += 1 }
    )
    guard !driftReplace, replaceTrashMutations == 0 else { exit(76) }

    enum ProbeTrashError: Error { case denied }
    let failedTrash = LegacyReplaceGuard.revalidateAndTrash(
        initial: initial, source: URL(fileURLWithPath: "/var/source"),
        destination: URL(fileURLWithPath: "/var/new/leaf"),
        system: fakeSystem(), trash: { _ in throw ProbeTrashError.denied }
    )
    guard !failedTrash, replaceTrashMutations == 0 else { exit(77) }

    let renameFixture = fixture.appendingPathComponent("exclusive-rename", isDirectory: true)
    try fm.createDirectory(at: renameFixture, withIntermediateDirectories: false)
    let successSource = renameFixture.appendingPathComponent("success-source")
    let successDestination = renameFixture.appendingPathComponent("success-destination")
    try Data("success".utf8).write(to: successSource)
    var successCalls = 0
    let successResult = LegacyExclusiveRename.move(
        source: successSource, destination: successDestination,
        systemCall: { sourcePath, destinationPath in
            successCalls += 1
            let result = Darwin.renameatx_np(
                AT_FDCWD, sourcePath, AT_FDCWD, destinationPath, UInt32(RENAME_EXCL)
            )
            return (result, result == 0 ? 0 : errno)
        }
    )
    guard successResult == .moved, successCalls == 1,
          !fm.fileExists(atPath: successSource.path),
          (try String(contentsOf: successDestination, encoding: .utf8)) == "success"
    else { exit(78) }

    let raceSource = renameFixture.appendingPathComponent("race-source")
    let raceDestination = renameFixture.appendingPathComponent("race-destination")
    try Data("source-stays".utf8).write(to: raceSource)
    try Data("destination-stays".utf8).write(to: raceDestination)
    let raceResult = LegacyExclusiveRename.move(source: raceSource, destination: raceDestination)
    guard raceResult == .failed(EEXIST),
          (try String(contentsOf: raceSource, encoding: .utf8)) == "source-stays",
          (try String(contentsOf: raceDestination, encoding: .utf8)) == "destination-stays"
    else { exit(79) }

    var injectedCalls = 0
    for code in [EXDEV, EACCES] {
        let result = LegacyExclusiveRename.move(
            source: raceSource, destination: raceDestination,
            systemCall: { _, _ in injectedCalls += 1; return (-1, code) }
        )
        guard result == .failed(code),
              (try String(contentsOf: raceSource, encoding: .utf8)) == "source-stays",
              (try String(contentsOf: raceDestination, encoding: .utf8)) == "destination-stays"
        else { exit(80) }
    }
    guard injectedCalls == 2 else { exit(81) }

    var lines = ["scenario\tfirst\tsecond\texpectedAction\tmutations"]
    for entry in classifierCases {
        lines.append("\(entry.0)\t\(entry.1.rawValue)\t-\tclassify\t0")
    }
    lines.append("real-var-folders\t\(varObservation.classification.rawValue)\t-\tcanonicalize\t0")
    lines.append("real-private-var\t\(privateObservation.classification.rawValue)\t-\tclassify\t0")
    lines.append("actual-deeper-symlink\tunknown\t-\tdeny-before-mutation\t0")
    for entry in fakeCases {
        lines.append("\(entry.0)\t\(entry.1.classification.rawValue)\t-\tclassify\t0")
    }
    lines.append("classification-drift\tsameLocal\tcrossVolume\tdeny-before-mutation\t\(classificationDriftMutations)")
    lines.append("same-class-identity-drift\tsameLocal\tsameLocal\tdeny-before-mutation\t\(identityDriftMutations)")
    lines.append("same-inode-content-drift\tsameLocal\tsameLocal\tdeny-before-mutation\t\(contentDriftMutations)")
    lines.append("ancestor-time-drift\tsameLocal\tsameLocal\tstable-ancestor-accepted\t0")
    lines.append("replace-revalidate-drift\tsameLocal\tsameLocal\thelper-denied-trash\t\(replaceTrashMutations)")
    lines.append("replace-trash-failure\tsameLocal\tinjected-trash-error\thelper-returned-false\t0")
    lines.append("replace-multi-item\tsameLocal\t2-items\thelper-denied-plan\t0")
    lines.append("exclusive-rename-success\tsameLocal\tmoved\trenameatx-once\t\(successCalls)")
    lines.append("exclusive-rename-race\tsameLocal\tEEXIST\tpreserve-both\t0")
    lines.append("exclusive-rename-exdev\tsameLocal\tEXDEV\tno-fallback\t0")
    lines.append("exclusive-rename-eacces\tsameLocal\tEACCES\tno-fallback\t0")
    try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: output, options: .atomic)
    exit(0)
}

let expected = CommandLine.arguments[1] == "allow"
let sentinel = URL(fileURLWithPath: CommandLine.arguments[2])
var presentationGate = LegacyWriteDenialPresentationGate()
guard presentationGate.claim(), !presentationGate.claim(), !presentationGate.claim() else {
    FileHandle.standardError.write(Data("legacy denial presentation gate is reentrant\n".utf8))
    exit(64)
}
let results = LegacyWriteCapability.allCases.map { capability in
    (capability.rawValue, LegacyWriteGate.allows(capability, reason: "M1 production-source probe"))
}
guard results.allSatisfy({ $0.1 == expected }) else {
    FileHandle.standardError.write(Data("gate result mismatch: \(results)\n".utf8))
    exit(65)
}
if expected {
    let payload = results.map(\.0).joined(separator: "\n") + "\n"
    try Data(payload.utf8).write(to: sentinel, options: .atomic)
}
SWIFT

CLANG_MODULE_CACHE_PATH="$PROBE_DIR/module-cache" SWIFT_MODULECACHE_PATH="$PROBE_DIR/module-cache" \
    swiftc -DDEBUG Sources/FinderTwo/FS/LegacyWriteGate.swift "$PROBE_DIR/main.swift" -o "$PROBE_DIR/debug-probe"
CLANG_MODULE_CACHE_PATH="$PROBE_DIR/module-cache" SWIFT_MODULECACHE_PATH="$PROBE_DIR/module-cache" \
    swiftc -O Sources/FinderTwo/FS/LegacyWriteGate.swift "$PROBE_DIR/main.swift" -o "$PROBE_DIR/release-probe"

mkdir -p "$PROBE_DIR/undo-debug" "$PROBE_DIR/undo-release"
cat > "$PROBE_DIR/undo-debug/main.swift" <<'SWIFT'
import Foundation

let expected = CommandLine.arguments[1] == "allow"
let sentinel = URL(fileURLWithPath: CommandLine.arguments[2])
let log = FileActionLog()
var undoCalls = 0
var redoCalls = 0
log.record("probe", undo: {
    undoCalls += 1
    try? Data("undo".utf8).write(to: sentinel, options: .atomic)
    return true
}, redo: {
    redoCalls += 1
    try? Data("redo".utf8).write(to: sentinel, options: .atomic)
    return true
})
let undoResult = log.performUndo()
let redoResult = log.performRedo()
if expected {
    guard undoResult, redoResult, undoCalls == 1, redoCalls == 1,
          FileManager.default.fileExists(atPath: sentinel.path) else { exit(91) }
} else {
    guard !undoResult, !redoResult, undoCalls == 0, redoCalls == 0,
          log.canUndo, !log.canRedo,
          !FileManager.default.fileExists(atPath: sentinel.path) else { exit(92) }
}
SWIFT
cp "$PROBE_DIR/undo-debug/main.swift" "$PROBE_DIR/undo-release/main.swift"
CLANG_MODULE_CACHE_PATH="$PROBE_DIR/module-cache" SWIFT_MODULECACHE_PATH="$PROBE_DIR/module-cache" \
    swiftc -DDEBUG Sources/FinderTwo/FS/LegacyWriteGate.swift \
    Sources/FinderTwo/Model/FileActionLog.swift "$PROBE_DIR/undo-debug/main.swift" \
    -o "$PROBE_DIR/debug-undo-probe"
CLANG_MODULE_CACHE_PATH="$PROBE_DIR/module-cache" SWIFT_MODULECACHE_PATH="$PROBE_DIR/module-cache" \
    swiftc -O Sources/FinderTwo/FS/LegacyWriteGate.swift \
    Sources/FinderTwo/Model/FileActionLog.swift "$PROBE_DIR/undo-release/main.swift" \
    -o "$PROBE_DIR/release-undo-probe"

"$PROBE_DIR/debug-probe" classifier "$OUT/classifier-cases.tsv"

sentinel_digest() {
    local path="$1"
    if [[ -f "$path" ]]; then
        shasum -a 256 "$path" | awk '{print $1}'
    else
        printf 'ABSENT\n'
    fi
}

printf 'scenario\tconfiguration\tenv\texpected\tbefore\tafter\n' > "$OUT/undo-gate-before-after.tsv"
run_undo_probe() {
    local scenario="$1" configuration="$2" value="$3" expected="$4" probe="$5"
    local sentinel="$PROBE_DIR/${scenario}-${configuration}-${value}.undo-sentinel"
    rm -f "$sentinel"
    local before after
    before="$(sentinel_digest "$sentinel")"
    if [[ "$value" == "UNSET" ]]; then
        env -u RASCAL_ENABLE_LEGACY_WRITES "$probe" "$expected" "$sentinel"
    else
        RASCAL_ENABLE_LEGACY_WRITES="$value" "$probe" "$expected" "$sentinel"
    fi
    after="$(sentinel_digest "$sentinel")"
    if [[ "$expected" == "deny" ]]; then
        [[ "$before" == "ABSENT" && "$after" == "ABSENT" ]] || exit 1
    else
        [[ "$before" == "ABSENT" && "$after" != "ABSENT" ]] || exit 1
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$scenario" "$configuration" "$value" "$expected" "$before" "$after" \
        >> "$OUT/undo-gate-before-after.tsv"
}

run_undo_probe M1-GATE-D-001 debug UNSET deny "$PROBE_DIR/debug-undo-probe"
run_undo_probe M1-GATE-L-001 debug 1 allow "$PROBE_DIR/debug-undo-probe"
run_undo_probe M1-GATE-R-001 release 1 deny "$PROBE_DIR/release-undo-probe"

printf 'scenario\tconfiguration\tenv\texpected\tbefore\tafter\n' > "$OUT/gate-before-after.tsv"

run_probe() {
    local scenario="$1" configuration="$2" value="$3" expected="$4" probe="$5"
    local sentinel="$PROBE_DIR/${scenario}-${configuration}-${value}.sentinel"
    rm -f "$sentinel"
    local before after
    before="$(sentinel_digest "$sentinel")"
    if [[ "$value" == "UNSET" ]]; then
        env -u RASCAL_ENABLE_LEGACY_WRITES "$probe" "$expected" "$sentinel"
    elif [[ "$value" == "EMPTY" ]]; then
        RASCAL_ENABLE_LEGACY_WRITES= "$probe" "$expected" "$sentinel"
    else
        RASCAL_ENABLE_LEGACY_WRITES="$value" "$probe" "$expected" "$sentinel"
    fi
    after="$(sentinel_digest "$sentinel")"
    if [[ "$expected" == "deny" ]]; then
        [[ "$before" == "ABSENT" && "$after" == "ABSENT" ]] || {
            echo "$scenario changed a denied sentinel" >&2
            exit 1
        }
    else
        [[ "$before" == "ABSENT" && "$after" != "ABSENT" ]] || {
            echo "$scenario did not execute the allowed fixture" >&2
            exit 1
        }
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$scenario" "$configuration" "$value" "$expected" "$before" "$after" \
        >> "$OUT/gate-before-after.tsv"
}

for value in UNSET 0 true 01 EMPTY; do
    run_probe M1-GATE-D-001 debug "$value" deny "$PROBE_DIR/debug-probe"
done
run_probe M1-GATE-L-001 debug 1 allow "$PROBE_DIR/debug-probe"
for value in UNSET 1; do
    run_probe M1-GATE-R-001 release "$value" deny "$PROBE_DIR/release-probe"
done

shasum -a 256 Scripts/verification/mutation-allowlist.json \
    "$OUT/mutation-owners.tsv" "$OUT/positive-entry-points.json" \
    "$OUT/gate-before-after.tsv" "$OUT/undo-gate-before-after.tsv" \
    "$OUT/classifier-cases.tsv" \
    "$OUT/app-binaries.tsv" "$OUT/binary-provenance-input.tsv" \
    "$OUT/binary-inspection.tsv" \
    > "$OUT/gate-evidence.sha256"

cat > "$OUT/evidence-classification.tsv" <<'EOF'
evidence	method	claim_boundary
exclusive-rename-success	live-filesystem-syscall	renameatx_np success moved one disposable fixture exactly once
exclusive-rename-race	live-filesystem-syscall	EEXIST preserved both disposable fixture paths
exclusive-rename-exdev	injected-system-call-helper	EXDEV mapping and no helper fallback only; no live EXDEV syscall claimed
exclusive-rename-eacces	injected-system-call-helper	EACCES mapping and no helper fallback only; no live EACCES syscall claimed
classifier-cases	classifier-helper-dynamic	production classifier/helper behavior on fixtures and injected observations
replace-helper-cases	replace-helper-dynamic	revalidation/trash callback behavior only; production FileOps enqueue was not executed
transfer-fileops-ordering	static-source-ordering	guards and revalidation dominate mutation/enqueue tokens in current source
EOF

cat > "$OUT/evidence-scope.txt" <<'EOF'
The supplied debug/release FinderTwo binaries are fingerprinted build products.
Gate decisions are exercised by probes compiled from the exact production source
with DEBUG and optimized/no-DEBUG flags; the GUI app binaries are not launched by
this script, so this evidence does not claim dynamic denial inside a release app process.
Package.swift places Sources/FinderTwo/FS/LegacyWriteGate.swift under the FinderTwo
executable target path, forming the source-to-product side of the composite evidence.
FileActionLog probes compile the exact production gate and central undo/redo entrypoints;
denied configurations preserve both the sentinel and undo/redo stack position.
The exclusive rename success and EEXIST cases invoke the live renameatx_np syscall
on disposable paths. EXDEV and EACCES are injected system-call helper outcomes and
do not claim live kernel errno coverage. Classifier and Replace cases dynamically
exercise production helpers only; they do not execute the production FileOps queue.
TransferQueue/FileOps mutation and enqueue ordering is established by static source
inspection, not described as a dynamic no-enqueue observation.
EOF
shasum -a 256 Package.swift Sources/FinderTwo/FS/LegacyWriteGate.swift \
    Sources/FinderTwo/Model/FileActionLog.swift \
    "$OUT/app-binaries.tsv" > "$OUT/source-product-graph.sha256"

echo "M1-GATE-D-001 PASS debug-source-probe app-fingerprint=$DEBUG_SHA"
echo "M1-GATE-L-001 PASS debug-source-probe app-fingerprint=$DEBUG_SHA"
echo "M1-GATE-R-001 PASS optimized-no-DEBUG-source-probe release-app-fingerprint=$RELEASE_SHA"
