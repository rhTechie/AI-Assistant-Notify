#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
TMP_DIR=$(mktemp -d)
MOCK_SEQUENCE_FILE="$TMP_DIR/responses"
MOCK_CALL_COUNT_FILE="$TMP_DIR/call-count"
MOCK_ARGS_LOG="$TMP_DIR/curl-args.log"
MOCK_SLEEP_LOG="$TMP_DIR/sleep.log"
MOCK_PAYLOAD_FILE="$TMP_DIR/payload.json"
STDOUT_FILE="$TMP_DIR/stdout.log"
STDERR_FILE="$TMP_DIR/stderr.log"
LAST_RC=0

cleanup() {
    rm -rf "$TMP_DIR"
}

trap cleanup EXIT

# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib_notify.sh"

fail() {
    echo "Test failed: $*" >&2
    exit 1
}

assert_equals() {
    local expected="$1"
    local actual="$2"
    local description="$3"

    if [ "$actual" != "$expected" ]; then
        fail "$description (expected=$expected actual=$actual)"
    fi
}

assert_file_contains() {
    local expected="$1"
    local file_path="$2"

    if ! grep -F -- "$expected" "$file_path" >/dev/null 2>&1; then
        echo "Expected to find: $expected" >&2
        echo "File contents:" >&2
        cat "$file_path" >&2
        exit 1
    fi
}

assert_file_not_contains() {
    local unexpected="$1"
    local file_path="$2"

    if grep -F -- "$unexpected" "$file_path" >/dev/null 2>&1; then
        echo "Did not expect to find: $unexpected" >&2
        echo "File contents:" >&2
        cat "$file_path" >&2
        exit 1
    fi
}

reset_config() {
    export CODEX_FEISHU_WEBHOOK="https://mock.invalid/webhook"
    export CODEX_FEISHU_KEYWORD="CodexTest"
    export FEISHU_NOTIFY_CONNECT_TIMEOUT_SECONDS=5
    export FEISHU_NOTIFY_MAX_TIME_SECONDS=15
    export FEISHU_NOTIFY_MAX_ATTEMPTS=3
    export FEISHU_NOTIFY_RETRY_BACKOFF_SECONDS=0
}

set_mock_responses() {
    printf '%s\n' "$@" > "$MOCK_SEQUENCE_FILE"
    printf '0\n' > "$MOCK_CALL_COUNT_FILE"
    : > "$MOCK_ARGS_LOG"
    : > "$MOCK_SLEEP_LOG"
    : > "$MOCK_PAYLOAD_FILE"
    : > "$STDOUT_FILE"
    : > "$STDERR_FILE"
}

mock_call_count() {
    sed -n '1p' "$MOCK_CALL_COUNT_FILE"
}

curl() {
    local output_file=""
    local payload=""
    local call_number
    local response_line
    local mock_exit
    local mock_http
    local mock_body
    local mock_stderr

    call_number=$(sed -n '1p' "$MOCK_CALL_COUNT_FILE")
    call_number=$((call_number + 1))
    printf '%s\n' "$call_number" > "$MOCK_CALL_COUNT_FILE"

    printf 'CALL=%s\n' "$call_number" >> "$MOCK_ARGS_LOG"
    for argument in "$@"; do
        printf 'ARG=%s\n' "$argument" >> "$MOCK_ARGS_LOG"
    done

    while [ "$#" -gt 0 ]; do
        case "$1" in
            -o)
                output_file="$2"
                shift 2
                ;;
            -d)
                payload="$2"
                shift 2
                ;;
            *)
                shift
                ;;
        esac
    done

    if [ -z "$output_file" ]; then
        echo "mock curl did not receive -o" >&2
        return 98
    fi

    response_line=$(sed -n "${call_number}p" "$MOCK_SEQUENCE_FILE")
    if [ -z "$response_line" ]; then
        echo "mock curl has no response for call $call_number" >&2
        return 97
    fi

    IFS='|' read -r mock_exit mock_http mock_body mock_stderr <<< "$response_line"
    printf '%s' "$mock_body" > "$output_file"
    printf '%s' "$payload" > "$MOCK_PAYLOAD_FILE"
    if [ -n "$mock_stderr" ]; then
        printf '%s\n' "$mock_stderr" >&2
    fi
    printf '%s' "$mock_http"
    return "$mock_exit"
}

sleep() {
    printf '%s\n' "$1" >> "$MOCK_SLEEP_LOG"
}

run_notification() {
    if send_feishu_notification codex "mock notification" >"$STDOUT_FILE" 2>"$STDERR_FILE"; then
        LAST_RC=0
    else
        LAST_RC=$?
    fi
}

assert_call_count() {
    assert_equals "$1" "$(mock_call_count)" "$2"
}

test_success_uses_default_timeouts() {
    reset_config
    unset FEISHU_NOTIFY_CONNECT_TIMEOUT_SECONDS
    unset FEISHU_NOTIFY_MAX_TIME_SECONDS
    set_mock_responses '0|200|{"code":0}|'

    run_notification

    assert_equals 0 "$LAST_RC" "successful notification return code"
    assert_call_count 1 "successful notification call count"
    assert_file_contains 'ARG=--connect-timeout' "$MOCK_ARGS_LOG"
    assert_file_contains 'ARG=5' "$MOCK_ARGS_LOG"
    assert_file_contains 'ARG=--max-time' "$MOCK_ARGS_LOG"
    assert_file_contains 'ARG=15' "$MOCK_ARGS_LOG"
    assert_file_contains 'CodexTest' "$MOCK_PAYLOAD_FILE"
}

test_timeout_overrides_are_forwarded() {
    reset_config
    export FEISHU_NOTIFY_CONNECT_TIMEOUT_SECONDS=4
    export FEISHU_NOTIFY_MAX_TIME_SECONDS=17
    set_mock_responses '0|200|{"StatusCode":0}|'

    run_notification

    assert_equals 0 "$LAST_RC" "timeout override return code"
    assert_file_contains 'ARG=4' "$MOCK_ARGS_LOG"
    assert_file_contains 'ARG=17' "$MOCK_ARGS_LOG"
}

test_curl_error_preserves_status_and_stderr() {
    reset_config
    export FEISHU_NOTIFY_MAX_ATTEMPTS=1
    set_mock_responses '7|000||mock connection refused'

    run_notification

    assert_equals 1 "$LAST_RC" "curl failure return code"
    assert_call_count 1 "single-attempt curl failure call count"
    assert_file_contains 'curl_exit=7' "$STDERR_FILE"
    assert_file_contains 'http_code=000' "$STDERR_FILE"
    assert_file_contains 'mock connection refused' "$STDERR_FILE"
}

test_pre_send_curl_failures_retry() {
    local exit_code

    for exit_code in 5 6 7; do
        reset_config
        export FEISHU_NOTIFY_MAX_ATTEMPTS=2
        export FEISHU_NOTIFY_RETRY_BACKOFF_SECONDS=2
        set_mock_responses \
            "$exit_code|000||pre-send failure $exit_code" \
            '0|200|{"code":0}|'

        run_notification

        assert_equals 0 "$LAST_RC" "curl $exit_code retry return code"
        assert_call_count 2 "curl $exit_code retry call count"
        assert_file_contains '2' "$MOCK_SLEEP_LOG"
    done
}

test_feishu_rate_limit_retries() {
    reset_config
    set_mock_responses \
        '0|200|{"code":11232,"msg":"frequency limited"}|' \
        '0|200|{"code":0}|'

    run_notification

    assert_equals 0 "$LAST_RC" "Feishu rate-limit retry return code"
    assert_call_count 2 "Feishu rate-limit retry call count"
}

test_retryable_http_statuses_retry() {
    local http_code

    for http_code in 408 429 503; do
        reset_config
        set_mock_responses \
            "0|$http_code|{\"error\":\"temporary\"}|" \
            '0|200|{"code":0}|'

        run_notification

        assert_equals 0 "$LAST_RC" "HTTP $http_code retry return code"
        assert_call_count 2 "HTTP $http_code retry call count"
    done
}

test_permanent_failures_do_not_retry() {
    reset_config
    set_mock_responses '0|400|{"code":19001,"msg":"bad request"}|'
    run_notification
    assert_equals 1 "$LAST_RC" "HTTP 400 return code"
    assert_call_count 1 "HTTP 400 call count"
    assert_file_contains 'HTTP 400' "$STDERR_FILE"
    assert_file_contains 'bad request' "$STDERR_FILE"

    reset_config
    set_mock_responses '0|200|{"code":19002,"msg":"invalid signature"}|'
    run_notification
    assert_equals 1 "$LAST_RC" "permanent business error return code"
    assert_call_count 1 "permanent business error call count"
    assert_file_contains 'invalid signature' "$STDERR_FILE"
}

test_ambiguous_timeout_does_not_retry() {
    reset_config
    set_mock_responses '28|000||operation timed out after upload'

    run_notification

    assert_equals 1 "$LAST_RC" "curl timeout return code"
    assert_call_count 1 "curl timeout call count"
    assert_file_contains 'curl_exit=28' "$STDERR_FILE"
    assert_file_contains 'operation timed out after upload' "$STDERR_FILE"
}

test_retry_exhaustion_keeps_final_error() {
    reset_config
    export FEISHU_NOTIFY_RETRY_BACKOFF_SECONDS=1
    set_mock_responses \
        '0|200|{"code":11232,"msg":"limited one"}|' \
        '0|200|{"code":11232,"msg":"limited two"}|' \
        '0|200|{"code":11232,"msg":"limited final"}|'

    run_notification

    assert_equals 1 "$LAST_RC" "retry exhaustion return code"
    assert_call_count 3 "retry exhaustion call count"
    assert_file_contains '1' "$MOCK_SLEEP_LOG"
    assert_file_contains '2' "$MOCK_SLEEP_LOG"
    assert_file_contains 'attempt=3/3' "$STDERR_FILE"
    assert_file_contains 'limited final' "$STDERR_FILE"
    assert_file_not_contains 'limited one' "$STDERR_FILE"
}

test_invalid_retry_config_fails_before_curl() {
    reset_config
    export FEISHU_NOTIFY_MAX_ATTEMPTS=0
    set_mock_responses '0|200|{"code":0}|'

    run_notification

    assert_equals 1 "$LAST_RC" "invalid retry config return code"
    assert_call_count 0 "invalid retry config call count"
    assert_file_contains 'FEISHU_NOTIFY_MAX_ATTEMPTS must be a positive integer' "$STDERR_FILE"
}

test_success_uses_default_timeouts
test_timeout_overrides_are_forwarded
test_curl_error_preserves_status_and_stderr
test_pre_send_curl_failures_retry
test_feishu_rate_limit_retries
test_retryable_http_statuses_retry
test_permanent_failures_do_not_retry
test_ambiguous_timeout_does_not_retry
test_retry_exhaustion_keeps_final_error
test_invalid_retry_config_fails_before_curl

echo "notification transport tests passed."
