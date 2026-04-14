#!/bin/bash

repo_root_from_script_path() {
    local script_path="$1"
    local script_dir

    script_dir=$(cd "$(dirname "$script_path")" && pwd)
    cd "$script_dir/.." && pwd
}

remember_env_override() {
    local name="$1"
    local keep_name="__REPO_ENV_KEEP_${name}"
    local value_name="__REPO_ENV_VALUE_${name}"

    if [ "${!name+x}" = "x" ]; then
        printf -v "$keep_name" '%s' "x"
        printf -v "$value_name" '%s' "${!name}"
    fi
}

restore_env_override() {
    local name="$1"
    local keep_name="__REPO_ENV_KEEP_${name}"
    local value_name="__REPO_ENV_VALUE_${name}"

    if [ "${!keep_name:-}" = "x" ]; then
        export "$name=${!value_name}"
    fi
}

load_repo_env_if_present() {
    local env_file="$1"
    local tracked_vars
    local name

    if [ ! -f "$env_file" ]; then
        return
    fi

    tracked_vars=(
        FEISHU_WEBHOOK
        FEISHU_KEYWORD
        CODEX_TUI_LOG_PATH
        CODEX_APPROVAL_EXTRA_EVENTS
        CODEX_APPROVAL_NOTIFY_COOLDOWN
        CODEX_APPROVAL_CONTEXT_WINDOW
        CODEX_APPROVAL_WATCH_DEBUG
        CODEX_APPROVAL_WATCH_DEBUG_LOG
        CODEX_APPROVAL_WATCH_ERROR_LOG
    )

    if [ "${__REPO_ENV_INITIALIZED:-0}" != "1" ]; then
        __REPO_ENV_INITIALIZED=1
        for name in "${tracked_vars[@]}"; do
            remember_env_override "$name"
        done
    fi

    set -a
    # shellcheck disable=SC1090
    source "$env_file"
    set +a

    for name in "${tracked_vars[@]}"; do
        restore_env_override "$name"
    done
}
