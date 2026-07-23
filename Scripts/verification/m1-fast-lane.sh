#!/usr/bin/env bash
set -euo pipefail

readonly PYTHON_BIN=/usr/bin/python3
[[ -x "$PYTHON_BIN" ]] || {
    echo "required system Python is unavailable: $PYTHON_BIN" >&2
    exit 65
}

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HEAD_OID="$(git -C "$ROOT" rev-parse HEAD)"
RUN_ID="${RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)-$$}"
MODE="${1:-full}"
if [[ "$MODE" == "--freeze-smoke-baseline" ]]; then
    LANE="m1-smoke-baseline"
elif [[ "$MODE" == "full" ]]; then
    LANE="m1-fast"
else
    echo "usage: m1-fast-lane.sh [full|--freeze-smoke-baseline]" >&2
    exit 64
fi

EVIDENCE="$ROOT/.build/verification/$HEAD_OID/$LANE/$RUN_ID"
SCRATCH="$ROOT/.build/verification-scratch/$HEAD_OID/$LANE/$RUN_ID"
EXPECTED_MANIFEST_SHA256="4cffd93ab26f4566f5406fb3d1e2866958d741f35495d6ff0286e69d7df62369"
DEFAULT_TIMEOUT_SECONDS="${M1_COMMAND_TIMEOUT_SECONDS:-1200}"
mkdir -p "$EVIDENCE"
cd "$ROOT"

finish() {
    local status=$?
    trap - EXIT
    printf '%s\n' "$status" > "$EVIDENCE/lane.exit"
    find "$EVIDENCE" -type f -not -name evidence.sha256 -print0 \
        | sort -z | xargs -0 shasum -a 256 > "$EVIDENCE/evidence.sha256"
    exit "$status"
}
trap finish EXIT

run_timed() {
    local name="$1" timeout_seconds="$2"
    shift 2
    local restore_errexit=0
    [[ "$-" == *e* ]] && restore_errexit=1
    printf '%q ' "$@" > "$EVIDENCE/$name.command"
    printf '\n' >> "$EVIDENCE/$name.command"
    set +e
    "$PYTHON_BIN" - "$timeout_seconds" "$EVIDENCE/$name.stdout" \
        "$EVIDENCE/$name.stderr" "$@" <<'PY'
import os
import signal
import subprocess
import sys
import time

timeout = float(sys.argv[1])
stdout_path, stderr_path = sys.argv[2:4]
command = sys.argv[4:]
if timeout <= 0 or not command:
    raise SystemExit(64)

def stop_group(process, grace=2.0):
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except (ProcessLookupError, PermissionError):
        return
    deadline = time.monotonic() + grace
    while time.monotonic() < deadline:
        try:
            os.killpg(process.pid, 0)
        except (ProcessLookupError, PermissionError):
            return
        time.sleep(0.05)
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except (ProcessLookupError, PermissionError):
        pass

with open(stdout_path, "wb") as stdout, open(stderr_path, "wb") as stderr:
    process = subprocess.Popen(command, stdout=stdout, stderr=stderr,
                               start_new_session=True)
    try:
        try:
            status = process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            stderr.write(
                f"verification timeout after {timeout:g}s: {command!r}\n".encode()
            )
            stderr.flush()
            stop_group(process)
            process.wait()
            status = 124
    finally:
        # A command can exit while leaving descendants alive. Every lane command
        # owns its complete process group, so both success and failure clean it.
        stop_group(process)
    raise SystemExit(status)
PY
    local status=$?
    if [[ "$restore_errexit" == 1 ]]; then set -e; else set +e; fi
    printf '%s\n' "$status" > "$EVIDENCE/$name.exit"
    if [[ "$status" != 0 ]]; then
        cat "$EVIDENCE/$name.stdout" >&2
        cat "$EVIDENCE/$name.stderr" >&2
        return "$status"
    fi
}

run() {
    local name="$1"
    shift
    run_timed "$name" "$DEFAULT_TIMEOUT_SECONDS" "$@"
}

MATCHED_BUILD_BIN=""
MATCHED_BUILD_RAW_SHA256=""
MATCHED_APP_SIGNED_SHA256=""
MATCHED_BUILD_PAYLOAD_SHA256=""
MATCHED_APP_PAYLOAD_SHA256=""

sha256_file() {
    local output
    output="$(shasum -a 256 "$1")" || return 1
    printf '%s\n' "${output%% *}"
}

find_matching_build_binary() {
    local build_root="$1" configuration="$2" app_binary="$3"
    local comparison_root="$4" report_path="$5"
    MATCHED_BUILD_BIN=""
    MATCHED_BUILD_RAW_SHA256=""
    MATCHED_APP_SIGNED_SHA256=""
    MATCHED_BUILD_PAYLOAD_SHA256=""
    MATCHED_APP_PAYLOAD_SHA256=""

    [[ -d "$build_root" && -f "$app_binary" && -x "$app_binary" ]] || {
        echo "missing $configuration build root or assembled FinderTwo" >&2
        return 1
    }
    [[ ! -e "$comparison_root" ]] || {
        echo "provenance comparison root already exists: $comparison_root" >&2
        return 1
    }
    mkdir -p "$comparison_root" || return 1

    local candidates_file="$comparison_root/candidates.nul"
    find "$build_root" -type f -path "*/$configuration/FinderTwo" -print0 \
        > "$candidates_file" || return 1
    local candidate="" unique_candidate="" candidate_count=0
    while IFS= read -r -d '' candidate; do
        ((candidate_count += 1))
        [[ "$candidate_count" == 1 ]] || {
            echo "multiple candidate $configuration FinderTwo binaries under $build_root" >&2
            return 1
        }
        unique_candidate="$candidate"
    done < "$candidates_file"
    [[ "$candidate_count" == 1 ]] || {
        echo "no candidate $configuration FinderTwo binary under $build_root" >&2
        return 1
    }

    candidate="$unique_candidate"
    local suffix="/Contents/MacOS/FinderTwo"
    [[ "$app_binary" == *"$suffix" ]] || {
        echo "assembled FinderTwo path is not inside an app bundle: $app_binary" >&2
        return 1
    }
    local app_root="${app_binary%$suffix}"
    local reference_app="$comparison_root/reference.app"
    local reference_binary="$reference_app/Contents/MacOS/FinderTwo"
    cp -R "$app_root" "$reference_app" || return 1
    cp -p "$candidate" "$reference_binary" || return 1
    codesign --force --deep --sign - --timestamp=none "$reference_app" \
        > "$comparison_root/reference-codesign.stdout" \
        2> "$comparison_root/reference-codesign.stderr" || return 1

    local build_raw_sha app_signed_sha build_payload_sha app_payload_sha
    build_raw_sha="$(sha256_file "$candidate")" || return 1
    app_signed_sha="$(sha256_file "$app_binary")" || return 1
    build_payload_sha="$(sha256_file "$reference_binary")" || return 1
    app_payload_sha="$(sha256_file "$app_binary")" || return 1

    local comparison_status payload_match=false
    if cmp -s "$reference_binary" "$app_binary"; then
        comparison_status=0
        payload_match=true
    else
        comparison_status=$?
        [[ "$comparison_status" == 1 ]] || {
            echo "reconstructed $configuration payload comparison failed with exit $comparison_status" >&2
            return 1
        }
    fi
    {
        printf 'configuration\tbuild_candidate\tsigned_app\traw_build_sha256\tsigned_app_sha256\treconstructed_signed_sha256\tactual_signed_sha256\tpayload_match\n'
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$configuration" "$candidate" "$app_binary" "$build_raw_sha" \
            "$app_signed_sha" "$build_payload_sha" "$app_payload_sha" "$payload_match"
    } > "$report_path" || return 1
    [[ "$comparison_status" == 0 ]] || {
        echo "assembled $configuration FinderTwo differs from deterministic ad-hoc reconstruction" >&2
        return 1
    }
    codesign --verify --deep --strict "$app_root" \
        > "$comparison_root/actual-codesign-verify.stdout" \
        2> "$comparison_root/actual-codesign-verify.stderr" || return 1
    codesign --verify --deep --strict "$reference_app" \
        > "$comparison_root/reference-codesign-verify.stdout" \
        2> "$comparison_root/reference-codesign-verify.stderr" || return 1

    MATCHED_BUILD_BIN="$candidate"
    MATCHED_BUILD_RAW_SHA256="$build_raw_sha"
    MATCHED_APP_SIGNED_SHA256="$app_signed_sha"
    MATCHED_BUILD_PAYLOAD_SHA256="$build_payload_sha"
    MATCHED_APP_PAYLOAD_SHA256="$app_payload_sha"
}

record_environment() {
    sw_vers > "$EVIDENCE/os.txt"
    xcodebuild -version > "$EVIDENCE/xcode.txt"
    swift --version > "$EVIDENCE/swift.txt"
    sqlite3 --version > "$EVIDENCE/sqlite.txt"
    git rev-parse HEAD > "$EVIDENCE/head.txt"
    git status --porcelain=v2 --untracked-files=all > "$EVIDENCE/git-status-v2.txt"
    git diff --binary > "$EVIDENCE/unstaged.diff"
    git diff --cached --binary > "$EVIDENCE/staged.diff"
    shasum -a 256 "$EVIDENCE/unstaged.diff" > "$EVIDENCE/unstaged-diff.sha256"
    shasum -a 256 "$EVIDENCE/staged.diff" > "$EVIDENCE/staged-diff.sha256"
    : > "$EVIDENCE/untracked-content.sha256"
    while IFS= read -r -d '' path; do
        shasum -a 256 "$path" >> "$EVIDENCE/untracked-content.sha256"
    done < <(git ls-files --others --exclude-standard -z | sort -z)
    printf 'seed\tdeterministic-id-generators\n' > "$EVIDENCE/seed.tsv"
    printf 'scenario\treason\n' > "$EVIDENCE/mandatory-skip-list.tsv"
    [[ "$(wc -l < "$EVIDENCE/mandatory-skip-list.tsv" | tr -d ' ')" == "1" ]] || {
        echo "mandatory local skip list is non-empty" >&2
        exit 1
    }
    printf '%s\n' \
        'journal=M1 N/A; UnavailableOperationJournal safe mode, no live journal mutation' \
        'M1-CI-001=is finalized only after the complete lane and workspace-stability check' \
        > "$EVIDENCE/journal-and-remote-boundary.txt"
    if [[ "${GITHUB_ACTIONS:-false}" == "true" ]]; then
        local required_name
        for required_name in GITHUB_RUN_ID GITHUB_RUN_ATTEMPT GITHUB_REPOSITORY \
            GITHUB_REF GITHUB_SHA GITHUB_WORKFLOW GITHUB_JOB; do
            [[ -n "${!required_name:-}" ]] || {
                echo "GitHub Actions metadata is missing $required_name" >&2
                exit 1
            }
        done
        {
            printf 'field\tvalue\n'
            printf 'run_id\t%s\n' "$GITHUB_RUN_ID"
            printf 'run_attempt\t%s\n' "$GITHUB_RUN_ATTEMPT"
            printf 'repository\t%s\n' "$GITHUB_REPOSITORY"
            printf 'ref\t%s\n' "$GITHUB_REF"
            printf 'sha\t%s\n' "$GITHUB_SHA"
            printf 'workflow\t%s\n' "$GITHUB_WORKFLOW"
            printf 'job\t%s\n' "$GITHUB_JOB"
            printf 'server_url\t%s\n' "${GITHUB_SERVER_URL:-unknown}"
        } > "$EVIDENCE/github-run-metadata.tsv"
        [[ "$(git rev-parse HEAD)" == "$GITHUB_SHA" ]] || {
            echo "checked-out HEAD does not match GITHUB_SHA" >&2
            exit 1
        }
    fi
    cat > "$EVIDENCE/test-manifest.tsv" <<'EOF'
stable_id	test_name
M1-UNIT-001	RascalFileOperationsTests.RequestValidatorTests/testAbsoluteFileURLsAndNormalizedDuplicateDirectoryEntries
M1-UNIT-002	RascalFileOperationsTests.RequestValidatorTests/testCallerCannotForgePortableMetadataPolicy
M1-UNIT-003	RascalFileOperationsTests.RequestValidatorTests/testEveryKindAcceptsItsNormativeStructuralShape
M1-UNIT-004	RascalFileOperationsTests.RequestValidatorTests/testKindCardinalityDestinationModeAndCreateDescriptorAreValidated
M1-UNIT-005	RascalFileOperationsTests.RequestValidatorTests/testOverlapIsLexicalNoFollowAndHardLinkPathsRemainDistinct
M1-UNIT-006	RascalFileOperationsTests.RequestValidatorTests/testProjectedDestinationsRespectExactAndContainerModes
M1-UNIT-007	RascalFileOperationsTests.RequestValidatorTests/testSchemaVersionIsRejectedBeforeAdmission
M1-UNIT-008	RascalFileOperationsTests.StateMachineTests/testAggregateTerminalStatesAreUnambiguous
M1-UNIT-009	RascalFileOperationsTests.StateMachineTests/testIllegalTransitionCarriesTypedContext
M1-UNIT-010	RascalFileOperationsTests.StateMachineTests/testItemTransitionCartesianProductMatchesNormativeTable
M1-UNIT-011	RascalFileOperationsTests.StateMachineTests/testLatePauseIsWithdrawnWhenPhaseQuiesces
M1-UNIT-012	RascalFileOperationsTests.StateMachineTests/testOperationTransitionCartesianProductMatchesNormativeGraph
M1-RECOVERY-001	RascalFileOperationsTests.RecoverySafetyTests/testCleanupRecoveryTreatsConfirmedAbsentSourceAsCompletedWithoutDelete
M1-RECOVERY-002	RascalFileOperationsTests.RecoverySafetyTests/testCleanupRetryAndRetainConvergeFromConfirmedSourceStateAndAreRestartIdempotent
M1-RECOVERY-003	RascalFileOperationsTests.RecoverySafetyTests/testCleanupRetryReinspectsIdentityAndKeepsChangedOrUnknownTokenLiveAcrossRestart
M1-RECOVERY-004	RascalFileOperationsTests.RecoverySafetyTests/testFinalizeCommittedItemsExecutesOnceAndClearsTerminalFailure
M1-RECOVERY-005	RascalFileOperationsTests.RecoverySafetyTests/testInitialCleanupInspectionHandlesAllOutcomesWithoutGuessing
M1-RECOVERY-006	RascalFileOperationsTests.RecoverySafetyTests/testMoveVerificationUsesKnownTopologyAndFailsClosedWhenUnknown
M1-RECOVERY-007	RascalFileOperationsTests.RecoverySafetyTests/testMultiItemRollbackResumesFromDurablePerItemLedgerAfterRestart
M1-RECOVERY-008	RascalFileOperationsTests.RecoverySafetyTests/testPhaseAuthorizationIsRecheckedAfterActorReentrancyWindow
M1-RECOVERY-009	RascalFileOperationsTests.RecoverySafetyTests/testPreflightCancellationKeepsActiveSlotUntilAdapterQuiesces
M1-RECOVERY-010	RascalFileOperationsTests.RecoverySafetyTests/testRestartFailsClosedForUnexplainedCommitAndCleanupEffects
M1-RECOVERY-011	RascalFileOperationsTests.RecoverySafetyTests/testResumeFromVerifiedStageExecutesAndIsDurablyIdempotentAcrossRestart
M1-RECOVERY-012	RascalFileOperationsTests.RecoverySafetyTests/testAmbiguousRecoveryEffectIsInspectedAndNeverReplayed
M1-RECOVERY-013	RascalFileOperationsTests.RecoverySafetyTests/testCleanupProjectionRepairsAfterItemTerminalCheckpointFailure
M1-RECOVERY-014	RascalFileOperationsTests.RecoverySafetyTests/testConcurrentSameRecoveryActionHasOneLeaseAndOneEffect
M1-RECOVERY-015	RascalFileOperationsTests.RecoverySafetyTests/testDiscardProjectionRepairsAfterItemTerminalCheckpointFailure
M1-RECOVERY-016	RascalFileOperationsTests.RecoverySafetyTests/testDurableRecoveryChoiceRejectsSiblingInProcessAndAfterRestart
M1-RECOVERY-017	RascalFileOperationsTests.RecoverySafetyTests/testFatalModeControlsProduceNoJournalMutationOrFilesystemEffect
M1-RECOVERY-018	RascalFileOperationsTests.RecoverySafetyTests/testFatalStartupDominatesRecoverableStateInBothLoadOrders
M1-RECOVERY-019	RascalFileOperationsTests.RecoverySafetyTests/testFinalRecoveryCommandCheckpointCanBeCompletedAfterRestartWithoutEffectReplay
M1-RECOVERY-020	RascalFileOperationsTests.RecoverySafetyTests/testFinalizeProjectionRepairsAfterItemsTerminalCheckpointFailure
M1-RECOVERY-021	RascalFileOperationsTests.RecoverySafetyTests/testInitialStagingCancelAmbiguousSurvivesRestartAndConvergesByInspection
M1-RECOVERY-022	RascalFileOperationsTests.RecoverySafetyTests/testInitialStagingCancelIntentBeforeEffectRestartsWithSameEffectIDOnce
M1-RECOVERY-023	RascalFileOperationsTests.RecoverySafetyTests/testInitialStagingCancelResultJournalFailureRestartsWithoutSecondEffect
M1-RECOVERY-024	RascalFileOperationsTests.RecoverySafetyTests/testIntentBeforeEffectCrashReusesStableEffectIDAfterNotPerformedInspection
M1-RECOVERY-025	RascalFileOperationsTests.RecoverySafetyTests/testProgressJournalFailureRevokesPhaseBeforeAnyFilesystemEffect
M1-RECOVERY-026	RascalFileOperationsTests.RecoverySafetyTests/testRecoveryCleanupReceiptFailureRestartsWithoutSecondCleanup
M1-RECOVERY-027	RascalFileOperationsTests.RecoverySafetyTests/testRecoveryModeGuardsAllControlsWithoutMutatingSiblingOperations
M1-RECOVERY-028	RascalFileOperationsTests.RecoverySafetyTests/testRecoveryResultCheckpointFailureInspectsWithoutSecondEffect
M1-RECOVERY-029	RascalFileOperationsTests.RecoverySafetyTests/testRestartTreatsInterruptedPrecommitAsRecoveryRequiredWithoutAction
M1-RECOVERY-030	RascalFileOperationsTests.RecoverySafetyTests/testRetainProjectionRepairsAfterItemTerminalCheckpointFailure
M1-RECOVERY-031	RascalFileOperationsTests.RecoverySafetyTests/testRollbackProjectionRepairsAfterItemsTerminalCheckpointFailure
M1-RECOVERY-032	RascalFileOperationsTests.RecoverySafetyTests/testTwoItemRecoveryPersistsEachIntentAndInspectsOnlyAmbiguousSecondItem
M1-RECOVERY-033	RascalFileOperationsTests.RecoverySafetyTests/testUnknownRecoveryInspectionPreservesIntentAndTokenWithoutNewMutation
M1-RECOVERY-034	RascalFileOperationsTests.RecoverySafetyTests/testQueuedAdmissionIsReplayDiscoverableBeforeExecutionStarts
M1-RECOVERY-035	RascalFileOperationsTests.RecoverySafetyTests/testQueuedPlannedOperationCanBeCancelledWithoutReleasingActiveSlot
M1-RECOVERY-036	RascalFileOperationsTests.RecoverySafetyTests/testNotCommittedInspectionDurablyCleansStagingBeforeRollbackCancellation
M1-EVENT-T001	RascalFileOperationsIntegrationTests.EventStreamIntegrationTests/testLongReplayIsPagedOutsideBoundedLiveQueue
M1-EVENT-T002	RascalFileOperationsIntegrationTests.EventStreamIntegrationTests/testProgressCoalescesPerItemWithoutOverwritingAnotherItem
M1-EVENT-T003	RascalFileOperationsIntegrationTests.EventStreamIntegrationTests/testProgressCoalescingNeverCrossesInterveningStateEvents
M1-EVENT-T004	RascalFileOperationsIntegrationTests.EventStreamIntegrationTests/testReplayThenConcurrentLiveHandoffHasNoMarkerDuplicateOrReordering
M1-EVENT-T005	RascalFileOperationsIntegrationTests.EventStreamIntegrationTests/testReservedGapSurvivesRestartAndProgressNeverMovesBackward
M1-EVENT-T006	RascalFileOperationsIntegrationTests.EventStreamIntegrationTests/testSequenceExhaustionFailsClosedWithoutWrapping
M1-EVENT-T007	RascalFileOperationsIntegrationTests.EventStreamIntegrationTests/testSlowSubscriberOverflowEndsOnlyThatStreamAndResubscribeConverges
M1-EVENT-T008	RascalFileOperationsIntegrationTests.EventStreamIntegrationTests/testTwoSubscribersReceiveIndependentIdenticalBroadcasts
M1-EVENT-T009	RascalFileOperationsIntegrationTests.EventStreamIntegrationTests/testZZCancellingAnIdleSubscriptionFinishesItsPendingPull
M1-EVENT-T010	RascalFileOperationsIntegrationTests.EventStreamIntegrationTests/testRecoveryConvergenceIsDurableReplayableAndBindsSuccessorAction
M1-SERVICE-001	RascalFileOperationsIntegrationTests.ServiceIntegrationTests/testCleanupGuardsStopBeforeAndAfterUnsafeJournalChanges
M1-SERVICE-002	RascalFileOperationsIntegrationTests.ServiceIntegrationTests/testCleanupRecoveryRetriesActualEffectAndIsIdempotent
M1-SERVICE-003	RascalFileOperationsIntegrationTests.ServiceIntegrationTests/testCommitPhaseRejectsCancellationAndCompletesOneCommitEffect
M1-SERVICE-004	RascalFileOperationsIntegrationTests.ServiceIntegrationTests/testCopyAndMoveSourceCleanupPlansAndReceiptsAreConsistent
M1-SERVICE-005	RascalFileOperationsIntegrationTests.ServiceIntegrationTests/testDecisionWaitingOccupiesActiveSlotAndDecisionLedgerIsDurable
M1-SERVICE-006	RascalFileOperationsIntegrationTests.ServiceIntegrationTests/testDefaultSafeModeValidatesBeforeRefusingAndCreatesNoOperation
M1-SERVICE-007	RascalFileOperationsIntegrationTests.ServiceIntegrationTests/testDurableEffectLedgerSuppressesCommitAcrossServiceRestart
M1-SERVICE-008	RascalFileOperationsIntegrationTests.ServiceIntegrationTests/testExecutableKindsCompleteAndMovePolicyIsRaisedToSHA256
M1-SERVICE-009	RascalFileOperationsIntegrationTests.ServiceIntegrationTests/testJournalFailureAfterCommitEffectLeavesNoRetryableReceipt
M1-SERVICE-010	RascalFileOperationsIntegrationTests.ServiceIntegrationTests/testJournalFailureBeforeCommitIntentPreventsCommitAndForcesSafeMode
M1-SERVICE-011	RascalFileOperationsIntegrationTests.ServiceIntegrationTests/testMetadataApprovalBindsLossesKindAndScope
M1-SERVICE-012	RascalFileOperationsIntegrationTests.ServiceIntegrationTests/testMetadataCancellationWaitsForExecutorQuiescenceAndStartsNoLaterPhase
M1-SERVICE-013	RascalFileOperationsIntegrationTests.ServiceIntegrationTests/testPartialCommitOffersFinalizeAndRollbackAndRollbackExecutes
M1-SERVICE-014	RascalFileOperationsIntegrationTests.ServiceIntegrationTests/testPauseResumeAndCommittedAwaitingCleanupCancellation
M1-SERVICE-015	RascalFileOperationsIntegrationTests.ServiceIntegrationTests/testPlanningCancellationQuiescesBeforeNextOperationStarts
M1-SERVICE-016	RascalFileOperationsIntegrationTests.ServiceIntegrationTests/testPrecommitCancellationUsesRecoveryLedgerForEveryCleanupOutcome
M1-SERVICE-017	RascalFileOperationsIntegrationTests.ServiceIntegrationTests/testProjectedNameCollisionAndUnknownEquivalenceStopBeforeEffects
M1-SERVICE-018	RascalFileOperationsIntegrationTests.ServiceIntegrationTests/testRecoveryActionsAreBoundUniqueAndPersistAcrossRestart
M1-SERVICE-019	RascalFileOperationsIntegrationTests.ServiceIntegrationTests/testRestartResumesDecisionThatWasDurableBeforeStateTransition
M1-SERVICE-020	RascalFileOperationsIntegrationTests.ServiceIntegrationTests/testRetryProducesOneCommittedEffectAndCannotPreemptAnotherOperation
M1-SERVICE-021	RascalFileOperationsIntegrationTests.ServiceIntegrationTests/testSingleActiveSchedulerPreservesSubmissionOrdinal
M1-SERVICE-022	RascalFileOperationsIntegrationTests.ServiceIntegrationTests/testSkipReturnsThroughPreflightAndRemainingScopeAppliesToAllItems
M1-SERVICE-023	RascalFileOperationsIntegrationTests.ServiceIntegrationTests/testSubmitReturnsOnlyAfterPlannedIntentIsDurable
M1-SERVICE-024	RascalFileOperationsIntegrationTests.ServiceIntegrationTests/testUnknownControlIsDiagnosticOnlyAndKnownRejectionFailureEntersSafeMode
M1-SERVICE-025	RascalFileOperationsIntegrationTests.ServiceIntegrationTests/testWaitingCancellationDurablyClearsDecisionToken
EOF
    cat > "$EVIDENCE/scenario-manifest.tsv" <<'EOF'
stable_id	lane	milestone_mandatory	local_required	description
M1-CORE-001	local-static	true	true	Core dependency and product boundary
M1-STATE-001	local-swift	true	true	State control recovery and idempotency XCTest contract
M1-EVENT-001	local-swift	true	true	Strict structured operation event trace
M1-GATE-D-001	local-gate	true	true	Debug legacy writes denied without exact opt-in
M1-GATE-L-001	local-gate	true	true	Debug legacy writes allowed only with exact opt-in
M1-GATE-R-001	local-gate	true	true	Release legacy writes denied even with opt-in
M1-BUILD-001	local-build	true	true	Clean ad-hoc signing fallback build and provenance
M1-COMPAT-001	local-compat	true	true	Exact 605 smoke assertions and zero GUI failures
M1-CI-001	remote-github	true	false	GitHub macOS fast lane on attributable commit
EOF
    shasum -a 256 "$EVIDENCE/test-manifest.tsv" "$EVIDENCE/scenario-manifest.tsv" \
        > "$EVIDENCE/stable-manifests.sha256"
}

verify_environment_unchanged() {
    git rev-parse HEAD > "$EVIDENCE/head-end.txt"
    git status --porcelain=v2 --untracked-files=all > "$EVIDENCE/git-status-v2-end.txt"
    git diff --binary > "$EVIDENCE/unstaged-end.diff"
    git diff --cached --binary > "$EVIDENCE/staged-end.diff"
    : > "$EVIDENCE/untracked-content-end.sha256"
    while IFS= read -r -d '' path; do
        shasum -a 256 "$path" >> "$EVIDENCE/untracked-content-end.sha256"
    done < <(git ls-files --others --exclude-standard -z | sort -z)
    cmp "$EVIDENCE/head.txt" "$EVIDENCE/head-end.txt"
    cmp "$EVIDENCE/git-status-v2.txt" "$EVIDENCE/git-status-v2-end.txt"
    cmp "$EVIDENCE/unstaged.diff" "$EVIDENCE/unstaged-end.diff"
    cmp "$EVIDENCE/staged.diff" "$EVIDENCE/staged-end.diff"
    cmp "$EVIDENCE/untracked-content.sha256" "$EVIDENCE/untracked-content-end.sha256"
    shasum -a 256 "$EVIDENCE/unstaged-end.diff" > "$EVIDENCE/unstaged-end-diff.sha256"
    shasum -a 256 "$EVIDENCE/staged-end.diff" > "$EVIDENCE/staged-end-diff.sha256"
    printf 'start_end_git_state\tPASS\n' > "$EVIDENCE/workspace-stability.tsv"
}

make_assertion_manifest() {
    local raw="$1"
    local manifest="$2"
    "$PYTHON_BIN" - "$raw" "$manifest" <<'PY'
import pathlib
import re
import sys

raw = pathlib.Path(sys.argv[1]).read_text(errors="replace").splitlines()
labels = []
for line in raw:
    if not line.startswith("  ✓ "):
        continue
    label = line[len("  ✓ "):]
    label = re.sub(r"got [0-9]+(?:\.[0-9]+)?(ms|ns)", r"got <N>\1", label)
    label = re.sub(r"matched [0-9]+", "matched <N>", label)
    labels.append(label)
if len(labels) != 605:
    raise SystemExit(f"expected 605 assertion labels, got {len(labels)}")
pathlib.Path(sys.argv[2]).write_text(
    "".join(f"FT-{index:04d}\t{label}\n" for index, label in enumerate(labels, 1))
)
PY
}

validate_swift_evidence() {
    local stdout_path="$1" result_path="$2" trace_path="$3"
    "$PYTHON_BIN" - "$EVIDENCE/test-manifest.tsv" "$stdout_path" \
        "$result_path" "$trace_path" <<'PY'
import csv
import pathlib
import re
import sys

manifest_path, stdout_path, result_path, trace_path = map(pathlib.Path, sys.argv[1:])
with manifest_path.open(newline="") as handle:
    rows = list(csv.DictReader(handle, delimiter="\t"))
if not rows or set(rows[0]) != {"stable_id", "test_name"}:
    raise SystemExit("invalid embedded M1 test manifest header")
ids = [row["stable_id"] for row in rows]
names = [row["test_name"] for row in rows]
if len(ids) != len(set(ids)) or len(names) != len(set(names)):
    raise SystemExit("duplicate stable ID or test name in M1 test manifest")

text = stdout_path.read_text(errors="replace")
case_pattern = re.compile(
    r"Test Case '-\[([^ ]+) ([^\]]+)\]' (started|passed|failed|skipped)"
)
observed = {state: [] for state in ("started", "passed", "failed", "skipped")}
for owner, method, state in case_pattern.findall(text):
    observed[state].append(f"{owner}/{method}")
expected = set(names)
for state, values in observed.items():
    duplicates = sorted(name for name in set(values) if values.count(name) != 1)
    if duplicates:
        raise SystemExit(f"duplicate XCTest {state} records: {duplicates}")
if set(observed["started"]) != expected:
    raise SystemExit(
        f"exact test manifest mismatch: missing={sorted(expected-set(observed['started']))} "
        f"unexpected={sorted(set(observed['started'])-expected)}"
    )
if set(observed["passed"]) != expected or observed["failed"] or observed["skipped"]:
    raise SystemExit(f"mandatory Swift test failed/skipped: {observed}")

name_to_id = {row["test_name"]: row["stable_id"] for row in rows}
result_path.write_text(
    "stable_id\ttest_name\tstatus\n" +
    "".join(f"{name_to_id[name]}\t{name}\tPASS\n" for name in names)
)

trace_lines = [line for line in text.splitlines()
               if line.startswith("M1_EVENT_TRACE\t")]
if not trace_lines:
    raise SystemExit("missing structured M1 event trace")
uuid_pattern = re.compile(
    r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"
)
parsed = []
for line in trace_lines:
    parts = line.split("\t")[1:]
    if any("=" not in part for part in parts):
        raise SystemExit(f"malformed trace field: {line}")
    fields = dict(part.split("=", 1) for part in parts)
    required = {"case", "operation", "item", "sequence", "durability", "payload"}
    if set(fields) != required or len(parts) != len(required):
        raise SystemExit(f"invalid event trace fields: {fields}")
    if fields["case"] != "M1-EVENT-001":
        raise SystemExit(f"wrong event trace case: {fields['case']}")
    if not uuid_pattern.fullmatch(fields["operation"]):
        raise SystemExit(f"invalid operation UUID: {fields['operation']}")
    if fields["item"] != "-" and not uuid_pattern.fullmatch(fields["item"]):
        raise SystemExit(f"invalid item UUID: {fields['item']}")
    if fields["durability"] not in {"durable", "transient"}:
        raise SystemExit(f"invalid durability: {fields['durability']}")
    try:
        sequence = int(fields["sequence"])
    except ValueError as error:
        raise SystemExit(f"invalid sequence: {fields['sequence']}") from error
    if sequence <= 0:
        raise SystemExit("event sequence must be positive")
    fields["sequence_value"] = sequence
    parsed.append(fields)
if len({row["operation"] for row in parsed}) != 1:
    raise SystemExit("event trace crosses operation IDs")
item_ids = {row["item"] for row in parsed if row["item"] != "-"}
if len(item_ids) != 1:
    raise SystemExit(f"single-item trace uses multiple item IDs: {sorted(item_ids)}")
sequences = [row["sequence_value"] for row in parsed]
if any(left >= right for left, right in zip(sequences, sequences[1:])):
    raise SystemExit(f"event trace is not strictly increasing: {sequences}")

state = r"(?:planned|preflight|waitingForDecision|staging|paused|metadata|verifying|committing|committedAwaitingCleanup|sourceQuarantining|cleaningSource|completed|completedWithSkips|completedWithSourceRetained|cancelled|failedRecoverable|recoveryRequired|cleanupRequired|rolledBack)"
item_state = r"(?:pending|preflight|waitingForDecision|staging|paused|metadata|verifying|committing|committed|committedAwaitingCleanup|sourceQuarantining|cleaningSource|completed|skipped|cancelled|failedRecoverable|recoveryRequired|cleanupRequired|rolledBack)"
payload_grammar = re.compile(
    rf"^(?:admitted|state:{state}->{state}|item:{item_state}->{item_state}|"
    r"progress:[0-9]+|receipt:cleanupPending=(?:true|false)|completed)$"
)
for row in parsed:
    payload = row["payload"]
    if not payload_grammar.fullmatch(payload):
        raise SystemExit(f"payload violates strict grammar: {payload}")
    item_scoped = payload.startswith(("item:", "progress:", "receipt:"))
    operation_scoped = payload == "admitted" or payload.startswith("state:") or payload == "completed"
    if item_scoped and row["item"] == "-":
        raise SystemExit(f"item-scoped payload lacks item ID: {payload}")
    if operation_scoped and row["item"] != "-":
        raise SystemExit(f"operation-scoped payload has item ID: {payload}")
    expected_durability = "transient" if payload.startswith("progress:") else "durable"
    if row["durability"] != expected_durability:
        raise SystemExit(f"payload durability mismatch: {payload}")

canonical = [
    ("-", 1, "durable", "admitted"),
    ("-", 2, "durable", "state:planned->preflight"),
    ("item", 3, "durable", "item:pending->preflight"),
    ("item", 4, "durable", "item:preflight->staging"),
    ("-", 5, "durable", "state:preflight->staging"),
    ("item", 6, "transient", "progress:1"),
    ("item", 14, "durable", "item:staging->paused"),
    ("-", 15, "durable", "state:staging->paused"),
    ("item", 16, "durable", "item:paused->staging"),
    ("-", 17, "durable", "state:paused->staging"),
    ("item", 19, "transient", "progress:3"),
    ("item", 26, "durable", "item:staging->metadata"),
    ("-", 27, "durable", "state:staging->metadata"),
    ("item", 28, "durable", "item:metadata->verifying"),
    ("-", 29, "durable", "state:metadata->verifying"),
    ("item", 30, "durable", "item:verifying->committing"),
    ("-", 31, "durable", "state:verifying->committing"),
    ("item", 32, "durable", "receipt:cleanupPending=false"),
    ("item", 33, "durable", "item:committing->committed"),
    ("item", 34, "durable", "item:committed->completed"),
    ("-", 35, "durable", "state:committing->completed"),
    ("-", 36, "durable", "completed"),
]
observed_trace = [
    ("-" if row["item"] == "-" else "item", row["sequence_value"],
     row["durability"], row["payload"])
    for row in parsed
]
if observed_trace != canonical:
    raise SystemExit(
        f"event trace differs from canonical state/event sequence: {observed_trace}"
    )

trace_path.write_text(
    "case\toperation\titem\tsequence\tdurability\tpayload\n" +
    "".join("\t".join(row[key] for key in (
        "case", "operation", "item", "sequence", "durability", "payload"
    )) + "\n" for row in parsed)
)
print(f"Swift evidence PASS ({len(names)} exact tests, {len(parsed)} trace events)")
PY
}

validate_scenarios() {
    local manifest="$1" output="$2" marker_root="$3"
    "$PYTHON_BIN" - "$manifest" "$output" "$marker_root" <<'PY'
import csv
import pathlib
import sys

manifest, output, marker_root = map(pathlib.Path, sys.argv[1:])
with manifest.open(newline="") as handle:
    rows = list(csv.DictReader(handle, delimiter="\t"))
header = {"stable_id", "lane", "milestone_mandatory", "local_required", "description"}
if not rows or set(rows[0]) != header:
    raise SystemExit("invalid embedded M1 scenario manifest")
expected = [
    ("M1-CORE-001", "local-static", "true", "true"),
    ("M1-STATE-001", "local-swift", "true", "true"),
    ("M1-EVENT-001", "local-swift", "true", "true"),
    ("M1-GATE-D-001", "local-gate", "true", "true"),
    ("M1-GATE-L-001", "local-gate", "true", "true"),
    ("M1-GATE-R-001", "local-gate", "true", "true"),
    ("M1-BUILD-001", "local-build", "true", "true"),
    ("M1-COMPAT-001", "local-compat", "true", "true"),
    ("M1-CI-001", "remote-github", "true", "false"),
]
tuples = [tuple(row[key] for key in (
    "stable_id", "lane", "milestone_mandatory", "local_required"
)) for row in rows]
if tuples != expected or len({row[0] for row in tuples}) != len(tuples):
    raise SystemExit(f"scenario tuples must be exactly {expected}, got {tuples}")
results = []
for row in rows:
    stable_id = row["stable_id"]
    if stable_id == "M1-CI-001":
        marker = marker_root / "scenario-M1-CI-001.pass"
        status = "PASS" if marker.is_file() else "NOT-EVALUATED-LOCAL-RUN"
    else:
        marker = marker_root / f"scenario-{stable_id}.pass"
        status = "PASS" if marker.is_file() else "FAIL-MISSING-EVIDENCE"
    results.append((row, status))
failures = [row["stable_id"] for row, status in results
            if row["stable_id"] != "M1-CI-001"
            and row["milestone_mandatory"] == "true" and status != "PASS"]
if failures:
    raise SystemExit(f"mandatory local scenarios lack evidence: {failures}")
output.write_text(
    "stable_id\tlane\tmilestone_mandatory\tlocal_required\tstatus\tdescription\n" +
    "".join("\t".join((
        row["stable_id"], row["lane"], row["milestone_mandatory"],
        row["local_required"], status, row["description"]
    )) + "\n" for row, status in results)
)
PY
}

record_environment
mkdir -p "$SCRATCH/volume-module-cache"
VOLUME_PROBE='import Foundation
let url = URL(fileURLWithPath: CommandLine.arguments[1])
let keys: Set<URLResourceKey> = [.volumeIdentifierKey, .volumeUUIDStringKey, .volumeLocalizedFormatDescriptionKey, .volumeNameKey]
let values = try url.resourceValues(forKeys: keys)
print("identifier=\(String(describing: values.volumeIdentifier))")
print("uuid=\(values.volumeUUIDString ?? "unknown")")
print("format=\(values.volumeLocalizedFormatDescription ?? "unknown")")
print("name=\(values.volumeName ?? "unknown")")'
run volume-info env \
    CLANG_MODULE_CACHE_PATH="$SCRATCH/volume-module-cache" \
    SWIFT_MODULECACHE_PATH="$SCRATCH/volume-module-cache" \
    swift -e "$VOLUME_PROBE" "$ROOT"

if [[ "$MODE" == "--freeze-smoke-baseline" ]]; then
    BIN="$ROOT/build/Rascal.app/Contents/MacOS/FinderTwo"
    [[ -x "$BIN" ]] || { echo "baseline requires an existing debug FinderTwo binary" >&2; exit 1; }
    shasum -a 256 "$BIN" > "$EVIDENCE/finder-two-debug-before-smoke.sha256"
    run smoke-baseline env RASCAL_ENABLE_LEGACY_WRITES=1 bash ./smoketest.sh
    [[ "$(grep -Ec '^=== 605 passed, 0 failed ===$' "$EVIDENCE/smoke-baseline.stdout")" == "1" ]] || {
        echo "baseline smoke summary is not exactly 605 passed, 0 failed" >&2
        exit 1
    }
    make_assertion_manifest "$EVIDENCE/smoke-baseline.stdout" "$EVIDENCE/assertion-manifest.tsv"
    shasum -a 256 "$EVIDENCE/assertion-manifest.tsv" > "$EVIDENCE/assertion-manifest.sha256"
    shasum -a 256 "$BIN" > "$EVIDENCE/finder-two-debug-after-smoke.sha256"
    cmp "$EVIDENCE/finder-two-debug-before-smoke.sha256" "$EVIDENCE/finder-two-debug-after-smoke.sha256"
    ACTUAL="$(awk '{print $1}' "$EVIDENCE/assertion-manifest.sha256")"
    echo "M1 smoke baseline PASS hash=$ACTUAL evidence=$EVIDENCE"
    exit 0
fi

run_timed swift-test 600 swift test --disable-sandbox --scratch-path "$SCRATCH/swift-tests" \
    --filter 'EventStreamIntegrationTests|RecoverySafetyTests|RequestValidatorTests|ServiceIntegrationTests|StateMachineTests'
validate_swift_evidence "$EVIDENCE/swift-test.stdout" \
    "$EVIDENCE/test-results.tsv" "$EVIDENCE/event-trace.tsv"
touch "$EVIDENCE/scenario-M1-STATE-001.pass" "$EVIDENCE/scenario-M1-EVENT-001.pass"

run core-boundary bash Scripts/verification/m1-core-boundary-scan.sh "$EVIDENCE/core-boundary"
touch "$EVIDENCE/scenario-M1-CORE-001.pass"
run ad-hoc-build env M1_AD_HOC_SCRATCH="$SCRATCH/ad-hoc-build" \
    bash Scripts/verification/m1-ad-hoc-signing-fallback.sh "$EVIDENCE/ad-hoc-build"
touch "$EVIDENCE/scenario-M1-BUILD-001.pass"

DEBUG_APP_BIN="$ROOT/build/Rascal.app/Contents/MacOS/FinderTwo"
find_matching_build_binary "$SCRATCH/ad-hoc-build" debug "$DEBUG_APP_BIN" \
    "$SCRATCH/provenance-comparison/debug" \
    "$EVIDENCE/debug-reconstructed-provenance.tsv"
DEBUG_BUILD_BIN="$MATCHED_BUILD_BIN"
DEBUG_BUILD_RAW_SHA256="$MATCHED_BUILD_RAW_SHA256"
DEBUG_APP_SIGNED_SHA256="$MATCHED_APP_SIGNED_SHA256"
DEBUG_BUILD_PAYLOAD_SHA256="$MATCHED_BUILD_PAYLOAD_SHA256"
DEBUG_APP_PAYLOAD_SHA256="$MATCHED_APP_PAYLOAD_SHA256"
DEBUG_BIN="$EVIDENCE/FinderTwo-debug"
cp "$DEBUG_BUILD_BIN" "$DEBUG_BIN"
chmod +x "$DEBUG_BIN"
shasum -a 256 "$DEBUG_APP_BIN" > "$EVIDENCE/finder-two-debug-before-smoke.sha256"
shasum -a 256 "$DEBUG_BIN" > "$EVIDENCE/finder-two-debug-saved.sha256"

# Prove that deterministic bundle reconstruction rejects both a content-byte
# mutation and the former __LINKEDIT.vmsize normalization escape hatch.
PROVENANCE_NEGATIVE_DIR="$SCRATCH/provenance-negative"
mkdir -p "$PROVENANCE_NEGATIVE_DIR"
run_provenance_negative() {
    local name="$1" mutation="$2"
    local negative_root="$PROVENANCE_NEGATIVE_DIR/$name"
    local tampered_app="$negative_root/Rascal.app"
    local tampered_binary="$tampered_app/Contents/MacOS/FinderTwo"
    mkdir -p "$negative_root"
    cp -R "$ROOT/build/Rascal.app" "$tampered_app"
    codesign --force --deep --sign - --timestamp=none "$tampered_app" \
        > "$EVIDENCE/negative-$name-sign.stdout" \
        2> "$EVIDENCE/negative-$name-sign.stderr"
    codesign --verify --deep --strict "$tampered_app" \
        > "$EVIDENCE/negative-$name-before-mutation-verify.stdout" \
        2> "$EVIDENCE/negative-$name-before-mutation-verify.stderr"
    "$PYTHON_BIN" - "$tampered_binary" "$mutation" \
        "$EVIDENCE/negative-$name-mutation.tsv" <<'PY'
import pathlib
import struct
import sys

path = pathlib.Path(sys.argv[1])
mutation = sys.argv[2]
data = bytearray(path.read_bytes())
if len(data) < 8192:
    raise SystemExit("FinderTwo payload is unexpectedly small")
if mutation == "payload":
    offset = len(data) // 2
    before = data[offset]
    data[offset] ^= 1
    after = data[offset]
elif mutation == "linkedit-vmsize":
    _, _, _, _, command_count, command_bytes, _, _ = struct.unpack_from(
        "<IiiIIIII", data, 0
    )
    offset = 32
    limit = 32 + command_bytes
    found = []
    for _ in range(command_count):
        command, command_size = struct.unpack_from("<II", data, offset)
        if command == 0x19 and data[offset + 8:offset + 24].split(b"\0", 1)[0] == b"__LINKEDIT":
            found.append(offset + 32)
        offset += command_size
    if offset != limit or len(found) != 1:
        raise SystemExit("expected one complete __LINKEDIT segment")
    offset = found[0]
    before = struct.unpack_from("<Q", data, offset)[0]
    after = before + 4096
    struct.pack_into("<Q", data, offset, after)
else:
    raise SystemExit(f"unknown mutation {mutation}")
path.write_bytes(data)
pathlib.Path(sys.argv[3]).write_text(
    f"mutation\toffset\tbefore\tafter\n{mutation}\t{offset}\t{before}\t{after}\n"
)
PY
    set +e
    codesign --verify --deep --strict "$tampered_app" \
        > "$EVIDENCE/negative-$name-after-mutation-verify.stdout" \
        2> "$EVIDENCE/negative-$name-after-mutation-verify.stderr"
    local signature_status=$?
    set -e
    printf '%s\n' "$signature_status" \
        > "$EVIDENCE/negative-$name-after-mutation-verify.exit"
    [[ "$signature_status" != 0 ]] || {
        echo "$name mutation unexpectedly preserved the code signature" >&2
        exit 1
    }
    set +e
    find_matching_build_binary "$SCRATCH/ad-hoc-build" debug "$tampered_binary" \
        "$SCRATCH/provenance-comparison/debug-$name" \
        "$EVIDENCE/negative-$name-comparison.tsv" \
        > "$EVIDENCE/negative-$name.stdout" \
        2> "$EVIDENCE/negative-$name.stderr"
    local status=$?
    set -e
    printf '%s\n' "$status" > "$EVIDENCE/negative-$name.exit"
    [[ "$status" != 0 ]] || { echo "$name provenance tamper was accepted" >&2; exit 1; }
    grep -Fq $'\tfalse' "$EVIDENCE/negative-$name-comparison.tsv" || {
        echo "$name tamper lacked exact comparison evidence" >&2
        exit 1
    }
    ! grep -Eq 'M1-[A-Z0-9-]+ PASS' \
        "$EVIDENCE/negative-$name.stdout" "$EVIDENCE/negative-$name.stderr" || {
        echo "$name provenance negative printed PASS" >&2
        exit 1
    }
    PROVENANCE_NEGATIVE_STATUS="$status"
}

PROVENANCE_NEGATIVE_STATUS=""
run_provenance_negative provenance-payload payload
PROVENANCE_PAYLOAD_NEGATIVE="$PROVENANCE_NEGATIVE_STATUS"
run_provenance_negative provenance-linkedit-vmsize linkedit-vmsize
PROVENANCE_LINKEDIT_NEGATIVE="$PROVENANCE_NEGATIVE_STATUS"

run_timed smoke 300 env RASCAL_ENABLE_LEGACY_WRITES=1 bash ./smoketest.sh
[[ "$(grep -Ec '^=== 605 passed, 0 failed ===$' "$EVIDENCE/smoke.stdout")" == "1" ]] || {
    echo "compatibility summary is not exactly 605 passed, 0 failed" >&2
    exit 1
}
make_assertion_manifest "$EVIDENCE/smoke.stdout" "$EVIDENCE/assertion-manifest.tsv"
ACTUAL_MANIFEST_SHA256="$(shasum -a 256 "$EVIDENCE/assertion-manifest.tsv" | awk '{print $1}')"
printf '%s\n' "$ACTUAL_MANIFEST_SHA256" > "$EVIDENCE/assertion-manifest.sha256"
[[ "$ACTUAL_MANIFEST_SHA256" == "$EXPECTED_MANIFEST_SHA256" ]] || {
    echo "assertion manifest changed: expected $EXPECTED_MANIFEST_SHA256 got $ACTUAL_MANIFEST_SHA256" >&2
    exit 1
}

shasum -a 256 "$DEBUG_APP_BIN" > "$EVIDENCE/finder-two-debug-after-smoke.sha256"
cmp "$EVIDENCE/finder-two-debug-before-smoke.sha256" "$EVIDENCE/finder-two-debug-after-smoke.sha256"
run_timed gui 300 bash ./guitest.sh
[[ "$(grep -Ec '^=== Result: 0 failure\(s\) ===$' "$EVIDENCE/gui.stdout")" == "1" ]] || {
    echo "GUI summary is not exactly 0 failures" >&2
    exit 1
}
shasum -a 256 "$DEBUG_APP_BIN" > "$EVIDENCE/finder-two-debug-after-gui.sha256"
cmp "$EVIDENCE/finder-two-debug-before-smoke.sha256" "$EVIDENCE/finder-two-debug-after-gui.sha256"
touch "$EVIDENCE/scenario-M1-COMPAT-001.pass"

[[ ! -e "$SCRATCH/release" ]] || {
    echo "release provenance requires a fresh scratch path" >&2
    exit 1
}
run release-build env RASCAL_SECURITY_TOOL=/usr/bin/false SWIFT_SCRATCH_PATH="$SCRATCH/release" bash ./build.sh release
RELEASE_APP_BIN="$ROOT/build/Rascal.app/Contents/MacOS/FinderTwo"
find_matching_build_binary "$SCRATCH/release" release "$RELEASE_APP_BIN" \
    "$SCRATCH/provenance-comparison/release" \
    "$EVIDENCE/release-reconstructed-provenance.tsv"
RELEASE_BUILD_BIN="$MATCHED_BUILD_BIN"
RELEASE_BUILD_RAW_SHA256="$MATCHED_BUILD_RAW_SHA256"
RELEASE_APP_SIGNED_SHA256="$MATCHED_APP_SIGNED_SHA256"
RELEASE_BUILD_PAYLOAD_SHA256="$MATCHED_BUILD_PAYLOAD_SHA256"
RELEASE_APP_PAYLOAD_SHA256="$MATCHED_APP_PAYLOAD_SHA256"
RELEASE_BIN="$EVIDENCE/FinderTwo-release"
cp "$RELEASE_BUILD_BIN" "$RELEASE_BIN"
chmod +x "$RELEASE_BIN"
shasum -a 256 "$RELEASE_BIN" > "$EVIDENCE/finder-two-release.sha256"
DEBUG_EVIDENCE_SHA256="$(sha256_file "$DEBUG_BIN")" || exit 1
RELEASE_EVIDENCE_SHA256="$(sha256_file "$RELEASE_BIN")" || exit 1
{
    printf 'configuration\tscratch_root\tbuilt_binary\traw_build_sha256\tsigned_app_binary\tsigned_app_sha256\treconstructed_signed_sha256\tactual_signed_sha256\tpayload_match\tevidence_binary\tevidence_binary_sha256\tevidence_binary_source\n'
    printf 'debug\t%s\t%s\t%s\t%s\t%s\t%s\t%s\ttrue\t%s\t%s\traw-swiftpm-product\n' \
        "$SCRATCH/ad-hoc-build" "$DEBUG_BUILD_BIN" "$DEBUG_BUILD_RAW_SHA256" \
        "$DEBUG_APP_BIN" "$DEBUG_APP_SIGNED_SHA256" "$DEBUG_BUILD_PAYLOAD_SHA256" \
        "$DEBUG_APP_PAYLOAD_SHA256" "$DEBUG_BIN" "$DEBUG_EVIDENCE_SHA256"
    printf 'release\t%s\t%s\t%s\t%s\t%s\t%s\t%s\ttrue\t%s\t%s\traw-swiftpm-product\n' \
        "$SCRATCH/release" "$RELEASE_BUILD_BIN" "$RELEASE_BUILD_RAW_SHA256" \
        "$RELEASE_APP_BIN" "$RELEASE_APP_SIGNED_SHA256" "$RELEASE_BUILD_PAYLOAD_SHA256" \
        "$RELEASE_APP_PAYLOAD_SHA256" "$RELEASE_BIN" "$RELEASE_EVIDENCE_SHA256"
} > "$EVIDENCE/binary-provenance.tsv"

run feature-gates env M1_FEATURE_GATE_SCRATCH="$SCRATCH/feature-gates" \
    M1_DEBUG_BUILD_ROOT="$SCRATCH/ad-hoc-build" \
    M1_RELEASE_BUILD_ROOT="$SCRATCH/release" \
    bash Scripts/verification/m1-feature-gates.sh \
    "$EVIDENCE/feature-gates" "$DEBUG_BIN" "$RELEASE_BIN"
touch "$EVIDENCE/scenario-M1-GATE-D-001.pass" \
    "$EVIDENCE/scenario-M1-GATE-L-001.pass" \
    "$EVIDENCE/scenario-M1-GATE-R-001.pass"

# Negative controls run only against disposable scratch or /tmp copies. Each validator
# must reject its tampered input, and the timeout must reap the whole child
# process group before the lane may claim its own positive evidence.
NEGATIVE_DIR="$(mktemp -d /tmp/rascal-m1-negative.XXXXXX)"
printf 'control\texit\texpected\n' > "$EVIDENCE/negative-controls.tsv"
printf 'provenance-reconstructed-payload-tamper\t%s\tnonzero-no-pass\n' \
    "$PROVENANCE_PAYLOAD_NEGATIVE" >> "$EVIDENCE/negative-controls.tsv"
printf 'provenance-linkedit-vmsize-tamper\t%s\tnonzero-no-pass\n' \
    "$PROVENANCE_LINKEDIT_NEGATIVE" >> "$EVIDENCE/negative-controls.tsv"

expect_swift_rejection() {
    local name="$1" input="$2"
    set +e
    validate_swift_evidence "$input" \
        "$NEGATIVE_DIR/$name-test-results.tsv" "$NEGATIVE_DIR/$name-trace.tsv" \
        > "$EVIDENCE/negative-$name.stdout" 2> "$EVIDENCE/negative-$name.stderr"
    local status=$?
    set -e
    [[ "$status" != 0 ]] || { echo "$name Swift evidence was accepted" >&2; exit 1; }
    printf '%s\t%s\tnonzero\n' "$name" "$status" >> "$EVIDENCE/negative-controls.tsv"
}

"$PYTHON_BIN" - "$EVIDENCE/swift-test.stdout" "$NEGATIVE_DIR" <<'PY'
import pathlib
import re
import sys

source = pathlib.Path(sys.argv[1]).read_text()
root = pathlib.Path(sys.argv[2])
cases = {
    "trace-case": source.replace("case=M1-EVENT-001", "case=M1-EVENT-999", 1),
    "trace-item": re.sub(
        r"(M1_EVENT_TRACE\t[^\n]*\titem=)[0-9a-f-]{36}",
        r"\g<1>00000000-0000-0000-0000-0000000000ff", source, count=1
    ),
    "trace-payload": source.replace("payload=progress:1", "payload=progress:+1", 1),
    "trace-durability": source.replace(
        "durability=transient\tpayload=progress:1",
        "durability=durable\tpayload=progress:1", 1
    ),
    "test-missing": "\n".join(
        line for line in source.splitlines()
        if "RecoverySafetyTests testPreflightCancellationKeepsActiveSlotUntilAdapterQuiesces" not in line
    ) + "\n",
    "test-skipped": source.replace(
        "RecoverySafetyTests testPreflightCancellationKeepsActiveSlotUntilAdapterQuiesces]' passed",
        "RecoverySafetyTests testPreflightCancellationKeepsActiveSlotUntilAdapterQuiesces]' skipped",
        1
    ),
    "test-unexpected": source +
        "Test Case '-[RascalFileOperationsTests.UnexpectedTests testForged]' started.\n" +
        "Test Case '-[RascalFileOperationsTests.UnexpectedTests testForged]' passed (0.001 seconds).\n",
}
for name, value in cases.items():
    if value == source:
        raise SystemExit(f"negative fixture {name} did not change input")
    (root / f"{name}.stdout").write_text(value)
PY
for control in trace-case trace-item trace-payload trace-durability \
    test-missing test-skipped test-unexpected; do
    expect_swift_rejection "$control" "$NEGATIVE_DIR/$control.stdout"
done

expect_scenario_rejection() {
    local name="$1" manifest="$2" markers="$3"
    set +e
    validate_scenarios "$manifest" "$NEGATIVE_DIR/$name-results.tsv" "$markers" \
        > "$EVIDENCE/negative-$name.stdout" 2> "$EVIDENCE/negative-$name.stderr"
    local status=$?
    set -e
    [[ "$status" != 0 ]] || { echo "$name scenario evidence was accepted" >&2; exit 1; }
    printf '%s\t%s\tnonzero\n' "$name" "$status" >> "$EVIDENCE/negative-controls.tsv"
}

"$PYTHON_BIN" - "$EVIDENCE/scenario-manifest.tsv" "$NEGATIVE_DIR" <<'PY'
import csv
import pathlib
import sys

source = pathlib.Path(sys.argv[1])
root = pathlib.Path(sys.argv[2])
with source.open(newline="") as handle:
    rows = list(csv.DictReader(handle, delimiter="\t"))
fields = list(rows[0])
mutations = {
    "scenario-lane": ("lane", "remote-github"),
    "scenario-mandatory": ("milestone_mandatory", "false"),
    "scenario-local-required": ("local_required", "false"),
}
for name, (field, value) in mutations.items():
    changed = [dict(row) for row in rows]
    changed[0][field] = value
    with (root / f"{name}.tsv").open("w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fields, delimiter="\t", lineterminator="\n")
        writer.writeheader()
        writer.writerows(changed)
extra = [dict(row) for row in rows]
extra.append(dict(rows[0], stable_id="M1-EXTRA-001"))
with (root / "scenario-extra.tsv").open("w", newline="") as handle:
    writer = csv.DictWriter(handle, fieldnames=fields, delimiter="\t", lineterminator="\n")
    writer.writeheader()
    writer.writerows(extra)
PY
for control in scenario-lane scenario-mandatory scenario-local-required scenario-extra; do
    expect_scenario_rejection "$control" "$NEGATIVE_DIR/$control.tsv" "$EVIDENCE"
done
mkdir -p "$NEGATIVE_DIR/markers"
cp "$EVIDENCE"/scenario-*.pass "$NEGATIVE_DIR/markers/"
rm -f "$NEGATIVE_DIR/markers/scenario-M1-CORE-001.pass"
expect_scenario_rejection scenario-missing-evidence \
    "$EVIDENCE/scenario-manifest.tsv" "$NEGATIVE_DIR/markers"

set +e
run_timed negative-provenance-missing 30 bash Scripts/verification/m1-feature-gates.sh \
    "$NEGATIVE_DIR/missing-provenance" "$DEBUG_BIN" "$RELEASE_BIN"
MISSING_PROVENANCE=$?
set -e
[[ "$MISSING_PROVENANCE" != 0 ]] || { echo "missing provenance was accepted" >&2; exit 1; }
! grep -Eq 'M1-GATE-[DLR]-001 PASS' "$EVIDENCE/negative-provenance-missing.stdout" || {
    echo "missing provenance printed a gate PASS" >&2
    exit 1
}
printf 'provenance-missing\t%s\tnonzero-no-pass\n' "$MISSING_PROVENANCE" \
    >> "$EVIDENCE/negative-controls.tsv"

cp /usr/bin/true "$NEGATIVE_DIR/FinderTwo-debug"
cp /usr/bin/false "$NEGATIVE_DIR/FinderTwo-release"
chmod +x "$NEGATIVE_DIR/FinderTwo-debug" "$NEGATIVE_DIR/FinderTwo-release"
set +e
run_timed negative-binary 30 env \
    M1_DEBUG_BUILD_ROOT="$SCRATCH/ad-hoc-build" \
    M1_RELEASE_BUILD_ROOT="$SCRATCH/release" \
    bash Scripts/verification/m1-feature-gates.sh "$NEGATIVE_DIR/bogus-binary" \
    "$NEGATIVE_DIR/FinderTwo-debug" "$NEGATIVE_DIR/FinderTwo-release"
BINARY_NEGATIVE=$?
set -e
[[ "$BINARY_NEGATIVE" != 0 ]] || { echo "renamed system utilities were accepted" >&2; exit 1; }
! grep -Eq 'M1-GATE-[DLR]-001 PASS' "$EVIDENCE/negative-binary.stdout" || {
    echo "invalid binary provenance printed a gate PASS" >&2
    exit 1
}
printf 'binary-renamed-true-false\t%s\tnonzero-no-pass\n' "$BINARY_NEGATIVE" \
    >> "$EVIDENCE/negative-controls.tsv"

set +e
run_timed negative-timeout 1 /bin/sh -c 'sleep 60 & child=$!; echo "$child"; wait "$child"'
TIMEOUT_NEGATIVE=$?
set -e
[[ "$TIMEOUT_NEGATIVE" == 124 ]] || {
    echo "timeout negative control returned $TIMEOUT_NEGATIVE, expected 124" >&2
    exit 1
}
TIMED_CHILD="$(head -n 1 "$EVIDENCE/negative-timeout.stdout")"
if [[ "$TIMED_CHILD" =~ ^[0-9]+$ ]] && kill -0 "$TIMED_CHILD" 2>/dev/null; then
    echo "timeout left child process $TIMED_CHILD alive" >&2
    exit 1
fi
printf 'timeout-process-group\t%s\t124-and-child-reaped\n' "$TIMEOUT_NEGATIVE" \
    >> "$EVIDENCE/negative-controls.tsv"

rm -rf "$NEGATIVE_DIR"

verify_environment_unchanged
if [[ "${GITHUB_ACTIONS:-false}" == "true" ]]; then
    touch "$EVIDENCE/scenario-M1-CI-001.pass"
    printf 'M1-CI-001=PASS; complete GitHub lane bound to github-run-metadata.tsv\n' \
        >> "$EVIDENCE/journal-and-remote-boundary.txt"
else
    printf 'M1-CI-001=NOT-EVALUATED-LOCAL-RUN\n' \
        >> "$EVIDENCE/journal-and-remote-boundary.txt"
fi
validate_scenarios "$EVIDENCE/scenario-manifest.tsv" \
    "$EVIDENCE/scenario-results.tsv" "$EVIDENCE"

echo "M1 local fast lane PASS evidence=$EVIDENCE"
