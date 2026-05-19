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

load_repo_env() {
    local repo_env_file="${1:-}"

    AI_ASSISTANT_NOTIFY_ENV_FILE=""
    if [ ! -f "$repo_env_file" ]; then
        echo "Error: config file not found: $repo_env_file" >&2
        return 1
    fi

    AI_ASSISTANT_NOTIFY_ENV_FILE="$repo_env_file"
    load_env_file "$repo_env_file"
}
