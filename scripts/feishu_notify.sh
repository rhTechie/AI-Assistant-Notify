#!/bin/bash

set -euo pipefail

usage() {
    cat <<'EOF'
Usage:
  feishu_notify.sh <message>

Environment:
  FEISHU_WEBHOOK   Required. Full Feishu custom bot webhook URL.
  FEISHU_KEYWORD   Optional. Prefix added to the message. Default: Codex审批

Example:
  FEISHU_WEBHOOK="https://open.feishu.cn/open-apis/bot/v2/hook/xxxx" \
  ./scripts/feishu_notify.sh "任务卡在权限确认，请回来处理。"
EOF
}

if [ "$#" -lt 1 ]; then
    usage
    exit 1
fi

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)

if [ -f "$REPO_ROOT/.env" ]; then
    set -a
    # shellcheck disable=SC1091
    source "$REPO_ROOT/.env"
    set +a
fi

if [ -z "${FEISHU_WEBHOOK:-}" ]; then
    echo "Error: FEISHU_WEBHOOK is required."
    exit 1
fi

MESSAGE="$*"
KEYWORD="${FEISHU_KEYWORD:-Codex审批}"

PAYLOAD=$(printf '{"msg_type":"text","content":{"text":"%s：%s"}}' "$KEYWORD" "$MESSAGE")

curl -sS -X POST "$FEISHU_WEBHOOK" \
    -H "Content-Type: application/json" \
    -d "$PAYLOAD"
