#!/usr/bin/env bash

set -euo pipefail

# Codex 监测模块

WATCHER_SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck disable=SC1091
source "$WATCHER_SCRIPT_DIR/../utils/log_utils.sh"
# shellcheck disable=SC1091
source "$WATCHER_SCRIPT_DIR/../utils/process_utils.sh"

CODEX_LOG_FILE="${CODEX_LOG_FILE:-$HOME/.codex/log/codex-tui.log}"
CODEX_SESSIONS_DIR="${CODEX_SESSIONS_DIR:-$HOME/.codex/sessions}"
CODEX_VERSION_FILE="${CODEX_VERSION_FILE:-$HOME/.codex/version.json}"
CODEX_CLI_PACKAGE_FILE="${CODEX_CLI_PACKAGE_FILE:-$HOME/.nvm/versions/node/v24.1.0/lib/node_modules/@openai/codex/package.json}"
CODEX_WATCH_SOURCE=""
CODEX_WATCHER_VERIFIED_MAX_VERSION="${CODEX_WATCHER_VERIFIED_MAX_VERSION:-0.137.0}"

extract_thread_id() {
    local line="$1"
    local thread_id

    thread_id=$(extract_with_sed "$line" 's/.*thread_id=\([^}: ]*\).*/\1/p')
    if [ -n "$thread_id" ]; then
        printf '%s' "$thread_id"
        return
    fi

    extract_with_sed "$line" 's/.*thread\.id=\([^} ]*\).*/\1/p'
}

extract_turn_id() {
    extract_with_sed "$1" 's/.*turn\.id=\([^} ]*\).*/\1/p'
}

is_valid_map_key() {
    local key="${1:-}"

    [ -n "$key" ] && [[ "$key" != *"]"* ]]
}

is_user_turn_line() {
    local line="$1"

    printf '%s\n' "$line" | grep -Eq 'codex\.op="user_input[^"]*"'
}

is_interrupt_line() {
    local line="$1"

    printf '%s\n' "$line" | grep -q 'codex.op="interrupt"' && \
        printf '%s\n' "$line" | grep -q 'interrupt received: abort current task, if any'
}

summarize_legacy_tool_call() {
    local line="$1"
    local command

    if printf '%s\n' "$line" | grep -q 'ToolCall: exec_command '; then
        command=$(printf '%s\n' "$line" | sed -n 's/.*ToolCall: exec_command {"cmd":"\([^"]*\)".*/\1/p')
        command=${command//\\\"/\"}
        command=${command//\\\\/\\}
        printf 'exec_command %s' "${command:-unknown}"
        return
    fi

    if printf '%s\n' "$line" | grep -q 'ToolCall: apply_patch '; then
        printf 'apply_patch'
        return
    fi

    printf '%s\n' "$line" | sed 's/.*ToolCall: //'
}

extract_legacy_tool_cwd() {
    local line="$1"
    local cwd

    cwd=$(printf '%s\n' "$line" | sed -n 's/.*"workdir":"\([^"]*\)".*/\1/p')
    cwd=${cwd//\\\"/\"}
    cwd=${cwd//\\\\/\\}
    printf '%s' "$cwd"
}

project_name_from_cwd() {
    local cwd="$1"

    if [ -n "$cwd" ]; then
        basename "$cwd"
    else
        printf 'unknown'
    fi
}

build_turn_message() {
    local event_type="$1"
    local cwd="$2"
    local context="$3"
    local message

    case "$event_type" in
        turn_complete)
            message="Codex 当前这一问已经回答结束，可以继续下一轮提问。"
            ;;
        turn_interrupted)
            message="Codex 当前这一问已被中断。"
            ;;
        *)
            message="Codex 状态发生变化。"
            ;;
    esac

    if [ -n "$cwd" ]; then
        message="${message} 项目：$(project_name_from_cwd "$cwd")。cwd：${cwd}。"
    fi
    if [ -n "$context" ]; then
        message="${message} 最近命令：${context}。"
    fi

    printf '%s' "$message"
}

rollout_session_id_from_file() {
    local file_path="$1"
    local file_name
    local session_id

    file_name=$(basename "$file_path")
    session_id=$(printf '%s\n' "$file_name" | sed -E 's/^rollout-[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}-[0-9]{2}-[0-9]{2}-([0-9a-f-]+)\.jsonl$/\1/')
    if [ "$session_id" = "$file_name" ]; then
        printf ''
        return
    fi

    printf '%s' "$session_id"
}

extract_rollout_string_field() {
    local line="$1"
    local field="$2"
    local value

    value=$(printf '%s\n' "$line" | sed -n "s/.*\"$field\":\"\\([^\"]*\\)\".*/\\1/p")
    value=${value//\\\"/\"}
    value=${value//\\\\/\\}
    printf '%s' "$value"
}

resolve_codex_watch_source() {
    if [ -f "$CODEX_LOG_FILE" ]; then
        CODEX_WATCH_SOURCE="legacy_log"
        return 0
    fi

    if [ -d "$CODEX_SESSIONS_DIR" ]; then
        CODEX_WATCH_SOURCE="rollout_jsonl"
        return 0
    fi

    CODEX_WATCH_SOURCE=""
    return 1
}

codex_installed_version_detect() {
    local version_line
    local version

    if command -v codex >/dev/null 2>&1; then
        version=$(codex --version 2>/dev/null | sed -n 's/^codex-cli[[:space:]]\+\([^[:space:]]\+\)$/\1/p')
        if [ -n "$version" ]; then
            printf '%s' "$version"
            return 0
        fi
    fi

    if [ -f "$CODEX_CLI_PACKAGE_FILE" ]; then
        version_line=$(sed -n '1,40p' "$CODEX_CLI_PACKAGE_FILE" 2>/dev/null || true)
        version=$(printf '%s\n' "$version_line" | sed -n 's/.*"version":[[:space:]]*"\([^"]*\)".*/\1/p')
        if [ -n "$version" ]; then
            printf '%s' "$version"
            return 0
        fi
    fi

    return 1
}

codex_latest_version_detect() {
    local version_line
    local version

    if [ -f "$CODEX_VERSION_FILE" ]; then
        version_line=$(sed -n '1p' "$CODEX_VERSION_FILE" 2>/dev/null || true)
        version=$(printf '%s\n' "$version_line" | sed -n 's/.*"latest_version":"\([^"]*\)".*/\1/p')
        if [ -n "$version" ]; then
            printf '%s' "$version"
            return 0
        fi
    fi

    return 1
}

version_to_sort_key() {
    local version="$1"

    printf '%s\n' "$version" | awk -F. '
        {
            major = ($1 == "" ? 0 : $1)
            minor = ($2 == "" ? 0 : $2)
            patch = ($3 == "" ? 0 : $3)
            printf "%09d%09d%09d\n", major, minor, patch
        }
    '
}

version_gt() {
    local left="$1"
    local right="$2"

    [ "$(version_to_sort_key "$left")" \> "$(version_to_sort_key "$right")" ]
}

codex_compatibility_status() {
    local installed_version="$1"

    if [ -z "$installed_version" ]; then
        printf 'unknown'
        return
    fi

    if version_gt "$installed_version" "$CODEX_WATCHER_VERIFIED_MAX_VERSION"; then
        printf 'recheck needed'
        return
    fi

    printf 'ok'
}

codex_watcher_init() {
    if resolve_codex_watch_source; then
        return 0
    fi

    echo "Warning: no supported Codex watcher source found. checked log=$CODEX_LOG_FILE sessions=$CODEX_SESSIONS_DIR" >&2
    return 1
}

emit_turn_interrupted() {
    local notify_callback="$1"
    local thread_id="$2"
    local turn_id="$3"
    local cwd="$4"
    local context="$5"

    local message
    message=$(build_turn_message "turn_interrupted" "$cwd" "$context")
    "$notify_callback" "codex" "turn_interrupted" "$message" "$thread_id" "$turn_id"
}

emit_turn_complete() {
    local notify_callback="$1"
    local thread_id="$2"
    local turn_id="$3"
    local cwd="$4"
    local context="$5"

    local message
    message=$(build_turn_message "turn_complete" "$cwd" "$context")
    "$notify_callback" "codex" "turn_complete" "$message" "$thread_id" "$turn_id"
}

watch_rollout_jsonl() {
    local notify_callback="$1"
    local runtime_log="$2"
    local sessions_dir="$3"

    declare -A rollout_offset_by_file=()
    declare -A rollout_session_by_file=()
    declare -A session_cwd_by_id=()
    declare -A active_turn_by_session=()
    declare -A turn_context_by_id=()
    declare -A turn_cwd_by_id=()
    declare -A turn_interrupted_by_id=()

    seed_rollout_file_state() {
        local file_path="$1"
        local initial_offset="$2"
        local session_line session_id cwd

        rollout_offset_by_file["$file_path"]="$initial_offset"
        session_id=$(rollout_session_id_from_file "$file_path")
        if [ -n "$session_id" ]; then
            rollout_session_by_file["$file_path"]="$session_id"
        fi

        session_line=$(sed -n '1p' "$file_path" 2>/dev/null || true)
        if printf '%s\n' "$session_line" | grep -q '"type":"session_meta"'; then
            session_id=$(extract_rollout_string_field "$session_line" "id")
            cwd=$(extract_rollout_string_field "$session_line" "cwd")
            if is_valid_map_key "$session_id"; then
                rollout_session_by_file["$file_path"]="$session_id"
                session_cwd_by_id["$session_id"]="$cwd"
            fi
        fi
    }

    process_rollout_line() {
        local file_path="$1"
        local line="$2"
        local session_id payload_type turn_id cwd context

        session_id="${rollout_session_by_file[$file_path]:-}"
        payload_type=$(printf '%s\n' "$line" | sed -n 's/.*"payload":{"type":"\([^"]*\)".*/\1/p')

        if printf '%s\n' "$line" | grep -q '"type":"session_meta"'; then
            session_id=$(extract_rollout_string_field "$line" "id")
            cwd=$(extract_rollout_string_field "$line" "cwd")
            if is_valid_map_key "$session_id"; then
                rollout_session_by_file["$file_path"]="$session_id"
                session_cwd_by_id["$session_id"]="$cwd"
            fi
            return
        fi

        if [ "$payload_type" = "task_started" ]; then
            turn_id=$(extract_rollout_string_field "$line" "turn_id")
            if is_valid_map_key "$session_id" && is_valid_map_key "$turn_id"; then
                active_turn_by_session["$session_id"]="$turn_id"
                turn_interrupted_by_id["$turn_id"]=0
                unset "turn_context_by_id[$turn_id]"
                unset "turn_cwd_by_id[$turn_id]"

                cwd="${session_cwd_by_id[$session_id]:-}"
                if [ -n "$cwd" ]; then
                    turn_cwd_by_id["$turn_id"]="$cwd"
                fi
            fi
            return
        fi

        if [ "$payload_type" = "function_call" ]; then
            turn_id="${active_turn_by_session[$session_id]:-}"
            if ! is_valid_map_key "$turn_id"; then
                return
            fi

            if printf '%s\n' "$line" | grep -q '"name":"exec_command"'; then
                context=$(printf '%s\n' "$line" | sed -n 's/.*"name":"exec_command".*"cmd":"\([^"]*\)".*/exec_command \1/p')
                context=${context//\\\"/\"}
                context=${context//\\\\/\\}
                turn_context_by_id["$turn_id"]="${context:-exec_command}"

                cwd=$(extract_rollout_string_field "$line" "workdir")
                if [ -n "$cwd" ]; then
                    turn_cwd_by_id["$turn_id"]="$cwd"
                fi
                return
            fi

            if printf '%s\n' "$line" | grep -q '"name":"apply_patch"'; then
                turn_context_by_id["$turn_id"]="apply_patch"
            fi
            return
        fi

        if [ "$payload_type" = "turn_aborted" ]; then
            turn_id=$(extract_rollout_string_field "$line" "turn_id")
            if ! is_valid_map_key "$turn_id"; then
                return
            fi

            turn_interrupted_by_id["$turn_id"]=1
            emit_turn_interrupted \
                "$notify_callback" \
                "${session_id:-unknown}" \
                "$turn_id" \
                "${turn_cwd_by_id[$turn_id]:-${session_cwd_by_id[$session_id]:-}}" \
                "${turn_context_by_id[$turn_id]:-}"
            unset "active_turn_by_session[$session_id]"
            return
        fi

        if [ "$payload_type" != "task_complete" ] && [ "$payload_type" != "task_failed" ]; then
            return
        fi

        turn_id=$(extract_rollout_string_field "$line" "turn_id")
        if ! is_valid_map_key "$turn_id"; then
            return
        fi

        if [ "${turn_interrupted_by_id[$turn_id]:-0}" != "1" ]; then
            emit_turn_complete \
                "$notify_callback" \
                "${session_id:-unknown}" \
                "$turn_id" \
                "${turn_cwd_by_id[$turn_id]:-${session_cwd_by_id[$session_id]:-}}" \
                "${turn_context_by_id[$turn_id]:-}"
        fi

        unset "active_turn_by_session[$session_id]"
        unset "turn_context_by_id[$turn_id]"
        unset "turn_cwd_by_id[$turn_id]"
        unset "turn_interrupted_by_id[$turn_id]"
    }

    local file line_count
    while IFS= read -r file; do
        [ -n "$file" ] || continue
        line_count=$(wc -l < "$file" 2>/dev/null || echo "0")
        seed_rollout_file_state "$file" "$line_count"
    done < <(find "$sessions_dir" -type f -name 'rollout-*.jsonl' 2>/dev/null | sort)

    while true; do
        local files=()
        mapfile -t files < <(find "$sessions_dir" -type f -name 'rollout-*.jsonl' 2>/dev/null | sort)

        for file in "${files[@]}"; do
            [ -n "$file" ] || continue

            if [ -z "${rollout_offset_by_file[$file]:-}" ]; then
                append_log "$runtime_log" "codex_watcher discovered rollout file=$file"
                seed_rollout_file_state "$file" 0
            fi

            line_count=$(wc -l < "$file" 2>/dev/null || echo "0")
            if [ "$line_count" -le "${rollout_offset_by_file[$file]:-0}" ]; then
                continue
            fi

            while IFS= read -r line; do
                process_rollout_line "$file" "$line"
            done < <(sed -n "$((rollout_offset_by_file[$file] + 1)),$line_count p" "$file")

            rollout_offset_by_file["$file"]="$line_count"
        done

        sleep 1
    done
}

watch_legacy_log() {
    local notify_callback="$1"
    local runtime_log="$2"
    local last_tool_thread=""
    local last_tool_cwd=""
    local tool_cwd=""
    declare -A active_turn_by_thread=()
    declare -A turn_context_by_thread=()
    declare -A turn_cwd_by_thread=()
    declare -A turn_interrupted_by_thread=()

    while IFS= read -r line; do
        local thread_id turn_id active_turn turn_context turn_cwd

        if is_user_turn_line "$line" && printf '%s\n' "$line" | grep -q 'codex_core::tasks: new'; then
            thread_id=$(extract_thread_id "$line")
            turn_id=$(extract_turn_id "$line")

            if is_valid_map_key "$thread_id" && [ -n "$turn_id" ]; then
                active_turn_by_thread["$thread_id"]="$turn_id"
                turn_interrupted_by_thread["$thread_id"]=0
                unset "turn_context_by_thread[$thread_id]"
                unset "turn_cwd_by_thread[$thread_id]"
            fi
        fi

        if printf '%s\n' "$line" | grep -q 'ToolCall:'; then
            last_tool_thread=$(extract_thread_id "$line")
            tool_cwd=$(extract_legacy_tool_cwd "$line")
            if [ -n "$tool_cwd" ]; then
                last_tool_cwd="$tool_cwd"
            fi

            if is_valid_map_key "$last_tool_thread" && [ -n "${active_turn_by_thread[$last_tool_thread]:-}" ]; then
                turn_context_by_thread["$last_tool_thread"]=$(summarize_legacy_tool_call "$line")
                if [ -n "$last_tool_cwd" ]; then
                    turn_cwd_by_thread["$last_tool_thread"]="$last_tool_cwd"
                fi
            fi
        fi

        if is_interrupt_line "$line"; then
            thread_id=$(extract_thread_id "$line")
            if ! is_valid_map_key "$thread_id"; then
                continue
            fi

            active_turn="${active_turn_by_thread[$thread_id]:-}"

            if [ -n "$active_turn" ]; then
                turn_interrupted_by_thread["$thread_id"]=1
                emit_turn_interrupted \
                    "$notify_callback" \
                    "$thread_id" \
                    "$active_turn" \
                    "${turn_cwd_by_thread[$thread_id]:-}" \
                    "${turn_context_by_thread[$thread_id]:-}"
            fi
        fi

        if ! is_user_turn_line "$line"; then
            continue
        fi

        if ! printf '%s\n' "$line" | grep -q 'codex_core::tasks: close'; then
            continue
        fi

        thread_id=$(extract_thread_id "$line")
        turn_id=$(extract_turn_id "$line")

        if ! is_valid_map_key "$thread_id" || [ -z "$turn_id" ]; then
            continue
        fi

        active_turn="${active_turn_by_thread[$thread_id]:-}"
        if [ "$turn_id" != "$active_turn" ]; then
            continue
        fi

        turn_context="${turn_context_by_thread[$thread_id]:-}"
        turn_cwd="${turn_cwd_by_thread[$thread_id]:-}"

        if [ "${turn_interrupted_by_thread[$thread_id]:-0}" != "1" ]; then
            emit_turn_complete "$notify_callback" "$thread_id" "$turn_id" "$turn_cwd" "$turn_context"
        fi

        unset "active_turn_by_thread[$thread_id]"
        unset "turn_context_by_thread[$thread_id]"
        unset "turn_cwd_by_thread[$thread_id]"
        unset "turn_interrupted_by_thread[$thread_id]"
    done < <(tail -n 0 -F "$CODEX_LOG_FILE" 2>/dev/null)
}

codex_watcher_run() {
    local notify_callback="$1"
    local runtime_log="$2"

    resolve_codex_watch_source

    case "$CODEX_WATCH_SOURCE" in
        legacy_log)
            append_log "$runtime_log" "codex_watcher started source=legacy_log log=$CODEX_LOG_FILE"
            watch_legacy_log "$notify_callback" "$runtime_log"
            ;;
        rollout_jsonl)
            append_log "$runtime_log" "codex_watcher started source=rollout_jsonl sessions=$CODEX_SESSIONS_DIR"
            watch_rollout_jsonl "$notify_callback" "$runtime_log" "$CODEX_SESSIONS_DIR"
            ;;
        *)
            append_log "$runtime_log" "codex_watcher failed source=unresolved"
            return 1
            ;;
    esac
}
