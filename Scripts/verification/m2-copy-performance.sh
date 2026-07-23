#!/usr/bin/env bash
set -euo pipefail

readonly PYTHON_BIN=/usr/bin/python3
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HEAD_OID="$(git -C "$ROOT" rev-parse HEAD)"
RUN_ID="${RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)-$$}"
OUT="${1:-$ROOT/.build/verification/$HEAD_OID/m2-performance/$RUN_ID}"
SCRATCH="$ROOT/.build/verification-scratch/$HEAD_OID/m2-performance/$RUN_ID"
PERF_ROOT="${RASCAL_M2_PERF_ROOT:-${TMPDIR:-/tmp}}"
mkdir -p "$OUT" "$SCRATCH"

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
printf '%q ' swift test --disable-sandbox --scratch-path "$SCRATCH" \
    --filter NativeCopyIntegrationTests/testConfiguredOneGiBPerformanceProtocol \
    > "$OUT/performance-test.command"
printf '\n' >> "$OUT/performance-test.command"

cat > "$OUT/protocol.txt" <<'EOF'
scenario=M2-PERF-001
fixture_bytes=1073741824
warmup_runs_per_engine=1
measured_runs_per_engine=7
order=deterministic-randomized-within-each-round
seed=0x72617363616c4d32
rascal_clone_shortcut=disabled
cp_command=/bin/cp SOURCE DESTINATION
cache_control=no-privileged-cache-purge; alternating order reduces systematic bias
threshold_throughput_ratio=0.70
threshold_rascal_idle_to_peak_rss_bytes=67108864
EOF

cd "$ROOT"
RASCAL_M2_PERF_ROOT="$PERF_ROOT" \
swift test --disable-sandbox --scratch-path "$SCRATCH" \
    --filter NativeCopyIntegrationTests/testConfiguredOneGiBPerformanceProtocol \
    > "$OUT/swift-test.stdout" 2> "$OUT/swift-test.stderr"

grep -F "Executed 1 test, with 0 failures" "$OUT/swift-test.stdout" >/dev/null
if grep -F "skipped" "$OUT/swift-test.stdout" >/dev/null; then
    echo "performance test reported a skip" >&2
    exit 1
fi

"$PYTHON_BIN" - "$OUT/swift-test.stdout" "$OUT/summary.json" "$OUT/samples.tsv" <<'PY'
import json
import math
import pathlib
import re
import statistics
import sys

text = pathlib.Path(sys.argv[1]).read_text()
pattern = re.compile(
    r"M2_PERF_SAMPLE engine=(rascal|cp) round=(\d+) "
    r"order=(rascal-first|cp-first) seconds=([0-9.]+) rss_delta_bytes=(\d+)"
)
samples = []
for match in pattern.finditer(text):
    samples.append({
        "engine": match.group(1),
        "round": int(match.group(2)),
        "order": match.group(3),
        "seconds": float(match.group(4)),
        "rss_delta_bytes": int(match.group(5)),
    })
for engine in ("rascal", "cp"):
    engine_samples = [sample for sample in samples if sample["engine"] == engine]
    if len(engine_samples) != 7 or {sample["round"] for sample in engine_samples} != set(range(1, 8)):
        raise SystemExit(f"{engine} does not have exactly seven measured rounds")
orders = {sample["order"] for sample in samples}
if orders != {"rascal-first", "cp-first"}:
    raise SystemExit(f"randomized order did not exercise both orders: {orders}")

def p95(values):
    ordered = sorted(values)
    return ordered[math.ceil(0.95 * len(ordered)) - 1]

rascal_times = [sample["seconds"] for sample in samples if sample["engine"] == "rascal"]
cp_times = [sample["seconds"] for sample in samples if sample["engine"] == "cp"]
rascal_median = statistics.median(rascal_times)
cp_median = statistics.median(cp_times)
throughput_ratio = cp_median / rascal_median
rascal_peak_delta = max(
    sample["rss_delta_bytes"] for sample in samples if sample["engine"] == "rascal"
)
summary = {
    "scenario": "M2-PERF-001",
    "rascal": {
        "median_seconds": rascal_median,
        "p95_seconds": p95(rascal_times),
        "max_idle_to_peak_rss_bytes": rascal_peak_delta,
    },
    "cp": {
        "median_seconds": cp_median,
        "p95_seconds": p95(cp_times),
        "max_rss_bytes": max(
            sample["rss_delta_bytes"] for sample in samples if sample["engine"] == "cp"
        ),
    },
    "throughput_ratio_rascal_to_cp": throughput_ratio,
    "throughput_pass": throughput_ratio >= 0.70,
    "rss_pass": rascal_peak_delta <= 64 * 1024 * 1024,
}
pathlib.Path(sys.argv[2]).write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n")
with pathlib.Path(sys.argv[3]).open("w") as handle:
    handle.write("engine\tround\torder\tseconds\trss_delta_bytes\n")
    for sample in samples:
        handle.write(
            f'{sample["engine"]}\t{sample["round"]}\t{sample["order"]}\t'
            f'{sample["seconds"]:.6f}\t{sample["rss_delta_bytes"]}\n'
        )
if not summary["throughput_pass"] or not summary["rss_pass"]:
    raise SystemExit("M2 performance threshold failed: " + json.dumps(summary, sort_keys=True))
print(
    "M2-PERF-001 PASS "
    f"throughput_ratio={throughput_ratio:.4f} "
    f"rascal_median={rascal_median:.6f}s cp_median={cp_median:.6f}s "
    f"rascal_rss_delta={rascal_peak_delta}"
)
PY

echo "M2-PERF-001 PASS evidence=$OUT"
