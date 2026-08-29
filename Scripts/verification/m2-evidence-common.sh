#!/usr/bin/env bash

# Runs a complete probe process group with a hard deadline. Headless AppKit
# probes must never leave a modal alert or detached child blocking the parent
# gate indefinitely.
m2_run_timed() {
    local out="$1" name="$2" timeout_seconds="$3"
    shift 3
    local restore_errexit=0
    [[ "$-" == *e* ]] && restore_errexit=1
    printf '%q ' "$@" > "$out/$name.command"
    printf '\n' >> "$out/$name.command"
    set +e
    /usr/bin/python3 - "$timeout_seconds" "$out/$name.stdout" \
        "$out/$name.stderr" "$@" <<'PY'
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
wrapper_pid_path = stdout_path.removesuffix(".stdout") + ".wrapper.pid"
with open(wrapper_pid_path, "w", encoding="ascii") as handle:
    handle.write(f"{os.getpid()}\n")

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

class ForwardedSignal(Exception):
    def __init__(self, signum):
        self.signum = signum

def forward_signal(signum, _frame):
    raise ForwardedSignal(signum)

handled_signals = {signal.SIGINT, signal.SIGTERM}
previous_mask = signal.pthread_sigmask(signal.SIG_BLOCK, handled_signals)
signal.signal(signal.SIGINT, forward_signal)
signal.signal(signal.SIGTERM, forward_signal)

with open(stdout_path, "wb") as stdout, open(stderr_path, "wb") as stderr:
    process = None
    mask_restored = False
    try:
        process = subprocess.Popen(
            command,
            stdout=stdout,
            stderr=stderr,
            start_new_session=True,
        )
        try:
            # Signals that arrived during spawn are delivered only after the
            # child process group is assigned and therefore recoverable.
            signal.pthread_sigmask(signal.SIG_SETMASK, previous_mask)
            mask_restored = True
            status = process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            stderr.write(
                f"verification timeout after {timeout:g}s: {command!r}\n".encode()
            )
            stderr.flush()
            stop_group(process)
            process.wait()
            status = 124
        except ForwardedSignal as interruption:
            signal.signal(signal.SIGINT, signal.SIG_IGN)
            signal.signal(signal.SIGTERM, signal.SIG_IGN)
            stop_group(process)
            process.wait()
            status = 128 + interruption.signum
    finally:
        if not mask_restored:
            signal.pthread_sigmask(signal.SIG_SETMASK, previous_mask)
        if process is not None:
            stop_group(process)
    raise SystemExit(status)
PY
    local status=$?
    if [[ "$restore_errexit" == 1 ]]; then set -e; else set +e; fi
    printf '%s\n' "$status" > "$out/$name.exit"
    return "$status"
}

# Exercises one signal against an active wrapper/probe/child process group.
# Each case has an isolated evidence directory so INT and TERM cannot satisfy
# one another's assertions accidentally.
m2_run_timed_signal_case() {
    local out="$1" signal_name="$2" expected_status="$3"
    mkdir -p "$out"
    (
        m2_run_timed "$out" active-signal 30 \
            /bin/sh -c \
            'printf "%s\n" "$$" > "$1"; exec /bin/sleep 30' \
            _ "$out/child.pid"
    ) &
    local wrapper_pid=$!
    local python_pid=""
    local attempt
    for attempt in {1..100}; do
        if [[ -s "$out/child.pid" && -s "$out/active-signal.wrapper.pid" ]]; then
            python_pid="$(cat "$out/active-signal.wrapper.pid")"
            break
        fi
        /bin/sleep 0.02
    done
    [[ -n "$python_pid" && -s "$out/child.pid" ]] || {
        [[ -n "$python_pid" ]] && /bin/kill -TERM "$python_pid" 2>/dev/null || true
        if [[ -s "$out/child.pid" ]]; then
            /bin/kill -TERM "$(cat "$out/child.pid")" 2>/dev/null || true
        fi
        wait "$wrapper_pid" 2>/dev/null || true
        echo "M2 $signal_name selftest failed to observe the active process group" >&2
        return 1
    }
    /bin/kill "-$signal_name" "$python_pid"
    local restore_errexit=0
    [[ "$-" == *e* ]] && restore_errexit=1
    set +e
    wait "$wrapper_pid"
    local wrapper_status=$?
    if [[ "$restore_errexit" == 1 ]]; then set -e; else set +e; fi
    local child_pid
    child_pid="$(cat "$out/child.pid")"
    local child_alive=0
    if /bin/kill -0 "$child_pid" 2>/dev/null; then child_alive=1; fi
    [[ "$wrapper_status" == "$expected_status" &&
       "$(cat "$out/active-signal.exit")" == "$expected_status" &&
       "$child_alive" == 0 ]] || {
        echo "M2 $signal_name selftest left an invalid status or live child" >&2
        return 1
    }
    printf 'signal\t%s\nwrapper_status\t%s\nprobe_status\t%s\nchild_alive\t%s\n' \
        "$signal_name" "$wrapper_status" \
        "$(cat "$out/active-signal.exit")" "$child_alive" > "$out/result.tsv"
}

# Proves that both supported external signals terminate the Python wrapper,
# the probe shell, and its child session. Sending the signals to the Python
# wrapper covers the Popen assignment/unmask boundary, not only the top-level
# total-gate traps.
m2_run_timed_signal_selftest() {
    local out="$1"
    mkdir -p "$out"
    m2_run_timed_signal_case "$out/int" INT 130
    m2_run_timed_signal_case "$out/term" TERM 143
    {
        printf 'case\tsignal\twrapper_status\tprobe_status\tchild_alive\n'
        local case_name
        for case_name in int term; do
            printf '%s\t%s\t%s\t%s\t%s\n' \
                "$case_name" \
                "$(awk -F '\t' '$1 == "signal" { print $2 }' "$out/$case_name/result.tsv")" \
                "$(awk -F '\t' '$1 == "wrapper_status" { print $2 }' "$out/$case_name/result.tsv")" \
                "$(awk -F '\t' '$1 == "probe_status" { print $2 }' "$out/$case_name/result.tsv")" \
                "$(awk -F '\t' '$1 == "child_alive" { print $2 }' "$out/$case_name/result.tsv")"
        done
    } > "$out/result.tsv"
}

# Capture the repository again at lane exit and prove that the evidence still
# describes the same source state. Build output is ignored by Git; any tracked
# or untracked source drift makes the lane fail.
m2_capture_end_and_compare() {
    local root="$1" out="$2"
    git -C "$root" rev-parse HEAD > "$out/head-end.txt"
    git -C "$root" status --porcelain=v2 --untracked-files=all \
        > "$out/git-status-v2-end.txt"
    git -C "$root" diff --binary > "$out/unstaged-end.diff"
    git -C "$root" diff --cached --binary > "$out/staged-end.diff"
    shasum -a 256 "$out/unstaged-end.diff" > "$out/unstaged-end-diff.sha256"
    shasum -a 256 "$out/staged-end.diff" > "$out/staged-end-diff.sha256"
    : > "$out/untracked-content-end.sha256"
    while IFS= read -r -d '' path; do
        shasum -a 256 "$root/$path" >> "$out/untracked-content-end.sha256"
    done < <(git -C "$root" ls-files --others --exclude-standard -z | sort -z)

    local unstaged_start unstaged_end staged_start staged_end
    unstaged_start="$(awk '{print $1}' "$out/unstaged-diff.sha256")"
    unstaged_end="$(awk '{print $1}' "$out/unstaged-end-diff.sha256")"
    staged_start="$(awk '{print $1}' "$out/staged-diff.sha256")"
    staged_end="$(awk '{print $1}' "$out/staged-end-diff.sha256")"

    cmp -s "$out/head.txt" "$out/head-end.txt" &&
        cmp -s "$out/git-status-v2.txt" "$out/git-status-v2-end.txt" &&
        [[ "$unstaged_start" == "$unstaged_end" ]] &&
        [[ "$staged_start" == "$staged_end" ]] &&
        cmp -s "$out/untracked-content.sha256" "$out/untracked-content-end.sha256"
}
