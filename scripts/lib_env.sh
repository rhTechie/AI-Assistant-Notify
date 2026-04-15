#!/bin/bash

repo_root_from_script_path() {
    local script_path="$1"
    local script_dir

    script_dir=$(cd "$(dirname "$script_path")" && pwd)
    cd "$script_dir/.." && pwd
}

load_repo_env_if_present() {
    local env_file="$1"

    if [ ! -f "$env_file" ]; then
        return
    fi

    set -a
    # shellcheck disable=SC1090
    source "$env_file"
    set +a
}
