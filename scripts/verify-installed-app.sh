#!/usr/bin/env bash
set -euo pipefail

APP_NAME="TokenRec"
APP_PATH="${TOKENREC_APP_PATH:-$HOME/Applications/$APP_NAME.app}"
EXECUTABLE="$APP_PATH/Contents/MacOS/$APP_NAME"
SAMPLE_SECONDS="${TOKENREC_VERIFY_SECONDS:-60}"
MAX_CPU_SECONDS="${TOKENREC_MAX_CPU_SECONDS:-5}"
APP_PID=""
SECOND_PID=""
LOG_FILE="$(mktemp -t tokenrec-verify.XXXXXX)"

stop_owned_pid() {
    local pid="${1:-}"
    [[ -n "$pid" ]] || return 0
    if kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null || true
        for _ in {1..50}; do
            kill -0 "$pid" 2>/dev/null || break
            sleep 0.1
        done
        if kill -0 "$pid" 2>/dev/null; then
            kill -KILL "$pid" 2>/dev/null || true
        fi
    fi
    wait "$pid" 2>/dev/null || true
}

cleanup() {
    local status=$?
    trap - EXIT INT TERM
    stop_owned_pid "$SECOND_PID"
    stop_owned_pid "$APP_PID"
    rm -f "$LOG_FILE"
    exit "$status"
}
trap cleanup EXIT INT TERM

if [[ "${1:-}" == "--teardown-probe" ]]; then
    [[ $# -eq 2 ]] || { echo "usage: $0 --teardown-probe <pid-file>" >&2; exit 64; }
    sleep 30 &
    APP_PID=$!
    printf '%s\n' "$APP_PID" > "$2"
    exit 0
fi

[[ -x "$EXECUTABLE" ]] || { echo "missing executable: $EXECUTABLE" >&2; exit 66; }
[[ "$SAMPLE_SECONDS" =~ ^[0-9]+$ ]] || { echo "TOKENREC_VERIFY_SECONDS must be an integer" >&2; exit 64; }
[[ "$MAX_CPU_SECONDS" =~ ^[0-9]+([.][0-9]+)?$ ]] || { echo "TOKENREC_MAX_CPU_SECONDS must be numeric" >&2; exit 64; }

exact_pids() {
    ps -axo pid=,command= | awk -v executable="$EXECUTABLE" '$2 == executable { print $1 }'
}

existing="$(exact_pids)"
[[ -z "$existing" ]] || {
    echo "refusing to verify while an unowned TokenRec process is running: $existing" >&2
    exit 73
}

"$EXECUTABLE" >"$LOG_FILE" 2>&1 &
APP_PID=$!
sleep 2
kill -0 "$APP_PID" 2>/dev/null || {
    echo "installed TokenRec exited during startup" >&2
    cat "$LOG_FILE" >&2
    exit 70
}

"$EXECUTABLE" >>"$LOG_FILE" 2>&1 &
SECOND_PID=$!
for _ in {1..50}; do
    kill -0 "$SECOND_PID" 2>/dev/null || break
    sleep 0.1
done
if kill -0 "$SECOND_PID" 2>/dev/null; then
    echo "second TokenRec instance did not exit" >&2
    exit 71
fi
wait "$SECOND_PID"
SECOND_PID=""
kill -0 "$APP_PID" 2>/dev/null || { echo "first TokenRec instance exited after double-open" >&2; exit 70; }

running="$(exact_pids)"
[[ "$running" == "$APP_PID" ]] || {
    echo "expected exactly owned PID $APP_PID, found: ${running:-none}" >&2
    exit 72
}

cpu_seconds() {
    local raw
    raw="$(ps -p "$1" -o time= | tr -d ' ')"
    python3 - "$raw" <<'PY'
import sys
value = sys.argv[1]
days = 0
if '-' in value:
    day, value = value.split('-', 1)
    days = int(day)
parts = [float(part) for part in value.split(':')]
if len(parts) == 3:
    hours, minutes, seconds = parts
elif len(parts) == 2:
    hours, minutes, seconds = 0, *parts
else:
    hours, minutes, seconds = 0, 0, parts[0]
print(days * 86400 + hours * 3600 + minutes * 60 + seconds)
PY
}

before="$(cpu_seconds "$APP_PID")"
session_count="$(find "${PI_CODING_AGENT_SESSION_DIR:-$HOME/pi-config/var/sessions}" -type f -name '*.jsonl' 2>/dev/null | wc -l | tr -d ' ')"
echo "pid=$APP_PID sample_seconds=$SAMPLE_SECONDS session_files=${session_count:-0} cpu_before=$before"
sleep "$SAMPLE_SECONDS"
after="$(cpu_seconds "$APP_PID")"
delta="$(awk -v after="$after" -v before="$before" 'BEGIN { printf "%.2f", after - before }')"
echo "cpu_after=$after cpu_delta_seconds=$delta max_cpu_seconds=$MAX_CPU_SECONDS"
awk -v delta="$delta" -v limit="$MAX_CPU_SECONDS" 'BEGIN { exit !(delta <= limit) }' || {
    echo "TokenRec CPU time delta exceeded threshold" >&2
    exit 74
}

echo "installed TokenRec verification passed"
