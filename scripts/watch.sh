#!/usr/bin/env bash

set -euo pipefail

usage() {
    cat <<'EOF'
Usage:
  ./bin/ai-assistant-notify run [codex]
  ./bin/ai-assistant-notify start [codex]
  ./bin/ai-assistant-notify stop [codex]
  ./bin/ai-assistant-notify status [codex]
  ./bin/ai-assistant-notify test-notify

Arguments:
  watcher_type    Optional. Only `codex` is supported. Default: codex

Environment:
  CODEX_FEISHU_WEBHOOK            Feishu webhook URL for Codex notifications.
  CODEX_FEISHU_KEYWORD            Optional. Keyword for Codex. Default: Codex提醒

Note:
  - 配置文件固定为仓库根目录 .env
  - 当前仅支持 Codex 监测
EOF
}

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib_env.sh"
REPO_ROOT=$(repo_root_from_script_path "${BASH_SOURCE[0]}")
ENV_FILE="$REPO_ROOT/.env"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib_notify.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/utils/process_utils.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/utils/log_utils.sh"

STATE_DIR="${TMPDIR:-/tmp}/ai-assistant-notify"
RUNTIME_LOG="$STATE_DIR/watch-runtime.log"
ERROR_LOG_FILE="$STATE_DIR/watch-errors.log"

mkdir -p "$STATE_DIR"

load_config() {
    load_repo_env "$ENV_FILE"
}

is_watcher_configured() {
    local watcher="$1"

    case "$watcher" in
        codex)
            [ -n "${CODEX_FEISHU_WEBHOOK:-}" ] && [ "${CODEX_FEISHU_WEBHOOK:-}" != "https://open.feishu.cn/open-apis/bot/v2/hook/replace-with-your-codex-webhook" ]
            ;;
        *)
            return 1
            ;;
    esac
}

get_configured_watchers() {
    if is_watcher_configured "codex"; then
        echo "codex"
        return
    fi

    echo ""
}

notify_callback() {
    local watcher_type="$1"
    local event_type="$2"
    local message="$3"
    local id1="${4:-unknown}"
    local id2="${5:-unknown}"
    local error_file

    error_file=$(mktemp "$STATE_DIR/notify-stderr.XXXXXX")
    if send_feishu_notification "$watcher_type" "$message" >/dev/null 2>"$error_file"; then
        append_log "$RUNTIME_LOG" "notification sent watcher=${watcher_type} type=${event_type} id1=${id1} id2=${id2}"
    else
        append_log "$ERROR_LOG_FILE" "notify failed watcher=${watcher_type} type=${event_type} id1=${id1} id2=${id2} error=$(tr '\n' ' ' < "$error_file")"
    fi
    rm -f "$error_file"
}

start_watcher_process() {
    local watcher_type="$1"
    local watcher_script="$SCRIPT_DIR/watchers/${watcher_type}_watcher.sh"
    local pid_file="$STATE_DIR/${watcher_type}_watcher.pid"
    local lock_file="$STATE_DIR/${watcher_type}_watcher.lock"

    if ! is_watcher_configured "$watcher_type"; then
        echo "Warning: ${watcher_type} webhook not configured, skipping." >&2
        return 1
    fi

    if [ ! -f "$watcher_script" ]; then
        echo "Error: watcher script not found: $watcher_script" >&2
        return 1
    fi

    # shellcheck disable=SC1090
    source "$watcher_script"

    if ! "${watcher_type}_watcher_init"; then
        echo "Warning: ${watcher_type} watcher init failed, skipping." >&2
        return 1
    fi

    if is_watcher_running "$pid_file" "${watcher_type}_watcher.sh run"; then
        local pid
        pid=$(read_pid_file "$pid_file")
        echo "${watcher_type} watcher is already running (pid ${pid:-unknown})."
        return 0
    fi

    exec 9>"$lock_file"
    if ! flock -n 9; then
        echo "Error: ${watcher_type} watcher is already starting." >&2
        return 1
    fi

    # 导出必要的环境变量和函数
    export STATE_DIR RUNTIME_LOG ERROR_LOG_FILE
    export CODEX_FEISHU_WEBHOOK CODEX_FEISHU_KEYWORD
    export CODEX_LOG_FILE CODEX_SESSIONS_DIR
    export -f notify_callback send_feishu_notification json_escape append_log

    if command -v setsid >/dev/null 2>&1; then
        nohup setsid bash -c "
            # 重新加载工具函数
            source \"$SCRIPT_DIR/utils/log_utils.sh\"
            source \"$SCRIPT_DIR/utils/process_utils.sh\"
            source \"$SCRIPT_DIR/lib_notify.sh\"

            printf '%s\n' \"\$\$\" > \"$pid_file\"
            append_log \"$RUNTIME_LOG\" \"${watcher_type}_watcher started pid=\$\$\"
            trap 'if [ -f \"$pid_file\" ] && [ \"\$(cat \"$pid_file\" 2>/dev/null)\" = \"\$\$\" ]; then rm -f \"$pid_file\"; fi; rm -f \"$lock_file\"' EXIT

            source \"$watcher_script\"
            ${watcher_type}_watcher_run notify_callback \"$RUNTIME_LOG\"
        " </dev/null >>"$RUNTIME_LOG" 2>&1 &
    else
        nohup bash -c "
            # 重新加载工具函数
            source \"$SCRIPT_DIR/utils/log_utils.sh\"
            source \"$SCRIPT_DIR/utils/process_utils.sh\"
            source \"$SCRIPT_DIR/lib_notify.sh\"

            printf '%s\n' \"\$\$\" > \"$pid_file\"
            append_log \"$RUNTIME_LOG\" \"${watcher_type}_watcher started pid=\$\$\"
            trap 'if [ -f \"$pid_file\" ] && [ \"\$(cat \"$pid_file\" 2>/dev/null)\" = \"\$\$\" ]; then rm -f \"$pid_file\"; fi; rm -f \"$lock_file\"' EXIT

            source \"$watcher_script\"
            ${watcher_type}_watcher_run notify_callback \"$RUNTIME_LOG\"
        " </dev/null >>"$RUNTIME_LOG" 2>&1 &
    fi

    sleep 1

    if is_watcher_running "$pid_file" "${watcher_type}_watcher.sh run"; then
        local pid
        pid=$(read_pid_file "$pid_file")
        echo "${watcher_type} watcher started (pid ${pid:-unknown})."
        return 0
    else
        echo "${watcher_type} watcher failed to start. Check $RUNTIME_LOG." >&2
        return 1
    fi
}

stop_watcher_process() {
    local watcher_type="$1"
    local pid_file="$STATE_DIR/${watcher_type}_watcher.pid"
    local lock_file="$STATE_DIR/${watcher_type}_watcher.lock"
    local pid
    local pids
    local stopped=0

    pid=$(read_pid_file "$pid_file")
    if pid_is_alive "$pid"; then
        terminate_pid "$pid"
        stopped=1
    fi

    pids=$(list_running_pids "${watcher_type}_watcher.sh run" || true)
    if [ -n "$pids" ]; then
        printf '%s\n' "$pids" | while IFS= read -r pid; do
            [ -n "$pid" ] || continue
            terminate_pid "$pid"
        done
        stopped=1
    fi

    rm -f "$pid_file" "$lock_file"

    if [ "$stopped" -eq 1 ]; then
        echo "${watcher_type} watcher stopped."
    else
        echo "${watcher_type} watcher is not running."
    fi
}

status_watcher_process() {
    local watcher_type="$1"
    local pid_file="$STATE_DIR/${watcher_type}_watcher.pid"
    local watcher_script="$SCRIPT_DIR/watchers/${watcher_type}_watcher.sh"
    local installed_version=""
    local latest_version=""
    local compatibility_status=""

    if is_watcher_running "$pid_file" "${watcher_type}_watcher.sh run"; then
        local pid
        pid=$(read_pid_file "$pid_file")
        echo "${watcher_type} watcher is running (pid ${pid:-unknown})."
    else
        echo "${watcher_type} watcher is not running."
    fi

    if [ -f "$watcher_script" ]; then
        # shellcheck disable=SC1090
        source "$watcher_script"
        installed_version=$(codex_installed_version_detect 2>/dev/null || true)
        latest_version=$(codex_latest_version_detect 2>/dev/null || true)
        compatibility_status=$(codex_compatibility_status "$installed_version")

        if codex_watcher_init >/dev/null 2>&1; then
            echo "Codex source: ${CODEX_WATCH_SOURCE:-unknown}"
        fi
        echo "Codex installed: ${installed_version:-unknown}"
        echo "Codex verified: ${CODEX_WATCHER_VERIFIED_MAX_VERSION:-unknown}"
        echo "Codex latest: ${latest_version:-unknown}"
        echo "Compatibility: ${compatibility_status:-unknown}"
    fi
}

normalize_watcher_type() {
    local watcher_type="${1:-codex}"

    case "$watcher_type" in
        ""|all|codex)
            printf 'codex\n'
            ;;
        *)
            echo "Error: unsupported watcher type: $watcher_type" >&2
            return 1
            ;;
    esac
}

run_command() {
    local watcher_type
    watcher_type=$(normalize_watcher_type "${1:-codex}")

    if ! is_watcher_configured "codex"; then
        echo "Error: CODEX_FEISHU_WEBHOOK is not configured in .env" >&2
        exit 1
    fi

    start_watcher_process "$watcher_type"

    wait
}

start_command() {
    local watcher_type
    watcher_type=$(normalize_watcher_type "${1:-codex}")

    if ! is_watcher_configured "codex"; then
        echo "Error: CODEX_FEISHU_WEBHOOK is not configured in .env" >&2
        exit 1
    fi

    start_watcher_process "$watcher_type"
}

stop_command() {
    local watcher_type
    watcher_type=$(normalize_watcher_type "${1:-codex}")
    stop_watcher_process "$watcher_type"
}

status_command() {
    local watcher_type
    watcher_type=$(normalize_watcher_type "${1:-codex}")

    echo "Runtime log: $RUNTIME_LOG"
    echo "Error log: $ERROR_LOG_FILE"
    if [ -n "${AI_ASSISTANT_NOTIFY_ENV_FILE:-}" ]; then
        echo "Config files: $AI_ASSISTANT_NOTIFY_ENV_FILE"
    else
        echo "Config files: not loaded"
    fi
    echo ""

    if is_watcher_configured "$watcher_type"; then
        status_watcher_process "$watcher_type"
    else
        echo "${watcher_type} watcher: not configured"
    fi
}

test_notify() {
    if ! is_watcher_configured "codex"; then
        echo "Error: CODEX_FEISHU_WEBHOOK is not configured in .env" >&2
        exit 1
    fi

    echo "Testing codex notification..."
    if send_feishu_notification "codex" "Codex 飞书通知链路测试。"; then
        echo "✓ codex notification sent successfully."
    else
        echo "✗ codex notification failed." >&2
        exit 1
    fi
}

COMMAND="${1:-}"
WATCHER_TYPE="${2:-codex}"

case "$COMMAND" in
    run)
        load_config
        run_command "$WATCHER_TYPE"
        ;;
    start)
        load_config
        start_command "$WATCHER_TYPE"
        ;;
    stop)
        stop_command "$WATCHER_TYPE"
        ;;
    status)
        load_config
        status_command "$WATCHER_TYPE"
        ;;
    test-notify)
        load_config
        test_notify
        ;;
    *)
        usage
        exit 1
        ;;
esac
