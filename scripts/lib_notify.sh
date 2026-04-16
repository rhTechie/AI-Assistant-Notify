#!/usr/bin/env bash

set -euo pipefail

# 飞书通知模块

json_escape() {
    local value="$1"

    value=${value//\\/\\\\}
    value=${value//\"/\\\"}
    value=${value//$'\n'/\\n}
    value=${value//$'\r'/\\r}
    value=${value//$'\t'/\\t}

    printf '%s' "$value"
}

send_feishu_notification() {
    local watcher_type="$1"
    local message="$2"
    local webhook=""
    local keyword=""

    case "$watcher_type" in
        codex)
            webhook="${CODEX_FEISHU_WEBHOOK:-${FEISHU_WEBHOOK:-}}"
            keyword="${CODEX_FEISHU_KEYWORD:-${FEISHU_KEYWORD:-Codex提醒}}"
            ;;
        claude)
            webhook="${CLAUDE_FEISHU_WEBHOOK:-${FEISHU_WEBHOOK:-}}"
            keyword="${CLAUDE_FEISHU_KEYWORD:-${FEISHU_KEYWORD:-Claude提醒}}"
            ;;
        *)
            webhook="${FEISHU_WEBHOOK:-}"
            keyword="${FEISHU_KEYWORD:-AI助手提醒}"
            ;;
    esac

    if [ -z "$webhook" ]; then
        echo "Error: FEISHU_WEBHOOK is required for $watcher_type." >&2
        return 1
    fi

    local payload
    payload=$(printf '{"msg_type":"text","content":{"text":"%s：%s"}}' \
        "$(json_escape "$keyword")" \
        "$(json_escape "$message")")

    local response_file
    local error_file
    local http_code=""
    local exit_code=0

    response_file=$(mktemp)
    error_file=$(mktemp)

    if ! http_code=$(curl -sS -o "$response_file" -w '%{http_code}' -X POST "$webhook" \
        -H "Content-Type: application/json" \
        -d "$payload" 2>"$error_file"); then
        exit_code=$?
    fi

    local response
    local error_output

    response=$(cat "$response_file")
    error_output=$(cat "$error_file")

    rm -f "$response_file" "$error_file"

    if [ "$exit_code" -ne 0 ]; then
        echo "Error: failed to send Feishu webhook (curl_exit=$exit_code http_code=${http_code:-unknown}). ${error_output:-No curl stderr.}" >&2
        return 1
    fi

    if [ -n "$http_code" ] && [ "$http_code" -ge 400 ] 2>/dev/null; then
        echo "Error: Feishu webhook returned HTTP $http_code." >&2
        if [ -n "$response" ]; then
            echo "Response body: $response" >&2
        fi
        return 1
    fi

    if ! printf '%s\n' "$response" | grep -Eq '"(code|StatusCode)"[[:space:]]*:[[:space:]]*0'; then
        echo "Error: Feishu webhook returned failure: $response" >&2
        return 1
    fi

    return 0
}

# 兼容旧的命令行调用方式
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    usage() {
        cat <<'EOF'
Usage:
  lib_notify.sh <watcher_type> <message>

Arguments:
  watcher_type    codex or claude
  message         Notification message

Environment:
  CODEX_FEISHU_WEBHOOK    Feishu webhook for Codex notifications
  CODEX_FEISHU_KEYWORD    Keyword for Codex notifications (default: Codex提醒)
  CLAUDE_FEISHU_WEBHOOK   Feishu webhook for Claude notifications
  CLAUDE_FEISHU_KEYWORD   Keyword for Claude notifications (default: Claude提醒)
  FEISHU_WEBHOOK          Fallback webhook if specific one not set
  FEISHU_KEYWORD          Fallback keyword if specific one not set

Example:
  CODEX_FEISHU_WEBHOOK="https://open.feishu.cn/open-apis/bot/v2/hook/xxxx" \
  ./scripts/lib_notify.sh codex "Codex 需要你回来处理。"
EOF
    }

    if [ "$#" -lt 2 ]; then
        usage
        exit 1
    fi

    SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
    # shellcheck disable=SC1091
    source "$SCRIPT_DIR/lib_env.sh"
    REPO_ROOT=$(repo_root_from_script_path "${BASH_SOURCE[0]}")
    ENV_FILE="$REPO_ROOT/.env"

    load_app_env_if_present "$ENV_FILE"

    WATCHER_TYPE="$1"
    shift
    MESSAGE="$*"

    if send_feishu_notification "$WATCHER_TYPE" "$MESSAGE"; then
        echo "Notification sent successfully."
        exit 0
    else
        exit 1
    fi
fi
