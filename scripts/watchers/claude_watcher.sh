#!/usr/bin/env bash

set -euo pipefail

# Claude Code 监测模块

WATCHER_SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck disable=SC1091
source "$WATCHER_SCRIPT_DIR/../utils/log_utils.sh"
# shellcheck disable=SC1091
source "$WATCHER_SCRIPT_DIR/../utils/process_utils.sh"

CLAUDE_PROJECTS_DIR="${CLAUDE_PROJECTS_DIR:-$HOME/.claude/projects}"
CLAUDE_WATCH_INTERVAL="${CLAUDE_WATCH_INTERVAL:-1}"
CLAUDE_WATCHER_VERIFIED_MAX_VERSION="${CLAUDE_WATCHER_VERIFIED_MAX_VERSION:-2.1.314}"
CLAUDE_WATCH_SOURCE=""

claude_project_name_from_cwd() {
    local cwd="$1"

    if [ -n "$cwd" ]; then
        basename "$cwd"
    else
        printf 'unknown'
    fi
}

claude_build_turn_message() {
    local event_type="$1"
    local cwd="$2"
    local context="$3"
    local message

    case "$event_type" in
        turn_complete)
            message="Claude Code 当前这一问已经回答结束，可以继续下一轮提问。"
            ;;
        question_requested)
            message="Claude Code 向你提出了问题，请返回会话回答。"
            ;;
        *)
            message="Claude Code 状态发生变化。"
            ;;
    esac

    if [ -n "$cwd" ]; then
        message="${message} 项目：$(claude_project_name_from_cwd "$cwd")。"
    fi
    if [ -n "$context" ]; then
        message="${message} 最近工具：${context}。"
    fi

    printf '%s' "$message"
}

claude_emit_question_requested() {
    local notify_callback="$1"
    local session_id="$2"
    local tool_use_id="$3"
    local cwd="$4"

    local message
    message=$(claude_build_turn_message "question_requested" "$cwd" "")
    "$notify_callback" "claude" "question_requested" "$message" "$session_id" "$tool_use_id"
}

claude_emit_turn_complete() {
    local notify_callback="$1"
    local session_id="$2"
    local uuid="$3"
    local cwd="$4"
    local context="$5"

    local message
    message=$(claude_build_turn_message "turn_complete" "$cwd" "$context")
    "$notify_callback" "claude" "turn_complete" "$message" "$session_id" "$uuid"
}

claude_main_session_files() {
    find "$CLAUDE_PROJECTS_DIR" -mindepth 2 -maxdepth 2 -type f -name '*.jsonl' 2>/dev/null |
        sort
}

claude_recent_main_session_files() {
    local limit="$1"

    find "$CLAUDE_PROJECTS_DIR" -mindepth 2 -maxdepth 2 -type f -name '*.jsonl' -printf '%T@ %p\n' 2>/dev/null |
        sort -nr |
        head -n "$limit" |
        sed 's/^[^ ]* //'
}

claude_latest_main_session_file() {
    local newest

    newest=$(find "$CLAUDE_PROJECTS_DIR" -mindepth 2 -maxdepth 2 -type f -name '*.jsonl' -printf '%T@ %p\n' 2>/dev/null |
        sort -nr |
        head -n 1 |
        sed 's/^[^ ]* //')
    [ -n "$newest" ] || return 1

    printf '%s' "$newest"
}

claude_installed_version_detect() {
    local version

    if command -v claude >/dev/null 2>&1; then
        version=$(claude --version 2>/dev/null |
            sed -n 's/^[^0-9]*\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\).*/\1/p' |
            head -n 1)
        if [ -n "$version" ]; then
            printf '%s' "$version"
            return 0
        fi
    fi

    local latest_file
    if latest_file=$(claude_latest_main_session_file); then
        version=$(jq -r 'select(.version? != null) | .version' "$latest_file" 2>/dev/null | head -n 1 || true)
        if [ -n "$version" ]; then
            printf '%s' "$version"
            return 0
        fi
    fi

    return 1
}

claude_version_to_sort_key() {
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

claude_version_gt() {
    local left="$1"
    local right="$2"

    [ "$(claude_version_to_sort_key "$left")" \> "$(claude_version_to_sort_key "$right")" ]
}

claude_session_file_has_events() {
    local file_path="$1"
    local installed_version="$2"

    jq -nRr --arg version "$installed_version" '
        def text_of:
            if (.message.content? | type) == "string" then .message.content
            elif (.message.content? | type) == "array" then
                ([.message.content[]? | select(.type == "text") | (.text // "")] | join("\n"))
            else "" end;
        def is_user_question:
            .type == "user"
            and ((.isMeta // false) != true)
            and (((.promptSource? // "") == "typed")
                or ((.promptSource? // "") == "queued")
                or ((.origin.kind? // "") == "human"))
            and ((.message.content? | type) == "string"
                or (((.message.content? | type) == "array")
                    and (any(.message.content[]?; .type == "tool_result") | not)))
            and ((text_of | contains("[Request interrupted by user")) | not);
        reduce inputs as $raw (
            { seen: false, found: false };
            (($raw | fromjson?) // {}) as $event
            | if (($event | type) != "object") or ($event.isSidechain == true) then .
              elif (($event.version? // "") == $version and ($event | is_user_question)) then .seen = true
              elif .seen and (
                  ($event.type == "assistant" and (($event.message.stop_reason? // "") == "end_turn"))
                  or ($event.type == "system" and (($event.subtype? // "") == "turn_duration"))) then
                  .found = true
              else . end
        )
        | .found
    ' "$file_path" 2>/dev/null || true
}

claude_event_format_observed() {
    local installed_version="$1"
    local file

    while IFS= read -r file; do
        [ -n "$file" ] || continue
        case "$file" in
            */subagents/*) continue ;;
        esac

        if [ "$(claude_session_file_has_events "$file" "$installed_version")" = "true" ]; then
            return 0
        fi
    done < <(claude_recent_main_session_files 50)

    return 1
}

claude_compatibility_status() {
    local installed_version="$1"

    if [ -z "$installed_version" ]; then
        printf 'unknown'
        return
    fi

    if ! claude_version_gt "$installed_version" "$CLAUDE_WATCHER_VERIFIED_MAX_VERSION"; then
        printf 'ok'
        return
    fi

    if ! command -v jq >/dev/null 2>&1; then
        printf 'unknown'
        return
    fi

    if claude_event_format_observed "$installed_version"; then
        printf 'event format observed'
    else
        printf 'recheck needed'
    fi
}

claude_watcher_init() {
    if [ ! -d "$CLAUDE_PROJECTS_DIR" ]; then
        echo "Warning: Claude Code projects directory not found: $CLAUDE_PROJECTS_DIR" >&2
        return 1
    fi

    if ! command -v jq >/dev/null 2>&1; then
        echo "Warning: jq is required by the Claude Code watcher." >&2
        return 1
    fi

    CLAUDE_WATCH_SOURCE="projects_jsonl"
    return 0
}

watch_projects_jsonl() {
    local notify_callback="$1"
    local runtime_log="$2"

    declare -A claude_offset_by_file=()
    declare -A claude_size_by_file=()
    declare -A claude_signature_by_file=()
    declare -A claude_head_by_file=()
    declare -A claude_session_by_file=()
    declare -A claude_cwd_by_session=()
    declare -A claude_active_turn=()
    declare -A claude_notified_turn=()
    declare -A claude_last_tool=()
    declare -A claude_notified_question=()

    claude_seed_file_state() {
        local file_path="$1"
        local initial_offset="$2"
        local initial_signature="${3:-}"

        if [ -z "$initial_signature" ]; then
            initial_signature=$(stat -c '%s:%y' "$file_path" 2>/dev/null || true)
        fi

        claude_offset_by_file["$file_path"]="$initial_offset"
        claude_signature_by_file["$file_path"]="$initial_signature"
        claude_size_by_file["$file_path"]="$(wc -c < "$file_path" 2>/dev/null || echo "0")"
        claude_head_by_file["$file_path"]="$(sed -n '1p' "$file_path" 2>/dev/null || true)"
        claude_session_by_file["$file_path"]="$(basename "$file_path" .jsonl)"
    }

    claude_process_line() {
        local file_path="$1"
        local line="$2"
        local is_sidechain event_type subtype stop_reason session_id cwd uuid
        local content_kind has_tool_result text ask_ids last_tool prompt_source origin_kind is_meta projected
        local tool_id question_key

        case "$line" in
            *'"type":"assistant"'*|*'"type":"user"'*|*'"type":"system"'*|\
            *'"type": "assistant"'*|*'"type": "user"'*|*'"type": "system"'*) ;;
            *) return 0 ;;
        esac

        projected=$(printf '%s\n' "$line" | jq -r '
            select(type == "object")
            | {
                is_sidechain: (.isSidechain == true),
                type: (.type // ""),
                subtype: (.subtype // ""),
                stop_reason: (.message.stop_reason // ""),
                session_id: (.sessionId // ""),
                cwd: (.cwd // ""),
                uuid: (.uuid // ""),
                content_kind: (.message.content? | type),
                has_tool_result: (
                    if (.message.content? | type) == "array"
                    then any(.message.content[]?; .type == "tool_result")
                    else false end
                ),
                text: (
                    if (.message.content? | type) == "string" then .message.content
                    elif (.message.content? | type) == "array" then
                        ([.message.content[]? | select(.type == "text") | (.text // "")] | join(" "))
                    else "" end
                ),
                ask_ids: ([.message.content[]? | select(.type == "tool_use" and .name == "AskUserQuestion") | (.id // "")] | join(",")),
                last_tool: ([.message.content[]? | select(.type == "tool_use" and .name != "AskUserQuestion") | (.name // "")] | last // ""),
                prompt_source: (.promptSource // ""),
                origin_kind: (.origin.kind // ""),
                is_meta: (.isMeta == true)
            }
            | [ .is_sidechain, .type, .subtype, .stop_reason, .session_id, .cwd, .uuid,
                .content_kind, .has_tool_result, .text, .ask_ids, .last_tool, .prompt_source, .origin_kind, .is_meta ]
            | map(tostring | gsub("[\r\n\t\u001f]"; " ")) | join("\u001f")
        ' 2>/dev/null) || return 0
        [ -n "$projected" ] || return 0

        IFS=$'\x1f' read -r is_sidechain event_type subtype stop_reason session_id cwd uuid \
            content_kind has_tool_result text ask_ids last_tool prompt_source origin_kind is_meta <<< "$projected" || true

        if [ "$is_sidechain" = "true" ]; then
            return 0
        fi

        if [ -z "$session_id" ]; then
            session_id="${claude_session_by_file[$file_path]:-$(basename "$file_path" .jsonl)}"
        fi
        if [ -n "$cwd" ]; then
            claude_cwd_by_session["$session_id"]="$cwd"
        else
            cwd="${claude_cwd_by_session[$session_id]:-}"
        fi

        case "$event_type" in
            user)
                if [ "$content_kind" != "string" ] && [ "$content_kind" != "array" ]; then
                    return 0
                fi

                if [[ "$text" == *"[Request interrupted by user"* ]]; then
                    claude_active_turn["$session_id"]=0
                    claude_notified_turn["$session_id"]=1
                    return 0
                fi

                if [ "$has_tool_result" = "true" ]; then
                    return 0
                fi

                # 只有用户输入（typed/queued 或 origin.kind=human）才开启新一轮。
                # 后台任务通知（promptSource=system）、system-reminder（isMeta=true）
                # 和斜杠命令输出都不会触发完成通知。
                if [ "$is_meta" = "true" ]; then
                    return 0
                fi
                case "$prompt_source" in
                    typed|queued) ;;
                    *)
                        if [ "$origin_kind" != "human" ]; then
                            return 0
                        fi
                        ;;
                esac

                claude_active_turn["$session_id"]=1
                claude_notified_turn["$session_id"]=0
                unset "claude_last_tool[$session_id]"
                ;;
            assistant)
                if [ -n "$ask_ids" ]; then
                    local -a ask_tool_ids=()
                    IFS=',' read -r -a ask_tool_ids <<< "$ask_ids"
                    for tool_id in "${ask_tool_ids[@]}"; do
                        [ -n "$tool_id" ] || continue
                        question_key="${session_id}|${tool_id}"
                        if [ -z "${claude_notified_question[$question_key]:-}" ]; then
                            claude_notified_question["$question_key"]=1
                            claude_emit_question_requested \
                                "$notify_callback" \
                                "$session_id" \
                                "$tool_id" \
                                "$cwd"
                        fi
                    done
                fi

                if [ -n "$last_tool" ]; then
                    claude_last_tool["$session_id"]="$last_tool"
                fi

                if [ "$stop_reason" = "end_turn" ] && \
                    [ "${claude_active_turn[$session_id]:-0}" = "1" ] && \
                    [ "${claude_notified_turn[$session_id]:-0}" = "0" ]; then
                    claude_emit_turn_complete \
                        "$notify_callback" \
                        "$session_id" \
                        "$uuid" \
                        "$cwd" \
                        "${claude_last_tool[$session_id]:-}"
                    claude_notified_turn["$session_id"]=1
                    claude_active_turn["$session_id"]=0
                fi
                ;;
            system)
                if [ "$subtype" = "turn_duration" ] && \
                    [ "${claude_active_turn[$session_id]:-0}" = "1" ] && \
                    [ "${claude_notified_turn[$session_id]:-0}" = "0" ]; then
                    claude_emit_turn_complete \
                        "$notify_callback" \
                        "$session_id" \
                        "$uuid" \
                        "$cwd" \
                        "${claude_last_tool[$session_id]:-}"
                    claude_notified_turn["$session_id"]=1
                    claude_active_turn["$session_id"]=0
                fi
                ;;
        esac

        return 0
    }

    local file line_count file_size current_head file_signature discovered known_file
    while IFS= read -r file; do
        [ -n "$file" ] || continue
        case "$file" in
            */subagents/*) continue ;;
        esac
        file_signature=$(stat -c '%s:%y' "$file" 2>/dev/null || true)
        [ -n "$file_signature" ] || continue
        line_count=$(wc -l < "$file" 2>/dev/null || echo "0")
        claude_seed_file_state "$file" "$line_count" "$file_signature"
    done < <(claude_main_session_files)
    append_log "$runtime_log" "claude_watcher ready pid=$$ source=projects_jsonl"

    while true; do
        local files=()
        mapfile -t files < <(claude_main_session_files)

        local -A file_signatures=()
        if [ "${#files[@]}" -gt 0 ]; then
            # NUL delimiters preserve paths; xargs splits batches at the argument limit.
            while IFS= read -r -d '' file && IFS= read -r -d '' file_signature; do
                file_signatures["$file"]="$file_signature"
            done < <(printf '%s\0' "${files[@]}" |
                xargs -0 -r stat --printf '%n\0%s:%y\0' -- 2>/dev/null || true)
        fi

        for known_file in "${!claude_offset_by_file[@]}"; do
            if [ ! -f "$known_file" ]; then
                append_log "$runtime_log" "claude_watcher remove missing file=$known_file"
                unset "claude_offset_by_file[$known_file]"
                unset "claude_size_by_file[$known_file]"
                unset "claude_signature_by_file[$known_file]"
                unset "claude_head_by_file[$known_file]"
                unset "claude_session_by_file[$known_file]"
            fi
        done

        for file in "${files[@]}"; do
            [ -n "$file" ] || continue
            case "$file" in
                */subagents/*) continue ;;
            esac
            discovered=0

            if [ -z "${claude_offset_by_file[$file]+set}" ]; then
                append_log "$runtime_log" "claude_watcher discovered file=$file"
                claude_seed_file_state "$file" 0
                discovered=1
            fi

            file_signature="${file_signatures[$file]:-}"
            [ -n "$file_signature" ] || continue
            if [ "$discovered" -eq 0 ] && [ "$file_signature" = "${claude_signature_by_file[$file]:-}" ]; then
                continue
            fi

            line_count=$(wc -l < "$file" 2>/dev/null || echo "0")
            file_size=${file_signature%%:*}
            current_head=$(sed -n '1p' "$file" 2>/dev/null || true)
            if [ "$line_count" -lt "${claude_offset_by_file[$file]:-0}" ] || {
                [ -n "${claude_size_by_file[$file]:-}" ] && \
                    [ "$file_size" -lt "${claude_size_by_file[$file]:-}" ]
            } || {
                [ -n "${claude_head_by_file[$file]:-}" ] && \
                    [ "$current_head" != "${claude_head_by_file[$file]:-}" ]
            }; then
                append_log "$runtime_log" "claude_watcher reset file=$file previous_offset=${claude_offset_by_file[$file]:-0} line_count=$line_count previous_size=${claude_size_by_file[$file]:-unknown} file_size=$file_size"
                claude_seed_file_state "$file" 0
            fi

            claude_signature_by_file["$file"]="$file_signature"

            if [ "$line_count" -le "${claude_offset_by_file[$file]:-0}" ]; then
                claude_size_by_file["$file"]="$file_size"
                continue
            fi

            while IFS= read -r line; do
                claude_process_line "$file" "$line"
            done < <(sed -n "$((claude_offset_by_file[$file] + 1)),${line_count}p" "$file")

            claude_offset_by_file["$file"]="$line_count"
            claude_size_by_file["$file"]="$file_size"
            claude_head_by_file["$file"]="$current_head"
        done

        sleep "$CLAUDE_WATCH_INTERVAL"
    done
}

claude_watcher_run() {
    local notify_callback="$1"
    local runtime_log="$2"

    if [ ! -d "$CLAUDE_PROJECTS_DIR" ]; then
        append_log "$runtime_log" "claude_watcher failed source=unresolved projects=$CLAUDE_PROJECTS_DIR"
        return 1
    fi

    if ! command -v jq >/dev/null 2>&1; then
        append_log "$runtime_log" "claude_watcher failed source=unresolved reason=jq-missing"
        return 1
    fi

    CLAUDE_WATCH_SOURCE="projects_jsonl"
    append_log "$runtime_log" "claude_watcher started source=projects_jsonl projects=$CLAUDE_PROJECTS_DIR"
    watch_projects_jsonl "$notify_callback" "$runtime_log"
}
