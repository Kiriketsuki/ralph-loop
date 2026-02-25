#!/bin/bash

# .ralph/plan.sh - Interactive Ralph Loop Planning Session v2
# Run from the project root directory.
# Usage: bash .ralph/plan.sh [engine] [model] [mode] [work_scope]
#   engine:     gemini | claude | copilot (default: gemini)
#   model:      model ID to pass to the engine (default: engine default)
#   mode:       plan (default) | plan-work
#   work_scope: description of scoped work (required when mode=plan-work)

export PATH="$HOME/.local/bin:$HOME/.npm-global/bin:/usr/local/bin:$PATH"
[ -s "$HOME/.nvm/nvm.sh" ] && source "$HOME/.nvm/nvm.sh"
export CLAUDE_CODE_MAX_OUTPUT_TOKENS=64000

ENGINE=${1:-"gemini"}
MODEL=${2:-""}
MODE=${3:-"plan"}
WORK_SCOPE=${4:-""}

MODEL_ARGS=()
[ -n "$MODEL" ] && MODEL_ARGS=("--model" "$MODEL")
SPEC_FILE=".ralph/spec.md"

# Resolve planner file from mode
case "$MODE" in
    plan)       PLANNER_FILE=".ralph/prompts/plan.md" ;;
    plan-work)  PLANNER_FILE=".ralph/prompts/plan-work.md" ;;
    *)
        echo "ERROR: Unknown mode '$MODE'. Use 'plan' or 'plan-work'." >&2
        exit 1
        ;;
esac

if [ ! -f "$PLANNER_FILE" ]; then
    echo "ERROR: $PLANNER_FILE not found. Run from the project root." >&2
    exit 1
fi

# Overwrite guard (only for full plan mode)
if [ "$MODE" = "plan" ] && [ -f "$SPEC_FILE" ]; then
    echo "WARNING: $SPEC_FILE already exists."
    read -r -p "Overwrite existing spec? (y/N): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo "Aborted. Existing spec preserved."
        exit 0
    fi
    echo "Proceeding with overwrite..."
fi

# plan-work mode: spec must exist (we're adding to it, not creating it)
if [ "$MODE" = "plan-work" ] && [ ! -f "$SPEC_FILE" ]; then
    echo "ERROR: $SPEC_FILE not found. Run 'bash .ralph/plan.sh' first to create a spec." >&2
    exit 1
fi

# plan-work mode: must be on a feature branch (not main/master/detached HEAD)
if [ "$MODE" = "plan-work" ]; then
    CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "main")
    if [[ "$CURRENT_BRANCH" == "main" || "$CURRENT_BRANCH" == "master" || "$CURRENT_BRANCH" == "HEAD" ]]; then
        echo "ERROR: plan-work mode requires a feature branch. You are on '$CURRENT_BRANCH'." >&2
        echo "Create a feature branch first: git checkout -b feature/<name>" >&2
        exit 1
    fi
    if [ -z "$WORK_SCOPE" ]; then
        echo "ERROR: plan-work mode requires a work_scope argument (4th positional arg)." >&2
        echo "Usage: bash .ralph/plan.sh [engine] [model] plan-work \"description of work\"" >&2
        exit 1
    fi
    export WORK_SCOPE

    # Validate WORK_SCOPE for injection safety
    if [ "${#WORK_SCOPE}" -gt 500 ]; then
        echo "ERROR: WORK_SCOPE exceeds 500 characters." >&2
        exit 1
    fi
    if printf '%s' "$WORK_SCOPE" | grep -qE '[`]|\$\('; then
        echo "ERROR: WORK_SCOPE contains unsafe characters (backticks or \$())." >&2
        exit 1
    fi
    if [ "$(printf '%s' "$WORK_SCOPE" | wc -l)" -gt 0 ]; then
        echo "ERROR: WORK_SCOPE must be a single line (no embedded newlines)." >&2
        exit 1
    fi
fi

if [ "$MODE" = "plan" ]; then
    echo "Starting Ralph Planning Session with $ENGINE..."
    echo "The agent will guide you through goal alignment, constraints, criteria, task decomposition, and scoring."
    echo "spec.md and agents.md will be written at the end of the session."
    echo "Review spec.md before running: bash .ralph/loop.sh"
else
    echo "Starting Ralph Feature-Branch Planning Session with $ENGINE..."
    echo "The agent will help you scope and plan a focused piece of work."
    echo "New tasks will be appended to spec.md."
    echo "When done, run: bash .ralph/loop.sh [engine] [max_iterations] [push] [model] build"
fi
echo ""

# Prepare prompt content (substitute $WORK_SCOPE for plan-work mode)
if [ "$MODE" = "plan-work" ]; then
    PLANNER_CONTENT="$(envsubst '$WORK_SCOPE' < "$PLANNER_FILE")"
else
    PLANNER_CONTENT="$(cat "$PLANNER_FILE")"
fi

if [ "$ENGINE" = "gemini" ]; then
    gemini "${MODEL_ARGS[@]}" <<< "$PLANNER_CONTENT"
elif [ "$ENGINE" = "claude" ]; then
    claude "${MODEL_ARGS[@]}" <<< "$PLANNER_CONTENT"
elif [ "$ENGINE" = "copilot" ]; then
    copilot "${MODEL_ARGS[@]}" <<< "$PLANNER_CONTENT"
else
    echo "ERROR: Unknown engine '$ENGINE'. Use 'gemini', 'claude', or 'copilot'." >&2
    exit 1
fi

ENGINE_EXIT=$?

echo ""
if [ "$ENGINE_EXIT" -eq 0 ]; then
    echo "Planning session ended."
    if [ "$MODE" = "plan" ]; then
        echo "Next step: review .ralph/spec.md and .ralph/agents.md, then run: bash .ralph/loop.sh [engine] [max_iterations] [push]"
    else
        echo "Next step: review .ralph/spec.md (new tasks appended), then run: bash .ralph/loop.sh [engine] [max_iterations] [push] [model] build"
    fi
else
    echo "WARNING: Engine exited with code $ENGINE_EXIT. Check that the planning session completed and spec.md was written before running loop.sh." >&2
fi
