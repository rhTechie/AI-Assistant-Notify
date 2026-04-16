#!/usr/bin/env bash

set -euo pipefail

usage() {
    cat <<'EOF'
Usage:
  ai-assistant-notify init [--local|--global] [--force]
  ai-assistant-notify run [watcher_type]
  ai-assistant-notify start [watcher_type]
  ai-assistant-notify stop [watcher_type]
  ai-assistant-notify status [watcher_type]
  ai-assistant-notify test-notify

Arguments:
  watcher_type    Optional. Specify which watcher to control: codex, claude, or all (default: all)
                  - all: 启动所有已配置 webhook 的监测器
                  - codex: 只启动 Codex 监测器
                  - claude: 只启动 Claude 监测器

Environment:
  CODEX_FEISHU_WEBHOOK            Feishu webhook URL for Codex notifications.
  CODEX_FEISHU_KEYWORD            Optional. Keyword for Codex. Default: Codex提醒
  CLAUDE_FEISHU_WEBHOOK           Feishu webhook URL for Claude notifications.
  CLAUDE_FEISHU_KEYWORD           Optional. Keyword for Claude. Default: Claude提醒
  AI_ASSISTANT_NOTIFY_ENV         Optional. Explicit .env file path.

Note:
  - 如果未配置某个 webhook，对应的监测器将不会启动
  - 可以多次调用 start 命令启动不同的监测器
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
    load_app_env_if_present "$ENV_FILE"
}

is_watcher_configured() {
    local watcher="$1"
    local webhook_var=""

    case "$watcher" in
        codex)
            webhook_var="${CODEX_FEISHU_WEBHOOK:-}"
            ;;
        claude)
            webhook_var="${CLAUDE_FEISHU_WEBHOOK:-}"
            ;;
        *)
            return 1
            ;;
    esac

    [ -n "$webhook_var" ] && [ "$webhook_var" != "https://open.feishu.cn/open-apis/bot/v2/hook/replace-with-your-codex-webhook" ] && [ "$webhook_var" != "https://open.feishu.cn/open-apis/bot/v2/hook/replace-with-your-claude-webhook" ]
}

get_configured_watchers() {
    local watchers=""

    if is_watcher_configured "codex"; then
        watchers="codex"
    fi

    if is_watcher_configured "claude"; then
        if [ -n "$watchers" ]; then
            watchers="$watchers,claude"
        else
            watchers="claude"
        fi
    fi

    echo "$watchers"
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
    export CLAUDE_FEISHU_WEBHOOK CLAUDE_FEISHU_KEYWORD
    export CODEX_LOG_FILE CLAUDE_SESSION_DIR CLAUDE_HISTORY_FILE CLAUDE_CHECK_INTERVAL
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

    if is_watcher_running "$pid_file" "${watcher_type}_watcher.sh run"; then
        local pid
        pid=$(read_pid_file "$pid_file")
        echo "${watcher_type} watcher is running (pid ${pid:-unknown})."
    else
        echo "${watcher_type} watcher is not running."
    fi
}

run_command() {
    local watcher_type="${1:-all}"

    if [ "$watcher_type" = "all" ]; then
        local configured_watchers
        configured_watchers=$(get_configured_watchers)

        if [ -z "$configured_watchers" ]; then
            echo "Error: No watchers configured. Please set CODEX_FEISHU_WEBHOOK or CLAUDE_FEISHU_WEBHOOK in .env" >&2
            exit 1
        fi

        IFS=',' read -ra watchers <<< "$configured_watchers"
        for watcher in "${watchers[@]}"; do
            watcher=$(echo "$watcher" | xargs)
            if [ -n "$watcher" ]; then
                start_watcher_process "$watcher" || true
            fi
        done
    else
        start_watcher_process "$watcher_type"
    fi

    wait
}

start_command() {
    local watcher_type="${1:-all}"

    if [ "$watcher_type" = "all" ]; then
        local configured_watchers
        configured_watchers=$(get_configured_watchers)

        if [ -z "$configured_watchers" ]; then
            echo "Error: No watchers configured. Please set CODEX_FEISHU_WEBHOOK or CLAUDE_FEISHU_WEBHOOK in .env" >&2
            exit 1
        fi

        IFS=',' read -ra watchers <<< "$configured_watchers"
        for watcher in "${watchers[@]}"; do
            watcher=$(echo "$watcher" | xargs)
            if [ -n "$watcher" ]; then
                start_watcher_process "$watcher" || true
            fi
        done
    else
        start_watcher_process "$watcher_type"
    fi
}

stop_command() {
    local watcher_type="${1:-all}"

    if [ "$watcher_type" = "all" ]; then
        # 停止所有可能运行的监测器
        for watcher in codex claude; do
            stop_watcher_process "$watcher" 2>/dev/null || true
        done
    else
        stop_watcher_process "$watcher_type"
    fi
}

status_command() {
    local watcher_type="${1:-all}"

    echo "Runtime log: $RUNTIME_LOG"
    echo "Error log: $ERROR_LOG_FILE"
    if [ -n "${AI_ASSISTANT_NOTIFY_ENV_FILE:-}" ]; then
        echo "Config files: $AI_ASSISTANT_NOTIFY_ENV_FILE"
    else
        echo "Config files: not loaded"
    fi
    echo ""

    if [ "$watcher_type" = "all" ]; then
        # 显示所有监测器的状态
        for watcher in codex claude; do
            if is_watcher_configured "$watcher"; then
                status_watcher_process "$watcher" || true
            else
                echo "${watcher} watcher: not configured"
            fi
        done
    else
        status_watcher_process "$watcher_type"
    fi
}

test_notify() {
    local configured_watchers
    configured_watchers=$(get_configured_watchers)

    if [ -z "$configured_watchers" ]; then
        echo "Error: No watchers configured. Please set CODEX_FEISHU_WEBHOOK or CLAUDE_FEISHU_WEBHOOK in .env" >&2
        exit 1
    fi

    local success=true

    IFS=',' read -ra watchers <<< "$configured_watchers"
    for watcher in "${watchers[@]}"; do
        watcher=$(echo "$watcher" | xargs)
        if [ -z "$watcher" ]; then
            continue
        fi

        echo "Testing ${watcher} notification..."
        local message=""
        case "$watcher" in
            codex)
                message="Codex 飞书通知链路测试。"
                ;;
            claude)
                message="Claude Code 飞书通知链路测试。"
                ;;
        esac

        if send_feishu_notification "$watcher" "$message"; then
            echo "✓ ${watcher} notification sent successfully."
        else
            echo "✗ ${watcher} notification failed." >&2
            success=false
        fi
    done

    if [ "$success" = false ]; then
        exit 1
    fi
}

init_command() {
    local target_scope="local"
    local force=0
    local arg
    local template_file="$REPO_ROOT/.env.example"
    local target_file

    for arg in "$@"; do
        case "$arg" in
            --local)
                target_scope="local"
                ;;
            --global)
                target_scope="global"
                ;;
            --force)
                force=1
                ;;
            -h|--help)
                usage
                return 0
                ;;
            *)
                echo "Error: unknown init option: $arg" >&2
                usage
                return 1
                ;;
        esac
    done

    if [ ! -f "$template_file" ]; then
        echo "Error: config template not found: $template_file" >&2
        return 1
    fi

    case "$target_scope" in
        local)
            target_file="${PWD:-$(pwd)}/.env"
            ;;
        global)
            target_file=$(default_user_env_file)
            if [ -z "$target_file" ]; then
                echo "Error: HOME or XDG_CONFIG_HOME is required for --global config." >&2
                return 1
            fi
            ;;
    esac

    if [ -f "$target_file" ] && [ "$force" -ne 1 ]; then
        echo "Config already exists: $target_file"
        echo "Use --force to overwrite it."
        return 1
    fi

    mkdir -p "$(dirname "$target_file")"
    cp "$template_file" "$target_file"
    chmod 600 "$target_file" 2>/dev/null || true

    echo "Created config file: $target_file"
    echo "Edit it and fill in your Feishu webhook."
}

COMMAND="${1:-}"
WATCHER_TYPE="${2:-all}"

case "$COMMAND" in
    init)
        shift
        init_command "$@"
        ;;
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
