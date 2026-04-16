#!/usr/bin/env bash

repo_root_from_script_path() {
    local script_path="$1"
    local script_dir
    local target

    while [ -L "$script_path" ]; do
        script_dir=$(cd -P "$(dirname "$script_path")" && pwd)
        target=$(readlink "$script_path")
        case "$target" in
            /*)
                script_path="$target"
                ;;
            *)
                script_path="$script_dir/$target"
                ;;
        esac
    done

    script_dir=$(cd -P "$(dirname "$script_path")" && pwd)
    cd "$script_dir/.." && pwd
}

load_env_file() {
    local env_file="$1"

    if [ ! -f "$env_file" ]; then
        return
    fi

    set -a
    # shellcheck disable=SC1090
    source "$env_file"
    set +a
}

env_file_has_app_keys() {
    local env_file="$1"

    grep -Eq '^[[:space:]]*(export[[:space:]]+)?(CODEX_FEISHU_|CLAUDE_FEISHU_|FEISHU_|CODEX_LOG_FILE=|CLAUDE_SESSION_DIR=|CLAUDE_HISTORY_FILE=|CLAUDE_CHECK_INTERVAL=|CLAUDE_IDLE_THRESHOLD=)' "$env_file"
}

default_user_env_file() {
    if [ -n "${XDG_CONFIG_HOME:-}" ]; then
        printf '%s/ai-assistant-notify/.env\n' "$XDG_CONFIG_HOME"
        return
    fi

    if [ -n "${HOME:-}" ]; then
        printf '%s/.config/ai-assistant-notify/.env\n' "$HOME"
    fi
}

load_app_env_if_present() {
    local repo_env_file="${1:-}"
    local user_env_file
    local current_env_file

    AI_ASSISTANT_NOTIFY_ENV_FILE=""

    if [ -n "${AI_ASSISTANT_NOTIFY_ENV:-}" ]; then
        if [ ! -f "$AI_ASSISTANT_NOTIFY_ENV" ]; then
            echo "Error: AI_ASSISTANT_NOTIFY_ENV does not exist: $AI_ASSISTANT_NOTIFY_ENV" >&2
            return 1
        fi

        AI_ASSISTANT_NOTIFY_ENV_FILE="$AI_ASSISTANT_NOTIFY_ENV"
        load_env_file "$AI_ASSISTANT_NOTIFY_ENV_FILE"
        return
    fi

    user_env_file=$(default_user_env_file)
    current_env_file="${PWD:-$(pwd)}/.env"

    load_candidate_env_file "$user_env_file"
    load_candidate_env_file "$current_env_file"

    # Compatibility fallback for direct source-tree usage from another cwd.
    # Do not let the package/source .env override user or cwd config.
    if [ -z "$AI_ASSISTANT_NOTIFY_ENV_FILE" ]; then
        load_candidate_env_file "$repo_env_file"
    fi
}

load_candidate_env_file() {
    local env_file="$1"

    [ -n "$env_file" ] || return
    [ -f "$env_file" ] || return

    case ",$AI_ASSISTANT_NOTIFY_ENV_FILE," in
        *",$env_file,"*)
            return
            ;;
    esac

    if ! env_file_has_app_keys "$env_file"; then
        return
    fi

    load_env_file "$env_file"
    if [ -n "$AI_ASSISTANT_NOTIFY_ENV_FILE" ]; then
        AI_ASSISTANT_NOTIFY_ENV_FILE="$AI_ASSISTANT_NOTIFY_ENV_FILE,$env_file"
    else
        AI_ASSISTANT_NOTIFY_ENV_FILE="$env_file"
    fi
}
