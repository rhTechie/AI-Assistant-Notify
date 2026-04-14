#!/bin/bash

set -euo pipefail

usage() {
    cat <<'EOF'
Usage:
  watch_codex_approval.sh run
  watch_codex_approval.sh start
  watch_codex_approval.sh stop
  watch_codex_approval.sh status
  watch_codex_approval.sh test-notify

Environment:
  FEISHU_WEBHOOK                  Required. Feishu custom bot webhook URL.
  FEISHU_KEYWORD                  Optional. Message prefix. Default: Codex提醒
  CODEX_TUI_LOG_PATH              Optional. Default: $HOME/.codex/log/codex-tui.log
  CODEX_APPROVAL_EXTRA_EVENTS     Optional. Extra Codex event names to watch, comma-separated.
  CODEX_APPROVAL_NOTIFY_COOLDOWN  Optional seconds. Default: 30
  CODEX_APPROVAL_CONTEXT_WINDOW   Optional seconds. Default: 120
  CODEX_APPROVAL_WATCH_DEBUG      Optional. 1 enables debug log.
  CODEX_APPROVAL_WATCH_DEBUG_LOG  Optional. Default: /tmp/codex-feishu-notify/watch-debug.log
  CODEX_APPROVAL_WATCH_ERROR_LOG  Optional. Default: /tmp/codex-feishu-notify/watch-errors.log
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
RULES_FILE="${CODEX_RULES_FILE:-$HOME/.codex/rules/default.rules}"
RUNTIME_LOG="$STATE_DIR/watch-runtime.log"
ERROR_LOG_FILE="${CODEX_APPROVAL_WATCH_ERROR_LOG:-$STATE_DIR/watch-errors.log}"
DEBUG_LOG_FILE="${CODEX_APPROVAL_WATCH_DEBUG_LOG:-$STATE_DIR/watch-debug.log}"
WATCH_LOG_FILE="${CODEX_TUI_LOG_PATH:-$HOME/.codex/log/codex-tui.log}"
COOLDOWN="${CODEX_APPROVAL_NOTIFY_COOLDOWN:-30}"
CONTEXT_WINDOW="${CODEX_APPROVAL_CONTEXT_WINDOW:-120}"
APPROVAL_EVENTS_DEFAULT="exec_approval|patch_approval|request_permissions|request_user_input"
APPROVAL_EXTRA_EVENTS_RAW="${CODEX_APPROVAL_EXTRA_EVENTS:-}"

mkdir -p "$STATE_DIR"

is_truthy() {
    case "${1:-0}" in
        1 | true | TRUE | yes | YES | on | ON)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

append_log() {
    local log_file="$1"
    local message="$2"

    mkdir -p "$(dirname "$log_file")"
    printf '%s %s\n' "$(date '+%F %T')" "$message" >> "$log_file"
}

watch_debug() {
    if is_truthy "${CODEX_APPROVAL_WATCH_DEBUG:-0}"; then
        append_log "$DEBUG_LOG_FILE" "$1"
    fi
}

build_approval_patterns() {
    local events_regex="$APPROVAL_EVENTS_DEFAULT"
    local extra_events_regex=""

    if [ -n "$APPROVAL_EXTRA_EVENTS_RAW" ]; then
        extra_events_regex=$(printf '%s\n' "$APPROVAL_EXTRA_EVENTS_RAW" | tr ', ' '\n' | sed '/^$/d' | sed 's/[^A-Za-z0-9_]//g' | paste -sd'|' -)
        if [ -n "$extra_events_regex" ]; then
            events_regex="${events_regex}|${extra_events_regex}"
        fi
    fi

    printf 'op\\.dispatch\\.(%s)' "$events_regex"
}

extract_with_sed() {
    local line="$1"
    local expr="$2"

    printf '%s\n' "$line" | sed -n "$expr"
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

extract_tool_justification() {
    local line="$1"
    local justification

    justification=$(printf '%s\n' "$line" | sed -n 's/.*"justification":"\([^"]*\)".*/\1/p')
    justification=${justification//\\\"/\"}
    justification=${justification//\\\\/\\}
    printf '%s' "$justification"
}

extract_tool_prefix_rule() {
    local line="$1"
    local prefix_rule

    prefix_rule=$(printf '%s\n' "$line" | sed -n 's/.*"prefix_rule":\[\([^]]*\)\].*/\1/p')
    printf '%s' "$prefix_rule"
}

prefix_rule_is_approved() {
    local prefix_rule_raw="$1"
    local prefix_rule_formatted=""

    if [ -z "$prefix_rule_raw" ] || [ ! -f "$RULES_FILE" ]; then
        return 1
    fi

    prefix_rule_formatted=$(printf '%s\n' "$prefix_rule_raw" | sed 's/","/", "/g')
    grep -Fq "prefix_rule(pattern=[${prefix_rule_formatted}], decision=\"allow\")" "$RULES_FILE"
}

toolcall_requires_early_notification() {
    local line="$1"
    local prefix_rule_raw=""

    if printf '%s\n' "$line" | grep -q 'ToolCall: exec_command ' && \
        printf '%s\n' "$line" | grep -q '"sandbox_permissions":"require_escalated"'; then
        prefix_rule_raw=$(extract_tool_prefix_rule "$line")
        if ! prefix_rule_is_approved "$prefix_rule_raw"; then
            printf 'exec_approval'
            return 0
        fi
    fi

    if printf '%s\n' "$line" | grep -q 'ToolCall: apply_patch '; then
        printf 'patch_approval'
        return 0
    fi

    return 1
}

approval_label() {
    case "$1" in
        exec_approval)
            printf '命令执行授权'
            ;;
        patch_approval)
            printf '文件修改授权'
            ;;
        request_permissions)
            printf '权限请求'
            ;;
        request_user_input)
            printf '用户选项请求'
            ;;
        *)
            printf '授权/选项请求'
            ;;
    esac
}

list_running_pids() {
    ps -ef | awk '/watch_codex_approval\.sh run/ && $0 !~ /awk/ {print $2}' | sort -u
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

should_skip_recent_notification() {
    local dedup_file="$1"
    local now="$2"
    local last_ts=0

    if [ -f "$dedup_file" ]; then
        last_ts=$(sed -n '1p' "$dedup_file" 2>/dev/null || printf '0')
    fi

    if [ $((now - last_ts)) -lt "$COOLDOWN" ]; then
        return 0
    fi

    return 1
}

mark_notification_sent() {
    local dedup_file="$1"
    local now="$2"

    printf '%s\n' "$now" > "$dedup_file"
}

APPROVAL_PATTERNS=$(build_approval_patterns)

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
    local last_tool_line=""
    local last_tool_thread=""
    local last_tool_ts=0
    local last_tool_cwd=""
    local last_tool_early_notify_type=""
    local existing_pid=""

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
        local now thread_id approval_type approval_text submission_id dedup_key dedup_file context context_cwd message error_file
        local tool_summary tool_justification tool_dedup_key tool_dedup_file tool_cwd
        local tool_approval_type tool_approval_text

        now=$(date +%s)

        if printf '%s\n' "$line" | grep -q 'ToolCall:'; then
            last_tool_line="$line"
            last_tool_thread=$(extract_with_sed "$line" 's/.*thread_id=\([^}: ]*\).*/\1/p')
            last_tool_ts="$now"
            tool_cwd=$(extract_tool_cwd "$line")
            if [ -n "$tool_cwd" ]; then
                last_tool_cwd="$tool_cwd"
            fi
            last_tool_early_notify_type=""
            watch_debug "toolcall thread=${last_tool_thread:-unknown} cwd=${last_tool_cwd:-unknown} summary=$(summarize_tool_call "$line")"

            if tool_approval_type=$(toolcall_requires_early_notification "$line"); then
                last_tool_early_notify_type="$tool_approval_type"
                tool_approval_text=$(approval_label "$tool_approval_type")
                tool_summary=$(summarize_tool_call "$line")
                tool_justification=$(extract_tool_justification "$line")
                tool_dedup_key=$(printf '%s\n' "${last_tool_thread}|${tool_approval_type}|${tool_summary}" | cksum | sed -n 's/^\([0-9][0-9]*\).*/\1/p')
                tool_dedup_file="$STATE_DIR/toolcall-${tool_dedup_key}.ts"

                if should_skip_recent_notification "$tool_dedup_file" "$now"; then
                    watch_debug "skip toolcall cooldown type=${tool_approval_type:-unknown} thread=${last_tool_thread:-unknown} summary=${tool_summary:-unknown}"
                else
                    message="Codex 出现需要你处理的${tool_approval_text:-授权/选项请求}。"
                    if [ -n "$last_tool_cwd" ]; then
                        message="${message} cwd：${last_tool_cwd}。"
                    fi
                    if [ -n "$tool_summary" ]; then
                        message="${message} 最近命令：${tool_summary}。"
                    fi
                    if [ -n "$tool_justification" ]; then
                        message="${message} 原因：${tool_justification}。"
                    fi

                    error_file=$(mktemp "$STATE_DIR/notify-stderr.XXXXXX")
                    if "$NOTIFY_SCRIPT" "$message" >/dev/null 2>"$error_file"; then
                        mark_notification_sent "$tool_dedup_file" "$now"
                        append_log "$RUNTIME_LOG" "notification sent type=toolcall_${tool_approval_type:-unknown} thread=${last_tool_thread:-unknown}"
                        watch_debug "notify sent type=toolcall_${tool_approval_type:-unknown} thread=${last_tool_thread:-unknown} cwd=${last_tool_cwd:-unknown} context=${tool_summary:-none}"
                    else
                        append_log "$ERROR_LOG_FILE" "notify failed type=toolcall_${tool_approval_type:-unknown} thread=${last_tool_thread:-unknown} error=$(tr '\n' ' ' < "$error_file")"
                        watch_debug "notify failed type=toolcall_${tool_approval_type:-unknown} thread=${last_tool_thread:-unknown} cwd=${last_tool_cwd:-unknown}"
                    fi
                    rm -f "$error_file"
                fi
            fi
        fi

        if ! printf '%s\n' "$line" | grep -Eq "$APPROVAL_PATTERNS"; then
            continue
        fi

        if ! printf '%s\n' "$line" | grep -q 'codex_core::codex: new'; then
            continue
        fi

        approval_type=$(extract_with_sed "$line" 's/.*codex\.op="\([^"]*\)".*/\1/p')
        approval_text=$(approval_label "$approval_type")
        submission_id=$(extract_with_sed "$line" 's/.*submission\.id="\([^"]*\)".*/\1/p')
        thread_id=$(extract_with_sed "$line" 's/.*thread_id=\([^}: ]*\).*/\1/p')
        dedup_key="${submission_id:-$(printf '%s\n' "$line" | cksum | sed -n 's/^\([0-9][0-9]*\).*/\1/p')}"
        dedup_file="$STATE_DIR/approval-${dedup_key}.ts"

        if should_skip_recent_notification "$dedup_file" "$now"; then
            watch_debug "skip cooldown type=${approval_type:-unknown} submission=${submission_id:-unknown}"
            continue
        fi

        context=""
        context_cwd=""
        if [ -n "$last_tool_line" ] && [ -n "$thread_id" ] && [ "$thread_id" = "$last_tool_thread" ] && [ $((now - last_tool_ts)) -le "$CONTEXT_WINDOW" ]; then
            context=$(summarize_tool_call "$last_tool_line")
            context_cwd="$last_tool_cwd"
        fi

        if [ -n "$last_tool_early_notify_type" ] && [ "${approval_type:-}" = "$last_tool_early_notify_type" ] && \
            [ -n "$thread_id" ] && [ "$thread_id" = "$last_tool_thread" ] && [ $((now - last_tool_ts)) -le "$CONTEXT_WINDOW" ]; then
            watch_debug "skip ${approval_type:-unknown} because toolcall notification already covered thread=${thread_id:-unknown}"
            mark_notification_sent "$dedup_file" "$now"
            continue
        fi

        message="Codex 出现需要你处理的${approval_text:-授权/选项请求}。type：${approval_type:-unknown}。"
        if [ -n "$context_cwd" ]; then
            message="${message} cwd：${context_cwd}。"
        fi
        if [ -n "$context" ]; then
            message="${message} 最近命令：${context}。"
        fi

        error_file=$(mktemp "$STATE_DIR/notify-stderr.XXXXXX")
        if "$NOTIFY_SCRIPT" "$message" >/dev/null 2>"$error_file"; then
            mark_notification_sent "$dedup_file" "$now"
            append_log "$RUNTIME_LOG" "notification sent type=${approval_type:-unknown} submission=${submission_id:-unknown}"
            watch_debug "notify sent type=${approval_type:-unknown} thread=${thread_id:-unknown} cwd=${context_cwd:-unknown} context=${context:-none}"
        else
            append_log "$ERROR_LOG_FILE" "notify failed type=${approval_type:-unknown} submission=${submission_id:-unknown} error=$(tr '\n' ' ' < "$error_file")"
            watch_debug "notify failed type=${approval_type:-unknown} thread=${thread_id:-unknown} cwd=${context_cwd:-unknown}"
        fi
        rm -f "$error_file"
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
