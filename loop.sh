#!/bin/bash

# .ralph/loop.sh - Headless Ralph Loop Orchestrator (Bash) v2
# Run from the project root directory.
# Usage: bash .ralph/loop.sh [engine] [max_iterations] [push] [model] [mode] [work_scope]
#   engine:         gemini | claude | copilot (default: gemini)
#   max_iterations: integer (default: 20)
#   push:           true | false (default: true)
#   model:          model ID to pass to the engine (default: engine default)
#   mode:           build | plan-work (default: build)
#   work_scope:     description of scoped work (required when mode=plan-work)
#
# Flags (can be placed anywhere before positional args):
#   --dry-run       Print full concatenated prompt and engine command, then exit.
#
# Exit codes:
#   0   MISSION_COMPLETE
#   1   Max iterations reached
#   2   Stuck -- no pending, no proposed tasks
#   3   Proposed tasks need human review
#   4   Gutter detected -- agent in a rut
#   130 Ctrl+C / SIGTERM

# Ensure user-local binaries (claude, gemini, etc.) are on PATH regardless of how this
# script was launched (bash scripts don't inherit zsh aliases or .zshrc PATH additions).
export PATH="$HOME/.local/bin:$HOME/.npm-global/bin:/usr/local/bin:$PATH"
# Source nvm to add nvm-managed binaries (e.g. gemini) to PATH.
# shellcheck disable=SC1091
[ -s "$HOME/.nvm/nvm.sh" ] && source "$HOME/.nvm/nvm.sh"
# Raise the per-response output token ceiling so agents can write large files
# (e.g. standalone HTML design system) without hitting the 32K default cap.
export CLAUDE_CODE_MAX_OUTPUT_TOKENS=64000

# Trap Ctrl+C / SIGTERM so the loop exits cleanly without leaving the terminal in a
# broken state. Claude reads from stdin by default (setting raw mode); the </dev/null
# redirect below breaks that attachment, but the trap ensures a clean exit regardless.
trap 'printf "\n"; echo "Loop interrupted."; exit 130' INT TERM

# --- Parse flags ---
DRY_RUN=false
POSITIONAL=()
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=true ;;
        *) POSITIONAL+=("$arg") ;;
    esac
done
set -- "${POSITIONAL[@]}"

ENGINE=${1:-"gemini"}
MAX_ITERATIONS=${2:-20}
PUSH_CHANGES=${3:-true}
MODEL=${4:-""}
MODE=${5:-"build"}
WORK_SCOPE=${6:-""}

MODEL_ARGS=()
[ -n "$MODEL" ] && MODEL_ARGS=("--model" "$MODEL")

SPEC_FILE=".ralph/spec.md"
GUARDRAILS_FILE=".ralph/prompts/guardrails.md"
AGENTS_FILE=".ralph/agents.md"
LOG_DIR=".ralph/logs"
PARSER=".ralph/stream/parser.sh"
GUTTER=".ralph/stream/gutter.sh"
ITERATION=0  # will be overwritten from spec after validation

# Resolve prompt file from mode
case "$MODE" in
    build)      PROMPT_FILE=".ralph/prompts/build.md" ;;
    plan-work)  PROMPT_FILE=".ralph/prompts/plan-work.md" ;;
    *)
        echo "ERROR: Unknown mode '$MODE'. Use 'build' or 'plan-work'." >&2
        exit 1
        ;;
esac

# Validate plan-work mode requirements
if [ "$MODE" = "plan-work" ]; then
    CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "main")
    if [[ "$CURRENT_BRANCH" == "main" || "$CURRENT_BRANCH" == "master" ]]; then
        echo "ERROR: plan-work mode requires a feature branch. You are on '$CURRENT_BRANCH'." >&2
        echo "Create a feature branch first: git checkout -b feature/<name>" >&2
        exit 1
    fi
    if [ -z "$WORK_SCOPE" ]; then
        echo "ERROR: plan-work mode requires a work_scope argument (6th positional arg)." >&2
        echo "Usage: bash .ralph/loop.sh [engine] [max_iterations] [push] [model] plan-work \"description of work\"" >&2
        exit 1
    fi
    # Export for envsubst substitution in plan-work.md
    export WORK_SCOPE
fi

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

# Check for jq -- used by parser.sh for claude stream-json
JQ_AVAILABLE=false
if command -v jq &>/dev/null; then
    JQ_AVAILABLE=true
fi
if [ "$ENGINE" = "claude" ] && [ "$JQ_AVAILABLE" = "false" ]; then
    echo "NOTE: jq not found. Claude stream output will pass through unprocessed. Install jq for structured output."
fi

# --- Build full prompt (guardrails + mode prompt + agents.md) ---
build_prompt() {
    local PROMPT_CONTENT
    PROMPT_CONTENT=""

    # Prepend guardrails if present
    if [ -f "$GUARDRAILS_FILE" ]; then
        PROMPT_CONTENT="$(cat "$GUARDRAILS_FILE")
---
"
    fi

    # Append mode-specific prompt (with envsubst for plan-work WORK_SCOPE substitution)
    if [ "$MODE" = "plan-work" ]; then
        PROMPT_CONTENT="${PROMPT_CONTENT}$(envsubst '$WORK_SCOPE' < "$PROMPT_FILE")"
    else
        PROMPT_CONTENT="${PROMPT_CONTENT}$(cat "$PROMPT_FILE")"
    fi

    # Append agents.md if it exists
    if [ -f "$AGENTS_FILE" ]; then
        PROMPT_CONTENT="${PROMPT_CONTENT}
---
$(cat "$AGENTS_FILE")"
    fi

    printf '%s' "$PROMPT_CONTENT"
}

# --- Dry-run mode ---
if [ "$DRY_RUN" = "true" ]; then
    echo "=== DRY RUN: Full Concatenated Prompt ==="
    echo ""
    build_prompt
    echo ""
    echo "=== Engine Command ==="
    MODEL_STR=""
    [ -n "$MODEL" ] && MODEL_STR=" --model $MODEL"
    case "$ENGINE" in
        gemini)  echo "gemini -p \"\$PROMPT\" -y${MODEL_STR}" ;;
        claude)  echo "claude -p \"\$PROMPT\" --dangerously-skip-permissions --output-format stream-json --verbose${MODEL_STR}" ;;
        copilot) echo "copilot -p \"\$PROMPT\" --allow-all-tools${MODEL_STR}" ;;
    esac
    echo ""
    echo "=== No engine invoked (--dry-run). ==="
    exit 0
fi

# --- Engine invocation ---
invoke_engine() {
    local PROMPT="$1"
    local LOG_FILE="$2"

    export LOG_FILE ENGINE

    if [ "$ENGINE" = "gemini" ]; then
        gemini -p "$PROMPT" -y "${MODEL_ARGS[@]}" 2>&1 | bash "$PARSER"
    elif [ "$ENGINE" = "claude" ]; then
        claude -p "$PROMPT" --dangerously-skip-permissions --output-format stream-json --verbose "${MODEL_ARGS[@]}" </dev/null 2>&1 | bash "$PARSER"
    elif [ "$ENGINE" = "copilot" ]; then
        copilot -p "$PROMPT" --allow-all-tools "${MODEL_ARGS[@]}" 2>&1 | bash "$PARSER"
    else
        echo "ERROR: Unknown engine '$ENGINE'. Use 'gemini', 'claude', or 'copilot'." >&2
        return 1
    fi

    return "${PIPESTATUS[1]}"
}

# Seed iteration counter from spec so resuming a session continues numbering correctly
ITERATION=$(grep -oP '(?<=\*\*Current Iteration\*\*: )\d+' "$SPEC_FILE" 2>/dev/null || echo 0)
ITERATION=${ITERATION:-0}

# On a fresh loop (iteration 0), create a dedicated ralph/<slug> branch so each
# project gets its own branch and the main branch stays clean.
if [ "$ITERATION" -eq 0 ] && [ "$MODE" = "build" ]; then
    PROJECT_SLUG=$(grep -m1 "^# Ralph Project Specification:" "$SPEC_FILE" \
        | sed 's/^# Ralph Project Specification: //' \
        | tr '[:upper:]' '[:lower:]' \
        | tr -cs '[:alnum:]' '-' \
        | sed 's/^-//;s/-$//')
    RALPH_BRANCH="ralph/${PROJECT_SLUG:-loop}"
    if git rev-parse --verify "$RALPH_BRANCH" &>/dev/null; then
        echo "Branch $RALPH_BRANCH already exists. Switching to it..."
        git checkout "$RALPH_BRANCH"
    else
        echo "Fresh loop detected (iteration 0). Creating branch $RALPH_BRANCH from $BRANCH..."
        git checkout -b "$RALPH_BRANCH"
    fi
    BRANCH="$RALPH_BRANCH"
fi

echo "Starting Headless Ralph Loop [mode: $MODE] with $ENGINE on branch $BRANCH (resuming from iteration $ITERATION)..."

while true; do
    ITERATION=$((ITERATION + 1))

    if [ "$ITERATION" -gt "$MAX_ITERATIONS" ]; then
        echo "WARNING: Max iterations reached ($MAX_ITERATIONS). Stopping loop."
        exit 1
    fi

    echo "--- Iteration $ITERATION ---"

    LOG_FILE="$LOG_DIR/iteration_$ITERATION.log"
    FULL_PROMPT=$(build_prompt)

    invoke_engine "$FULL_PROMPT" "$LOG_FILE"
    ENGINE_EXIT=$?

    # Exit code 10 = token rotate: parser terminated stream at context limit.
    # Treat as a clean iteration end -- the agent should have updated spec before hitting limit.
    if [ "$ENGINE_EXIT" -eq 10 ]; then
        echo "Token rotate: context limit reached. Treating as clean iteration end."
    elif [ "$ENGINE_EXIT" -ne 0 ]; then
        echo "WARNING: Engine exited with code $ENGINE_EXIT." >&2
    fi

    # --- Gutter detection ---
    if [ -f "$GUTTER" ]; then
        if ! bash "$GUTTER"; then
            echo "GUTTER DETECTED: Agent appears to be in a rut. Human review needed." >&2
            echo "Check .ralph/progress.md for repeated patterns, then re-run or adjust spec." >&2
            exit 4
        fi
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

    # plan-work mode has its own exit condition: agent writes plan to spec and exits.
    # We run for up to MAX_ITERATIONS but typically complete in 1-2.
    if [ "$MODE" = "plan-work" ]; then
        # Check if agent wrote new pending tasks (plan complete)
        if grep -qE "\| *pending *\|" "$SPEC_FILE"; then
            echo "Plan-work session complete. New pending tasks written to spec.md."
            echo "Switch to build mode: bash .ralph/loop.sh [engine] [max_iterations] [push] [model] build"
            exit 0
        fi
        echo "Iteration $ITERATION complete. Continuing plan-work session..."
        continue
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
