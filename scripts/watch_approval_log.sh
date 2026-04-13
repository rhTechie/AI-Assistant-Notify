#!/bin/bash

set -euo pipefail

usage() {
    cat <<'EOF'
Usage:
  watch_approval_log.sh <log_file>

Environment:
  FEISHU_WEBHOOK           Required unless provided by repo-root .env
  FEISHU_KEYWORD           Optional. Default: Codex审批
  WATCH_PATTERNS           Optional regex. Default matches common approval prompts
  WATCH_NOTIFY_COOLDOWN    Optional seconds. Default: 600

Example:
  ./scripts/watch_approval_log.sh /tmp/codex.log
EOF
}

if [ "$#" -ne 1 ]; then
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

LOG_FILE="$1"
NOTIFY_SCRIPT="$SCRIPT_DIR/feishu_notify.sh"
PATTERNS="${WATCH_PATTERNS:-require_escalated|approval|Do you want me to|need user confirmation|需要确认|等待确认|审批}"
COOLDOWN="${WATCH_NOTIFY_COOLDOWN:-600}"
LAST_SENT_TS=0
LAST_MATCH=""

if [ ! -f "$NOTIFY_SCRIPT" ]; then
    echo "Error: notify script not found: $NOTIFY_SCRIPT"
    exit 1
fi

mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"

echo "Watching $LOG_FILE for approval prompts..."

tail -n 0 -F "$LOG_FILE" | while IFS= read -r line; do
    if ! printf '%s\n' "$line" | grep -Eiq "$PATTERNS"; then
        continue
    fi

    NOW=$(date +%s)
    if [ "$line" = "$LAST_MATCH" ] && [ $((NOW - LAST_SENT_TS)) -lt "$COOLDOWN" ]; then
        continue
    fi

    if [ $((NOW - LAST_SENT_TS)) -lt "$COOLDOWN" ]; then
        continue
    fi

    LAST_SENT_TS="$NOW"
    LAST_MATCH="$line"

    "$NOTIFY_SCRIPT" "检测到可能的审批等待状态。日志文件：$LOG_FILE。匹配内容：$line" >/dev/null
    echo "$(date '+%F %T') notification sent for approval-like line"
done
