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

feishu_is_positive_integer() {
    [[ "${1:-}" =~ ^[1-9][0-9]*$ ]]
}

feishu_is_non_negative_integer() {
    [[ "${1:-}" =~ ^[0-9]+$ ]]
}

feishu_response_code() {
    sed -nE '/"(code|StatusCode)"[[:space:]]*:[[:space:]]*-?[0-9]+/ {
        s/.*"(code|StatusCode)"[[:space:]]*:[[:space:]]*(-?[0-9]+).*/\2/p
        q
    }' <<< "$1"
}

feishu_is_retryable_curl_exit() {
    case "$1" in
        5|6|7)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

feishu_is_retryable_curl_timeout() {
    local exit_code="$1"
    local http_code="$2"
    local error_output="$3"

    if [ "$exit_code" != "28" ] || [ "${http_code:-000}" != "000" ]; then
        return 1
    fi

    printf '%s\n' "$error_output" | grep -Eqi 'resolving timed out|connection timed out|failed to connect'
}

feishu_is_retryable_http_status() {
    local http_code="$1"

    case "$http_code" in
        408|429)
            return 0
            ;;
    esac

    [[ "$http_code" =~ ^[0-9]{3}$ ]] && [ "$http_code" -ge 500 ] && [ "$http_code" -le 599 ]
}

send_feishu_notification() {
    local watcher_type="$1"
    local message="$2"
    local webhook=""
    local keyword=""
    local connect_timeout="${FEISHU_NOTIFY_CONNECT_TIMEOUT_SECONDS:-5}"
    local max_time="${FEISHU_NOTIFY_MAX_TIME_SECONDS:-15}"
    local max_attempts="${FEISHU_NOTIFY_MAX_ATTEMPTS:-3}"
    local retry_backoff="${FEISHU_NOTIFY_RETRY_BACKOFF_SECONDS:-1}"

    case "$watcher_type" in
        codex)
            webhook="${CODEX_FEISHU_WEBHOOK:-}"
            keyword="${CODEX_FEISHU_KEYWORD:-Codex提醒}"
            ;;
        *)
            echo "Error: unsupported watcher type: $watcher_type" >&2
            return 1
        ;;
    esac

    if [ -z "$webhook" ]; then
        echo "Error: CODEX_FEISHU_WEBHOOK is required." >&2
        return 1
    fi

    if ! feishu_is_positive_integer "$connect_timeout"; then
        echo "Error: FEISHU_NOTIFY_CONNECT_TIMEOUT_SECONDS must be a positive integer." >&2
        return 1
    fi
    if ! feishu_is_positive_integer "$max_time"; then
        echo "Error: FEISHU_NOTIFY_MAX_TIME_SECONDS must be a positive integer." >&2
        return 1
    fi
    if ! feishu_is_positive_integer "$max_attempts"; then
        echo "Error: FEISHU_NOTIFY_MAX_ATTEMPTS must be a positive integer." >&2
        return 1
    fi
    if ! feishu_is_non_negative_integer "$retry_backoff"; then
        echo "Error: FEISHU_NOTIFY_RETRY_BACKOFF_SECONDS must be a non-negative integer." >&2
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
    local response=""
    local response_code=""
    local error_output=""
    local final_error=""
    local final_detail=""
    local attempt=1
    local retry_delay=0
    local should_retry=0

    if ! response_file=$(mktemp); then
        echo "Error: failed to create temporary response file." >&2
        return 1
    fi
    if ! error_file=$(mktemp); then
        rm -f "$response_file"
        echo "Error: failed to create temporary error file." >&2
        return 1
    fi

    while [ "$attempt" -le "$max_attempts" ]; do
        : > "$response_file"
        : > "$error_file"
        http_code=""
        exit_code=0
        should_retry=0

        if http_code=$(curl -sS \
            --connect-timeout "$connect_timeout" \
            --max-time "$max_time" \
            -o "$response_file" \
            -w '%{http_code}' \
            -X POST "$webhook" \
            -H "Content-Type: application/json" \
            -d "$payload" 2>"$error_file"); then
            exit_code=0
        else
            exit_code=$?
        fi

        response=$(cat "$response_file")
        error_output=$(cat "$error_file")
        response_code=$(feishu_response_code "$response")
        final_detail=""

        if [ "$exit_code" -ne 0 ]; then
            final_error="Error: failed to send Feishu webhook (curl_exit=$exit_code http_code=${http_code:-unknown} attempt=$attempt/$max_attempts)."
            final_detail="${error_output:-No curl stderr.}"
            if feishu_is_retryable_curl_exit "$exit_code" || feishu_is_retryable_curl_timeout "$exit_code" "${http_code:-000}" "$error_output"; then
                should_retry=1
            fi
        elif [[ "$http_code" =~ ^[0-9]{3}$ ]] && [ "$http_code" -ge 400 ]; then
            final_error="Error: Feishu webhook returned HTTP $http_code (attempt=$attempt/$max_attempts)."
            if [ -n "$response" ]; then
                final_detail="Response body: $response"
            fi
            if feishu_is_retryable_http_status "$http_code"; then
                should_retry=1
            fi
        elif [ "$response_code" = "0" ]; then
            rm -f "$response_file" "$error_file"
            return 0
        else
            final_error="Error: Feishu webhook returned failure (attempt=$attempt/$max_attempts): $response"
            if [ "$response_code" = "11232" ]; then
                should_retry=1
            fi
        fi

        if [ "$should_retry" = "1" ] && [ "$attempt" -lt "$max_attempts" ]; then
            retry_delay=$((retry_backoff * attempt))
            if [ "$retry_delay" -gt 0 ]; then
                sleep "$retry_delay"
            fi
            attempt=$((attempt + 1))
            continue
        fi

        break
    done

    rm -f "$response_file" "$error_file"

    echo "$final_error" >&2
    if [ -n "$final_detail" ]; then
        echo "$final_detail" >&2
    fi

    return 1
}

# 兼容旧的命令行调用方式
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    usage() {
        cat <<'EOF'
Usage:
  lib_notify.sh <watcher_type> <message>

Arguments:
  watcher_type    codex
  message         Notification message

Environment:
  CODEX_FEISHU_WEBHOOK    Feishu webhook for Codex notifications
  CODEX_FEISHU_KEYWORD    Keyword for Codex notifications (default: Codex提醒)
  FEISHU_NOTIFY_CONNECT_TIMEOUT_SECONDS  Connect timeout (default: 5)
  FEISHU_NOTIFY_MAX_TIME_SECONDS         Total request timeout (default: 15)
  FEISHU_NOTIFY_MAX_ATTEMPTS             Maximum attempts (default: 3)
  FEISHU_NOTIFY_RETRY_BACKOFF_SECONDS    Linear retry backoff (default: 1)

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

    load_repo_env "$ENV_FILE"

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
