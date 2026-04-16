#!/usr/bin/env bash

set -euo pipefail

# Codex 监测模块

WATCHER_SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck disable=SC1091
source "$WATCHER_SCRIPT_DIR/../utils/log_utils.sh"
# shellcheck disable=SC1091
source "$WATCHER_SCRIPT_DIR/../utils/process_utils.sh"

CODEX_LOG_FILE="${CODEX_LOG_FILE:-$HOME/.codex/log/codex-tui.log}"

extract_thread_id() {
    extract_with_sed "$1" 's/.*thread_id=\([^}: ]*\).*/\1/p'
}

extract_turn_id() {
    extract_with_sed "$1" 's/.*turn\.id=\([^} ]*\).*/\1/p'
}

summarize_tool_call() {
    local line="$1"
    local command

    if printf '%s\n' "$line" | grep -q 'ToolCall: exec_command '; then
        command=$(printf '%s\n' "$line" | sed -n 's/.*ToolCall: exec_command {"cmd":"\([^"]*\)".*/\1/p')
        command=${command//\\\"/\"}
        command=${command//\\\\/\\}
        printf 'exec_command %s' "${command:-unknown}"
        return
    fi

    if printf '%s\n' "$line" | grep -q 'ToolCall: apply_patch '; then
        printf 'apply_patch'
        return
    fi

    printf '%s\n' "$line" | sed 's/.*ToolCall: //'
}

extract_tool_cwd() {
    local line="$1"
    local cwd

    cwd=$(printf '%s\n' "$line" | sed -n 's/.*"workdir":"\([^"]*\)".*/\1/p')
    cwd=${cwd//\\\"/\"}
    cwd=${cwd//\\\\/\\}
    printf '%s' "$cwd"
}

project_name_from_cwd() {
    local cwd="$1"

    if [ -n "$cwd" ]; then
        basename "$cwd"
    else
        printf 'unknown'
    fi
}

build_turn_message() {
    local event_type="$1"
    local cwd="$2"
    local context="$3"
    local message

    case "$event_type" in
        turn_complete)
            message="Codex 当前这一问已经回答结束，可以继续下一轮提问。"
            ;;
        turn_interrupted)
            message="Codex 当前这一问已被中断。"
            ;;
        *)
            message="Codex 状态发生变化。"
            ;;
    esac

    if [ -n "$cwd" ]; then
        message="${message} 项目：$(project_name_from_cwd "$cwd")。cwd：${cwd}。"
    fi
    if [ -n "$context" ]; then
        message="${message} 最近命令：${context}。"
    fi

    printf '%s' "$message"
}

codex_watcher_init() {
    if [ ! -f "$CODEX_LOG_FILE" ]; then
        echo "Warning: Codex log file not found: $CODEX_LOG_FILE" >&2
        return 1
    fi
    return 0
}

codex_watcher_run() {
    local notify_callback="$1"
    local runtime_log="$2"
    local last_tool_thread=""
    local last_tool_cwd=""
    local tool_cwd=""
    declare -A active_turn_by_thread=()
    declare -A turn_context_by_thread=()
    declare -A turn_cwd_by_thread=()
    declare -A turn_interrupted_by_thread=()

    append_log "$runtime_log" "codex_watcher started log=$CODEX_LOG_FILE"

    while IFS= read -r line; do
        local thread_id turn_id active_turn turn_context turn_cwd

        if printf '%s\n' "$line" | grep -q 'codex.op="user_input"' && printf '%s\n' "$line" | grep -q 'codex_core::tasks: new'; then
            thread_id=$(extract_thread_id "$line")
            turn_id=$(extract_turn_id "$line")

            if [ -n "$thread_id" ] && [ -n "$turn_id" ]; then
                active_turn_by_thread["$thread_id"]="$turn_id"
                turn_interrupted_by_thread["$thread_id"]=0
                unset "turn_context_by_thread[$thread_id]"
                unset "turn_cwd_by_thread[$thread_id]"
            fi
        fi

        if printf '%s\n' "$line" | grep -q 'ToolCall:'; then
            last_tool_thread=$(extract_thread_id "$line")
            tool_cwd=$(extract_tool_cwd "$line")
            if [ -n "$tool_cwd" ]; then
                last_tool_cwd="$tool_cwd"
            fi

            if [ -n "$last_tool_thread" ] && [ -n "${active_turn_by_thread[$last_tool_thread]:-}" ]; then
                turn_context_by_thread["$last_tool_thread"]=$(summarize_tool_call "$line")
                if [ -n "$last_tool_cwd" ]; then
                    turn_cwd_by_thread["$last_tool_thread"]="$last_tool_cwd"
                fi
            fi
        fi

        if printf '%s\n' "$line" | grep -q 'codex.op="interrupt"' && printf '%s\n' "$line" | grep -q 'codex_core::codex: new'; then
            thread_id=$(extract_thread_id "$line")
            active_turn="${active_turn_by_thread[$thread_id]:-}"

            if [ -n "$thread_id" ] && [ -n "$active_turn" ]; then
                turn_interrupted_by_thread["$thread_id"]=1
                local message
                message=$(build_turn_message "turn_interrupted" "${turn_cwd_by_thread[$thread_id]:-}" "${turn_context_by_thread[$thread_id]:-}")
                "$notify_callback" "codex" "turn_interrupted" "$message" "$thread_id" "$active_turn"
            fi
        fi

        if ! printf '%s\n' "$line" | grep -q 'codex.op="user_input"'; then
            continue
        fi

        if ! printf '%s\n' "$line" | grep -q 'codex_core::tasks: close'; then
            continue
        fi

        thread_id=$(extract_thread_id "$line")
        turn_id=$(extract_turn_id "$line")

        if [ -z "$thread_id" ] || [ -z "$turn_id" ]; then
            continue
        fi

        active_turn="${active_turn_by_thread[$thread_id]:-}"

        if [ "$turn_id" != "$active_turn" ]; then
            continue
        fi

        turn_context="${turn_context_by_thread[$thread_id]:-}"
        turn_cwd="${turn_cwd_by_thread[$thread_id]:-}"

        if [ "${turn_interrupted_by_thread[$thread_id]:-0}" != "1" ]; then
            local message
            message=$(build_turn_message "turn_complete" "$turn_cwd" "$turn_context")
            "$notify_callback" "codex" "turn_complete" "$message" "$thread_id" "$turn_id"
        fi

        unset "active_turn_by_thread[$thread_id]"
        unset "turn_context_by_thread[$thread_id]"
        unset "turn_cwd_by_thread[$thread_id]"
        unset "turn_interrupted_by_thread[$thread_id]"
    done < <(tail -n 0 -F "$CODEX_LOG_FILE" 2>/dev/null)
}
