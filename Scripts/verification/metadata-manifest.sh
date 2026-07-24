#!/usr/bin/env bash
set -euo pipefail

readonly PYTHON_BIN=/usr/bin/python3
[[ $# -ge 1 && $# -le 3 ]] || {
    echo "usage: metadata-manifest.sh SOURCE [DESTINATION] [OUTPUT_DIR]" >&2
    exit 64
}

SOURCE="$1"
DESTINATION="${2:-}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="${3:-$ROOT/.build/verification/local/m2-metadata-manifest/manual}"
mkdir -p "$OUT"

"$PYTHON_BIN" - "$SOURCE" "$DESTINATION" "$OUT" <<'PY'
import ctypes
import hashlib
import json
import os
import pathlib
import stat
import struct
import subprocess
import sys

libc = ctypes.CDLL("/usr/lib/libSystem.B.dylib", use_errno=True)
libc.listxattr.argtypes = [ctypes.c_char_p, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_int]
libc.listxattr.restype = ctypes.c_ssize_t
libc.getxattr.argtypes = [
    ctypes.c_char_p, ctypes.c_char_p, ctypes.c_void_p, ctypes.c_size_t,
    ctypes.c_uint32, ctypes.c_int,
]
libc.getxattr.restype = ctypes.c_ssize_t
XATTR_NOFOLLOW = 0x0001
ATTR_BIT_MAP_COUNT = 5
ATTR_CMN_CRTIME = 0x00000200
FSOPT_NOFOLLOW = 0x00000001

class AttrList(ctypes.Structure):
    _fields_ = [
        ("bitmapcount", ctypes.c_uint16),
        ("reserved", ctypes.c_uint16),
        ("commonattr", ctypes.c_uint32),
        ("volattr", ctypes.c_uint32),
        ("dirattr", ctypes.c_uint32),
        ("fileattr", ctypes.c_uint32),
        ("forkattr", ctypes.c_uint32),
    ]

libc.getattrlist.argtypes = [
    ctypes.c_char_p, ctypes.POINTER(AttrList), ctypes.c_void_p,
    ctypes.c_size_t, ctypes.c_uint32,
]
libc.getattrlist.restype = ctypes.c_int

source = pathlib.Path(sys.argv[1]).resolve()
destination_arg = sys.argv[2]
destination = pathlib.Path(destination_arg).resolve() if destination_arg else None
out = pathlib.Path(sys.argv[3])

if not source.exists() and not source.is_symlink():
    raise SystemExit(f"source is missing: {source}")
if destination is not None and not destination.exists() and not destination.is_symlink():
    raise SystemExit(f"destination is missing: {destination}")

def sha256_file(path):
    digest = hashlib.sha256()
    with open(path, "rb", buffering=0) as handle:
        while True:
            block = handle.read(1024 * 1024)
            if not block:
                return digest.hexdigest()
            digest.update(block)

def sparse_ranges(path, size):
    if size <= 0 or not hasattr(os, "SEEK_DATA"):
        return []
    ranges = []
    fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    try:
        cursor = 0
        while cursor < size:
            try:
                start = os.lseek(fd, cursor, os.SEEK_DATA)
            except OSError as error:
                if error.errno == 6:  # ENXIO: no later data
                    break
                raise
            end = min(size, os.lseek(fd, start, os.SEEK_HOLE))
            ranges.append([start, end])
            if end <= cursor:
                raise RuntimeError(f"sparse cursor did not advance: {path}")
            cursor = end
    finally:
        os.close(fd)
    return ranges

def acl_text(path, symlink):
    command = ["/bin/ls", "-lde", str(path)]
    result = subprocess.run(command, check=True, capture_output=True, text=True)
    lines = result.stdout.splitlines()
    return "\n".join(line.strip() for line in lines[1:] if line.startswith(" "))

def xattrs(path):
    result = {}
    encoded_path = os.fsencode(path)
    needed = libc.listxattr(encoded_path, None, 0, XATTR_NOFOLLOW)
    if needed < 0:
        error = ctypes.get_errno()
        if error in (45, 93):  # ENOTSUP/EOPNOTSUPP
            return result
        raise OSError(error, os.strerror(error), str(path))
    if needed == 0:
        return result
    names_buffer = ctypes.create_string_buffer(needed)
    actual = libc.listxattr(encoded_path, names_buffer, needed, XATTR_NOFOLLOW)
    if actual != needed:
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error), str(path))
    names = sorted(name for name in names_buffer.raw[:actual].split(b"\0") if name)
    for encoded_name in names:
        size = libc.getxattr(encoded_path, encoded_name, None, 0, 0, XATTR_NOFOLLOW)
        if size < 0:
            error = ctypes.get_errno()
            raise OSError(error, os.strerror(error), str(path))
        value_buffer = ctypes.create_string_buffer(size)
        read = libc.getxattr(
            encoded_path, encoded_name, value_buffer, size, 0, XATTR_NOFOLLOW
        )
        if read != size:
            error = ctypes.get_errno()
            raise OSError(error, os.strerror(error), str(path))
        name = encoded_name.decode("utf-8", errors="surrogateescape")
        result[name] = hashlib.sha256(value_buffer.raw[:read]).hexdigest()
    return result

def birthtime_ns(path):
    attributes = AttrList(
        bitmapcount=ATTR_BIT_MAP_COUNT,
        reserved=0,
        commonattr=ATTR_CMN_CRTIME,
        volattr=0,
        dirattr=0,
        fileattr=0,
        forkattr=0,
    )
    # Attribute buffers use 4-byte packing: u32 total length followed by
    # timespec(tv_sec, tv_nsec). Reading the kernel fields directly avoids the
    # precision loss of Python's floating-point st_birthtime.
    buffer = ctypes.create_string_buffer(4 + 16)
    result = libc.getattrlist(
        os.fsencode(path), ctypes.byref(attributes), buffer,
        ctypes.sizeof(buffer), FSOPT_NOFOLLOW,
    )
    if result != 0:
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error), str(path))
    length = struct.unpack_from("=I", buffer.raw, 0)[0]
    if length != ctypes.sizeof(buffer):
        raise RuntimeError(f"unexpected creation-time attribute size {length}: {path}")
    seconds, nanoseconds = struct.unpack_from("=qq", buffer.raw, 4)
    return seconds * 1_000_000_000 + nanoseconds

def manifest(root):
    pending = [(".", root)]
    nodes = []
    while pending:
        relative, path = pending.pop(0)
        info = os.lstat(path)
        nodes.append((relative, path, info))
        if stat.S_ISDIR(info.st_mode):
            for name in sorted(os.listdir(path), key=lambda value: value.encode("utf-8")):
                child_relative = name if relative == "." else f"{relative}/{name}"
                pending.append((child_relative, path / name))

    hardlink_leaders = {}
    entries = []
    for relative, path, info in nodes:
        if stat.S_ISREG(info.st_mode):
            kind = "regular"
        elif stat.S_ISDIR(info.st_mode):
            kind = "directory"
        elif stat.S_ISLNK(info.st_mode):
            kind = "symbolicLink"
        else:
            raise SystemExit(f"unsupported node: {path}")
        hardlink = None
        if kind == "regular" and info.st_nlink > 1:
            key = (info.st_dev, info.st_ino)
            hardlink = hardlink_leaders.setdefault(key, relative)
        size = info.st_size if kind == "regular" else 0
        entries.append({
            "relativePath": relative,
            "kind": kind,
            "logicalSize": size,
            "allocatedBytes": info.st_blocks * 512 if kind == "regular" else 0,
            "sparseDataRanges": sparse_ranges(path, size) if kind == "regular" else [],
            "mode": stat.S_IMODE(info.st_mode),
            "flags": getattr(info, "st_flags", 0),
            "mtimeNs": info.st_mtime_ns,
            "birthNs": birthtime_ns(path),
            "symlinkTarget": os.readlink(path) if kind == "symbolicLink" else None,
            "hardLinkGroup": hardlink,
            "xattrs": xattrs(path),
            "acl": acl_text(path, kind == "symbolicLink"),
            "sha256": sha256_file(path) if kind == "regular" else None,
        })
    return entries

def write_manifest(label, root):
    entries = manifest(root)
    data = json.dumps(entries, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
    (out / f"{label}.json").write_text(data + "\n")
    (out / f"{label}.sha256").write_text(hashlib.sha256(data.encode()).hexdigest() + "\n")
    return entries

source_entries = write_manifest("source", source)
if destination is not None:
    destination_entries = write_manifest("destination", destination)
    if source_entries != destination_entries:
        for index, pair in enumerate(zip(source_entries, destination_entries)):
            if pair[0] != pair[1]:
                raise SystemExit(
                    "metadata manifest mismatch at index " + str(index) + "\n" +
                    json.dumps({"source": pair[0], "destination": pair[1]}, indent=2, ensure_ascii=False)
                )
        raise SystemExit(
            f"metadata manifest node count differs: {len(source_entries)} vs {len(destination_entries)}"
        )
    (out / "comparison.txt").write_text("M2-META-001 PASS\n")
    print(f"M2-META-001 PASS entries={len(source_entries)} evidence={out}")
else:
    print(f"metadata manifest captured entries={len(source_entries)} evidence={out}")
PY
