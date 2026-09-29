#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
TMP_DIR=$(mktemp -d)
TEST_PIDS=""

# shellcheck disable=SC1091
source "$REPO_ROOT/scripts/utils/process_utils.sh"

cleanup() {
    local pid

    for pid in $TEST_PIDS; do
        if pid_is_alive "$pid"; then
            kill -TERM -- "$pid" 2>/dev/null || true
        fi
        wait "$pid" 2>/dev/null || true
    done
    rm -rf -- "$TMP_DIR"
}

fail() {
    echo "$*" >&2
    exit 1
}

assert_equal() {
    local expected="$1"
    local actual="$2"

    [ "$expected" = "$actual" ] || fail "Expected <$expected>, got <$actual>."
}

assert_process_alive() {
    local pid="$1"

    pid_is_alive "$pid" || fail "Expected process $pid to be alive."
}

assert_process_dead() {
    local pid="$1"

    ! pid_is_alive "$pid" || fail "Expected process $pid to be stopped."
}

wait_for_match() {
    local pid="$1"
    local marker="$2"
    local legacy_command="${3:-}"
    local attempts=50

    while [ "$attempts" -gt 0 ]; do
        if watcher_process_matches "$pid" "$marker" "$legacy_command"; then
            return 0
        fi
        sleep 0.02
        attempts=$((attempts - 1))
    done

    return 1
}

register_pid() {
    TEST_PIDS="$TEST_PIDS $1"
}

trap cleanup EXIT

for unsafe_pid in "" 0 1 -1 abc 1.5; do
    if pid_is_safe "$unsafe_pid"; then
        fail "Unsafe PID <$unsafe_pid> was accepted."
    fi
    if pid_is_alive "$unsafe_pid"; then
        fail "Unsafe PID <$unsafe_pid> was reported alive."
    fi
done

unrelated_marker="ai-assistant-notify:test:unrelated:$$"
unrelated_pid_file="$TMP_DIR/unrelated.pid"
sleep 60 &
unrelated_pid=$!
register_pid "$unrelated_pid"
write_pid_file "$unrelated_pid_file" "$unrelated_pid"

if is_watcher_running "$unrelated_pid_file" "$unrelated_marker"; then
    fail "A live unrelated PID was accepted as a watcher."
fi
[ ! -e "$unrelated_pid_file" ] || fail "Rejected unrelated PID file was not removed."
if terminate_pid "$unrelated_pid" "$unrelated_marker"; then
    fail "terminate_pid accepted an unrelated process."
fi
assert_process_alive "$unrelated_pid"

exact_marker="ai-assistant-notify:test:exact:$$"
exact_pid_file="$TMP_DIR/exact.pid"
bash -c 'exec -a "$1" sleep 60' _ "$exact_marker" &
exact_pid=$!
register_pid "$exact_pid"
wait_for_match "$exact_pid" "$exact_marker" || fail "Exact marker process was not recognized."

is_watcher_running "$exact_pid_file" "$exact_marker" || fail "Exact marker fallback failed."
assert_equal "$exact_pid" "$(read_pid_file "$exact_pid_file")"

old_pattern=$(printf '%s%s' 'codex_watcher.sh' ' run unrelated')
bash -c 'exec -a "$1" sleep 60' _ "$old_pattern" &
old_pattern_pid=$!
register_pid "$old_pattern_pid"
sleep 0.05

if watcher_process_matches "$old_pattern_pid" "$exact_marker"; then
    fail "Old substring pattern matched the exact watcher marker."
fi
if list_running_pids "$exact_marker" | grep -Fx -- "$old_pattern_pid" >/dev/null 2>&1; then
    fail "Old substring process appeared in exact marker fallback."
fi
assert_process_alive "$old_pattern_pid"

terminate_pid "$exact_pid" "$exact_marker" || fail "Exact marker process could not be terminated."
wait "$exact_pid" 2>/dev/null || true
assert_process_dead "$exact_pid"

legacy_command='trap "exit 0" TERM; while :; do sleep 0.1; done'
legacy_marker="ai-assistant-notify:test:legacy:$$"
bash -c "$legacy_command" &
legacy_pid=$!
register_pid "$legacy_pid"
wait_for_match "$legacy_pid" "$legacy_marker" "$legacy_command" || fail "Exact legacy argv was not recognized."
terminate_pid "$legacy_pid" "$legacy_marker" "$legacy_command" || fail "Exact legacy process could not be terminated."
wait "$legacy_pid" 2>/dev/null || true
assert_process_dead "$legacy_pid"

insecure_state_dir="$TMP_DIR/insecure-state"
mkdir "$insecure_state_dir"
chmod 777 "$insecure_state_dir"
secure_state_dir "$insecure_state_dir"
assert_equal 700 "$(stat -c '%a' "$insecure_state_dir")"

insecure_state_file="$insecure_state_dir/runtime.log"
: > "$insecure_state_file"
chmod 666 "$insecure_state_file"
secure_state_file "$insecure_state_file"
assert_equal 600 "$(stat -c '%a' "$insecure_state_file")"

mkdir "$TMP_DIR/state-target"
ln -s "$TMP_DIR/state-target" "$TMP_DIR/state-link"
if secure_state_dir "$TMP_DIR/state-link" 2>/dev/null; then
    fail "Symbolic-link state directory was accepted."
fi

ln -s "$TMP_DIR/missing-target" "$insecure_state_dir/dangling-link"
if secure_state_file "$insecure_state_dir/dangling-link" 2>/dev/null; then
    fail "Dangling symbolic-link state file was accepted."
fi

runtime_root="$TMP_DIR/runtime-root"
state_dir="$runtime_root/ai-assistant-notify"
lock_file="$state_dir/codex_watcher.lock"
mkdir -p "$state_dir"
chmod 700 "$state_dir"
cli_marker="ai-assistant-notify:codex:$REPO_ROOT:$state_dir"

bash -c '
    trap "exit 0" TERM
    exec 9>"$1"
    flock -n 9 || exit 2
    while :; do sleep 0.1; done
' "$cli_marker" "$lock_file" &
lock_holder_pid=$!
register_pid "$lock_holder_pid"
wait_for_match "$lock_holder_pid" "$cli_marker" || fail "Lock holder marker was not recognized."

if (exec 8>"$lock_file"; flock -n 8); then
    fail "Expected the watcher lock to be held."
fi

stop_output=$(TMPDIR="$runtime_root" "$REPO_ROOT/bin/ai-assistant-notify" stop codex)
case "$stop_output" in
    *"codex watcher stopped."*) ;;
    *) fail "Fallback stop did not report a stopped watcher: $stop_output" ;;
esac

wait "$lock_holder_pid" 2>/dev/null || true
assert_process_dead "$lock_holder_pid"
[ -f "$lock_file" ] || fail "Stop removed the persistent lock path."
assert_equal 600 "$(stat -c '%a' "$lock_file")"
(exec 8>"$lock_file"; flock -n 8) || fail "Lock remained held after the watcher stopped."

cli_home="$TMP_DIR/cli-home"
cli_runtime_root="$TMP_DIR/cli-runtime"
cli_state_dir="$cli_runtime_root/ai-assistant-notify"
mkdir -p "$cli_home/.codex/sessions" "$cli_runtime_root"

start_output=$(HOME="$cli_home" TMPDIR="$cli_runtime_root" "$REPO_ROOT/bin/ai-assistant-notify" start codex)
case "$start_output" in
    *"codex watcher started"*) ;;
    *) fail "Isolated watcher did not start: $start_output" ;;
esac

started_pid=$(read_pid_file "$cli_state_dir/codex_watcher.pid")
register_pid "$started_pid"
started_marker="ai-assistant-notify:codex:$REPO_ROOT:$cli_state_dir"
wait_for_match "$started_pid" "$started_marker" || fail "Started watcher did not expose the exact marker."
grep -Fq "codex_watcher ready pid=$started_pid " "$cli_state_dir/watch-runtime.log" || fail "Started watcher did not become ready."
status_output=$(HOME="$cli_home" TMPDIR="$cli_runtime_root" "$REPO_ROOT/bin/ai-assistant-notify" status codex)
case "$status_output" in
    *"codex watcher is running (pid $started_pid)."*) ;;
    *) fail "Status did not report the ready watcher: $status_output" ;;
esac
assert_equal 700 "$(stat -c '%a' "$cli_state_dir")"
assert_equal 600 "$(stat -c '%a' "$cli_state_dir/codex_watcher.pid")"
assert_equal 600 "$(stat -c '%a' "$cli_state_dir/codex_watcher.lock")"

second_start_output=$(HOME="$cli_home" TMPDIR="$cli_runtime_root" "$REPO_ROOT/bin/ai-assistant-notify" start codex)
case "$second_start_output" in
    *"already running (pid $started_pid)"*) ;;
    *) fail "Second start did not preserve the single watcher: $second_start_output" ;;
esac

HOME="$cli_home" TMPDIR="$cli_runtime_root" "$REPO_ROOT/bin/ai-assistant-notify" stop codex >/dev/null
wait "$started_pid" 2>/dev/null || true
assert_process_dead "$started_pid"
[ ! -e "$cli_state_dir/codex_watcher.pid" ] || fail "Stopped watcher left its PID file behind."
[ -f "$cli_state_dir/codex_watcher.lock" ] || fail "Stopped watcher removed its persistent lock path."

echo "process utility regression test passed."
