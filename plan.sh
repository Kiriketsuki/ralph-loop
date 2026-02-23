#!/bin/bash

# .ralph/plan.sh - Interactive Ralph Loop Planning Session
# Run from the project root directory.
# Usage: bash .ralph/plan.sh [engine]
#   engine: gemini | claude | copilot (default: gemini)

ENGINE=${1:-"gemini"}
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

OPENING=$(cat "$PLANNER_FILE")

echo "Starting Ralph Planning Session with $ENGINE..."
echo "The agent will guide you through goal alignment, constraints, criteria, task decomposition, and scoring."
echo "spec.md will be written at the end of the session."
echo "Review spec.md before running: bash .ralph/loop.sh"
echo ""

if [ "$ENGINE" = "gemini" ]; then
    gemini "$OPENING"
elif [ "$ENGINE" = "claude" ]; then
    claude "$OPENING"
elif [ "$ENGINE" = "copilot" ]; then
    copilot "$OPENING"
else
    echo "ERROR: Unknown engine '$ENGINE'. Use 'gemini', 'claude', or 'copilot'." >&2
    exit 1
fi

echo ""
echo "Planning session ended."
echo "Next step: review .ralph/spec.md, then run: bash .ralph/loop.sh [engine] [max_iterations] [push]"
