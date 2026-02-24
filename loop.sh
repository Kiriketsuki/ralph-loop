#!/bin/bash

# .ralph/loop.sh - Headless Ralph Loop Orchestrator (Bash)
# Run from the project root directory.
# Usage: bash .ralph/loop.sh [engine] [max_iterations] [push] [model]
#   engine:         gemini | claude | copilot (default: gemini)
#   max_iterations: integer (default: 20)
#   push:           true | false (default: true)
#   model:          model ID to pass to the engine (default: engine default)

# Ensure user-local binaries (claude, gemini, etc.) are on PATH regardless of how this
# script was launched (bash scripts don't inherit zsh aliases or .zshrc PATH additions).
export PATH="$HOME/.local/bin:$HOME/.npm-global/bin:/usr/local/bin:$PATH"
# Source nvm to add nvm-managed binaries (e.g. gemini) to PATH.
# shellcheck disable=SC1091
[ -s "$HOME/.nvm/nvm.sh" ] && source "$HOME/.nvm/nvm.sh"

ENGINE=${1:-"gemini"}
MAX_ITERATIONS=${2:-20}
PUSH_CHANGES=${3:-true}
MODEL=${4:-""}

MODEL_ARGS=()
[ -n "$MODEL" ] && MODEL_ARGS=("--model" "$MODEL")

SPEC_FILE=".ralph/spec.md"
PROMPT_FILE=".ralph/prompt.md"
LOG_DIR=".ralph/logs"
ITERATION=0  # will be overwritten from spec after validation

if [ ! -f "$SPEC_FILE" ]; then
    echo "ERROR: $SPEC_FILE not found. Run from the project root." >&2
    exit 1
fi

if [ ! -f "$PROMPT_FILE" ]; then
    echo "ERROR: $PROMPT_FILE not found. Run from the project root." >&2
    exit 1
fi

BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "main")

mkdir -p "$LOG_DIR"

# Check for jq -- required for real-time streaming output when using claude engine
JQ_AVAILABLE=false
if command -v jq &>/dev/null; then
    JQ_AVAILABLE=true
fi
if [ "$ENGINE" = "claude" ] && [ "$JQ_AVAILABLE" = "false" ]; then
    echo "NOTE: jq not found. Claude output will not stream in real time. Install jq for live output."
fi

# Seed iteration counter from spec so resuming a session continues numbering correctly
ITERATION=$(grep -oP '(?<=\*\*Current Iteration\*\*: )\d+' "$SPEC_FILE" 2>/dev/null || echo 0)
ITERATION=${ITERATION:-0}

echo "Starting Headless Ralph Loop with $ENGINE on branch $BRANCH (resuming from iteration $ITERATION)..."

while true; do
    ITERATION=$((ITERATION + 1))

    if [ "$ITERATION" -gt "$MAX_ITERATIONS" ]; then
        echo "WARNING: Max iterations reached ($MAX_ITERATIONS). Stopping loop."
        exit 1
    fi

    echo "--- Iteration $ITERATION ---"

    LOG_FILE="$LOG_DIR/iteration_$ITERATION.log"
    PROMPT=$(cat "$PROMPT_FILE")

    if [ "$ENGINE" = "gemini" ]; then
        gemini -p "$PROMPT" -y "${MODEL_ARGS[@]}" 2>&1 | stdbuf -oL tee "$LOG_FILE"
    elif [ "$ENGINE" = "claude" ]; then
        if [ "$JQ_AVAILABLE" = "true" ]; then
            # stream-json emits newline-delimited JSON events as they are produced,
            # enabling real-time output. jq extracts assistant text and tool names.
            claude -p "$PROMPT" --dangerously-skip-permissions --output-format stream-json --verbose "${MODEL_ARGS[@]}" 2>&1 | \
                while IFS= read -r line; do
                    printf '%s\n' "$line" >> "$LOG_FILE"
                    printf '%s\n' "$line" | jq -rj '
                        if .type == "assistant" then
                            ([.message.content[]? | select(.type == "text") | .text] | join(""))
                        elif .type == "tool_use" then
                            ("[Tool: " + (.tool_use.name // "unknown") + "]\n")
                        else empty end
                    ' 2>/dev/null
                done
        else
            claude -p "$PROMPT" --dangerously-skip-permissions "${MODEL_ARGS[@]}" 2>&1 | stdbuf -oL tee "$LOG_FILE"
        fi
    elif [ "$ENGINE" = "copilot" ]; then
        copilot -p "$PROMPT" --allow-all-tools "${MODEL_ARGS[@]}" 2>&1 | stdbuf -oL tee "$LOG_FILE"
    else
        echo "ERROR: Unknown engine '$ENGINE'. Use 'gemini', 'claude', or 'copilot'." >&2
        exit 1
    fi

    # Auto-sync to GitHub if there are changes
    if [ "$PUSH_CHANGES" = "true" ] && [ -n "$(git status --porcelain)" ]; then
        echo "Syncing changes to GitHub (branch: $BRANCH)..."
        # Build semantic commit message from the progress entry the agent just wrote.
        # Expected format: - **[YYYY-MM-DD HH:MM]** (Iteration N) [type]: summary
        PROGRESS_LINE=$(grep -m1 "(Iteration $ITERATION) [a-z]*:" ".ralph/progress.md" 2>/dev/null || true)
        COMMIT_TYPE=$(printf '%s' "$PROGRESS_LINE" | sed -n 's/.*Iteration [0-9]*) \([a-z]*\):.*/\1/p')
        COMMIT_SUMMARY=$(printf '%s' "$PROGRESS_LINE" | sed 's/.*Iteration [0-9]*) [a-z]*: //')
        COMMIT_TYPE=${COMMIT_TYPE:-"chore"}
        COMMIT_SUMMARY=${COMMIT_SUMMARY:-"Iteration $ITERATION automated progress sync"}
        git add .
        git commit -m "${COMMIT_TYPE}(ralph): ${COMMIT_SUMMARY}"
        git push origin "$BRANCH"
    fi

    # Check for mission completion
    if grep -qE "\*\*Overall Status\*\*:\s*MISSION_COMPLETE" "$SPEC_FILE"; then
        echo "Goal reached. Overall Status: MISSION_COMPLETE"
        exit 0
    fi

    # Check for verification pending -- allow one more iteration
    if grep -qE "\*\*Overall Status\*\*:\s*VERIFICATION_PENDING" "$SPEC_FILE"; then
        echo "Verification iteration triggered. Agent will verify acceptance criteria..."
        continue
    fi

    # Check for stuck state: no pending tasks remain but mission not complete
    if ! grep -qE "\| *pending *\|" "$SPEC_FILE"; then
        if grep -qE "\| *proposed *\|" "$SPEC_FILE"; then
            echo "PAUSED: Proposed tasks require human review. Promote to 'pending' and re-run." >&2
            exit 3
        fi
        echo "WARNING: No pending tasks remain but mission is not complete. Stopping loop." >&2
        exit 2
    fi

    echo "Iteration $ITERATION complete. Reloading with fresh context..."
done
