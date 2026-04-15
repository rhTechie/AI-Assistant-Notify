#!/bin/bash

set -euo pipefail

# Claude Code 监测模块

WATCHER_SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck disable=SC1091
source "$WATCHER_SCRIPT_DIR/../utils/log_utils.sh"
# shellcheck disable=SC1091
source "$WATCHER_SCRIPT_DIR/../utils/process_utils.sh"

CLAUDE_SESSION_DIR="${CLAUDE_SESSION_DIR:-$HOME/.claude/sessions}"
CLAUDE_HISTORY_FILE="${CLAUDE_HISTORY_FILE:-$HOME/.claude/history.jsonl}"
CLAUDE_CHECK_INTERVAL="${CLAUDE_CHECK_INTERVAL:-5}"

declare -A tracked_sessions=()
declare -A session_last_input_time=()
declare -A session_cwd=()
declare -A session_last_display=()

extract_json_field() {
    local json="$1"
    local field="$2"

    printf '%s' "$json" | grep -o "\"$field\":\"[^\"]*\"" | sed "s/\"$field\":\"\([^\"]*\)\"/\1/" || true
}

project_name_from_cwd() {
    local cwd="$1"

    if [ -n "$cwd" ]; then
        basename "$cwd"
    else
        printf 'unknown'
    fi
}

build_claude_message() {
    local event_type="$1"
    local session_id="$2"
    local cwd="$3"
    local last_input="$4"
    local message

    case "$event_type" in
        session_complete)
            message="Claude Code 会话已结束。"
            ;;
        session_idle)
            message="Claude Code 可能已完成当前任务（超过 ${CLAUDE_IDLE_THRESHOLD:-300} 秒无新输入）。"
            ;;
        *)
            message="Claude Code 状态发生变化。"
            ;;
    esac

    if [ -n "$cwd" ]; then
        message="${message} 项目：$(project_name_from_cwd "$cwd")。cwd：${cwd}。"
    fi
    if [ -n "$last_input" ]; then
        local truncated_input="${last_input:0:100}"
        [ "${#last_input}" -gt 100 ] && truncated_input="${truncated_input}..."
        message="${message} 最后输入：${truncated_input}。"
    fi
    message="${message} SessionID：${session_id}。"

    printf '%s' "$message"
}

scan_active_sessions() {
    local session_dir="$1"

    if [ ! -d "$session_dir" ]; then
        return
    fi

    for session_file in "$session_dir"/*.json; do
        [ -f "$session_file" ] || continue

        local content
        content=$(cat "$session_file" 2>/dev/null || true)
        [ -z "$content" ] && continue

        local pid
        local session_id
        local cwd

        pid=$(extract_json_field "$content" "pid")
        session_id=$(extract_json_field "$content" "sessionId")
        cwd=$(extract_json_field "$content" "cwd")

        if [ -n "$pid" ] && [ -n "$session_id" ]; then
            if pid_is_alive "$pid"; then
                if [ -z "${tracked_sessions[$session_id]:-}" ]; then
                    tracked_sessions["$session_id"]="$pid"
                    session_cwd["$session_id"]="$cwd"
                    session_last_input_time["$session_id"]=$(date +%s)
                fi
            fi
        fi
    done
}

check_history_updates() {
    local history_file="$1"
    local last_line_count="${2:-0}"

    if [ ! -f "$history_file" ]; then
        echo "$last_line_count"
        return
    fi

    local current_line_count
    current_line_count=$(wc -l < "$history_file" 2>/dev/null || echo "0")

    if [ "$current_line_count" -gt "$last_line_count" ]; then
        local new_lines=$((current_line_count - last_line_count))
        tail -n "$new_lines" "$history_file" 2>/dev/null | while IFS= read -r line; do
            local session_id
            local display

            session_id=$(extract_json_field "$line" "sessionId")
            display=$(extract_json_field "$line" "display")

            if [ -n "$session_id" ] && [ -n "${tracked_sessions[$session_id]:-}" ]; then
                session_last_input_time["$session_id"]=$(date +%s)
                session_last_display["$session_id"]="$display"
            fi
        done
    fi

    echo "$current_line_count"
}

claude_watcher_init() {
    if [ ! -d "$CLAUDE_SESSION_DIR" ]; then
        echo "Warning: Claude session directory not found: $CLAUDE_SESSION_DIR" >&2
        return 1
    fi
    return 0
}

claude_watcher_run() {
    local notify_callback="$1"
    local runtime_log="$2"
    local last_line_count=0

    append_log "$runtime_log" "claude_watcher started session_dir=$CLAUDE_SESSION_DIR history=$CLAUDE_HISTORY_FILE"

    if [ -f "$CLAUDE_HISTORY_FILE" ]; then
        last_line_count=$(wc -l < "$CLAUDE_HISTORY_FILE" 2>/dev/null || echo "0")
    fi

    while true; do
        scan_active_sessions "$CLAUDE_SESSION_DIR"

        last_line_count=$(check_history_updates "$CLAUDE_HISTORY_FILE" "$last_line_count")

        local current_time
        current_time=$(date +%s)

        for session_id in "${!tracked_sessions[@]}"; do
            local pid="${tracked_sessions[$session_id]}"

            if ! pid_is_alive "$pid"; then
                local message
                message=$(build_claude_message "session_complete" "$session_id" "${session_cwd[$session_id]:-}" "${session_last_display[$session_id]:-}")
                "$notify_callback" "claude" "session_complete" "$message" "$session_id" "$pid"

                unset "tracked_sessions[$session_id]"
                unset "session_last_input_time[$session_id]"
                unset "session_cwd[$session_id]"
                unset "session_last_display[$session_id]"

                append_log "$runtime_log" "claude session ended session=$session_id pid=$pid"
            fi
        done

        sleep "$CLAUDE_CHECK_INTERVAL"
    done
}
