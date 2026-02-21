#!/bin/bash

# .ralph/loop.sh - Headless Ralph Loop Orchestrator (Bash)
# This script runs the agent in a context-free loop until the goal is reached.

ENGINE=
MAX_ITERATIONS=

SPEC_FILE=".ralph/spec.md"
PROMPT_FILE=".ralph/prompt.md"
LOG_DIR=".ralph/logs"
ITERATION=0

mkdir -p ""

echo "🚀 Starting Headless Ralph Loop with ..."

while true; do
    ITERATION=
    
    if [  -gt  ]; then
        echo "⚠️ Max iterations reached (). Stopping loop."
        exit 1
    fi

    echo "--- Iteration  ---"
    
    LOG_FILE="/iteration_.log"
    PROMPT=

    if [ "" == "gemini" ]; then
        # Run Gemini in headless mode
        # -p is for headless prompt, -y for YOLO mode
        gemini -p "" -y 2>&1 | tee ""
    elif [ "" == "claude" ]; then
        # Run Claude Code in headless mode
        # -p is for print (non-interactive), --dangerously-skip-permissions for YOLO-like behavior
        claude -p "" --dangerously-skip-permissions 2>&1 | tee ""
    else
        echo "❌ Unknown engine: . Use 'gemini' or 'claude'."
        exit 1
    fi

    # Check for Mission Completion in the spec file
    if grep -q "MISSION_COMPLETE" ""; then
        echo "🎉 Goal Reached! Overall Status: MISSION_COMPLETE"
        echo "Final check of acceptance criteria..."
        exit 0
    fi

    echo "Iteration  complete. Resetting context for next turn."
done