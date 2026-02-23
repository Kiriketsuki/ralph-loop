#!/bin/bash

# .ralph/plan.sh - Interactive Ralph Loop Planning Session
# Run from the project root directory.
# Usage: bash .ralph/plan.sh [engine] [model]
#   engine: gemini | claude | copilot (default: gemini)
#   model:  model ID to pass to the engine (default: engine default)

ENGINE=${1:-"gemini"}
MODEL=${2:-""}

MODEL_ARGS=()
[ -n "$MODEL" ] && MODEL_ARGS=("--model" "$MODEL")
SPEC_FILE=".ralph/spec.md"
PLANNER_FILE=".ralph/planner.md"

if [ ! -f "$PLANNER_FILE" ]; then
    echo "ERROR: $PLANNER_FILE not found. Run from the project root." >&2
    exit 1
fi

# Overwrite guard
if [ -f "$SPEC_FILE" ]; then
    echo "WARNING: $SPEC_FILE already exists."
    read -r -p "Overwrite existing spec? (y/N): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo "Aborted. Existing spec preserved."
        exit 0
    fi
    echo "Proceeding with overwrite..."
fi

echo "Starting Ralph Planning Session with $ENGINE..."
echo "The agent will guide you through goal alignment, constraints, criteria, task decomposition, and scoring."
echo "spec.md will be written at the end of the session."
echo "Review spec.md before running: bash .ralph/loop.sh"
echo ""

if [ "$ENGINE" = "gemini" ]; then
    gemini "${MODEL_ARGS[@]}" < "$PLANNER_FILE"
elif [ "$ENGINE" = "claude" ]; then
    claude "${MODEL_ARGS[@]}" < "$PLANNER_FILE"
elif [ "$ENGINE" = "copilot" ]; then
    copilot "${MODEL_ARGS[@]}" < "$PLANNER_FILE"
else
    echo "ERROR: Unknown engine '$ENGINE'. Use 'gemini', 'claude', or 'copilot'." >&2
    exit 1
fi

ENGINE_EXIT=$?

echo ""
if [ "$ENGINE_EXIT" -eq 0 ]; then
    echo "Planning session ended."
    echo "Next step: review .ralph/spec.md, then run: bash .ralph/loop.sh [engine] [max_iterations] [push]"
else
    echo "WARNING: Engine exited with code $ENGINE_EXIT. Check that the planning session completed and spec.md was written before running loop.sh." >&2
fi
