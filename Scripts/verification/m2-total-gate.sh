#!/usr/bin/env bash
set -euo pipefail

readonly PYTHON_BIN=/usr/bin/python3
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/Scripts/verification/m2-evidence-common.sh"
HEAD_OID="$(git -C "$ROOT" rev-parse HEAD)"
RUN_ID="${RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)-$$}"
OUT="${1:-$ROOT/.build/verification/$HEAD_OID/m2-total/$RUN_ID}"
SCRATCH="$ROOT/.build/verification-scratch/$HEAD_OID/m2-total/$RUN_ID"
LANES="$OUT/lanes"
mkdir -p "$OUT" "$SCRATCH" "$LANES"
FINALIZE_READY=0
SIGNAL_STATUS=0

finish() {
    local status=$?
    trap - EXIT
    set +e
    if [[ "$SIGNAL_STATUS" != 0 ]]; then
        status="$SIGNAL_STATUS"
    fi
    if [[ "$FINALIZE_READY" != 1 && "$status" == 0 ]]; then
        status=1
    fi
    local source_stable=0
    if m2_capture_end_and_compare "$ROOT" "$OUT"; then
        source_stable=1
    else
        echo "M2 evidence source state changed during total gate" >&2
        status=1
    fi
    if [[ "$status" == 0 && "$FINALIZE_READY" == 1 && "$source_stable" == 1 ]]; then
        if "$PYTHON_BIN" - "$OUT/scenario-bindings.tsv" \
            "$OUT/binding-results.pending.tsv" "$OUT/binding-results.tsv" \
            "$OUT/scenario-results.tsv" "$OUT/scenario-manifest.tsv" \
            "$OUT/summary.txt" <<'PY'
import csv
import pathlib
import sys

bindings_path, pending_path, binding_results_path, results_path, manifest, summary = (
    pathlib.Path(value) for value in sys.argv[1:]
)
with bindings_path.open(newline="") as handle:
    bindings = list(csv.DictReader(handle, delimiter="\t"))
with pending_path.open(newline="") as handle:
    binding_results = list(csv.DictReader(handle, delimiter="\t"))
if len(bindings) != len(binding_results):
    raise SystemExit("binding result count does not match frozen manifest")
for binding, result in zip(bindings, binding_results):
    identity = (
        binding["scenario_id"], binding["classification"], binding["lane"],
        binding["binding_type"], binding["selector"],
    )
    result_identity = tuple(result[key] for key in (
        "scenario_id", "classification", "lane", "binding_type", "selector"
    ))
    if identity != result_identity:
        raise SystemExit(f"binding result identity mismatch: {identity} != {result_identity}")
    if binding["scenario_id"] == "M2-EVIDENCE-001" and \
            binding["binding_type"] == "gate":
        if result["status"] != "PENDING_FINALIZE":
            raise SystemExit("M2 evidence gate was not pending final source comparison")
        result["status"] = "PASS"
        result["evidence"] = "child-hashes+source-stability+trace+journal+m1-manifest"
    elif result["status"] != "PASS":
        raise SystemExit(f"non-PASS binding before finalization: {result}")
if any(row["status"] != "PASS" for row in binding_results):
    raise SystemExit("not every exact binding reached PASS")

binding_results_path.write_text(
    "scenario_id\tclassification\tlane\tbinding_type\tselector\tstatus\tevidence\n" +
    "".join("\t".join(row[key] for key in (
        "scenario_id", "classification", "lane", "binding_type", "selector",
        "status", "evidence"
    )) + "\n" for row in binding_results)
)

scenario_rows = {}
for row in binding_results:
    entry = scenario_rows.setdefault(row["scenario_id"], {
        "classification": row["classification"],
        "lanes": set(),
        "statuses": [],
    })
    if entry["classification"] != row["classification"]:
        raise SystemExit(f"scenario classification changed: {row['scenario_id']}")
    entry["lanes"].add(row["lane"])
    entry["statuses"].append(row["status"])
rows = [{
    "scenario_id": scenario,
    "classification": entry["classification"],
    "lane": "+".join(sorted(entry["lanes"])),
    "status": "PASS" if all(value == "PASS" for value in entry["statuses"]) else "FAIL",
} for scenario, entry in sorted(scenario_rows.items())]
expected_mandatory = {
    "M2-APFS-001",
    "M2-CANCEL-001",
    "M2-COMMIT-RECHECK-001",
    "M2-DECISION-IDENTITY-001",
    "M2-EVIDENCE-001",
    "M2-FAULT-001",
    "M2-META-001",
    "M2-NAME-001",
    "M2-PERF-001",
    "M2-REFRESH-001",
    "M2-RELEASE-DISABLED-001",
    "M2-ROUTE-001",
}
expected_deferred = {"M2-CSAPFS-001", "M2-EXFAT-001"}
ids = [row["scenario_id"] for row in rows]
if len(ids) != len(set(ids)):
    raise SystemExit(f"duplicate scenario result: {ids}")
mandatory = {row["scenario_id"] for row in rows
             if row["classification"] == "mandatory"}
deferred = {row["scenario_id"] for row in rows
            if row["classification"] == "deferred-disabled"}
if mandatory != expected_mandatory or deferred != expected_deferred:
    raise SystemExit(
        f"scenario coverage mismatch mandatory={mandatory} deferred={deferred}"
    )
if any(row["status"] != "PASS" for row in rows):
    raise SystemExit(f"non-PASS scenario result: {rows}")
results_path.write_text(
    "scenario_id\tclassification\tlane\tstatus\n" +
    "".join("\t".join((
        row["scenario_id"], row["classification"], row["lane"], row["status"]
    )) + "\n" for row in rows)
)
manifest.write_text(
    "scenario_id\tclassification\tlane\tstatus\n" +
    "".join("\t".join((
        row["scenario_id"], row["classification"], row["lane"], row["status"]
    )) + "\n" for row in rows)
)
summary.write_text(
    f"mandatory_scenarios={len(expected_mandatory)}\n"
    f"mandatory_pass={len(expected_mandatory)}\n"
    "mandatory_skip_count=0\n"
    f"deferred_disabled_pass={len(expected_deferred)}\n"
)
PY
        then
            rm -f "$OUT/binding-results.pending.tsv"
            echo "M2-EVIDENCE-001 PASS mandatory=12 skips=0 evidence=$OUT"
        else
            status=1
        fi
    fi
    local manifest_tmp="$OUT/evidence.sha256.tmp"
    local manifest_ready=0
    rm -f "$OUT/evidence.sha256" "$manifest_tmp" "$OUT/lane.exit"
    if find "$OUT" -type f \
        ! -path "$OUT/evidence.sha256" \
        ! -path "$manifest_tmp" \
        ! -path "$OUT/lane.exit" \
        -print0 \
        | sort -z \
        | xargs -0 shasum -a 256 > "$manifest_tmp"; then
        if shasum -a 256 -c "$manifest_tmp" >/dev/null &&
           mv "$manifest_tmp" "$OUT/evidence.sha256"; then
            manifest_ready=1
        else
            echo "M2 evidence manifest could not be verified/finalized" >&2
            status=1
        fi
    else
        echo "M2 evidence manifest generation failed" >&2
        status=1
    fi
    rm -f "$manifest_tmp"
    if [[ "$status" == 0 && "$FINALIZE_READY" == 1 &&
          "$source_stable" == 1 && "$manifest_ready" == 1 ]]; then
        printf '0\n' > "$OUT/lane.exit"
    else
        [[ "$status" != 0 ]] || status=1
        printf '%s\n' "$status" > "$OUT/lane.exit"
    fi
    exit "$status"
}
trap finish EXIT
trap 'SIGNAL_STATUS=130; exit 130' INT
trap 'SIGNAL_STATUS=143; exit 143' TERM

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
: > "$OUT/mandatory-skips.txt"
cat > "$OUT/scenario-bindings.tsv" <<'EOF'
scenario_id	classification	lane	binding_type	selector
M2-APFS-001	mandatory	apfs	xctest	RascalFileOperationsIntegrationTests.NativeCopyIntegrationTests/testConfiguredDistinctAPFSVolumeMatrix
M2-APFS-001	mandatory	apfs	xctest	RascalFileOperationsIntegrationTests.NativeCopyIntegrationTests/testConfiguredRealAPFSNoSpaceLeavesNoPartialFinal
M2-CANCEL-001	mandatory	swift-full	xctest	RascalFileOperationsIntegrationTests.NativeCopyIntegrationTests/testCancelAfterMetadataBeforeCommitCleansVerifiedStage
M2-CANCEL-001	mandatory	swift-full	xctest	RascalFileOperationsIntegrationTests.NativeCopyIntegrationTests/testCancelAfterMetadataBeforeVerificationCleansStage
M2-CANCEL-001	mandatory	swift-full	xctest	RascalFileOperationsIntegrationTests.NativeCopyIntegrationTests/testCancelBeforeMetadataApplicationCleansVerifiedStage
M2-CANCEL-001	mandatory	swift-full	xctest	RascalFileOperationsIntegrationTests.NativeCopyIntegrationTests/testCancelDuringFileCopyCleansStageAndPreservesSource
M2-CANCEL-001	mandatory	swift-full	xctest	RascalFileOperationsIntegrationTests.NativeCopyIntegrationTests/testCancelMidTreeCleansAllStagedChildren
M2-COMMIT-RECHECK-001	mandatory	swift-full	xctest	RascalFileOperationsIntegrationTests.NativeCopyIntegrationTests/testCleanupReplacementAfterManifestValidationIsNeverDeleted
M2-COMMIT-RECHECK-001	mandatory	swift-full	xctest	RascalFileOperationsIntegrationTests.NativeCopyIntegrationTests/testCleanupDescendantReplacementAtFinalUnlinkCheckpointIsNeverDeleted
M2-COMMIT-RECHECK-001	mandatory	swift-full	xctest	RascalFileOperationsIntegrationTests.NativeCopyIntegrationTests/testCommitParentReplacementAfterDescriptorOpenNeverCommitsReplacementStage
M2-COMMIT-RECHECK-001	mandatory	swift-full	xctest	RascalFileOperationsIntegrationTests.NativeCopyIntegrationTests/testDestinationParentReplacementAfterPlanBeforeStageCreationIsRejected
M2-COMMIT-RECHECK-001	mandatory	swift-full	xctest	RascalFileOperationsIntegrationTests.NativeCopyIntegrationTests/testSourceChildMutationAfterVerificationWithRestoredMtimeBlocksCommit
M2-COMMIT-RECHECK-001	mandatory	swift-full	xctest	RascalFileOperationsIntegrationTests.NativeCopyIntegrationTests/testStageRootReplacementAfterVerificationIsNeverCommittedOrDeleted
M2-COMMIT-RECHECK-001	mandatory	swift-full	xctest	RascalFileOperationsIntegrationTests.NativeCopyIntegrationTests/testStageChildMutationAfterVerificationIsNeverCommittedOrDeleted
M2-COMMIT-RECHECK-001	mandatory	swift-full	xctest	RascalFileOperationsIntegrationTests.NativeCopyIntegrationTests/testStageReplacementAtFinalRenameCheckpointIsNeverCommitted
M2-COMMIT-RECHECK-001	mandatory	swift-full	xctest	RascalFileOperationsIntegrationTests.NativeCopyIntegrationTests/testDestinationParentRelocationKeepsMovedStageRegisteredForRecovery
M2-COMMIT-RECHECK-001	mandatory	swift-full	xctest	RascalFileOperationsIntegrationTests.NativeCopyIntegrationTests/testMissingOriginalParentKeepsMovedStageRegisteredWithRecoveryRequired
M2-DECISION-IDENTITY-001	mandatory	swift-full	xctest	RascalFileOperationsIntegrationTests.NativeCopyIntegrationTests/testResolvedConflictDecisionExpiresWhenDestinationIdentityChanges
M2-DECISION-IDENTITY-001	mandatory	swift-full	xctest	RascalFileOperationsIntegrationTests.NativeCopyIntegrationTests/testResolvedConflictDecisionExpiresWhenSourceIdentityChanges
M2-DECISION-IDENTITY-001	mandatory	swift-full	xctest	RascalFileOperationsIntegrationTests.NativeCopyIntegrationTests/testResolvedDecisionWithoutIdentityDigestIsRejected
M2-DECISION-IDENTITY-001	mandatory	swift-full	xctest	RascalFileOperationsIntegrationTests.NativeCopyIntegrationTests/testSourceReplacementAfterPreflightBeforePlanIsRejected
M2-DECISION-IDENTITY-001	mandatory	swift-full	xctest	RascalFileOperationsIntegrationTests.NativeCopyIntegrationTests/testDestinationParentReplacementAfterPreflightBeforePlanIsRejected
M2-EVIDENCE-001	mandatory	m2-total	gate	source-stability-and-all-child-evidence-hashes
M2-EVIDENCE-001	mandatory	swift-full	xctest	RascalFileOperationsIntegrationTests.NativeCopyIntegrationTests/testM2EvidenceEmitsEventTraceAndVolatileJournalDump
M2-FAULT-001	mandatory	swift-full	xctest	RascalFileOperationsIntegrationTests.NativeCopyIntegrationTests/testInjectedMidFileNoSpaceCleansStagingAndPreservesSource
M2-FAULT-001	mandatory	swift-full	xctest	RascalFileOperationsIntegrationTests.NativeCopyIntegrationTests/testInjectedMidFileReadPermissionFailureCleansStaging
M2-FAULT-001	mandatory	swift-full	xctest	RascalFileOperationsIntegrationTests.NativeCopyIntegrationTests/testInjectedMetadataFailureCleansStagingBeforeFinalIsVisible
M2-FAULT-001	mandatory	swift-full	xctest	RascalFileOperationsIntegrationTests.NativeCopyIntegrationTests/testInjectedCopyDataAndVerifyRulesUsePathCallSelectorsAndReportHits
M2-FAULT-001	mandatory	swift-full	xctest	RascalFileOperationsIntegrationTests.NativeCopyIntegrationTests/testInjectedNestedEnumerationRuleUsesPathAndCallSelectors
M2-FAULT-001	mandatory	swift-full	xctest	RascalFileOperationsIntegrationTests.NativeCopyIntegrationTests/testInjectedCleanupFailureLeavesOwnedStageForRecoveryAndReportsBothHits
M2-FAULT-001	mandatory	swift-full	xctest	RascalFileOperationsIntegrationTests.NativeCopyIntegrationTests/testInjectedEnumerationPermissionFailureCreatesNoFinal
M2-FAULT-001	mandatory	swift-full	xctest	RascalFileOperationsIntegrationTests.NativeCopyIntegrationTests/testInjectedCommitFailureCleansVerifiedStage
M2-FAULT-001	mandatory	swift-full	xctest	RascalFileOperationsIntegrationTests.NativeCopyIntegrationTests/testSameSizeStageDigestMutationFailsAsVerificationMismatch
M2-META-001	mandatory	apfs	artifact	six-independent-metadata-comparison.txt-markers
M2-NAME-001	mandatory	swift-full	xctest	RascalFileOperationsIntegrationTests.NativeCopyIntegrationTests/testKeepBothCommitRaceAdvancesSuffixAndUpdatesSnapshot
M2-NAME-001	mandatory	swift-full	xctest	RascalFileOperationsIntegrationTests.NativeCopyIntegrationTests/testMultiSourceKeepBothPlansSameCaseAndUnicodeNamesBeforeFirstCommit
M2-PERF-001	mandatory	performance	artifact	summary.json-thresholds-and-seven-samples-per-engine
M2-REFRESH-001	mandatory	swift-full	xctest	RascalFileOperationsIntegrationTests.ServiceIntegrationTests/testDescendingAndPostTerminalProgressAreIgnored
M2-REFRESH-001	mandatory	route-owner	ui-probe	fast-terminal-and-partial-commit-refresh-markers
M2-RELEASE-DISABLED-001	mandatory	static-release	release-probe	routes=6-native=0-legacy=0-fixture=unchanged
M2-ROUTE-001	mandatory	route-owner	ui-probe	six-real-owners-one-operation-id-and-zero-legacy
M2-CSAPFS-001	deferred-disabled	deferred-disabled	probe	runtime-ui-disabled-and-no-fallback
M2-EXFAT-001	deferred-disabled	deferred-disabled	probe	runtime-ui-disabled-and-no-fallback
EOF
readonly EXPECTED_BINDINGS_SHA256="3d6f8426825a93bac6c6e6405e903d80f55bf7118c6346c8ffd84f174f422e85"
ACTUAL_BINDINGS_SHA256="$(shasum -a 256 "$OUT/scenario-bindings.tsv" | awk '{print $1}')"
printf 'expected\t%s\nactual\t%s\n' \
    "$EXPECTED_BINDINGS_SHA256" "$ACTUAL_BINDINGS_SHA256" \
    > "$OUT/scenario-bindings.sha256"
[[ "$ACTUAL_BINDINGS_SHA256" == "$EXPECTED_BINDINGS_SHA256" ]]
if [[ "${M2_TOTAL_INTERRUPT_SELFTEST:-0}" == 1 ]]; then
    kill -INT "$$"
fi

m2_run_timed_signal_selftest "$OUT/signal-selftest" \
    > "$OUT/signal-selftest.stdout" 2> "$OUT/signal-selftest.stderr"

cd "$ROOT"
printf '%q ' env SWIFT_SCRATCH_PATH="$SCRATCH/release-build" bash "$ROOT/build.sh" release \
    > "$OUT/release-build.command"
printf '\n' >> "$OUT/release-build.command"
SWIFT_SCRATCH_PATH="$SCRATCH/release-build" bash "$ROOT/build.sh" release \
    > "$OUT/release-build.stdout" 2> "$OUT/release-build.stderr"
RELEASE_APP="$ROOT/build/Rascal.app"

bash "$ROOT/Scripts/verification/m2-copy-static-scan.sh" \
    "$LANES/static-release" "$RELEASE_APP" \
    > "$OUT/static-release.stdout" 2> "$OUT/static-release.stderr"

printf '%q ' swift test --disable-sandbox --scratch-path "$SCRATCH/swift-full" \
    > "$OUT/swift-full.command"
printf '\n' >> "$OUT/swift-full.command"
swift test --disable-sandbox --scratch-path "$SCRATCH/swift-full" \
    > "$OUT/swift-full.stdout" 2> "$OUT/swift-full.stderr"
grep -E 'Executed [0-9]+ tests?, with 0 failures' "$OUT/swift-full.stdout" >/dev/null

bash "$ROOT/Scripts/verification/m2-route-owner-probe.sh" "$LANES/route-owner" \
    > "$OUT/route-owner.stdout" 2> "$OUT/route-owner.stderr"
bash "$ROOT/Scripts/verification/m2-apfs-volume-matrix.sh" "$LANES/apfs" \
    > "$OUT/apfs.stdout" 2> "$OUT/apfs.stderr"
bash "$ROOT/Scripts/verification/m2-deferred-disabled.sh" "$LANES/deferred-disabled" \
    > "$OUT/deferred-disabled.stdout" 2> "$OUT/deferred-disabled.stderr"
bash "$ROOT/Scripts/verification/m2-copy-performance.sh" "$LANES/performance" \
    > "$OUT/performance.stdout" 2> "$OUT/performance.stderr"

M1_RUN_ID="$RUN_ID-m1-regression"
M1_EVIDENCE="$ROOT/.build/verification/$HEAD_OID/m1-fast/$M1_RUN_ID"
printf '%q ' env RUN_ID="$M1_RUN_ID" \
    bash "$ROOT/Scripts/verification/m1-fast-lane.sh" full \
    > "$OUT/m1-regression.command"
printf '\n' >> "$OUT/m1-regression.command"
RUN_ID="$M1_RUN_ID" bash "$ROOT/Scripts/verification/m1-fast-lane.sh" full \
    > "$OUT/m1-regression.stdout" 2> "$OUT/m1-regression.stderr"
printf '%s\n' "$M1_EVIDENCE" > "$OUT/m1-evidence-path.txt"
grep -Fxq '0' "$M1_EVIDENCE/lane.exit"
grep -Fxq $'start_end_git_state\tPASS' "$M1_EVIDENCE/workspace-stability.tsv"
[[ "$(wc -l < "$M1_EVIDENCE/mandatory-skip-list.tsv" | tr -d ' ')" == 1 ]]
grep -Fq $'M1-COMPAT-001\tlocal-compat\ttrue\ttrue\tPASS\t' \
    "$M1_EVIDENCE/scenario-results.tsv"
shasum -a 256 -c "$M1_EVIDENCE/evidence.sha256" \
    > "$OUT/m1-evidence-check.stdout"
cp "$M1_EVIDENCE/evidence.sha256" "$OUT/m1-evidence-manifest.sha256"
shasum -a 256 "$OUT/m1-evidence-manifest.sha256" \
    > "$OUT/m1-evidence-manifest-file.sha256"

for lane in static-release route-owner apfs deferred-disabled performance; do
    grep -Fxq '0' "$LANES/$lane/lane.exit"
    shasum -a 256 -c "$LANES/$lane/evidence.sha256" \
        > "$OUT/$lane-evidence-check.stdout"
done

"$PYTHON_BIN" - "$OUT/scenario-bindings.tsv" "$OUT/swift-full.stdout" \
    "$LANES" "$OUT/binding-results.pending.tsv" "$OUT" \
    "$EXPECTED_BINDINGS_SHA256" <<'PY'
import csv
import hashlib
import json
import pathlib
import re
import sys

bindings_path = pathlib.Path(sys.argv[1])
swift_path = pathlib.Path(sys.argv[2])
lanes = pathlib.Path(sys.argv[3])
output = pathlib.Path(sys.argv[4])
evidence_root = pathlib.Path(sys.argv[5])
expected_bindings_sha = sys.argv[6]
binding_bytes = bindings_path.read_bytes()
if hashlib.sha256(binding_bytes).hexdigest() != expected_bindings_sha:
    raise SystemExit("M2 exact binding manifest digest changed")
with bindings_path.open(newline="") as handle:
    bindings = list(csv.DictReader(handle, delimiter="\t"))
fieldnames = ["scenario_id", "classification", "lane", "binding_type", "selector"]
if not bindings or list(bindings[0]) != fieldnames:
    raise SystemExit("invalid M2 scenario binding manifest")
if set(bindings[0]) != {
    "scenario_id", "classification", "lane", "binding_type", "selector"
}:
    raise SystemExit("invalid M2 scenario binding manifest")
if len({(row["scenario_id"], row["binding_type"], row["selector"])
        for row in bindings}) != len(bindings):
    raise SystemExit("duplicate M2 scenario binding")

def serialize(rows):
    lines = ["\t".join(fieldnames)]
    lines.extend("\t".join(row[field] for field in fieldnames) for row in rows)
    return ("\n".join(lines) + "\n").encode()

def rejects_exact(rows):
    identities = [
        (row["scenario_id"], row["binding_type"], row["selector"]) for row in rows
    ]
    return (
        hashlib.sha256(serialize(rows)).hexdigest() != expected_bindings_sha
        or len(identities) != len(set(identities))
    )

negative_rows = []
mutations = {
    "missing": bindings[:-1],
    "extra-unknown": bindings + [{
        "scenario_id": "M2-UNKNOWN-999",
        "classification": "mandatory",
        "lane": "swift-full",
        "binding_type": "xctest",
        "selector": "UnknownTests/testUnknown",
    }],
    "duplicate": bindings + [dict(bindings[0])],
}
for name, candidate in mutations.items():
    if not rejects_exact(candidate):
        raise SystemExit(f"binding negative control was accepted: {name}")
    negative_rows.append((name, "REJECTED"))
(evidence_root / "binding-negative-controls.tsv").write_text(
    "mutation\tresult\n" +
    "".join(f"{name}\t{result}\n" for name, result in negative_rows)
)

case_pattern = re.compile(
    r"Test Case '-\[([^ ]+) ([^\]]+)\]' (started|passed|failed|skipped)"
)
observed = {state: [] for state in ("started", "passed", "failed", "skipped")}
for owner, method, state in case_pattern.findall(
    swift_path.read_text(errors="replace")
):
    observed[state].append(f"{owner}/{method}")
for state, values in observed.items():
    duplicates = sorted(name for name in set(values) if values.count(name) != 1)
    if duplicates:
        raise SystemExit(f"duplicate XCTest {state} records: {duplicates}")

def require_exact_test(name):
    if (name not in observed["started"] or name not in observed["passed"]
            or name in observed["failed"] or name in observed["skipped"]):
        raise SystemExit(f"required XCTest did not pass exactly once: {name}")
    return f"{swift_path.name}:{name}"

def require_line(path, line):
    lines = path.read_text(errors="replace").splitlines()
    if line not in lines:
        raise SystemExit(f"missing exact marker {line!r} in {path}")

def require_test_in_file(path, expected):
    local_observed = {
        state: [] for state in ("started", "passed", "failed", "skipped")
    }
    for owner, method, state in case_pattern.findall(
        path.read_text(errors="replace")
    ):
        local_observed[state].append(f"{owner}/{method}")
    if (local_observed["started"].count(expected) != 1
            or local_observed["passed"].count(expected) != 1
            or expected in local_observed["failed"]
            or expected in local_observed["skipped"]):
        raise SystemExit(
            f"required lane XCTest did not pass exactly once: {expected} in {path}"
        )
    return f"{path.name}:{expected}"

apfs = lanes / "apfs"
metadata_markers = sorted(apfs.glob("metadata-*/comparison.txt"))
performance = json.loads((lanes / "performance/summary.json").read_text())
samples = list(csv.DictReader(
    (lanes / "performance/samples.tsv").open(newline=""), delimiter="\t"
))
route_stdout = lanes / "route-owner/ui-probe.stdout"
deferred_stdout = lanes / "deferred-disabled/ui-probe.stderr"

trace_lines = [
    line for line in swift_path.read_text(errors="replace").splitlines()
    if line.startswith("M2_EVENT_TRACE\t")
]
journal_lines = [
    line for line in swift_path.read_text(errors="replace").splitlines()
    if line.startswith("M2_JOURNAL_DUMP\t")
]
if not trace_lines or len(journal_lines) != 1:
    raise SystemExit("missing M2 event trace or unique volatile journal dump")

def marker_fields(line, marker):
    parts = line.split("\t")
    if parts[0] != marker:
        raise SystemExit(f"wrong marker: {line}")
    fields = {}
    for part in parts[1:]:
        if "=" not in part:
            raise SystemExit(f"malformed marker field: {part}")
        key, value = part.split("=", 1)
        if key in fields or not key or not value:
            raise SystemExit(f"invalid marker field: {part}")
        fields[key] = value
    return fields

parsed_trace = [marker_fields(line, "M2_EVENT_TRACE") for line in trace_lines]
trace_keys = {"operation", "item", "sequence", "durability", "payload"}
if any(set(row) != trace_keys for row in parsed_trace):
    raise SystemExit("M2 event trace fields changed")
operations = {row["operation"] for row in parsed_trace}
sequences = [int(row["sequence"]) for row in parsed_trace]
payloads = [row["payload"] for row in parsed_trace]
if (len(operations) != 1 or sequences != sorted(set(sequences))
        or payloads[0] != "admitted" or payloads[-1] != "completed"
        or not any(value.startswith("receipt:") for value in payloads)
        or any(row["durability"] != "durable" for row in parsed_trace)):
    raise SystemExit("M2 event trace violates operation/order/terminal contract")
journal = marker_fields(journal_lines[0], "M2_JOURNAL_DUMP")
journal_field_order = [
    "operation", "schema", "state", "ordinal", "latest_durable",
    "latest_emitted", "reserved_through", "items", "committed_effects",
    "prior_decisions",
]
if set(journal) != set(journal_field_order):
    raise SystemExit("M2 volatile journal dump fields changed")
if (journal["operation"] not in operations or journal["schema"] != "1"
        or journal["state"] != "completed" or journal["items"] != "1"
        or journal["committed_effects"] != "1"
        or int(journal["latest_durable"]) != max(sequences)
        or journal["latest_emitted"] != journal["latest_durable"]
        or journal["reserved_through"] != journal["latest_durable"]):
    raise SystemExit("M2 volatile journal dump does not match event trace")
(evidence_root / "event-trace.tsv").write_text(
    "operation\titem\tsequence\tdurability\tpayload\n" +
    "".join("\t".join(row[key] for key in (
        "operation", "item", "sequence", "durability", "payload"
    )) + "\n" for row in parsed_trace)
)
(evidence_root / "volatile-journal-dump.tsv").write_text(
    "\t".join(journal_field_order) + "\n" +
    "\t".join(journal[key] for key in journal_field_order) + "\n"
)

def artifact_evidence(row):
    selector = row["selector"]
    kind = row["binding_type"]
    if kind == "xctest":
        if row["lane"] == "swift-full":
            return require_exact_test(selector)
        if row["lane"] == "apfs":
            if selector.endswith("testConfiguredDistinctAPFSVolumeMatrix"):
                return require_test_in_file(apfs / "swift-test.stdout", selector)
            if selector.endswith("testConfiguredRealAPFSNoSpaceLeavesNoPartialFinal"):
                return require_test_in_file(apfs / "enospc-test.stdout", selector)
        raise SystemExit(f"unknown XCTest lane binding: {row}")
    if kind == "artifact" and selector == "six-independent-metadata-comparison.txt-markers":
        if len(metadata_markers) != 6:
            raise SystemExit(f"expected six metadata comparisons, got {metadata_markers}")
        for marker in metadata_markers:
            require_line(marker, "M2-META-001 PASS")
        return "six-metadata-comparisons"
    if kind == "artifact" and \
            selector == "summary.json-thresholds-and-seven-samples-per-engine":
        if (performance.get("scenario") != "M2-PERF-001"
                or performance.get("throughput_pass") is not True
                or performance.get("rss_pass") is not True
                or len([row for row in samples if row["engine"] == "rascal"]) != 7
                or len([row for row in samples if row["engine"] == "cp"]) != 7):
            raise SystemExit("performance evidence is incomplete or below threshold")
        return "performance-summary+14-samples"
    if kind == "release-probe":
        require_line(
            lanes / "static-release/release-probe.stderr",
            "M2_RELEASE_PROBE PASS routes=6 native=0 legacy=0 fixture=unchanged",
        )
        return "release-probe-whole-fixture"
    if kind == "ui-probe" and \
            selector == "fast-terminal-and-partial-commit-refresh-markers":
        for marker in (
            "  ✓ M2 fast terminal registers then converges one refresh",
            "  ✓ M2 partial commit failure refreshes exactly once",
            "  ✓ M2 stale snapshot cannot regress terminal projection",
            "  ✓ M2 unavailable copy has one bridge presentation owner",
            "=== 7 passed, 0 failed ===",
        ):
            require_line(route_stdout, marker)
        return "route-owner-refresh-markers"
    if kind == "ui-probe" and \
            selector == "six-real-owners-one-operation-id-and-zero-legacy":
        for marker in (
            "  ✓ M2 six copy routes complete",
            "  ✓ M2 one unique OperationID per route",
            "  ✓ M2 native routes enqueue zero legacy operations",
            "=== 7 passed, 0 failed ===",
        ):
            require_line(route_stdout, marker)
        return "route-owner-six-real-owners"
    if kind == "probe":
        require_line(
            deferred_stdout,
            "M2_DEFERRED_PROBE PASS volumes=2 routes=12 native=12 legacy=0 finals=0",
        )
        return f"deferred-disabled:{selector}"
    if kind == "gate" and row["scenario_id"] == "M2-EVIDENCE-001":
        return "PENDING_FINALIZE"
    raise SystemExit(f"unknown M2 binding: {row}")

binding_results = []
for row in bindings:
    evidence = artifact_evidence(row)
    binding_results.append({
        **row,
        "status": "PENDING_FINALIZE" if evidence == "PENDING_FINALIZE" else "PASS",
        "evidence": evidence,
    })
output.write_text(
    "scenario_id\tclassification\tlane\tbinding_type\tselector\tstatus\tevidence\n" +
    "".join("\t".join(row[key] for key in (
        "scenario_id", "classification", "lane", "binding_type", "selector",
        "status", "evidence"
    )) + "\n" for row in binding_results)
)
PY

[[ ! -s "$OUT/mandatory-skips.txt" ]]
FINALIZE_READY=1
