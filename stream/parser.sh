#!/bin/bash

# stream/parser.sh - Ralph stream parser with token counting
#
# Reads engine output from stdin, estimates token usage, and:
#   - Passes readable text to stdout (for display)
#   - Writes raw output to LOG_FILE (env var)
#   - Emits [TOKEN WARNING] to stderr at RALPH_TOKEN_WARN threshold (default: 100000)
#   - Exits with code 10 at RALPH_TOKEN_ROTATE threshold (default: 128000)
#
# Token estimation: ~4 chars per token (rough but dependency-free).
# Interface is stable -- swap this script for a precise tokenizer without
# touching loop.sh, as long as stdin/stdout/exit codes are preserved.
#
# Usage: engine_command | bash .ralph/stream/parser.sh
# Environment:
#   LOG_FILE           - Path to write raw output (required)
#   RALPH_TOKEN_WARN   - Token count for warning threshold (default: 100000). Converted to chars internally (~4 chars/token).
#   RALPH_TOKEN_ROTATE - Token count for rotate threshold (default: 128000). Converted to chars internally (~4 chars/token).
#   ENGINE             - Engine name, used to decide JSON parsing (optional)

LOG_FILE="${LOG_FILE:-/dev/null}"
# Thresholds in chars (tokens × 4)
# IMPORTANT: defaults MUST stay in sync with loop.ps1 (token counting section).
# Validate env vars are plain integers to prevent bash arithmetic injection.
_raw_warn="${RALPH_TOKEN_WARN:-100000}"
_raw_rotate="${RALPH_TOKEN_ROTATE:-128000}"
_raw_maxlog="${RALPH_MAX_LOG_SIZE:-52428800}"
case "$_raw_warn"   in ''|*[!0-9]*) echo "ERROR: RALPH_TOKEN_WARN must be a positive integer, got: $_raw_warn" >&2; exit 1;; esac
case "$_raw_rotate" in ''|*[!0-9]*) echo "ERROR: RALPH_TOKEN_ROTATE must be a positive integer, got: $_raw_rotate" >&2; exit 1;; esac
case "$_raw_maxlog" in ''|*[!0-9]*) echo "ERROR: RALPH_MAX_LOG_SIZE must be a positive integer, got: $_raw_maxlog" >&2; exit 1;; esac
WARN_CHARS=$(( _raw_warn * 4 ))
ROTATE_CHARS=$(( _raw_rotate * 4 ))
MAX_LOG_SIZE=$_raw_maxlog

TOTAL_CHARS=0
WARNED=false

# Ensure log directory exists
LOG_DIR="$(dirname "$LOG_FILE")"
[ "$LOG_DIR" != "." ] && mkdir -p "$LOG_DIR"

# Check jq availability once before the loop rather than per-line (hot path optimisation)
USE_JQ=false
if [ "${ENGINE:-}" = "claude" ] && command -v jq &>/dev/null; then
    USE_JQ=true
fi

# For claude stream-json: use a single long-running jq coprocess via FIFO to avoid
# spawning a new jq process per line (thousands of fork+exec pairs on long responses).
if [ "$USE_JQ" = "true" ]; then
    # Atomic FIFO creation inside a restricted temp directory (T5: eliminates TOCTOU race)
    JQ_DIR=$(mktemp -d /tmp/ralph-jq.XXXXXX)
    chmod 700 "$JQ_DIR"
    JQ_FIFO="${JQ_DIR}/fifo"
    mkfifo "$JQ_FIFO"
    jq --unbuffered -R -r -n '
        def process:
            try (
                fromjson |
                if .type == "assistant" then
                    ([.message.content[]? | select(.type == "text") | .text] | join(""))
                elif .type == "tool_use" then
                    "[Tool: " + (.tool_use.name // "unknown") + "\n"
                else empty end
            ) catch empty;
        inputs | process
    ' < "$JQ_FIFO" &
    JQ_PID=$!
    exec 3>"$JQ_FIFO"
    trap 'exec 3>&-; wait "$JQ_PID" 2>/dev/null; rm -rf "$JQ_DIR"' EXIT
fi

while IFS= read -r line; do
    # Write raw line to log
    printf '%s\n' "$line" >> "$LOG_FILE"

    # Accumulate char count
    LINE_LEN=${#line}
    TOTAL_CHARS=$(( TOTAL_CHARS + LINE_LEN + 1 ))  # +1 for newline

    # For claude stream-json: feed line to jq coprocess; otherwise print directly
    if [ "$USE_JQ" = "true" ]; then
        printf '%s\n' "$line" >&3
    else
        printf '%s\n' "$line"
    fi

    # Warn threshold -- note: [TOKEN WARNING] goes to stderr only; agents running in a
    # subprocess cannot see it. The guardrails.md instruction has been updated to reflect
    # the actual mechanism (incremental spec updates) rather than relying on this signal.
    if [ "$WARNED" = "false" ] && [ "$TOTAL_CHARS" -ge "$WARN_CHARS" ]; then
        WARNED=true
        printf '[TOKEN WARNING] Approaching context limit. Finish current step and exit.\n' >&2
        # Log file size cap check (T8): triggered once at warn threshold to avoid hot-path stat()
        if [ "$LOG_FILE" != "/dev/null" ] && [ "$MAX_LOG_SIZE" -gt 0 ]; then
            _log_size=$(stat -c%s "$LOG_FILE" 2>/dev/null || stat -f%z "$LOG_FILE" 2>/dev/null || echo 0)
            if [ "$_log_size" -ge "$MAX_LOG_SIZE" ]; then
                tail -c "$((MAX_LOG_SIZE / 2))" "$LOG_FILE" > "${LOG_FILE}.tmp" 2>/dev/null \
                    && mv "${LOG_FILE}.tmp" "$LOG_FILE" 2>/dev/null || true
                printf '[LOG TRUNCATED] Log exceeded %d bytes. Oldest content removed.\n' "$MAX_LOG_SIZE" >&2
            fi
        fi
    fi

    # Rotate threshold -- exit 10 signals loop.sh to treat this as a clean iteration end
    if [ "$TOTAL_CHARS" -ge "$ROTATE_CHARS" ]; then
        printf '[TOKEN ROTATE] Context limit reached. Stopping stream.\n' >&2
        exit 10
    fi
done

exit 0
