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
#   RALPH_TOKEN_WARN   - Char count for warning threshold (default: 400000 = ~100k tokens)
#   RALPH_TOKEN_ROTATE - Char count for rotate threshold (default: 512000 = ~128k tokens)
#   ENGINE             - Engine name, used to decide JSON parsing (optional)

LOG_FILE="${LOG_FILE:-/dev/null}"
# Thresholds in chars (tokens × 4)
WARN_CHARS=$(( ${RALPH_TOKEN_WARN:-100000} * 4 ))
ROTATE_CHARS=$(( ${RALPH_TOKEN_ROTATE:-128000} * 4 ))

TOTAL_CHARS=0
WARNED=false

# Ensure log directory exists
LOG_DIR="$(dirname "$LOG_FILE")"
[ "$LOG_DIR" != "." ] && mkdir -p "$LOG_DIR"

while IFS= read -r line; do
    # Write raw line to log
    printf '%s\n' "$line" >> "$LOG_FILE"

    # Accumulate char count
    LINE_LEN=${#line}
    TOTAL_CHARS=$(( TOTAL_CHARS + LINE_LEN + 1 ))  # +1 for newline

    # For claude stream-json: extract human-readable text if jq is available
    if [ "${ENGINE:-}" = "claude" ] && command -v jq &>/dev/null; then
        READABLE=$(printf '%s\n' "$line" | jq -rj '
            if .type == "assistant" then
                ([.message.content[]? | select(.type == "text") | .text] | join(""))
            elif .type == "tool_use" then
                ("[Tool: " + (.tool_use.name // "unknown") + "]\n")
            else empty end
        ' 2>/dev/null)
        [ -n "$READABLE" ] && printf '%s' "$READABLE"
    else
        printf '%s\n' "$line"
    fi

    # Warn threshold
    if [ "$WARNED" = "false" ] && [ "$TOTAL_CHARS" -ge "$WARN_CHARS" ]; then
        WARNED=true
        printf '[TOKEN WARNING] Approaching context limit. Finish current step and exit.\n' >&2
    fi

    # Rotate threshold -- exit 10 signals loop.sh to treat this as a clean iteration end
    if [ "$TOTAL_CHARS" -ge "$ROTATE_CHARS" ]; then
        printf '[TOKEN ROTATE] Context limit reached. Stopping stream.\n' >&2
        exit 10
    fi
done

exit 0
