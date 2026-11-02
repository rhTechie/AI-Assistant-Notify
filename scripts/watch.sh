#!/usr/bin/env bash

set -euo pipefail

usage() {
    cat <<'EOF'
Usage:
  ./bin/ai-assistant-notify run [codex|claude|all]
  ./bin/ai-assistant-notify start [codex|claude|all]
  ./bin/ai-assistant-notify stop [codex|claude|all]
  ./bin/ai-assistant-notify status [codex|claude|all]
  ./bin/ai-assistant-notify test-notify

Arguments:
  watcher_type    Optional. `codex`, `claude` or `all`. Default: all

Environment:
  CODEX_FEISHU_WEBHOOK            Feishu webhook URL for Codex notifications.
  CODEX_FEISHU_KEYWORD            Optional. Keyword for Codex. Default: Codex提醒
  CLAUDE_FEISHU_WEBHOOK           Feishu webhook URL for Claude notifications.
  CLAUDE_FEISHU_KEYWORD           Optional. Keyword for Claude. Default: Claude提醒
  FEISHU_NOTIFY_CONNECT_TIMEOUT_SECONDS  Optional. Connect timeout. Default: 5
  FEISHU_NOTIFY_MAX_TIME_SECONDS         Optional. Total request timeout. Default: 15
  FEISHU_NOTIFY_MAX_ATTEMPTS             Optional. Maximum attempts. Default: 3
  FEISHU_NOTIFY_RETRY_BACKOFF_SECONDS    Optional. Linear retry backoff. Default: 1

Note:
  - 配置文件固定为仓库根目录 .env
  - `all` processes every configured watcher (codex and claude)
  - only watchers with a configured webhook are started by `start`/`run`
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

umask 077

STATE_DIR="${TMPDIR:-/tmp}/ai-assistant-notify"
RUNTIME_LOG="$STATE_DIR/watch-runtime.log"
ERROR_LOG_FILE="$STATE_DIR/watch-errors.log"

secure_state_dir "$STATE_DIR"
secure_state_file "$RUNTIME_LOG"
secure_state_file "$ERROR_LOG_FILE"
secure_state_file "$STATE_DIR/codex_watcher.pid"
secure_state_file "$STATE_DIR/codex_watcher.lock"
secure_state_file "$STATE_DIR/claude_watcher.pid"
secure_state_file "$STATE_DIR/claude_watcher.lock"

watcher_process_marker() {
    local watcher_type="$1"

    printf 'ai-assistant-notify:%s:%s:%s\n' "$watcher_type" "$REPO_ROOT" "$STATE_DIR"
}

legacy_watcher_command() {
    local watcher_type="$1"
    local watcher_script="$SCRIPT_DIR/watchers/${watcher_type}_watcher.sh"
    local pid_file="$STATE_DIR/${watcher_type}_watcher.pid"
    local lock_file="$STATE_DIR/${watcher_type}_watcher.lock"

    printf '%s' "
            # 重新加载工具函数
            source \"$SCRIPT_DIR/utils/log_utils.sh\"
            source \"$SCRIPT_DIR/utils/process_utils.sh\"
            source \"$SCRIPT_DIR/lib_notify.sh\"

            printf '%s\\n' \"\$\$\" > \"$pid_file\"
            append_log \"$RUNTIME_LOG\" \"${watcher_type}_watcher started pid=\$\$\"
            trap 'if [ -f \"$pid_file\" ] && [ \"\$(cat \"$pid_file\" 2>/dev/null)\" = \"\$\$\" ]; then rm -f \"$pid_file\"; fi; rm -f \"$lock_file\"' EXIT

            source \"$watcher_script\"
            ${watcher_type}_watcher_run notify_callback \"$RUNTIME_LOG\"
        "
}

load_config() {
    load_repo_env "$ENV_FILE"
}

watcher_webhook_variable() {
    local watcher="$1"

    case "$watcher" in
        codex)
            printf 'CODEX_FEISHU_WEBHOOK\n'
            ;;
        claude)
            printf 'CLAUDE_FEISHU_WEBHOOK\n'
            ;;
        *)
            return 1
            ;;
    esac
}

is_watcher_configured() {
    local watcher="$1"

    case "$watcher" in
        codex)
            [ -n "${CODEX_FEISHU_WEBHOOK:-}" ] && [ "${CODEX_FEISHU_WEBHOOK:-}" != "https://open.feishu.cn/open-apis/bot/v2/hook/replace-with-your-codex-webhook" ]
            ;;
        claude)
            [ -n "${CLAUDE_FEISHU_WEBHOOK:-}" ] && [ "${CLAUDE_FEISHU_WEBHOOK:-}" != "https://open.feishu.cn/open-apis/bot/v2/hook/replace-with-your-claude-webhook" ]
            ;;
        *)
            return 1
            ;;
    esac
}

get_configured_watchers() {
    local watcher

    for watcher in codex claude; do
        if is_watcher_configured "$watcher"; then
            printf '%s\n' "$watcher"
        fi
    done
}

collect_watcher_targets() {
    local watcher_type="$1"
    local watcher

    SELECTED_WATCHERS=()

    if [ "$watcher_type" = "all" ]; then
        while IFS= read -r watcher; do
            [ -n "$watcher" ] || continue
            SELECTED_WATCHERS+=("$watcher")
        done < <(get_configured_watchers)

        if [ "${#SELECTED_WATCHERS[@]}" -eq 0 ]; then
            echo "Error: no watcher is configured in .env" >&2
            return 1
        fi
        return 0
    fi

    if ! is_watcher_configured "$watcher_type"; then
        echo "Error: $(watcher_webhook_variable "$watcher_type") is not configured in .env" >&2
        return 1
    fi

    SELECTED_WATCHERS=("$watcher_type")
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
    local marker
    local legacy_command
    local child_command

    marker=$(watcher_process_marker "$watcher_type")
    legacy_command=$(legacy_watcher_command "$watcher_type")

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

    if is_watcher_running "$pid_file" "$marker" "$legacy_command"; then
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
    export CLAUDE_FEISHU_WEBHOOK CLAUDE_FEISHU_KEYWORD
    export CLAUDE_PROJECTS_DIR CLAUDE_WATCH_INTERVAL
    export -f notify_callback send_feishu_notification json_escape append_log

    child_command="
            # 重新加载工具函数
            source \"$SCRIPT_DIR/utils/log_utils.sh\"
            source \"$SCRIPT_DIR/utils/process_utils.sh\"
            source \"$SCRIPT_DIR/lib_notify.sh\"

            write_pid_file \"$pid_file\" \"\$\$\"
            append_log \"$RUNTIME_LOG\" \"${watcher_type}_watcher started pid=\$\$\"
            trap 'remove_pid_file_for_pid \"$pid_file\" \"\$\$\"' EXIT

            source \"$watcher_script\"
            ${watcher_type}_watcher_run notify_callback \"$RUNTIME_LOG\"
        "

    if command -v setsid >/dev/null 2>&1; then
        nohup setsid bash -c "$child_command" "$marker" </dev/null >>"$RUNTIME_LOG" 2>&1 &
    else
        nohup bash -c "$child_command" "$marker" </dev/null >>"$RUNTIME_LOG" 2>&1 &
    fi

    sleep 1

    if is_watcher_running "$pid_file" "$marker" "$legacy_command"; then
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
    local pid
    local pids
    local stopped=0
    local marker
    local legacy_command

    marker=$(watcher_process_marker "$watcher_type")
    legacy_command=$(legacy_watcher_command "$watcher_type")

    pid=$(read_pid_file "$pid_file")
    if terminate_pid "$pid" "$marker" "$legacy_command"; then
        stopped=1
    fi

    pids=$(list_running_pids "$marker" "$legacy_command" || true)
    while IFS= read -r pid; do
        [ -n "$pid" ] || continue
        if terminate_pid "$pid" "$marker" "$legacy_command"; then
            stopped=1
        fi
    done <<< "$pids"

    pid=$(read_pid_file "$pid_file")
    if ! watcher_process_matches "$pid" "$marker" "$legacy_command"; then
        rm -f -- "$pid_file"
    fi

    if [ "$stopped" -eq 1 ]; then
        echo "${watcher_type} watcher stopped."
    else
        echo "${watcher_type} watcher is not running."
    fi
}

watcher_display_name() {
    case "$1" in
        codex)
            printf 'Codex\n'
            ;;
        claude)
            printf 'Claude\n'
            ;;
        *)
            printf '%s\n' "$1"
            ;;
    esac
}

status_watcher_process() {
    local watcher_type="$1"
    local pid_file="$STATE_DIR/${watcher_type}_watcher.pid"
    local watcher_script="$SCRIPT_DIR/watchers/${watcher_type}_watcher.sh"
    local installed_version=""
    local compatibility_status=""
    local event_status=""
    local source_name="unknown"
    local source_var
    local display_name
    local marker
    local legacy_command

    marker=$(watcher_process_marker "$watcher_type")
    legacy_command=$(legacy_watcher_command "$watcher_type")

    if is_watcher_running "$pid_file" "$marker" "$legacy_command"; then
        local pid
        pid=$(read_pid_file "$pid_file")
        if grep -Fq "${watcher_type}_watcher ready pid=$pid " "$RUNTIME_LOG"; then
            echo "${watcher_type} watcher is running (pid ${pid:-unknown})."
        else
            echo "${watcher_type} watcher is initializing (pid ${pid:-unknown})."
        fi
    else
        echo "${watcher_type} watcher is not running."
    fi

    if [ -f "$watcher_script" ]; then
        # shellcheck disable=SC1090
        source "$watcher_script"
        installed_version=$("${watcher_type}_installed_version_detect" 2>/dev/null || true)
        if "${watcher_type}_watcher_init" >/dev/null 2>&1; then
            source_var="$(printf '%s' "$watcher_type" | tr '[:lower:]' '[:upper:]')_WATCH_SOURCE"
            source_name="${!source_var:-unknown}"
        fi
        compatibility_status=$("${watcher_type}_compatibility_status" "$installed_version" 2>/dev/null || true)
        case "$compatibility_status" in
            ok) event_status="verified" ;;
            'event format observed') event_status="recognized" ;;
            'recheck needed') event_status="unconfirmed" ;;
            *) event_status="unavailable" ;;
        esac
        display_name=$(watcher_display_name "$watcher_type")
        echo "${display_name}: ${installed_version:-unknown} ($source_name)"
        echo "Core events: $event_status"
    fi
}

normalize_watcher_type() {
    local watcher_type="${1:-all}"

    case "$watcher_type" in
        ""|all)
            printf 'all\n'
            ;;
        codex|claude)
            printf '%s\n' "$watcher_type"
            ;;
        *)
            echo "Error: unsupported watcher type: $watcher_type" >&2
            return 1
            ;;
    esac
}

run_command() {
    local watcher_type
    local watcher
    local start_failed=0

    watcher_type=$(normalize_watcher_type "${1:-all}")

    collect_watcher_targets "$watcher_type" || exit 1

    for watcher in "${SELECTED_WATCHERS[@]}"; do
        if ! start_watcher_process "$watcher"; then
            start_failed=1
        fi
    done

    if [ "$start_failed" -ne 0 ]; then
        exit 1
    fi

    wait
}

start_command() {
    local watcher_type
    local watcher
    local start_failed=0

    watcher_type=$(normalize_watcher_type "${1:-all}")

    collect_watcher_targets "$watcher_type" || exit 1

    for watcher in "${SELECTED_WATCHERS[@]}"; do
        if ! start_watcher_process "$watcher"; then
            start_failed=1
        fi
    done

    if [ "$start_failed" -ne 0 ]; then
        exit 1
    fi
}

stop_command() {
    local watcher_type

    watcher_type=$(normalize_watcher_type "${1:-all}")

    if [ "$watcher_type" = "all" ]; then
        stop_watcher_process "codex"
        stop_watcher_process "claude"
    else
        stop_watcher_process "$watcher_type"
    fi
}

status_command() {
    local watcher_type
    local watcher
    local first=1

    watcher_type=$(normalize_watcher_type "${1:-all}")

    echo "Runtime log: $RUNTIME_LOG"
    echo "Error log: $ERROR_LOG_FILE"
    if [ -n "${AI_ASSISTANT_NOTIFY_ENV_FILE:-}" ]; then
        echo "Config files: $AI_ASSISTANT_NOTIFY_ENV_FILE"
    else
        echo "Config files: not loaded"
    fi
    echo ""

    if [ "$watcher_type" = "all" ]; then
        for watcher in codex claude; do
            if [ "$first" -eq 0 ]; then
                echo ""
            fi
            first=0

            if is_watcher_configured "$watcher"; then
                status_watcher_process "$watcher"
            else
                echo "${watcher} watcher: not configured"
            fi
        done
    elif is_watcher_configured "$watcher_type"; then
        status_watcher_process "$watcher_type"
    else
        echo "${watcher_type} watcher: not configured"
    fi
}

test_notify() {
    local watcher
    local message
    local failed=0
    local configured=()

    while IFS= read -r watcher; do
        [ -n "$watcher" ] || continue
        configured+=("$watcher")
    done < <(get_configured_watchers)

    if [ "${#configured[@]}" -eq 0 ]; then
        echo "Error: no watcher is configured in .env" >&2
        exit 1
    fi

    for watcher in "${configured[@]}"; do
        case "$watcher" in
            codex)
                message="Codex 飞书通知链路测试。"
                ;;
            claude)
                message="Claude 飞书通知链路测试。"
                ;;
            *)
                message="${watcher} 飞书通知链路测试。"
                ;;
        esac

        echo "Testing ${watcher} notification..."
        if send_feishu_notification "$watcher" "$message"; then
            echo "✓ ${watcher} notification sent successfully."
        else
            echo "✗ ${watcher} notification failed." >&2
            failed=1
        fi
    done

    if [ "$failed" -ne 0 ]; then
        exit 1
    fi
}

COMMAND="${1:-}"
WATCHER_TYPE="${2:-all}"

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
