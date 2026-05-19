#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
TMP_DIR=$(mktemp -d)
CODEX_LOG_FILE="$TMP_DIR/codex-tui.log"
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
