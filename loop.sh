#!/bin/bash

# .ralph/loop.sh - Headless Ralph Loop Orchestrator (Bash)
# This script runs the agent in a context-free loop until the goal is reached.

ENGINE=${1:-"gemini"}
MAX_ITERATIONS=${2:-20}
PUSH_CHANGES=true

SPEC_FILE=".ralph/spec.md"
PROMPT_FILE=".ralph/prompt.md"
LOG_DIR=".ralph/logs"
ITERATION=0

mkdir -p "$LOG_DIR"

echo "🚀 Starting Headless Ralph Loop with $ENGINE..."

while true; do
    ITERATION=$((ITERATION+1))
    
    if [ $ITERATION -gt $MAX_ITERATIONS ]; then
        echo "⚠️ Max iterations reached ($MAX_ITERATIONS). Stopping loop."
        exit 1
    fi

    echo "--- Iteration $ITERATION ---"
    
    LOG_FILE="$LOG_DIR/iteration_$ITERATION.log"
    PROMPT=$(cat "$PROMPT_FILE")

    if [ "$ENGINE" == "gemini" ]; then
        gemini -p "$PROMPT" -y 2>&1 | tee "$LOG_FILE"
    elif [ "$ENGINE" == "claude" ]; then
        claude -p "$PROMPT" --dangerously-skip-permissions 2>&1 | tee "$LOG_FILE"
    else
        echo "❌ Unknown engine: $ENGINE. Use 'gemini' or 'claude'."
        exit 1
    fi

    # Auto-sync to GitHub if there are changes
    if [ "$PUSH_CHANGES" = true ] && [ -n "$(git status --porcelain)" ]; then
        echo "🔄 Syncing changes to GitHub..."
        git add .
        git commit -m "Ralph Iteration $ITERATION: Automated Progress Sync"
        git push origin main
    fi

    # Check for Mission Completion in the spec file
    if grep -q "MISSION_COMPLETE" "$SPEC_FILE"; then
        echo "🎉 Goal Reached! Overall Status: MISSION_COMPLETE"
        exit 0
    fi

    echo "Iteration $ITERATION complete. Fresh context reload starting..."
done
