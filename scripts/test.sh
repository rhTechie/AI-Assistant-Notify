#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)

bash -n \
    "$REPO_ROOT/bin/ai-assistant-notify" \
    "$REPO_ROOT/scripts/"*.sh \
    "$REPO_ROOT/scripts/watchers/codex_watcher.sh" \
    "$REPO_ROOT/scripts/utils/"*.sh

bash "$REPO_ROOT/scripts/test_codex_watcher.sh"
