#!/bin/bash

set -euo pipefail

usage() {
    cat <<'EOF'
Usage:
  watch_codex_notify.sh run
  watch_codex_notify.sh start
  watch_codex_notify.sh stop
  watch_codex_notify.sh status
  watch_codex_notify.sh test-notify

Environment:
  FEISHU_WEBHOOK                  Required. Feishu custom bot webhook URL.
  FEISHU_KEYWORD                  Optional. Message prefix. Default: Codex提醒
EOF
}

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib_env.sh"
REPO_ROOT=$(repo_root_from_script_path "${BASH_SOURCE[0]}")
ENV_FILE="$REPO_ROOT/.env"
NOTIFY_SCRIPT="$SCRIPT_DIR/feishu_notify.sh"

load_repo_env_if_present "$ENV_FILE"

STATE_DIR="${TMPDIR:-/tmp}/codex-feishu-notify"
PID_FILE="$STATE_DIR/watch.pid"
LOCK_FILE="$STATE_DIR/watch.lock"
RUNTIME_LOG="$STATE_DIR/watch-runtime.log"
ERROR_LOG_FILE="$STATE_DIR/watch-errors.log"
WATCH_LOG_FILE="$HOME/.codex/log/codex-tui.log"

mkdir -p "$STATE_DIR"

append_log() {
    local log_file="$1"
    local message="$2"

    mkdir -p "$(dirname "$log_file")"
    printf '%s %s\n' "$(date '+%F %T')" "$message" >> "$log_file"
}

extract_with_sed() {
    local line="$1"
    local expr="$2"

    printf '%s\n' "$line" | sed -n "$expr"
}

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

send_notification() {
    local event_type="$1"
    local message="$2"
    local thread_id="$3"
    local turn_id="$4"
    local error_file

    error_file=$(mktemp "$STATE_DIR/notify-stderr.XXXXXX")
    if "$NOTIFY_SCRIPT" "$message" >/dev/null 2>"$error_file"; then
        append_log "$RUNTIME_LOG" "notification sent type=${event_type} thread=${thread_id:-unknown} turn=${turn_id:-unknown}"
    else
        append_log "$ERROR_LOG_FILE" "notify failed type=${event_type} thread=${thread_id:-unknown} turn=${turn_id:-unknown} error=$(tr '\n' ' ' < "$error_file")"
    fi
    rm -f "$error_file"
}

notify_turn_event() {
    local event_type="$1"
    local thread_id="$2"
    local turn_id="$3"
    local cwd="$4"
    local context="$5"
    local message

    message=$(build_turn_message "$event_type" "$cwd" "$context")
    send_notification "$event_type" "$message" "$thread_id" "$turn_id"
}

list_running_pids() {
    ps -ef | awk '/watch_codex_notify\.sh run/ && $0 !~ /awk/ {print $2}' | sort -u
}

first_running_pid() {
    list_running_pids | sed -n '1p'
}

read_pid_file() {
    sed -n '1p' "$PID_FILE" 2>/dev/null || true
}

pid_is_alive() {
    local pid="${1:-}"

    [ -n "$pid" ] || return 1
    kill -0 "$pid" 2>/dev/null
}

terminate_pid() {
    local pid="${1:-}"

    if ! pid_is_alive "$pid"; then
        return 0
    fi

    kill "$pid" >/dev/null 2>&1 || true
    sleep 1

    if pid_is_alive "$pid"; then
        kill -9 "$pid" >/dev/null 2>&1 || true
    fi
}

is_running() {
    local pid
    local fallback_pid

    pid=$(read_pid_file)
    if pid_is_alive "$pid"; then
        return 0
    fi

    rm -f "$PID_FILE"

    fallback_pid=$(first_running_pid)
    if pid_is_alive "$fallback_pid"; then
        printf '%s\n' "$fallback_pid" > "$PID_FILE"
        return 0
    fi

    return 1
}

run_watcher() {
    local existing_pid=""
    local last_tool_thread=""
    local last_tool_cwd=""
    local tool_cwd=""
    declare -A active_turn_by_thread=()
    declare -A turn_context_by_thread=()
    declare -A turn_cwd_by_thread=()
    declare -A turn_interrupted_by_thread=()

    if [ ! -x "$NOTIFY_SCRIPT" ]; then
        echo "Error: notify script not executable: $NOTIFY_SCRIPT" >&2
        exit 1
    fi

    if [ -z "${FEISHU_WEBHOOK:-}" ]; then
        echo "Error: FEISHU_WEBHOOK is required." >&2
        exit 1
    fi

    existing_pid=$(read_pid_file)
    if pid_is_alive "$existing_pid"; then
        echo "Error: watcher is already running (pid $existing_pid)." >&2
        exit 1
    fi

    exec 9>"$LOCK_FILE"
    if ! flock -n 9; then
        existing_pid=$(read_pid_file)
        echo "Error: watcher is already running${existing_pid:+ (pid $existing_pid)}." >&2
        exit 1
    fi

    printf '%s\n' "$$" > "$PID_FILE"
    append_log "$RUNTIME_LOG" "watcher started pid=$$ log=$WATCH_LOG_FILE"
    trap 'if [ -f "$PID_FILE" ] && [ "$(cat "$PID_FILE" 2>/dev/null)" = "$$" ]; then rm -f "$PID_FILE"; fi; rm -f "$LOCK_FILE"' EXIT

    while [ ! -f "$WATCH_LOG_FILE" ]; do
        append_log "$RUNTIME_LOG" "waiting for log file: $WATCH_LOG_FILE"
        sleep 2
    done

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
                notify_turn_event \
                    "turn_interrupted" \
                    "$thread_id" \
                    "$active_turn" \
                    "${turn_cwd_by_thread[$thread_id]:-}" \
                    "${turn_context_by_thread[$thread_id]:-}"
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
            notify_turn_event "turn_complete" "$thread_id" "$turn_id" "$turn_cwd" "$turn_context"
        fi

        unset "active_turn_by_thread[$thread_id]"
        unset "turn_context_by_thread[$thread_id]"
        unset "turn_cwd_by_thread[$thread_id]"
        unset "turn_interrupted_by_thread[$thread_id]"
    done < <(tail -n 0 -F "$WATCH_LOG_FILE" 2>/dev/null)
}

start_watcher() {
    local pid

    if is_running; then
        pid=$(read_pid_file)
        echo "Watcher is already running (pid ${pid:-unknown})."
        exit 0
    fi

    if command -v setsid >/dev/null 2>&1; then
        nohup setsid "$0" run </dev/null >>"$RUNTIME_LOG" 2>&1 &
    else
        nohup "$0" run </dev/null >>"$RUNTIME_LOG" 2>&1 &
    fi
    sleep 1

    if is_running; then
        pid=$(read_pid_file)
        echo "Watcher started (pid ${pid:-unknown})."
    else
        echo "Watcher failed to start. Check $RUNTIME_LOG." >&2
        exit 1
    fi
}

stop_watcher() {
    local pid
    local pids
    local stopped=0

    pid=$(read_pid_file)
    if pid_is_alive "$pid"; then
        terminate_pid "$pid"
        stopped=1
    fi

    pids=$(list_running_pids || true)
    if [ -n "$pids" ]; then
        printf '%s\n' "$pids" | while IFS= read -r pid; do
            [ -n "$pid" ] || continue
            terminate_pid "$pid"
        done
        stopped=1
    fi

    rm -f "$PID_FILE" "$LOCK_FILE"

    if [ "$stopped" -eq 1 ]; then
        echo "Watcher stopped."
    else
        echo "Watcher is not running."
    fi
}

status_watcher() {
    local pid

    if is_running; then
        pid=$(read_pid_file)
        echo "Watcher is running."
        echo "PID: ${pid:-unknown}"
        echo "Log: $WATCH_LOG_FILE"
        echo "Runtime log: $RUNTIME_LOG"
    else
        echo "Watcher is not running."
        echo "Log: $WATCH_LOG_FILE"
        echo "Runtime log: $RUNTIME_LOG"
    fi
}

test_notify() {
    if [ -z "${FEISHU_WEBHOOK:-}" ]; then
        echo "Error: FEISHU_WEBHOOK is required." >&2
        exit 1
    fi

    "$NOTIFY_SCRIPT" "Codex 飞书通知链路测试。watcher 当前监听日志：$WATCH_LOG_FILE"
}

COMMAND="${1:-run}"

case "$COMMAND" in
    run)
        run_watcher
        ;;
    start)
        start_watcher
        ;;
    stop)
        stop_watcher
        ;;
    status)
        status_watcher
        ;;
    test-notify)
        test_notify
        ;;
    *)
        usage
        exit 1
        ;;
esac
