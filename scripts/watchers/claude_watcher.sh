#!/usr/bin/env bash

set -euo pipefail

# Claude Code 监测模块

WATCHER_SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck disable=SC1091
source "$WATCHER_SCRIPT_DIR/../utils/log_utils.sh"
# shellcheck disable=SC1091
source "$WATCHER_SCRIPT_DIR/../utils/process_utils.sh"

CLAUDE_SESSION_DIR="${CLAUDE_SESSION_DIR:-$HOME/.claude/sessions}"
CLAUDE_PROJECTS_DIR="${CLAUDE_PROJECTS_DIR:-$HOME/.claude/projects}"
CLAUDE_HISTORY_FILE="${CLAUDE_HISTORY_FILE:-$HOME/.claude/history.jsonl}"
CLAUDE_CHECK_INTERVAL="${CLAUDE_CHECK_INTERVAL:-2}"
CLAUDE_COMPLETION_DELAY="${CLAUDE_COMPLETION_DELAY:-8}"

declare -A tracked_sessions=()
declare -A session_log_file=()
declare -A session_log_line_count=()
declare -A session_last_assistant_time=()
declare -A session_notified=()
declare -A session_cwd=()
declare -A session_last_display=()

extract_json_field() {
    local json="$1"
    local field="$2"

    # 尝试提取字符串值（带引号）
    local result
    result=$(printf '%s' "$json" | grep -o "\"$field\":\"[^\"]*\"" | sed "s/\"$field\":\"\([^\"]*\)\"/\1/" || true)

    if [ -n "$result" ]; then
        printf '%s' "$result"
        return 0
    fi

    # 尝试提取数字值（不带引号）
    result=$(printf '%s' "$json" | grep -o "\"$field\":[0-9]*" | sed "s/\"$field\":\([0-9]*\)/\1/" || true)

    if [ -n "$result" ]; then
        printf '%s' "$result"
        return 0
    fi

    return 1
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
        turn_complete)
            message="Claude Code 对话回合已完成。"
            ;;
        session_complete)
            message="Claude Code 会话已结束。"
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

                    # 查找会话日志文件
                    local log_file
                    if log_file=$(get_session_log_file "$session_id" "$cwd"); then
                        session_log_file["$session_id"]="$log_file"
                        local line_count
                        line_count=$(wc -l < "$log_file" 2>/dev/null || echo "0")
                        session_log_line_count["$session_id"]="$line_count"

                        append_log "$runtime_log" "claude session tracked session=$session_id pid=$pid log=$log_file"
                    else
                        append_log "$runtime_log" "claude session tracked but no log file session=$session_id pid=$pid cwd=$cwd"
                    fi
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
                session_last_display["$session_id"]="$display"
            fi
        done
    fi

    echo "$current_line_count"
}

get_session_log_file() {
    local session_id="$1"
    local cwd="$2"

    # 根据 cwd 构建项目目录路径
    if [ -z "$cwd" ]; then
        return 1
    fi

    # 将 cwd 转换为项目目录名（替换 / 为 -）
    local project_dir
    project_dir=$(echo "$cwd" | sed 's|^/||; s|/|-|g')

    local log_file="$CLAUDE_PROJECTS_DIR/-${project_dir}/${session_id}.jsonl"

    if [ -f "$log_file" ]; then
        echo "$log_file"
        return 0
    fi

    return 1
}

check_session_log_for_completion() {
    local session_id="$1"
    local log_file="${session_log_file[$session_id]:-}"

    if [ -z "$log_file" ] || [ ! -f "$log_file" ]; then
        return 1
    fi

    local current_line_count
    current_line_count=$(wc -l < "$log_file" 2>/dev/null || echo "0")

    local last_line_count="${session_log_line_count[$session_id]:-0}"

    if [ "$current_line_count" -le "$last_line_count" ]; then
        return 1
    fi

    # 检查新增的行
    local new_lines=$((current_line_count - last_line_count))
    local has_end_turn=0
    local has_assistant=0
    local last_assistant_timestamp=""

    if command -v jq >/dev/null 2>&1; then
        # 检查是否有 end_turn（立即通知）
        if tail -n "$new_lines" "$log_file" 2>/dev/null | \
           jq -e 'select(.type == "assistant" and .message.stop_reason == "end_turn")' >/dev/null 2>&1; then
            has_end_turn=1
        fi

        # 获取最后一条 assistant 消息的时间戳（用于延迟通知）
        last_assistant_timestamp=$(tail -n "$new_lines" "$log_file" 2>/dev/null | \
           jq -r 'select(.type == "assistant") | .timestamp' | tail -1)

        if [ -n "$last_assistant_timestamp" ]; then
            has_assistant=1
        fi
    else
        # 降级方案：使用 grep
        if tail -n "$new_lines" "$log_file" 2>/dev/null | \
           grep -q '"type":"assistant".*"stop_reason":"end_turn"'; then
            has_end_turn=1
        fi

        if tail -n "$new_lines" "$log_file" 2>/dev/null | grep -q '"type":"assistant"'; then
            has_assistant=1
        fi
    fi

    session_log_line_count["$session_id"]="$current_line_count"

    # 如果有 end_turn，立即返回成功
    if [ "$has_end_turn" -eq 1 ]; then
        return 0
    fi

    # 如果有 assistant 消息（tool_use），记录时间用于延迟通知
    if [ "$has_assistant" -eq 1 ]; then
        if [ -n "$last_assistant_timestamp" ]; then
            local unix_time
            unix_time=$(date -d "$last_assistant_timestamp" +%s 2>/dev/null || date +%s)
            session_last_assistant_time["$session_id"]="$unix_time"
        fi
        # 重置通知标记
        unset "session_notified[$session_id]"
    fi

    return 1
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

        for session_id in "${!tracked_sessions[@]}"; do
            local pid="${tracked_sessions[$session_id]}"

            if ! pid_is_alive "$pid"; then
                local message
                message=$(build_claude_message "session_complete" "$session_id" "${session_cwd[$session_id]:-}" "${session_last_display[$session_id]:-}")
                "$notify_callback" "claude" "session_complete" "$message" "$session_id" "$pid"

                unset "tracked_sessions[$session_id]"
                unset "session_log_file[$session_id]"
                unset "session_log_line_count[$session_id]"
                unset "session_last_assistant_time[$session_id]"
                unset "session_notified[$session_id]"
                unset "session_cwd[$session_id]"
                unset "session_last_display[$session_id]"

                append_log "$runtime_log" "claude session ended session=$session_id pid=$pid"
            else
                # 检查会话日志是否有 end_turn（立即通知）
                if check_session_log_for_completion "$session_id"; then
                    local message
                    message=$(build_claude_message "turn_complete" "$session_id" "${session_cwd[$session_id]:-}" "${session_last_display[$session_id]:-}")
                    "$notify_callback" "claude" "turn_complete" "$message" "$session_id" "$pid"

                    append_log "$runtime_log" "claude turn complete (end_turn) session=$session_id pid=$pid"
                else
                    # 检查是否应该发送延迟通知（tool_use 情况）
                    local last_assistant_time="${session_last_assistant_time[$session_id]:-0}"
                    if [ "$last_assistant_time" -gt 0 ] && [ -z "${session_notified[$session_id]:-}" ]; then
                        local current_time
                        current_time=$(date +%s)
                        local idle_time=$((current_time - last_assistant_time))

                        if [ "$idle_time" -ge "$CLAUDE_COMPLETION_DELAY" ]; then
                            local message
                            message=$(build_claude_message "turn_complete" "$session_id" "${session_cwd[$session_id]:-}" "${session_last_display[$session_id]:-}")
                            "$notify_callback" "claude" "turn_complete" "$message" "$session_id" "$pid"

                            session_notified["$session_id"]="1"
                            append_log "$runtime_log" "claude turn complete (tool_use timeout) session=$session_id pid=$pid idle_time=${idle_time}s"
                        fi
                    fi
                fi
            fi
        done

        sleep "$CLAUDE_CHECK_INTERVAL"
    done
}
