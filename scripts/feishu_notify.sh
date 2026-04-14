#!/bin/bash

set -euo pipefail

json_escape() {
    local value="$1"

    value=${value//\\/\\\\}
    value=${value//\"/\\\"}
    value=${value//$'\n'/\\n}
    value=${value//$'\r'/\\r}
    value=${value//$'\t'/\\t}

    printf '%s' "$value"
}

usage() {
    cat <<'EOF'
Usage:
  feishu_notify.sh <message>

Environment:
  FEISHU_WEBHOOK   Required. Full Feishu custom bot webhook URL.
  FEISHU_KEYWORD   Optional. Prefix added to the message. Default: Codex提醒

Example:
  FEISHU_WEBHOOK="https://open.feishu.cn/open-apis/bot/v2/hook/xxxx" \
  ./scripts/feishu_notify.sh "Codex 需要你回来处理。"
EOF
}

if [ "$#" -lt 1 ]; then
    usage
    exit 1
fi

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib_env.sh"
REPO_ROOT=$(repo_root_from_script_path "${BASH_SOURCE[0]}")
ENV_FILE="$REPO_ROOT/.env"

load_repo_env_if_present "$ENV_FILE"

if [ -z "${FEISHU_WEBHOOK:-}" ]; then
    echo "Error: FEISHU_WEBHOOK is required."
    exit 1
fi

MESSAGE="$*"
KEYWORD="${FEISHU_KEYWORD:-Codex提醒}"

PAYLOAD=$(printf '{"msg_type":"text","content":{"text":"%s：%s"}}' \
    "$(json_escape "$KEYWORD")" \
    "$(json_escape "$MESSAGE")")

RESPONSE_FILE=$(mktemp)
ERROR_FILE=$(mktemp)
HTTP_CODE=""
EXIT_CODE=0

if ! HTTP_CODE=$(curl -sS -o "$RESPONSE_FILE" -w '%{http_code}' -X POST "$FEISHU_WEBHOOK" \
    -H "Content-Type: application/json" \
    -d "$PAYLOAD" 2>"$ERROR_FILE"); then
    EXIT_CODE=$?
fi

RESPONSE=$(cat "$RESPONSE_FILE")
ERROR_OUTPUT=$(cat "$ERROR_FILE")

rm -f "$RESPONSE_FILE" "$ERROR_FILE"

if [ "$EXIT_CODE" -ne 0 ]; then
    echo "Error: failed to send Feishu webhook (curl_exit=$EXIT_CODE http_code=${HTTP_CODE:-unknown}). ${ERROR_OUTPUT:-No curl stderr.}" >&2
    if [ -n "$RESPONSE" ]; then
        echo "Response body: $RESPONSE" >&2
    fi
    exit 1
fi

if [ -n "$HTTP_CODE" ] && [ "$HTTP_CODE" -ge 400 ] 2>/dev/null; then
    echo "Error: Feishu webhook returned HTTP $HTTP_CODE." >&2
    if [ -n "$RESPONSE" ]; then
        echo "Response body: $RESPONSE" >&2
    fi
    exit 1
fi

if ! printf '%s\n' "$RESPONSE" | grep -Eq '"(code|StatusCode)"[[:space:]]*:[[:space:]]*0'; then
    echo "Error: Feishu webhook returned failure: $RESPONSE" >&2
    exit 1
fi

printf '%s\n' "$RESPONSE"
