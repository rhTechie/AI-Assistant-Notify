#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
TMP_DIR=$(mktemp -d)
PROJECTS_DIR="$TMP_DIR/projects"
RUNTIME_LOG="$TMP_DIR/runtime.log"
EVENT_LOG="$TMP_DIR/events.log"

cleanup() {
    stop_watcher
    rm -rf "$TMP_DIR"
}

trap cleanup EXIT

fail() {
    echo "Test failed: $*" >&2
    exit 1
}

stop_watcher() {
    if [ -n "${WATCHER_PID:-}" ] && kill -0 "$WATCHER_PID" 2>/dev/null; then
        kill "$WATCHER_PID" 2>/dev/null || true
        wait "$WATCHER_PID" 2>/dev/null || true
    fi
    WATCHER_PID=""
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
        echo "Unexpected event text: $unexpected" >&2
        echo "Recorded events:" >&2
        cat "$EVENT_LOG" >&2
        exit 1
    fi
}

assert_message_not_contains() {
    local unexpected="$1"

    if awk -F'|' '{print $5}' "$EVENT_LOG" | grep -F -- "$unexpected" >/dev/null 2>&1; then
        echo "Unexpected text in notification message: $unexpected" >&2
        echo "Recorded events:" >&2
        cat "$EVENT_LOG" >&2
        exit 1
    fi
}

assert_event_count() {
    local expected_count="$1"
    local description="$2"
    local event_count

    event_count=$(wc -l < "$EVENT_LOG" 2>/dev/null || echo "0")
    if [ "$event_count" -ne "$expected_count" ]; then
        echo "Expected $expected_count $description, got $event_count." >&2
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
    local attempts=100
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

wait_for_runtime_log_contains() {
    local expected="$1"
    local attempts=100

    while [ "$attempts" -gt 0 ]; do
        if grep -F -- "$expected" "$RUNTIME_LOG" >/dev/null 2>&1; then
            return 0
        fi
        attempts=$((attempts - 1))
        sleep 0.1
    done

    echo "Timed out waiting for runtime log: $expected" >&2
    [ -f "$RUNTIME_LOG" ] && cat "$RUNTIME_LOG" >&2 || true
    exit 1
}

start_watcher() {
    export CLAUDE_PROJECTS_DIR="$PROJECTS_DIR"
    export CLAUDE_WATCH_INTERVAL=0.2
    : > "$RUNTIME_LOG"

    (
        # shellcheck disable=SC1091
        source "$REPO_ROOT/scripts/watchers/claude_watcher.sh"

        notify_callback() {
            local watcher_type="$1"
            local event_type="$2"
            local message="$3"
            local session_id="$4"
            local event_id="$5"

            printf '%s|%s|%s|%s|%s\n' \
                "$watcher_type" \
                "$event_type" \
                "$session_id" \
                "$event_id" \
                "$message" >> "$EVENT_LOG"
        }

        claude_watcher_init
        claude_watcher_run notify_callback "$RUNTIME_LOG"
    ) &
    WATCHER_PID=$!
}

append_json_line() {
    local file_path="$1"
    local line="$2"

    mkdir -p "$(dirname "$file_path")"
    printf '%s\n' "$line" >> "$file_path"
}

user_prompt_line() {
    local session_id="$1"
    local cwd="$2"
    local text="$3"
    local uuid="$4"
    local is_sidechain="${5:-false}"

    printf '{"type":"user","isSidechain":%s,"sessionId":"%s","cwd":"%s","message":{"role":"user","content":"%s"},"promptSource":"typed","uuid":"%s"}' \
        "$is_sidechain" "$session_id" "$cwd" "$text" "$uuid"
}

tool_result_line() {
    local session_id="$1"
    local cwd="$2"
    local tool_use_id="$3"
    local uuid="$4"
    local is_sidechain="${5:-false}"

    printf '{"type":"user","isSidechain":%s,"sessionId":"%s","cwd":"%s","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"%s"}]},"uuid":"%s"}' \
        "$is_sidechain" "$session_id" "$cwd" "$tool_use_id" "$uuid"
}

assistant_tool_line() {
    local session_id="$1"
    local cwd="$2"
    local tool_name="$3"
    local tool_id="$4"
    local input_json="$5"
    local uuid="$6"
    local is_sidechain="${7:-false}"

    printf '{"type":"assistant","isSidechain":%s,"sessionId":"%s","cwd":"%s","message":{"role":"assistant","content":[{"type":"tool_use","name":"%s","id":"%s","input":%s}],"stop_reason":"tool_use"},"uuid":"%s"}' \
        "$is_sidechain" "$session_id" "$cwd" "$tool_name" "$tool_id" "$input_json" "$uuid"
}

assistant_end_line() {
    local session_id="$1"
    local cwd="$2"
    local uuid="$3"
    local is_sidechain="${4:-false}"

    printf '{"type":"assistant","isSidechain":%s,"sessionId":"%s","cwd":"%s","message":{"role":"assistant","content":[{"type":"text","text":"done"}],"stop_reason":"end_turn"},"uuid":"%s"}' \
        "$is_sidechain" "$session_id" "$cwd" "$uuid"
}

system_turn_duration_line() {
    local session_id="$1"
    local cwd="$2"
    local uuid="$3"

    printf '{"type":"system","subtype":"turn_duration","sessionId":"%s","cwd":"%s","uuid":"%s"}' \
        "$session_id" "$cwd" "$uuid"
}

interrupt_line() {
    local session_id="$1"
    local cwd="$2"
    local uuid="$3"

    printf '{"type":"user","isSidechain":false,"sessionId":"%s","cwd":"%s","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user]"}]},"uuid":"%s"}' \
        "$session_id" "$cwd" "$uuid"
}

system_user_line() {
    local session_id="$1"
    local cwd="$2"
    local text="$3"
    local uuid="$4"

    printf '{"type":"user","isSidechain":false,"sessionId":"%s","cwd":"%s","message":{"role":"user","content":"%s"},"promptSource":"system","uuid":"%s"}' \
        "$session_id" "$cwd" "$text" "$uuid"
}

meta_user_line() {
    local session_id="$1"
    local cwd="$2"
    local text="$3"
    local uuid="$4"

    printf '{"type":"user","isSidechain":false,"isMeta":true,"sessionId":"%s","cwd":"%s","message":{"role":"user","content":"%s"},"uuid":"%s"}' \
        "$session_id" "$cwd" "$text" "$uuid"
}

untyped_user_line() {
    local session_id="$1"
    local cwd="$2"
    local text="$3"
    local uuid="$4"

    printf '{"type":"user","isSidechain":false,"sessionId":"%s","cwd":"%s","message":{"role":"user","content":"%s"},"uuid":"%s"}' \
        "$session_id" "$cwd" "$text" "$uuid"
}

queued_user_line() {
    local session_id="$1"
    local cwd="$2"
    local text="$3"
    local uuid="$4"

    printf '{"type":"user","isSidechain":false,"sessionId":"%s","cwd":"%s","message":{"role":"user","content":"%s"},"promptSource":"queued","origin":{"kind":"human"},"uuid":"%s"}' \
        "$session_id" "$cwd" "$text" "$uuid"
}

SESSION_A="aaaaaaaa-1111-7111-8111-111111111111"
SESSION_B="bbbbbbbb-2222-7222-8222-222222222222"
SESSION_Q="cccccccc-3333-7333-8333-333333333333"
SESSION_I="dddddddd-4444-7444-8444-444444444444"
SESSION_SUB="eeeeeeee-5555-7555-8555-555555555555"
SESSION_T="ffffffff-6666-7666-8666-666666666666"
SESSION_M="99999999-7777-7777-8777-777777777777"
SESSION_P="abababab-8888-7888-8888-888888888888"
SESSION_N="cdcdcdcd-9999-7999-8999-999999999999"

# ---------------------------------------------------------------------------
# Version detection and compatibility checks
# ---------------------------------------------------------------------------
(
    export CLAUDE_PROJECTS_DIR="$TMP_DIR/unit-projects"
    mkdir -p "$CLAUDE_PROJECTS_DIR/unit-project"

    # shellcheck disable=SC1091
    source "$REPO_ROOT/scripts/watchers/claude_watcher.sh"

    if ! claude_watcher_init; then
        echo "Expected claude_watcher_init to succeed for an existing projects dir." >&2
        exit 1
    fi
    if [ "$CLAUDE_WATCH_SOURCE" != "projects_jsonl" ]; then
        echo "Expected CLAUDE_WATCH_SOURCE=projects_jsonl, got '$CLAUDE_WATCH_SOURCE'." >&2
        exit 1
    fi

    fake_bin="$TMP_DIR/fake-bin"
    mkdir -p "$fake_bin"
    printf '#!/usr/bin/env bash\nprintf "2.1.314 (Claude Code)\\n"\n' > "$fake_bin/claude"
    chmod +x "$fake_bin/claude"
    export PATH="$fake_bin:$PATH"

    # A session record with a different version must not win over `claude --version`.
    printf '%s\n' \
        '{"type":"user","isSidechain":false,"sessionId":"9.9.9-session","cwd":"/tmp/unit-project","version":"9.9.9","message":{"role":"user","content":"unit prompt"},"uuid":"unit-user"}' \
        > "$CLAUDE_PROJECTS_DIR/unit-project/14141414-cccc-7ccc-8ccc-cccccccccccc.jsonl"

    detected_version=$(claude_installed_version_detect)
    if [ "$detected_version" != "2.1.314" ]; then
        echo "Expected claude_installed_version_detect to parse '2.1.314 (Claude Code)', got '$detected_version'." >&2
        exit 1
    fi

    if [ "$(claude_compatibility_status "")" != "unknown" ]; then
        echo "Expected empty version to report unknown compatibility." >&2
        exit 1
    fi
    if [ "$(claude_compatibility_status "2.1.314")" != "ok" ]; then
        echo "Expected verified max version 2.1.314 to report ok compatibility." >&2
        exit 1
    fi
    if [ "$(claude_compatibility_status "2.1.300")" != "ok" ]; then
        echo "Expected older version 2.1.300 to report ok compatibility." >&2
        exit 1
    fi
    if [ "$(claude_compatibility_status "2.1.315")" != "recheck needed" ]; then
        echo "Expected newer version without observed sessions to report recheck needed." >&2
        exit 1
    fi

    compat_dir="$TMP_DIR/compat-projects"
    compat_session="12121212-aaaa-7aaa-8aaa-aaaaaaaaaaaa"
    compat_file="$compat_dir/compat-project/$compat_session.jsonl"
    mkdir -p "$(dirname "$compat_file")"
    printf '%s\n' \
        '{"type":"user","isSidechain":false,"sessionId":"12121212-aaaa-7aaa-8aaa-aaaaaaaaaaaa","cwd":"/tmp/compat-project","version":"2.1.320","message":{"role":"user","content":"compatibility prompt"},"promptSource":"typed","uuid":"compat-user"}' \
        '{"type":"assistant","isSidechain":false,"sessionId":"12121212-aaaa-7aaa-8aaa-aaaaaaaaaaaa","cwd":"/tmp/compat-project","version":"2.1.320","message":{"role":"assistant","content":[{"type":"text","text":"done"}],"stop_reason":"end_turn"},"uuid":"compat-assistant"}' > "$compat_file"

    CLAUDE_PROJECTS_DIR="$compat_dir"
    if [ "$(claude_compatibility_status "2.1.320")" != "event format observed" ]; then
        echo "Expected matching newer main-session evidence to report event format observed." >&2
        exit 1
    fi
    if [ "$(claude_compatibility_status "2.1.321")" != "recheck needed" ]; then
        echo "Expected a different newer version to still report recheck needed." >&2
        exit 1
    fi

    sidechain_file="$compat_dir/sidechain-project/13131313-bbbb-7bbb-8bbb-bbbbbbbbbbbb.jsonl"
    mkdir -p "$(dirname "$sidechain_file")"
    printf '%s\n' \
        '{"type":"user","isSidechain":true,"sessionId":"13131313-bbbb-7bbb-8bbb-bbbbbbbbbbbb","cwd":"/tmp/sidechain-project","version":"2.1.322","message":{"role":"user","content":"sidechain prompt"},"uuid":"side-user"}' \
        '{"type":"assistant","isSidechain":true,"sessionId":"13131313-bbbb-7bbb-8bbb-bbbbbbbbbbbb","cwd":"/tmp/sidechain-project","version":"2.1.322","message":{"role":"assistant","content":[{"type":"text","text":"done"}],"stop_reason":"end_turn"},"uuid":"side-assistant"}' > "$sidechain_file"

    if [ "$(claude_compatibility_status "2.1.322")" != "recheck needed" ]; then
        echo "Expected sidechain-only evidence not to count as a real main session." >&2
        exit 1
    fi

    non_typed_file="$compat_dir/non-typed-project/15151515-eeee-7eee-8eee-eeeeeeeeeeee.jsonl"
    mkdir -p "$(dirname "$non_typed_file")"
    printf '%s\n' \
        '{"type":"user","isSidechain":false,"sessionId":"15151515-eeee-7eee-8eee-eeeeeeeeeeee","cwd":"/tmp/non-typed-project","version":"2.1.323","promptSource":"system","message":{"role":"user","content":"<task-notification>compat background task</task-notification>"},"uuid":"non-typed-user"}' \
        '{"type":"assistant","isSidechain":false,"sessionId":"15151515-eeee-7eee-8eee-eeeeeeeeeeee","cwd":"/tmp/non-typed-project","version":"2.1.323","message":{"role":"assistant","content":[{"type":"text","text":"done"}],"stop_reason":"end_turn"},"uuid":"non-typed-assistant"}' > "$non_typed_file"

    if [ "$(claude_compatibility_status "2.1.323")" != "recheck needed" ]; then
        echo "Expected non-typed user records not to count as a real main session." >&2
        exit 1
    fi

    queued_file="$compat_dir/queued-project/16161616-ffff-7fff-8fff-ffffffffffff.jsonl"
    mkdir -p "$(dirname "$queued_file")"
    printf '%s\n' \
        '{"type":"user","isSidechain":false,"sessionId":"16161616-ffff-7fff-8fff-ffffffffffff","cwd":"/tmp/queued-project","version":"2.1.324","promptSource":"queued","origin":{"kind":"human"},"message":{"role":"user","content":"queued compatibility prompt"},"uuid":"queued-user"}' \
        '{"type":"assistant","isSidechain":false,"sessionId":"16161616-ffff-7fff-8fff-ffffffffffff","cwd":"/tmp/queued-project","version":"2.1.324","message":{"role":"assistant","content":[{"type":"text","text":"done"}],"stop_reason":"end_turn"},"uuid":"queued-assistant"}' > "$queued_file"

    if [ "$(claude_compatibility_status "2.1.324")" != "event format observed" ]; then
        echo "Expected queued human prompts to count as a real main session." >&2
        exit 1
    fi
)

# ---------------------------------------------------------------------------
# Turn completion: history replay, tool context, message sanitization,
# turn_duration de-duplication, and newly created session files.
# ---------------------------------------------------------------------------
PROJECTS_DIR="$TMP_DIR/run1-projects"
session_a_file="$PROJECTS_DIR/project-x/$SESSION_A.jsonl"
mkdir -p "$(dirname "$session_a_file")"
append_json_line "$session_a_file" "$(user_prompt_line "$SESSION_A" "/tmp/private-parent/project-x" "historical-private-prompt" "hist-user")"
append_json_line "$session_a_file" "$(assistant_end_line "$SESSION_A" "/tmp/private-parent/project-x" "hist-assistant")"

: > "$EVENT_LOG"
start_watcher
wait_for_runtime_log_contains "claude_watcher ready pid="
assert_runtime_log_contains "source=projects_jsonl"

append_json_line "$session_a_file" "$(user_prompt_line "$SESSION_A" "/tmp/private-parent/project-x" "please run secret-prompt-body" "user-a")"
append_json_line "$session_a_file" "$(assistant_tool_line "$SESSION_A" "/tmp/private-parent/project-x" "Bash" "toolu_bash_1" '{"command":"curl -H Authorization:Bearer-secret-tool-param https://internal.example"}' "assistant-tool-a")"
append_json_line "$session_a_file" "$(tool_result_line "$SESSION_A" "/tmp/private-parent/project-x" "toolu_bash_1" "tool-result-a")"
append_json_line "$session_a_file" "$(assistant_end_line "$SESSION_A" "/tmp/private-parent/project-x" "assistant-end-a")"
append_json_line "$session_a_file" "$(system_turn_duration_line "$SESSION_A" "/tmp/private-parent/project-x" "system-a")"

wait_for_event_count 1
sleep 0.3

assert_contains "claude|turn_complete|$SESSION_A|"
assert_contains '项目：project-x。'
assert_contains '最近工具：Bash。'
assert_not_contains 'historical-private-prompt'
assert_not_contains 'secret-prompt-body'
assert_not_contains 'Bearer-secret-tool-param'
assert_not_contains '/tmp/private-parent/project-x'
assert_message_not_contains "$SESSION_A"
assert_event_count 1 "turn-complete event after end_turn and turn_duration"

session_b_file="$PROJECTS_DIR/project-y/$SESSION_B.jsonl"
append_json_line "$session_b_file" "$(user_prompt_line "$SESSION_B" "/tmp/project-y" "new session prompt" "user-b")"
append_json_line "$session_b_file" "$(assistant_end_line "$SESSION_B" "/tmp/project-y" "assistant-end-b")"

wait_for_event_count 2
sleep 0.3

assert_contains "claude|turn_complete|$SESSION_B|"
assert_contains '项目：project-y。'
assert_event_count 2 "events after a session file created while running"

stop_watcher

# ---------------------------------------------------------------------------
# Questions are notified once per tool_use id; interrupts suppress
# turn_duration; subagent files never notify.
# ---------------------------------------------------------------------------
PROJECTS_DIR="$TMP_DIR/run2-projects"
session_q_file="$PROJECTS_DIR/project-x/$SESSION_Q.jsonl"
session_i_file="$PROJECTS_DIR/project-x/$SESSION_I.jsonl"
session_sub_main_file="$PROJECTS_DIR/project-x/$SESSION_SUB.jsonl"
session_sub_agent_file="$PROJECTS_DIR/project-x/$SESSION_SUB/subagents/agent-1.jsonl"
mkdir -p "$(dirname "$session_q_file")" "$(dirname "$session_i_file")" "$(dirname "$session_sub_agent_file")"
: > "$session_q_file"
: > "$session_i_file"
: > "$session_sub_main_file"
: > "$session_sub_agent_file"

: > "$EVENT_LOG"
start_watcher
wait_for_runtime_log_contains "claude_watcher ready pid="

question_tool_line=$(assistant_tool_line \
    "$SESSION_Q" "/tmp/private-parent/project-q" "AskUserQuestion" "toolu_question_1" \
    '{"questions":[{"question":"secret-question-body"}]}' "assistant-question-q")
append_json_line "$session_q_file" "$(user_prompt_line "$SESSION_Q" "/tmp/private-parent/project-q" "question turn prompt" "user-q")"
append_json_line "$session_q_file" "$question_tool_line"
append_json_line "$session_q_file" "$question_tool_line"

append_json_line "$session_i_file" "$(user_prompt_line "$SESSION_I" "/tmp/private-parent/project-i" "interrupt turn prompt" "user-i")"
append_json_line "$session_i_file" "$(assistant_tool_line "$SESSION_I" "/tmp/private-parent/project-i" "Bash" "toolu_i_bash" '{"command":"git status"}' "assistant-tool-i")"
append_json_line "$session_i_file" "$(interrupt_line "$SESSION_I" "/tmp/private-parent/project-i" "interrupt-i")"
append_json_line "$session_i_file" "$(system_turn_duration_line "$SESSION_I" "/tmp/private-parent/project-i" "system-i")"

append_json_line "$session_sub_agent_file" "$(user_prompt_line "$SESSION_SUB" "/tmp/private-parent/project-sub" "subagent prompt" "sub-user" true)"
append_json_line "$session_sub_agent_file" "$(assistant_tool_line "$SESSION_SUB" "/tmp/private-parent/project-sub" "AskUserQuestion" "toolu_sub_question" '{"questions":[{"question":"subagent-private-question"}]}' "sub-question" true)"
append_json_line "$session_sub_agent_file" "$(assistant_end_line "$SESSION_SUB" "/tmp/private-parent/project-sub" "sub-end" true)"

wait_for_event_count 1
sleep 0.5

assert_contains "claude|question_requested|$SESSION_Q|toolu_question_1|"
assert_contains '项目：project-q。'
assert_not_contains "claude|turn_complete|$SESSION_I|"
assert_not_contains "claude|question_requested|$SESSION_I|"
assert_not_contains "claude|turn_complete|$SESSION_SUB|"
assert_not_contains "claude|question_requested|$SESSION_SUB|"
assert_not_contains 'secret-question-body'
assert_not_contains 'subagent-private-question'
assert_message_not_contains "$SESSION_Q"
assert_event_count 1 "question event after duplicate AskUserQuestion and interrupt suppression"

append_json_line "$session_q_file" "$(assistant_end_line "$SESSION_Q" "/tmp/private-parent/project-q" "assistant-end-q")"
wait_for_event_count 2
sleep 0.3

assert_contains "claude|turn_complete|$SESSION_Q|"
assert_not_contains "claude|turn_complete|$SESSION_I|"
assert_event_count 2 "events after the question turn completes"

stop_watcher

# ---------------------------------------------------------------------------
# Truncated/rewritten session files reset their offset and keep working.
# ---------------------------------------------------------------------------
PROJECTS_DIR="$TMP_DIR/run3-projects"
session_t_file="$PROJECTS_DIR/project-trunc/$SESSION_T.jsonl"
mkdir -p "$(dirname "$session_t_file")"
append_json_line "$session_t_file" "$(user_prompt_line "$SESSION_T" "/tmp/project-trunc" "before truncate prompt" "user-t-before")"
append_json_line "$session_t_file" "$(assistant_tool_line "$SESSION_T" "/tmp/project-trunc" "Bash" "toolu_t_before" '{"command":"ls"}' "assistant-t-before")"
append_json_line "$session_t_file" "$(assistant_end_line "$SESSION_T" "/tmp/project-trunc" "assistant-end-before")"

: > "$EVENT_LOG"
start_watcher
wait_for_runtime_log_contains "claude_watcher ready pid="

: > "$session_t_file"
append_json_line "$session_t_file" "$(user_prompt_line "$SESSION_T" "/tmp/project-trunc" "after truncate prompt" "user-t-after")"
append_json_line "$session_t_file" "$(assistant_end_line "$SESSION_T" "/tmp/project-trunc" "assistant-end-after")"

wait_for_event_count 1
sleep 0.3

assert_contains "claude|turn_complete|$SESSION_T|"
assert_runtime_log_contains "claude_watcher reset file=$session_t_file"
assert_event_count 1 "event after a truncated session file was rewritten"

stop_watcher

# ---------------------------------------------------------------------------
# isSidechain lines inside a main session file are ignored, while later
# main-session lines in that same file keep working.
# ---------------------------------------------------------------------------
PROJECTS_DIR="$TMP_DIR/run4-projects"
session_m_file="$PROJECTS_DIR/project-side/$SESSION_M.jsonl"
mkdir -p "$(dirname "$session_m_file")"
: > "$session_m_file"

: > "$EVENT_LOG"
start_watcher
wait_for_runtime_log_contains "claude_watcher ready pid="

append_json_line "$session_m_file" "$(user_prompt_line "$SESSION_M" "/tmp/private-parent/project-side" "mixed file prompt" "user-m")"
append_json_line "$session_m_file" "$(assistant_tool_line "$SESSION_M" "/tmp/private-parent/project-side" "AskUserQuestion" "toolu_m_side_question" '{"questions":[{"question":"sidechain-question-secret"}]}' "sidechain-question-m" true)"
append_json_line "$session_m_file" "$(assistant_end_line "$SESSION_M" "/tmp/private-parent/project-side" "sidechain-end-m" true)"
sleep 0.7
assert_event_count 0 "events after sidechain question and end_turn lines"
assert_not_contains 'sidechain-question-secret'

append_json_line "$session_m_file" "$(assistant_end_line "$SESSION_M" "/tmp/private-parent/project-side" "main-end-m" false)"
wait_for_event_count 1
sleep 0.3

assert_contains "claude|turn_complete|$SESSION_M|"
assert_event_count 1 "event after a main-session end_turn following an ignored sidechain line"

stop_watcher

# ---------------------------------------------------------------------------
# A partially written line (no trailing newline) is not processed until the
# line is complete; the completed line is then read exactly once.
# ---------------------------------------------------------------------------
PROJECTS_DIR="$TMP_DIR/run5-projects"
session_p_file="$PROJECTS_DIR/project-partial/$SESSION_P.jsonl"
mkdir -p "$(dirname "$session_p_file")"
: > "$session_p_file"

: > "$EVENT_LOG"
start_watcher
wait_for_runtime_log_contains "claude_watcher ready pid="

printf '%s' "$(user_prompt_line "$SESSION_P" "/tmp/project-partial" "partial line prompt" "user-p")" >> "$session_p_file"
sleep 0.6
assert_event_count 0 "events for a partially written line without a trailing newline"

printf '\n' >> "$session_p_file"
append_json_line "$session_p_file" "$(assistant_end_line "$SESSION_P" "/tmp/project-partial" "assistant-end-p")"
wait_for_event_count 1
sleep 0.3

assert_contains "claude|turn_complete|$SESSION_P|"
assert_event_count 1 "event after the partial line was completed"
stop_watcher

# ---------------------------------------------------------------------------
# Only typed user prompts (promptSource=typed, not isMeta) start a new turn.
# Background task notifications, system reminders and slash command output
# must not produce a completion notification.
# ---------------------------------------------------------------------------
PROJECTS_DIR="$TMP_DIR/run6-projects"
session_n_file="$PROJECTS_DIR/project-nontyped/$SESSION_N.jsonl"
mkdir -p "$(dirname "$session_n_file")"
: > "$session_n_file"

: > "$EVENT_LOG"
start_watcher
wait_for_runtime_log_contains "claude_watcher ready pid="

append_json_line "$session_n_file" "$(system_user_line "$SESSION_N" "/tmp/project-nontyped" '<task-notification>secret-background-task</task-notification>' "system-n-1")"
append_json_line "$session_n_file" "$(assistant_end_line "$SESSION_N" "/tmp/project-nontyped" "end-after-system-n-1")"
append_json_line "$session_n_file" "$(system_turn_duration_line "$SESSION_N" "/tmp/project-nontyped" "duration-after-system-n-1")"
sleep 0.6
assert_event_count 0 "events for a background task notification turn"

append_json_line "$session_n_file" "$(meta_user_line "$SESSION_N" "/tmp/project-nontyped" '<system-reminder>secret-meta-reminder</system-reminder>' "meta-n-2")"
append_json_line "$session_n_file" "$(assistant_end_line "$SESSION_N" "/tmp/project-nontyped" "end-after-meta-n-2")"
sleep 0.6
assert_event_count 0 "events for a system-reminder turn"

append_json_line "$session_n_file" "$(untyped_user_line "$SESSION_N" "/tmp/project-nontyped" '<local-command-stdout>Set model</local-command-stdout>' "untyped-n-3")"
append_json_line "$session_n_file" "$(assistant_end_line "$SESSION_N" "/tmp/project-nontyped" "end-after-untyped-n-3")"
sleep 0.6
assert_event_count 0 "events for an untyped slash command turn"

append_json_line "$session_n_file" "$(user_prompt_line "$SESSION_N" "/tmp/project-nontyped" "real typed prompt" "typed-n-4")"
append_json_line "$session_n_file" "$(system_turn_duration_line "$SESSION_N" "/tmp/project-nontyped" "duration-after-typed-n-4")"
wait_for_event_count 1
sleep 0.3

assert_contains "claude|turn_complete|$SESSION_N|"
assert_not_contains 'secret-background-task'
assert_not_contains 'secret-meta-reminder'
assert_event_count 1 "event for the typed prompt after non-typed user lines"

# turn_duration alone completes the turn; a later end_turn must not repeat it.
append_json_line "$session_n_file" "$(assistant_end_line "$SESSION_N" "/tmp/project-nontyped" "end-after-typed-n-4")"
sleep 0.6
assert_event_count 1 "turn_duration and end_turn are de-duplicated"

# A queued human prompt (promptSource=queued) is a real turn and must notify.
append_json_line "$session_n_file" "$(queued_user_line "$SESSION_N" "/tmp/project-nontyped" "queued prompt" "queued-n-5")"
append_json_line "$session_n_file" "$(assistant_end_line "$SESSION_N" "/tmp/project-nontyped" "end-after-queued-n-5")"
wait_for_event_count 2
sleep 0.3

assert_contains "claude|turn_complete|$SESSION_N|end-after-queued-n-5|"
assert_event_count 2 "event for a queued human prompt"
stop_watcher

echo "claude watcher replay test passed."
