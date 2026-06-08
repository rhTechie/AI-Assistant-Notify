#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
TMP_DIR=$(mktemp -d)
CODEX_LOG_FILE="$TMP_DIR/codex-tui.log"
CODEX_SESSIONS_DIR="$TMP_DIR/sessions"
RUNTIME_LOG="$TMP_DIR/runtime.log"
EVENT_LOG="$TMP_DIR/events.log"

cleanup() {
    if [ -n "${WATCHER_PID:-}" ] && kill -0 "$WATCHER_PID" 2>/dev/null; then
        kill "$WATCHER_PID" 2>/dev/null || true
        wait "$WATCHER_PID" 2>/dev/null || true
    fi
    rm -rf "$TMP_DIR"
}

append_line() {
    printf '%s\n' "$1" >> "$CODEX_LOG_FILE"
}

append_rollout_line() {
    local file_path="$1"
    local line="$2"

    printf '%s\n' "$line" >> "$file_path"
}

assert_contains() {
    local expected="$1"

    if ! grep -F -- "$expected" "$EVENT_LOG" >/dev/null 2>&1; then
        echo "Missing expected event: $expected" >&2
        echo "Recorded events:" >&2
        [ -f "$EVENT_LOG" ] && cat "$EVENT_LOG" >&2 || true
        exit 1
    fi
}

assert_not_contains() {
    local unexpected="$1"

    if grep -F -- "$unexpected" "$EVENT_LOG" >/dev/null 2>&1; then
        echo "Unexpected event: $unexpected" >&2
        echo "Recorded events:" >&2
        cat "$EVENT_LOG" >&2
        exit 1
    fi
}

wait_for_event_count() {
    local expected_count="$1"
    local attempts=50
    local count=0

    while [ "$attempts" -gt 0 ]; do
        count=$(wc -l < "$EVENT_LOG" 2>/dev/null || echo "0")
        if [ "$count" -ge "$expected_count" ]; then
            return 0
        fi
        attempts=$((attempts - 1))
        sleep 0.1
    done

    echo "Timed out waiting for $expected_count watcher events (got $count)." >&2
    echo "Recorded events:" >&2
    [ -f "$EVENT_LOG" ] && cat "$EVENT_LOG" >&2 || true
    exit 1
}

trap cleanup EXIT

: > "$CODEX_LOG_FILE"
: > "$EVENT_LOG"

(
    export CODEX_LOG_FILE
    export CODEX_SESSIONS_DIR
    source "$REPO_ROOT/scripts/watchers/codex_watcher.sh"

    if ! version_gt "0.137.0" "0.136.0"; then
        echo "Expected 0.137.0 to be newer than 0.136.0." >&2
        exit 1
    fi

    if version_gt "0.136.0" "0.137.0"; then
        echo "Expected 0.136.0 to not be newer than 0.137.0." >&2
        exit 1
    fi

    if [ "$(codex_compatibility_status "0.137.0")" != "ok" ]; then
        echo "Expected compatibility status for 0.137.0 to be ok." >&2
        exit 1
    fi

    if [ "$(codex_compatibility_status "0.138.0")" != "recheck needed" ]; then
        echo "Expected compatibility status for 0.138.0 to require recheck." >&2
        exit 1
    fi
)

(
    export CODEX_LOG_FILE
    export CODEX_SESSIONS_DIR
    source "$REPO_ROOT/scripts/watchers/codex_watcher.sh"

    notify_callback() {
        local watcher_type="$1"
        local event_type="$2"
        local message="$3"
        local thread_id="$4"
        local turn_id="$5"

        printf '%s|%s|%s|%s|%s\n' \
            "$watcher_type" \
            "$event_type" \
            "$thread_id" \
            "$turn_id" \
            "$message" >> "$EVENT_LOG"
    }

    codex_watcher_run notify_callback "$RUNTIME_LOG"
) &
WATCHER_PID=$!

sleep 0.5

append_line '2026-05-19T02:00:00.000000Z  INFO session_loop{thread_id=thread-old}:submission_dispatch{otel.name="op.dispatch.user_input" submission.id="turn-old" codex.op="user_input"}:turn{otel.name="session_task.turn" thread.id=thread-old turn.id=turn-old model=gpt-5.4}: codex_core::tasks: new'
append_line '2026-05-19T02:00:01.000000Z  INFO session_loop{thread_id=thread-old}:submission_dispatch{otel.name="op.dispatch.user_input" submission.id="turn-old" codex.op="user_input"}:turn{otel.name="session_task.turn" thread.id=thread-old turn.id=turn-old model=gpt-5.4}: codex_core::stream_events_utils: ToolCall: exec_command {"cmd":"pwd","workdir":"/tmp/project-old","yield_time_ms":1000} thread_id=thread-old'
append_line '2026-05-19T02:00:02.000000Z  INFO session_loop{thread_id=thread-old}:submission_dispatch{otel.name="op.dispatch.user_input" submission.id="turn-old" codex.op="user_input"}:turn{otel.name="session_task.turn" thread.id=thread-old turn.id=turn-old model=gpt-5.4}: codex_core::tasks: close time.busy=10ms time.idle=1s'

append_line '2026-05-19T02:01:00.000000Z  INFO session_loop{thread_id=thread-new}:submission_dispatch{otel.name="op.dispatch.user_input_with_turn_context" submission.id="turn-new" codex.op="user_input_with_turn_context"}:turn{otel.name="session_task.turn" thread.id=thread-new turn.id=turn-new model=gpt-5.4 codex.turn.reasoning_effort=xhigh}: codex_core::tasks: new'
append_line '2026-05-19T02:01:01.000000Z  INFO session_loop{thread_id=thread-new}:submission_dispatch{otel.name="op.dispatch.user_input_with_turn_context" submission.id="turn-new" codex.op="user_input_with_turn_context"}:turn{otel.name="session_task.turn" thread.id=thread-new turn.id=turn-new model=gpt-5.4 codex.turn.reasoning_effort=xhigh}: codex_core::stream_events_utils: ToolCall: exec_command {"cmd":"rg --files","workdir":"/tmp/project-new","yield_time_ms":1000} thread_id=thread-new'
append_line '2026-05-19T02:01:02.000000Z  INFO session_loop{thread_id=thread-new}:submission_dispatch{otel.name="op.dispatch.user_input_with_turn_context" submission.id="turn-new" codex.op="user_input_with_turn_context"}:turn{otel.name="session_task.turn" thread.id=thread-new turn.id=turn-new model=gpt-5.4 codex.turn.reasoning_effort=xhigh}: codex_core::tasks: close time.busy=10ms time.idle=1s'

append_line '2026-05-19T02:02:00.000000Z  INFO session_loop{thread_id=thread-interrupt}:submission_dispatch{otel.name="op.dispatch.user_input_with_turn_context" submission.id="turn-interrupt" codex.op="user_input_with_turn_context"}:turn{otel.name="session_task.turn" thread.id=thread-interrupt turn.id=turn-interrupt model=gpt-5.4 codex.turn.reasoning_effort=xhigh}: codex_core::tasks: new'
append_line '2026-05-19T02:02:01.000000Z  INFO session_loop{thread_id=thread-interrupt}:submission_dispatch{otel.name="op.dispatch.user_input_with_turn_context" submission.id="turn-interrupt" codex.op="user_input_with_turn_context"}:turn{otel.name="session_task.turn" thread.id=thread-interrupt turn.id=turn-interrupt model=gpt-5.4 codex.turn.reasoning_effort=xhigh}: codex_core::stream_events_utils: ToolCall: exec_command {"cmd":"git status --short","workdir":"/tmp/project-interrupt","yield_time_ms":1000} thread_id=thread-interrupt'
append_line '2026-05-19T02:02:02.000000Z  INFO session_loop{thread_id=thread-interrupt}:submission_dispatch{otel.name="op.dispatch.interrupt" submission.id="interrupt-1" codex.op="interrupt"}: codex_core::session: interrupt received: abort current task, if any'
append_line '2026-05-19T02:02:03.000000Z  INFO session_loop{thread_id=thread-interrupt}:submission_dispatch{otel.name="op.dispatch.user_input_with_turn_context" submission.id="turn-interrupt" codex.op="user_input_with_turn_context"}:turn{otel.name="session_task.turn" thread.id=thread-interrupt turn.id=turn-interrupt model=gpt-5.4 codex.turn.reasoning_effort=xhigh}: codex_core::tasks: close time.busy=10ms time.idle=1s'

wait_for_event_count 3

assert_contains 'codex|turn_complete|thread-old|turn-old|'
assert_contains 'codex|turn_complete|thread-new|turn-new|'
assert_contains 'codex|turn_interrupted|thread-interrupt|turn-interrupt|'
assert_not_contains 'codex|turn_complete|thread-interrupt|turn-interrupt|'

event_count=$(wc -l < "$EVENT_LOG")
if [ "$event_count" -ne 3 ]; then
    echo "Expected 3 watcher events, got $event_count." >&2
    cat "$EVENT_LOG" >&2
    exit 1
fi

echo "codex watcher replay test passed."

kill "$WATCHER_PID" 2>/dev/null || true
wait "$WATCHER_PID" 2>/dev/null || true
WATCHER_PID=""

: > "$EVENT_LOG"
mkdir -p "$CODEX_SESSIONS_DIR/2026/05/29"
rm -f "$CODEX_LOG_FILE"

ROLLOUT_FILE="$CODEX_SESSIONS_DIR/2026/05/29/rollout-2026-05-29T15-53-42-019e72b9-87cb-79b1-b8cf-534ecf01bec7.jsonl"
: > "$ROLLOUT_FILE"

(
    export CODEX_LOG_FILE
    export CODEX_SESSIONS_DIR
    source "$REPO_ROOT/scripts/watchers/codex_watcher.sh"

    notify_callback() {
        local watcher_type="$1"
        local event_type="$2"
        local message="$3"
        local thread_id="$4"
        local turn_id="$5"

        printf '%s|%s|%s|%s|%s\n' \
            "$watcher_type" \
            "$event_type" \
            "$thread_id" \
            "$turn_id" \
            "$message" >> "$EVENT_LOG"
    }

    codex_watcher_run notify_callback "$RUNTIME_LOG"
) &
WATCHER_PID=$!

sleep 1.2

append_rollout_line "$ROLLOUT_FILE" '{"timestamp":"2026-05-29T07:53:58.199Z","type":"session_meta","payload":{"id":"019e72b9-87cb-79b1-b8cf-534ecf01bec7","timestamp":"2026-05-29T07:53:42.098Z","cwd":"/tmp/project-rollout","originator":"codex-tui"}}'
append_rollout_line "$ROLLOUT_FILE" '{"timestamp":"2026-05-29T07:53:58.200Z","type":"event_msg","payload":{"type":"task_started","turn_id":"turn-rollout-complete","started_at":1780041238}}'
append_rollout_line "$ROLLOUT_FILE" '{"timestamp":"2026-05-29T07:54:10.023Z","type":"response_item","payload":{"type":"function_call","name":"exec_command","arguments":"{\"cmd\":\"pwd\",\"workdir\":\"/tmp/project-rollout\",\"yield_time_ms\":1000}","call_id":"call-rollout-complete"}}'
append_rollout_line "$ROLLOUT_FILE" '{"timestamp":"2026-05-29T07:54:21.023Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"turn-rollout-complete","completed_at":1780041261}}'
append_rollout_line "$ROLLOUT_FILE" '{"timestamp":"2026-05-29T07:55:58.200Z","type":"event_msg","payload":{"type":"task_started","turn_id":"turn-rollout-interrupt","started_at":1780041358}}'
append_rollout_line "$ROLLOUT_FILE" '{"timestamp":"2026-05-29T07:56:10.023Z","type":"response_item","payload":{"type":"function_call","name":"apply_patch","arguments":"*** Begin Patch\n*** End Patch","call_id":"call-rollout-interrupt"}}'
append_rollout_line "$ROLLOUT_FILE" '{"timestamp":"2026-05-29T07:56:12.023Z","type":"event_msg","payload":{"type":"turn_aborted","turn_id":"turn-rollout-interrupt","reason":"interrupted","completed_at":1780041372}}'
append_rollout_line "$ROLLOUT_FILE" '{"timestamp":"2026-05-29T07:56:13.023Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"turn-rollout-interrupt","completed_at":1780041373}}'

wait_for_event_count 2

assert_contains 'codex|turn_complete|019e72b9-87cb-79b1-b8cf-534ecf01bec7|turn-rollout-complete|'
assert_contains 'codex|turn_interrupted|019e72b9-87cb-79b1-b8cf-534ecf01bec7|turn-rollout-interrupt|'
assert_not_contains 'codex|turn_complete|019e72b9-87cb-79b1-b8cf-534ecf01bec7|turn-rollout-interrupt|'

event_count=$(wc -l < "$EVENT_LOG")
if [ "$event_count" -ne 2 ]; then
    echo "Expected 2 rollout watcher events, got $event_count." >&2
    cat "$EVENT_LOG" >&2
    exit 1
fi

echo "codex rollout watcher replay test passed."
