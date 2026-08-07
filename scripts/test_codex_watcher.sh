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

assert_runtime_log_contains() {
    local expected="$1"

    if ! grep -F -- "$expected" "$RUNTIME_LOG" >/dev/null 2>&1; then
        echo "Missing expected runtime log: $expected" >&2
        echo "Runtime log:" >&2
        [ -f "$RUNTIME_LOG" ] && cat "$RUNTIME_LOG" >&2 || true
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
    original_path="$PATH"

    dual_source_log="$TMP_DIR/dual-source/codex-tui.log"
    dual_source_sessions="$TMP_DIR/dual-source/sessions"
    mkdir -p "$dual_source_sessions"
    : > "$dual_source_log"
    CODEX_LOG_FILE="$dual_source_log"
    CODEX_SESSIONS_DIR="$dual_source_sessions"
    resolve_codex_watch_source
    if [ "$CODEX_WATCH_SOURCE" != "rollout_jsonl" ]; then
        echo "Expected rollout_jsonl when both Codex sources exist, got $CODEX_WATCH_SOURCE." >&2
        exit 1
    fi

    rm -rf "$dual_source_sessions"
    resolve_codex_watch_source
    if [ "$CODEX_WATCH_SOURCE" != "legacy_log" ]; then
        echo "Expected legacy_log fallback when sessions are absent, got $CODEX_WATCH_SOURCE." >&2
        exit 1
    fi

    fake_bin="$TMP_DIR/fake-bin"
    mkdir -p "$fake_bin"
    printf '#!/usr/bin/env bash\nprintf "codex-cli 0.147.1\\n"\n' > "$fake_bin/codex"
    chmod +x "$fake_bin/codex"
    PATH="$fake_bin:$original_path"
    if [ "$(codex_installed_version_detect)" != "0.147.1" ]; then
        echo "Expected codex_installed_version_detect to prefer codex --version." >&2
        exit 1
    fi

    rm -f "$fake_bin/codex"
    PATH="/usr/bin:/bin"
    CODEX_CLI_PACKAGE_FILE="$TMP_DIR/codex-package.json"
    printf '{"version":"0.146.9"}\n' > "$CODEX_CLI_PACKAGE_FILE"
    if [ "$(codex_installed_version_detect)" != "0.146.9" ]; then
        echo "Expected codex_installed_version_detect to fall back to package.json." >&2
        exit 1
    fi

    CODEX_VERSION_FILE="$TMP_DIR/version.json"
    printf '{"latest_version":"0.148.0"}\n' > "$CODEX_VERSION_FILE"
    if [ "$(codex_latest_version_detect)" != "0.148.0" ]; then
        echo "Expected codex_latest_version_detect to read latest_version." >&2
        exit 1
    fi
    PATH="$original_path"

    if ! version_gt "0.141.0" "0.140.0"; then
        echo "Expected 0.141.0 to be newer than 0.140.0." >&2
        exit 1
    fi

    if version_gt "0.140.0" "0.141.0"; then
        echo "Expected 0.140.0 to not be newer than 0.141.0." >&2
        exit 1
    fi

    if [ "$(codex_compatibility_status "")" != "unknown" ]; then
        echo "Expected empty installed version to have unknown compatibility status." >&2
        exit 1
    fi

    CODEX_WATCHER_VERIFIED_MAX_VERSION=0.200.0
    if [ "$(codex_compatibility_status "0.199.9")" != "ok" ]; then
        echo "Expected compatibility override to mark 0.199.9 as ok." >&2
        exit 1
    fi

    if [ "$(codex_compatibility_status "0.200.1")" != "recheck needed" ]; then
        echo "Expected compatibility override to mark 0.200.1 as recheck needed." >&2
        exit 1
    fi

    CODEX_WATCHER_VERIFIED_MAX_VERSION=0.147.0
    if [ "$(codex_compatibility_status "0.147.0")" != "ok" ]; then
        echo "Expected compatibility status for 0.147.0 to be ok." >&2
        exit 1
    fi

    if [ "$(codex_compatibility_status "0.147.1")" != "recheck needed" ]; then
        echo "Expected compatibility status for 0.147.1 to require recheck." >&2
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
append_line '2026-05-19T02:00:01.000000Z  INFO session_loop{thread_id=thread-old}:submission_dispatch{otel.name="op.dispatch.user_input" submission.id="turn-old" codex.op="user_input"}:turn{otel.name="session_task.turn" thread.id=thread-old turn.id=turn-old model=gpt-5.4}: codex_core::stream_events_utils: ToolCall: exec_command {"cmd":"curl --header Authorization:Bearer-legacy-secret https://internal.example","workdir":"/tmp/private-parent/project-old","yield_time_ms":1000} thread_id=thread-old'
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
assert_contains 'codex|turn_complete|thread-old|turn-old|Codex 当前这一问已经回答结束，可以继续下一轮提问。 项目：project-old。 最近工具：exec_command。'
assert_not_contains 'codex|turn_complete|thread-interrupt|turn-interrupt|'
assert_not_contains 'Bearer-legacy-secret'
assert_not_contains '/tmp/private-parent/project-old'

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

SUBAGENT_ROLLOUT_FILE="$CODEX_SESSIONS_DIR/2026/05/29/rollout-2026-05-29T15-52-00-019e72b9-1111-7111-8111-111111111111.jsonl"
ROLLOUT_FILE="$CODEX_SESSIONS_DIR/2026/05/29/rollout-2026-05-29T15-53-42-019e72b9-87cb-79b1-b8cf-534ecf01bec7.jsonl"
: > "$SUBAGENT_ROLLOUT_FILE"
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

append_rollout_line "$SUBAGENT_ROLLOUT_FILE" '{"timestamp":"2026-05-29T07:52:00.000Z","type":"session_meta","payload":{"id":"019e72b9-1111-7111-8111-111111111111","timestamp":"2026-05-29T07:52:00.000Z","cwd":"/tmp/project-rollout","originator":"codex-tui","source":{"subagent":{"thread_spawn":{"parent_thread_id":"019e72b9-87cb-79b1-b8cf-534ecf01bec7","depth":1,"agent_path":"/root/test-agent"}}},"parent_thread_id":"019e72b9-87cb-79b1-b8cf-534ecf01bec7","agent_path":"/root/test-agent"}}'
append_rollout_line "$SUBAGENT_ROLLOUT_FILE" '{"timestamp":"2026-05-29T07:52:00.001Z","type":"session_meta","payload":{"id":"019e72b9-87cb-79b1-b8cf-534ecf01bec7","timestamp":"2026-05-29T07:51:42.098Z","cwd":"/tmp/project-rollout","originator":"codex-tui","source":"cli"}}'
append_rollout_line "$SUBAGENT_ROLLOUT_FILE" '{"timestamp":"2026-05-29T07:52:00.002Z","type":"event_msg","payload":{"type":"task_started","turn_id":"turn-parent-inherited","started_at":1780041120}}'
append_rollout_line "$SUBAGENT_ROLLOUT_FILE" '{"timestamp":"2026-05-29T07:52:01.000Z","type":"event_msg","payload":{"type":"task_started","turn_id":"turn-subagent","started_at":1780041121}}'
append_rollout_line "$SUBAGENT_ROLLOUT_FILE" '{"timestamp":"2026-05-29T07:52:02.000Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"turn-subagent","completed_at":1780041122}}'

append_rollout_line "$ROLLOUT_FILE" '{"timestamp":"2026-05-29T07:53:58.199Z","type":"session_meta","payload":{"id":"019e72b9-87cb-79b1-b8cf-534ecf01bec7","timestamp":"2026-05-29T07:53:42.098Z","cwd":"/tmp/private-parent/project-rollout","originator":"codex-tui"}}'
append_rollout_line "$ROLLOUT_FILE" '{"timestamp":"2026-05-29T07:53:58.200Z","type":"event_msg","payload":{"type":"task_started","turn_id":"turn-rollout-complete","started_at":1780041238}}'
append_rollout_line "$ROLLOUT_FILE" '{"timestamp":"2026-05-29T07:54:10.023Z","type":"response_item","payload":{"type":"function_call","name":"exec_command","arguments":"{\"cmd\":\"curl --header Authorization:Bearer-rollout-secret https://internal.example\",\"workdir\":\"/tmp/private-parent/project-rollout\",\"yield_time_ms\":1000}","call_id":"call-rollout-complete"}}'
append_rollout_line "$ROLLOUT_FILE" '{"timestamp":"2026-05-29T07:54:21.023Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"turn-rollout-complete","completed_at":1780041261}}'
append_rollout_line "$ROLLOUT_FILE" '{"timestamp":"2026-05-29T07:55:58.200Z","type":"event_msg","payload":{"type":"task_started","turn_id":"turn-rollout-interrupt","started_at":1780041358}}'
append_rollout_line "$ROLLOUT_FILE" '{"timestamp":"2026-05-29T07:56:10.023Z","type":"response_item","payload":{"type":"function_call","name":"apply_patch","arguments":"*** Begin Patch\n*** End Patch","call_id":"call-rollout-interrupt"}}'
append_rollout_line "$ROLLOUT_FILE" '{"timestamp":"2026-05-29T07:56:12.023Z","type":"event_msg","payload":{"type":"turn_aborted","turn_id":"turn-rollout-interrupt","reason":"interrupted","completed_at":1780041372}}'
append_rollout_line "$ROLLOUT_FILE" '{"timestamp":"2026-05-29T07:56:13.023Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"turn-rollout-interrupt","completed_at":1780041373}}'
append_rollout_line "$ROLLOUT_FILE" '{"timestamp":"2026-05-29T07:57:58.200Z","type":"event_msg","payload":{"type":"task_started","turn_id":"turn-rollout-failed","started_at":1780041478}}'
append_rollout_line "$ROLLOUT_FILE" '{"timestamp":"2026-05-29T07:58:10.023Z","type":"response_item","payload":{"type":"function_call","name":"exec_command","arguments":"{\"cmd\":\"printenv TOP_SECRET_VALUE\",\"workdir\":\"/tmp/private-parent/project-rollout\",\"yield_time_ms\":1000}","call_id":"call-rollout-failed"}}'
append_rollout_line "$ROLLOUT_FILE" '{"timestamp":"2026-05-29T07:58:21.023Z","type":"event_msg","payload":{"type":"task_failed","turn_id":"turn-rollout-failed","error":"synthetic failure"}}'

wait_for_event_count 3
sleep 0.5

assert_contains 'codex|turn_complete|019e72b9-87cb-79b1-b8cf-534ecf01bec7|turn-rollout-complete|'
assert_contains 'codex|turn_interrupted|019e72b9-87cb-79b1-b8cf-534ecf01bec7|turn-rollout-interrupt|'
assert_contains 'codex|turn_failed|019e72b9-87cb-79b1-b8cf-534ecf01bec7|turn-rollout-failed|Codex 当前这一问执行失败，请查看终端中的错误信息。'
assert_contains '项目：project-rollout。 最近工具：exec_command。'
assert_not_contains 'codex|turn_complete|019e72b9-87cb-79b1-b8cf-534ecf01bec7|turn-rollout-interrupt|'
assert_not_contains 'codex|turn_complete|019e72b9-87cb-79b1-b8cf-534ecf01bec7|turn-rollout-failed|'
assert_not_contains '|turn-subagent|'
assert_not_contains 'Bearer-rollout-secret'
assert_not_contains 'TOP_SECRET_VALUE'
assert_not_contains '/tmp/private-parent/project-rollout'

event_count=$(wc -l < "$EVENT_LOG")
if [ "$event_count" -ne 3 ]; then
    echo "Expected 3 rollout watcher events, got $event_count." >&2
    cat "$EVENT_LOG" >&2
    exit 1
fi

echo "codex rollout watcher replay test passed."

kill "$WATCHER_PID" 2>/dev/null || true
wait "$WATCHER_PID" 2>/dev/null || true
WATCHER_PID=""

: > "$EVENT_LOG"
RESTART_ROLLOUT_FILE="$CODEX_SESSIONS_DIR/2026/05/29/rollout-2026-05-29T16-00-00-019e72b9-9999-7999-8999-999999999999.jsonl"
: > "$RESTART_ROLLOUT_FILE"
append_rollout_line "$RESTART_ROLLOUT_FILE" '{"timestamp":"2026-05-29T08:00:00.000Z","type":"session_meta","payload":{"id":"019e72b9-9999-7999-8999-999999999999","timestamp":"2026-05-29T08:00:00.000Z","cwd":"/tmp/restart-project","originator":"codex-tui"}}'
append_rollout_line "$RESTART_ROLLOUT_FILE" '{"timestamp":"2026-05-29T08:00:01.000Z","type":"event_msg","payload":{"type":"task_started","turn_id":"turn-restart-aborted","started_at":1780041601}}'
append_rollout_line "$RESTART_ROLLOUT_FILE" '{"timestamp":"2026-05-29T08:00:02.000Z","type":"event_msg","payload":{"type":"turn_aborted","turn_id":"turn-restart-aborted","reason":"interrupted","completed_at":1780041602}}'

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

append_rollout_line "$RESTART_ROLLOUT_FILE" '{"timestamp":"2026-05-29T08:00:03.000Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"turn-restart-aborted","completed_at":1780041603}}'
append_rollout_line "$RESTART_ROLLOUT_FILE" '{"timestamp":"2026-05-29T08:01:00.000Z","type":"event_msg","payload":{"type":"task_started","turn_id":"turn-after-restart","started_at":1780041660}}'
append_rollout_line "$RESTART_ROLLOUT_FILE" '{"timestamp":"2026-05-29T08:01:01.000Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"turn-after-restart","completed_at":1780041661}}'

wait_for_event_count 1
sleep 0.5

assert_contains 'codex|turn_complete|019e72b9-9999-7999-8999-999999999999|turn-after-restart|'
assert_not_contains '|turn-restart-aborted|'

event_count=$(wc -l < "$EVENT_LOG")
if [ "$event_count" -ne 1 ]; then
    echo "Expected 1 event after watcher restart, got $event_count." >&2
    cat "$EVENT_LOG" >&2
    exit 1
fi

echo "codex watcher restart state test passed."

kill "$WATCHER_PID" 2>/dev/null || true
wait "$WATCHER_PID" 2>/dev/null || true
WATCHER_PID=""

: > "$EVENT_LOG"
TRUNCATED_ROLLOUT_FILE="$CODEX_SESSIONS_DIR/2026/05/29/rollout-2026-05-29T16-10-00-019e72b9-aaaa-7aaa-8aaa-aaaaaaaaaaaa.jsonl"
: > "$TRUNCATED_ROLLOUT_FILE"
append_rollout_line "$TRUNCATED_ROLLOUT_FILE" '{"timestamp":"2026-05-29T08:10:00.000Z","type":"session_meta","payload":{"id":"019e72b9-aaaa-7aaa-8aaa-aaaaaaaaaaaa","timestamp":"2026-05-29T08:10:00.000Z","cwd":"/tmp/truncated-project","originator":"codex-tui"}}'
append_rollout_line "$TRUNCATED_ROLLOUT_FILE" '{"timestamp":"2026-05-29T08:10:01.000Z","type":"event_msg","payload":{"type":"task_started","turn_id":"turn-before-truncate","started_at":1780042201}}'
append_rollout_line "$TRUNCATED_ROLLOUT_FILE" '{"timestamp":"2026-05-29T08:10:02.000Z","type":"event_msg","payload":{"type":"response_item_done","item_id":"item-before-truncate"}}'

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

: > "$TRUNCATED_ROLLOUT_FILE"
append_rollout_line "$TRUNCATED_ROLLOUT_FILE" '{"timestamp":"2026-05-29T08:11:00.000Z","type":"session_meta","payload":{"id":"019e72b9-aaaa-7aaa-8aaa-aaaaaaaaaaaa","timestamp":"2026-05-29T08:11:00.000Z","cwd":"/tmp/truncated-project","originator":"codex-tui"}}'
append_rollout_line "$TRUNCATED_ROLLOUT_FILE" '{"timestamp":"2026-05-29T08:11:01.000Z","type":"event_msg","payload":{"type":"task_started","turn_id":"turn-after-truncate","started_at":1780042261}}'
append_rollout_line "$TRUNCATED_ROLLOUT_FILE" '{"timestamp":"2026-05-29T08:11:02.000Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"turn-after-truncate","completed_at":1780042262}}'

wait_for_event_count 1
sleep 0.5

assert_contains 'codex|turn_complete|019e72b9-aaaa-7aaa-8aaa-aaaaaaaaaaaa|turn-after-truncate|'
assert_not_contains '|turn-before-truncate|'
assert_runtime_log_contains "codex_watcher reset rollout file=$TRUNCATED_ROLLOUT_FILE previous_offset=3"

event_count=$(wc -l < "$EVENT_LOG")
if [ "$event_count" -ne 1 ]; then
    echo "Expected 1 event after rollout truncation reset, got $event_count." >&2
    cat "$EVENT_LOG" >&2
    exit 1
fi

echo "codex watcher truncation reset test passed."

kill "$WATCHER_PID" 2>/dev/null || true
wait "$WATCHER_PID" 2>/dev/null || true
WATCHER_PID=""
