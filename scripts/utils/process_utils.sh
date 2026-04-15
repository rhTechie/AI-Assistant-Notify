#!/bin/bash

# 进程管理工具函数

list_running_pids() {
    local pattern="$1"
    ps -ef | awk "/$pattern/ && \$0 !~ /awk/ {print \$2}" | sort -u
}

first_running_pid() {
    local pattern="$1"
    list_running_pids "$pattern" | sed -n '1p'
}

read_pid_file() {
    local pid_file="$1"
    sed -n '1p' "$pid_file" 2>/dev/null || true
}

pid_is_alive() {
    local pid="${1:-}"

    [ -n "$pid" ] || return 1
    kill -0 "$pid" 2>/dev/null
}

terminate_pid() {
    local pid="${1:-}"

    if ! pid_is_alive "$pid"; then
        return 0
    fi

    kill "$pid" >/dev/null 2>&1 || true
    sleep 1

    if pid_is_alive "$pid"; then
        kill -9 "$pid" >/dev/null 2>&1 || true
    fi
}

is_watcher_running() {
    local pid_file="$1"
    local pattern="$2"
    local pid
    local fallback_pid

    pid=$(read_pid_file "$pid_file")
    if pid_is_alive "$pid"; then
        return 0
    fi

    rm -f "$pid_file"

    fallback_pid=$(first_running_pid "$pattern")
    if pid_is_alive "$fallback_pid"; then
        printf '%s\n' "$fallback_pid" > "$pid_file"
        return 0
    fi

    return 1
}
