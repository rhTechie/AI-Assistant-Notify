#!/usr/bin/env bash

# Process and runtime-state helpers.

pid_is_safe() {
    local pid="${1:-}"

    case "$pid" in
        ""|*[!0-9]*)
            return 1
            ;;
    esac

    [ "$pid" -gt 1 ] 2>/dev/null
}

pid_is_alive() {
    local pid="${1:-}"

    pid_is_safe "$pid" || return 1
    kill -0 -- "$pid" 2>/dev/null
}

process_is_owned_by_current_user() {
    local pid="${1:-}"
    local process_uid

    pid_is_safe "$pid" || return 1
    process_uid=$(stat -c '%u' "/proc/$pid" 2>/dev/null) || return 1
    [ "$process_uid" = "${EUID:-$(id -u)}" ]
}

process_has_exact_argument() {
    local pid="${1:-}"
    local expected="${2:-}"
    local argument

    [ -n "$expected" ] || return 1
    [ -r "/proc/$pid/cmdline" ] || return 1

    while IFS= read -r -d '' argument; do
        if [ "$argument" = "$expected" ]; then
            return 0
        fi
    done < "/proc/$pid/cmdline"

    return 1
}

process_argv_equals() {
    local pid="${1:-}"
    shift || return 1
    local -a actual_argv=()
    local argument
    local index=0

    [ -r "/proc/$pid/cmdline" ] || return 1

    while IFS= read -r -d '' argument; do
        actual_argv+=("$argument")
    done < "/proc/$pid/cmdline"

    [ "${#actual_argv[@]}" -eq "$#" ] || return 1
    for argument in "$@"; do
        [ "${actual_argv[$index]}" = "$argument" ] || return 1
        index=$((index + 1))
    done
}

watcher_process_matches() {
    local pid="${1:-}"
    local marker="${2:-}"
    local legacy_command="${3:-}"

    pid_is_alive "$pid" || return 1
    process_is_owned_by_current_user "$pid" || return 1

    if process_has_exact_argument "$pid" "$marker"; then
        return 0
    fi

    [ -n "$legacy_command" ] || return 1
    process_argv_equals "$pid" "bash" "-c" "$legacy_command"
}

list_running_pids() {
    local marker="$1"
    local legacy_command="${2:-}"
    local proc_dir
    local pid

    for proc_dir in /proc/[0-9]*; do
        [ -d "$proc_dir" ] || continue
        pid=${proc_dir##*/}
        if watcher_process_matches "$pid" "$marker" "$legacy_command"; then
            printf '%s\n' "$pid"
        fi
    done | sort -n
}

first_running_pid() {
    local marker="$1"
    local legacy_command="${2:-}"

    list_running_pids "$marker" "$legacy_command" | sed -n '1p'
}

read_pid_file() {
    local pid_file="$1"

    sed -n '1p' "$pid_file" 2>/dev/null || true
}

write_pid_file() {
    local pid_file="$1"
    local pid="$2"
    local temp_file

    pid_is_safe "$pid" || return 1
    temp_file=$(mktemp "${pid_file}.tmp.XXXXXX") || return 1
    chmod 600 "$temp_file"
    if ! printf '%s\n' "$pid" > "$temp_file" || ! mv -f -- "$temp_file" "$pid_file"; then
        rm -f -- "$temp_file"
        return 1
    fi
}

remove_pid_file_for_pid() {
    local pid_file="$1"
    local pid="$2"

    if [ "$(read_pid_file "$pid_file")" = "$pid" ]; then
        rm -f -- "$pid_file"
    fi
}

terminate_pid() {
    local pid="${1:-}"
    local marker="${2:-}"
    local legacy_command="${3:-}"
    local attempts=10

    watcher_process_matches "$pid" "$marker" "$legacy_command" || return 1

    if ! kill -TERM -- "$pid" >/dev/null 2>&1; then
        pid_is_alive "$pid" && return 1
        return 0
    fi

    while [ "$attempts" -gt 0 ]; do
        if ! pid_is_alive "$pid"; then
            return 0
        fi
        sleep 0.1
        attempts=$((attempts - 1))
    done

    watcher_process_matches "$pid" "$marker" "$legacy_command" || return 1
    kill -KILL -- "$pid" >/dev/null 2>&1 || ! pid_is_alive "$pid"
}

is_watcher_running() {
    local pid_file="$1"
    local marker="$2"
    local legacy_command="${3:-}"
    local pid
    local fallback_pid

    pid=$(read_pid_file "$pid_file")
    if watcher_process_matches "$pid" "$marker" "$legacy_command"; then
        return 0
    fi

    rm -f -- "$pid_file"

    fallback_pid=$(first_running_pid "$marker" "$legacy_command")
    if watcher_process_matches "$fallback_pid" "$marker" "$legacy_command"; then
        write_pid_file "$pid_file" "$fallback_pid"
        return 0
    fi

    return 1
}

secure_state_dir() {
    local state_dir="$1"
    local owner_uid

    if [ -L "$state_dir" ]; then
        echo "Error: state directory must not be a symbolic link: $state_dir" >&2
        return 1
    fi

    if [ -e "$state_dir" ]; then
        [ -d "$state_dir" ] || {
            echo "Error: state path is not a directory: $state_dir" >&2
            return 1
        }
        owner_uid=$(stat -c '%u' "$state_dir" 2>/dev/null) || return 1
        if [ "$owner_uid" != "${EUID:-$(id -u)}" ]; then
            echo "Error: state directory is not owned by the current user: $state_dir" >&2
            return 1
        fi
    else
        mkdir -m 700 -p -- "$state_dir" || return 1
    fi

    chmod 700 -- "$state_dir"
}

secure_state_file() {
    local state_file="$1"
    local owner_uid

    if [ -L "$state_file" ]; then
        echo "Error: unsafe state file: $state_file" >&2
        return 1
    fi
    [ -e "$state_file" ] || return 0
    if [ ! -f "$state_file" ]; then
        echo "Error: unsafe state file: $state_file" >&2
        return 1
    fi

    owner_uid=$(stat -c '%u' "$state_file" 2>/dev/null) || return 1
    if [ "$owner_uid" != "${EUID:-$(id -u)}" ]; then
        echo "Error: state file is not owned by the current user: $state_file" >&2
        return 1
    fi

    chmod 600 -- "$state_file"
}
