#!/bin/bash

set -euo pipefail

usage() {
    cat <<'EOF'
Usage:
  run_with_watch.sh <log_file> -- <command> [args...]

Example:
  ./scripts/run_with_watch.sh /tmp/codex.log -- bash -lc 'your-command 2>&1'
EOF
}

if [ "$#" -lt 3 ]; then
    usage
    exit 1
fi

LOG_FILE="$1"
shift

if [ "$1" != "--" ]; then
    usage
    exit 1
fi
shift

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
WATCHER="$SCRIPT_DIR/watch_approval_log.sh"

mkdir -p "$(dirname "$LOG_FILE")"
: > "$LOG_FILE"

"$WATCHER" "$LOG_FILE" &
WATCHER_PID=$!

cleanup() {
    if kill -0 "$WATCHER_PID" >/dev/null 2>&1; then
        kill "$WATCHER_PID" >/dev/null 2>&1 || true
        wait "$WATCHER_PID" 2>/dev/null || true
    fi
}

trap cleanup EXIT

"$@" > >(tee -a "$LOG_FILE") 2> >(tee -a "$LOG_FILE" >&2)
