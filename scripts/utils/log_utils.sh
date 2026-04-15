#!/bin/bash

# 日志工具函数

append_log() {
    local log_file="$1"
    local message="$2"

    mkdir -p "$(dirname "$log_file")"
    printf '%s %s\n' "$(date '+%F %T')" "$message" >> "$log_file"
}

extract_with_sed() {
    local line="$1"
    local expr="$2"

    printf '%s\n' "$line" | sed -n "$expr"
}
