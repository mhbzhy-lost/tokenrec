#!/usr/bin/env bash
set -euo pipefail

APP_NAME="TokenRec"
APP_PATH="${TOKENREC_APP_PATH:-$HOME/Applications/$APP_NAME.app}"
EXECUTABLE="$APP_PATH/Contents/MacOS/$APP_NAME"
SAMPLE_SECONDS="${TOKENREC_VERIFY_SECONDS:-60}"
MAX_CPU_SECONDS="${TOKENREC_MAX_CPU_SECONDS:-5}"
APP_PID=""
APP_IDENTITY=""
SECOND_PID=""
SECOND_IDENTITY=""
LOG_FILE="$(mktemp -t tokenrec-verify.XXXXXX)"

process_identity() {
    ps -ww -p "$1" -o lstart= -o command= 2>/dev/null
}

capture_identity() {
    local pid="$1"
    local identity
    for _ in {1..50}; do
        identity="$(process_identity "$pid" || true)"
        if [[ -n "$identity" ]]; then printf '%s\n' "$identity"; return 0; fi
        kill -0 "$pid" 2>/dev/null || return 1
        sleep 0.01
    done
    return 1
}

stop_owned_pid() {
    local pid="${1:-}"
    local expected_identity="${2:-}"
    [[ -n "$pid" && -n "$expected_identity" ]] || return 0
    local current_identity
    current_identity="$(process_identity "$pid" || true)"
    if [[ "$current_identity" != "$expected_identity" ]]; then
        echo "refusing to stop PID $pid because process identity changed" >&2
        return 0
    fi

    kill "$pid" 2>/dev/null || true
    for _ in {1..50}; do
        current_identity="$(process_identity "$pid" || true)"
        [[ "$current_identity" == "$expected_identity" ]] || break
        sleep 0.1
    done
    current_identity="$(process_identity "$pid" || true)"
    if [[ "$current_identity" == "$expected_identity" ]]; then
        kill -KILL "$pid" 2>/dev/null || true
    fi
    wait "$pid" 2>/dev/null || true
}

wait_for_second_exit() {
    local pid="$1"
    local identity="$2"
    if [[ -n "$identity" ]]; then
        for _ in {1..50}; do
            [[ "$(process_identity "$pid" || true)" == "$identity" ]] || break
            sleep 0.1
        done
        if [[ "$(process_identity "$pid" || true)" == "$identity" ]]; then return 1; fi
    fi
    wait "$pid"
}

cleanup() {
    local status=$?
    trap - EXIT INT TERM
    stop_owned_pid "$SECOND_PID" "$SECOND_IDENTITY"
    stop_owned_pid "$APP_PID" "$APP_IDENTITY"
    rm -f "$LOG_FILE"
    exit "$status"
}
trap cleanup EXIT INT TERM

if [[ "${1:-}" == "--immediate-exit-probe" || "${1:-}" == "--second-exit-loop-probe" ]]; then
    /usr/bin/true &
    SECOND_PID=$!
    SECOND_IDENTITY="$(capture_identity "$SECOND_PID" || true)"
    if ! wait_for_second_exit "$SECOND_PID" "$SECOND_IDENTITY"; then exit 75; fi
    SECOND_PID=""
    SECOND_IDENTITY=""
    exit 0
fi

if [[ "${1:-}" == "--teardown-probe" || "${1:-}" == "--identity-mismatch-probe" ]]; then
    [[ $# -eq 2 ]] || { echo "usage: $0 ${1:-probe} <pid-file>" >&2; exit 64; }
    /bin/sleep 30 &
    APP_PID=$!
    APP_IDENTITY="$(process_identity "$APP_PID")"
    printf '%s\n' "$APP_PID" > "$2"
    if [[ "$1" == "--identity-mismatch-probe" ]]; then APP_IDENTITY="intentional-mismatch"; fi
    exit 0
fi

[[ -x "$EXECUTABLE" ]] || { echo "missing executable: $EXECUTABLE" >&2; exit 66; }
[[ "$SAMPLE_SECONDS" =~ ^[0-9]+$ ]] || { echo "TOKENREC_VERIFY_SECONDS must be an integer" >&2; exit 64; }
[[ "$MAX_CPU_SECONDS" =~ ^[0-9]+([.][0-9]+)?$ ]] || { echo "TOKENREC_MAX_CPU_SECONDS must be numeric" >&2; exit 64; }

exact_pids() {
    ps -axo pid=,command= | awk -v executable="$EXECUTABLE" '{ pid=$1; sub(/^[[:space:]]*[0-9]+[[:space:]]+/, "", $0); if ($0 == executable) print pid }'
}

existing="$(exact_pids)"
[[ -z "$existing" ]] || {
    echo "refusing to verify while an unowned TokenRec process is running: $existing" >&2
    exit 73
}

"$EXECUTABLE" >"$LOG_FILE" 2>&1 &
APP_PID=$!
APP_IDENTITY="$(capture_identity "$APP_PID" || true)"
sleep 2
[[ -n "$APP_IDENTITY" && "$(process_identity "$APP_PID" || true)" == "$APP_IDENTITY" ]] || {
    echo "installed TokenRec exited during startup" >&2
    cat "$LOG_FILE" >&2
    exit 70
}

"$EXECUTABLE" >>"$LOG_FILE" 2>&1 &
SECOND_PID=$!
SECOND_IDENTITY="$(capture_identity "$SECOND_PID" || true)"
if ! wait_for_second_exit "$SECOND_PID" "$SECOND_IDENTITY"; then
    if [[ -n "$SECOND_IDENTITY" && "$(process_identity "$SECOND_PID" || true)" == "$SECOND_IDENTITY" ]]; then
        echo "second TokenRec instance did not exit" >&2
        exit 71
    fi
    echo "second TokenRec instance exited with a failure status" >&2
    exit 75
fi
SECOND_PID=""
SECOND_IDENTITY=""
[[ "$(process_identity "$APP_PID" || true)" == "$APP_IDENTITY" ]] || { echo "first TokenRec instance exited after double-open" >&2; exit 70; }

running="$(exact_pids)"
[[ "$running" == "$APP_PID" ]] || {
    echo "expected exactly owned PID $APP_PID, found: ${running:-none}" >&2
    exit 72
}

cpu_seconds() {
    local raw
    raw="$(ps -p "$1" -o time= | tr -d ' ')"
    awk -v value="$raw" 'BEGIN {
        days = 0
        if (index(value, "-") > 0) {
            split(value, day_parts, "-")
            days = day_parts[1]
            value = day_parts[2]
        }
        count = split(value, parts, ":")
        if (count == 3) { hours = parts[1]; minutes = parts[2]; seconds = parts[3] }
        else if (count == 2) { hours = 0; minutes = parts[1]; seconds = parts[2] }
        else { hours = 0; minutes = 0; seconds = parts[1] }
        print days * 86400 + hours * 3600 + minutes * 60 + seconds
    }'
}

before="$(cpu_seconds "$APP_PID")"
SESSION_DIR="${PI_CODING_AGENT_SESSION_DIR:-$HOME/pi-config/var/sessions}"
if [[ -d "$SESSION_DIR" ]]; then
    session_count="$(find "$SESSION_DIR" -type f -name '*.jsonl' | wc -l | tr -d ' ')"
else
    session_count=0
fi
echo "pid=$APP_PID sample_seconds=$SAMPLE_SECONDS session_files=$session_count cpu_before=$before"
sleep "$SAMPLE_SECONDS"
[[ "$(process_identity "$APP_PID" || true)" == "$APP_IDENTITY" ]] || { echo "owned TokenRec exited during CPU sample" >&2; exit 70; }
after="$(cpu_seconds "$APP_PID")"
delta="$(awk -v after="$after" -v before="$before" 'BEGIN { printf "%.2f", after - before }')"
echo "cpu_after=$after cpu_delta_seconds=$delta max_cpu_seconds=$MAX_CPU_SECONDS"
awk -v delta="$delta" -v limit="$MAX_CPU_SECONDS" 'BEGIN { exit !(delta <= limit) }' || {
    echo "TokenRec CPU time delta exceeded threshold" >&2
    exit 74
}

echo "installed TokenRec verification passed"
