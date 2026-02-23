#!/bin/bash

# .ralph/loop.sh - Headless Ralph Loop Orchestrator (Bash)
# Run from the project root directory.
# Usage: bash .ralph/loop.sh [engine] [max_iterations] [push] [model]
#   engine:         gemini | claude | copilot (default: gemini)
#   max_iterations: integer (default: 20)
#   push:           true | false (default: true)
#   model:          model ID to pass to the engine (default: engine default)

ENGINE=${1:-"gemini"}
MAX_ITERATIONS=${2:-20}
PUSH_CHANGES=${3:-true}
MODEL=${4:-""}

MODEL_ARGS=()
[ -n "$MODEL" ] && MODEL_ARGS=("--model" "$MODEL")

SPEC_FILE=".ralph/spec.md"
PROMPT_FILE=".ralph/prompt.md"
LOG_DIR=".ralph/logs"
ITERATION=0

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

echo "Starting Headless Ralph Loop with $ENGINE on branch $BRANCH..."

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
        gemini -p "$PROMPT" -y "${MODEL_ARGS[@]}" 2>&1 | tee "$LOG_FILE"
    elif [ "$ENGINE" = "claude" ]; then
        claude -p "$PROMPT" --dangerously-skip-permissions "${MODEL_ARGS[@]}" 2>&1 | tee "$LOG_FILE"
    elif [ "$ENGINE" = "copilot" ]; then
        copilot -p "$PROMPT" --allow-all-tools "${MODEL_ARGS[@]}" 2>&1 | tee "$LOG_FILE"
    else
        echo "ERROR: Unknown engine '$ENGINE'. Use 'gemini', 'claude', or 'copilot'." >&2
        exit 1
    fi

    # Auto-sync to GitHub if there are changes
    if [ "$PUSH_CHANGES" = "true" ] && [ -n "$(git status --porcelain)" ]; then
        echo "Syncing changes to GitHub (branch: $BRANCH)..."
        git add .
        git commit -m "Ralph Iteration $ITERATION: Automated Progress Sync"
        git push origin "$BRANCH"
    fi

    # Check for mission completion
    if grep -q "MISSION_COMPLETE" "$SPEC_FILE"; then
        echo "Goal reached. Overall Status: MISSION_COMPLETE"
        exit 0
    fi

    # Check for verification pending -- allow one more iteration
    if grep -q "VERIFICATION_PENDING" "$SPEC_FILE"; then
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
