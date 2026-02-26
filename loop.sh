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

# Parallel execution settings (overridable via env vars)
MAX_PARALLEL=${MAX_PARALLEL:-5}
RALPH_MAX_RETRIES=${RALPH_MAX_RETRIES:-3}

if ! [[ "$MAX_PARALLEL" =~ ^[1-9][0-9]*$ ]]; then
    echo "ERROR: MAX_PARALLEL must be a positive integer, got '$MAX_PARALLEL'." >&2; exit 1
fi
if ! [[ "$RALPH_MAX_RETRIES" =~ ^[1-9][0-9]*$ ]]; then
    echo "ERROR: RALPH_MAX_RETRIES must be a positive integer, got '$RALPH_MAX_RETRIES'." >&2; exit 1
fi

# Global state for worktree tracking (accessed by trap handler and cleanup function).
# Parallel indexed arrays — bash 3.2-compatible replacement for declare -A.
# Index i in each array corresponds to VALID_TASK_PAIRS[i] set during batch setup.
TASK_WORKTREES=()
TASK_BRANCHES=()
AGENT_ITERATIONS=()
AGENT_PIDS=()
# NOTE: DISPATCH_PIPE_STATUSES is set inside dispatch_engine() and read by its direct caller
# (run_parallel_agent) within the same subshell. Do NOT read it from the parent shell after
# `wait` — background subshells cannot propagate array writes back to the parent.
declare -a DISPATCH_PIPE_STATUSES=()
WORKTREE_PATH=""
RALPH_BRANCH=""

# --- Cleanup: remove per-task worktrees and branches for the current batch ---
cleanup_task_worktrees() {
    # Abort any in-progress merge before removing worktrees (handles Ctrl+C during merge)
    # Use -C $WORKTREE_PATH so this runs on the main ralph worktree regardless of CWD.
    [ -n "$WORKTREE_PATH" ] && git -C "$WORKTREE_PATH" merge --abort 2>/dev/null || true
    for (( _ci=0; _ci<${#TASK_WORKTREES[@]}; _ci++ )); do
        local wt="${TASK_WORKTREES[$_ci]}"
        local br="${TASK_BRANCHES[$_ci]}"
        if [ -d "$wt" ]; then
            git worktree remove --force "$wt" 2>/dev/null || true
        fi
        git branch -D "$br" 2>/dev/null || true
    done
    # Clean up prompt temp files from this batch
    [ -n "$WORKTREE_PATH" ] && rm -f "${WORKTREE_PATH}/${LOG_DIR}"/prompt_*.txt 2>/dev/null || true
    TASK_WORKTREES=()
    TASK_BRANCHES=()
}

# Portable sed -i: macOS (BSD sed) requires `sed -i ''`; GNU sed uses `sed -i`.
sedi() { if [[ "$OSTYPE" == darwin* ]]; then sed -i '' "$@"; else sed -i "$@"; fi; }

trap '
    printf "\n"; echo "Loop interrupted."
    # Gracefully stop background agents before removing their worktrees.
    for _pid in "${AGENT_PIDS[@]}"; do kill "$_pid" 2>/dev/null || true; done
    wait 2>/dev/null
    cleanup_task_worktrees
    exit 130
' INT TERM

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

# Absolute path to the .ralph directory (resolves correctly regardless of the caller's CWD).
RALPH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SPEC_FILE=".ralph/spec.md"
GUARDRAILS_FILE=".ralph/prompts/guardrails.md"
AGENTS_FILE=".ralph/agents.md"
LOG_DIR=".ralph/logs"
# Use absolute paths so PARSER/GUTTER remain valid after cd into a per-task worktree.
PARSER="${RALPH_DIR}/stream/parser.sh"
GUTTER="${RALPH_DIR}/stream/gutter.sh"

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
    if [[ "$CURRENT_BRANCH" == "main" || "$CURRENT_BRANCH" == "master" || "$CURRENT_BRANCH" == "HEAD" ]]; then
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
    local PROMPT_CONTENT=""

    if [ -f "$GUARDRAILS_FILE" ]; then
        PROMPT_CONTENT="$(cat "$GUARDRAILS_FILE")
---
"
    fi

    if [ "$MODE" = "plan-work" ]; then
        PROMPT_CONTENT="${PROMPT_CONTENT}## Headless Planning Mode
You are running non-interactively via loop.sh. Complete all stages W1-W4 in a single autonomous pass using WORK_SCOPE as your primary input. Do not ask the user questions — make reasonable assumptions and document them in your final summary.

---
$(envsubst '$WORK_SCOPE' < "$PROMPT_FILE")"
    else
        PROMPT_CONTENT="${PROMPT_CONTENT}$(cat "$PROMPT_FILE")"
    fi

    if [ -f "$AGENTS_FILE" ]; then
        PROMPT_CONTENT="${PROMPT_CONTENT}
---
$(cat "$AGENTS_FILE")"
    fi

    printf '%s' "$PROMPT_CONTENT"
}

# Extract commit type and summary from a progress.md line.
# Sets COMMIT_TYPE and COMMIT_SUMMARY in the caller's scope.
extract_commit_parts() {
    local progress_line="$1"
    COMMIT_TYPE=""
    COMMIT_SUMMARY=""
    COMMIT_TYPE=$(printf '%s' "$progress_line" | sed -n 's/.*Iteration [0-9]*) \([a-z]*\):.*/\1/p')
    COMMIT_SUMMARY=$(printf '%s' "$progress_line" | sed -n 's/.*Iteration [0-9]*) [a-z]*: //p')
}

# --- Dry-run mode ---
if [ "$DRY_RUN" = "true" ]; then
    echo "=== DRY RUN: Full Concatenated Prompt ==="
    echo ""
    build_prompt
    echo ""
    echo "=== Sample Orchestrator Preamble (build mode, T1, iteration 1) ==="
    echo ""
    cat <<'PREAMBLE_EOF'
## Orchestrator Assignment
- **Assigned Task**: T1
- **Assigned Iteration**: 1
- **Mode**: parallel
---
PREAMBLE_EOF
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

# --- Shared engine dispatcher (single source of truth for all engine invocations) ---
# Runs the engine pipeline and stores exit codes in DISPATCH_PIPE_STATUSES:
#   [0] = engine exit code, [1] = parser exit code (10 = token rotate).
# Callers must read DISPATCH_PIPE_STATUSES immediately after this returns.
dispatch_engine() {
    local prompt="$1"
    export LOG_FILE ENGINE
    if [ "$ENGINE" = "gemini" ]; then
        gemini -p "$prompt" -y "${MODEL_ARGS[@]}" 2>&1 | bash "$PARSER"
        DISPATCH_PIPE_STATUSES=("${PIPESTATUS[@]}")
    elif [ "$ENGINE" = "claude" ]; then
        claude -p "$prompt" --dangerously-skip-permissions --output-format stream-json --verbose "${MODEL_ARGS[@]}" </dev/null 2>&1 | bash "$PARSER"
        DISPATCH_PIPE_STATUSES=("${PIPESTATUS[@]}")
    elif [ "$ENGINE" = "copilot" ]; then
        copilot -p "$prompt" --allow-all-tools "${MODEL_ARGS[@]}" 2>&1 | bash "$PARSER"
        DISPATCH_PIPE_STATUSES=("${PIPESTATUS[@]}")
    else
        echo "ERROR: Unknown engine '$ENGINE'. Use 'gemini', 'claude', or 'copilot'." >&2
        return 1
    fi
}

# --- Engine invocation (used for plan-work mode and verification iterations) ---
invoke_engine() {
    local PROMPT="$1"
    local LOG_FILE_ARG="$2"
    export LOG_FILE="$LOG_FILE_ARG" ENGINE

    dispatch_engine "$PROMPT"
    local ENGINE_CODE="${DISPATCH_PIPE_STATUSES[0]}"
    local PARSER_CODE="${DISPATCH_PIPE_STATUSES[1]}"

    if [ "$PARSER_CODE" -eq 10 ]; then
        return 10
    elif [ "$ENGINE_CODE" -ne 0 ]; then
        return "$ENGINE_CODE"
    elif [ "$PARSER_CODE" -ne 0 ]; then
        return "$PARSER_CODE"
    fi
    return 0
}

# =============================================================================
# Parallel execution functions (build mode only)
# =============================================================================

# Select eligible tasks for parallel execution.
# Outputs one "TASK_ID:SCORE" pair per line, sorted by score desc (or row order
# if mode=ordered), up to $max tasks. Parent tasks (containers) are excluded.
select_parallel_tasks() {
    local spec="$1" max="$2" mode="$3"
    awk -F'|' -v max="$max" -v sel_mode="$mode" '
    BEGIN { n_pending = 0 }
    /^\|[-: ]+\|/ { next }
    /^\| *ID *\|/  { next }
    /\| *completed *\|/ {
        id = $2; gsub(/[[:space:]]/, "", id)
        if (id != "") completed[id] = 1
    }
    # Build parent set from ALL statuses: a parent whose only children are 'proposed'
    # (not yet approved) is still excluded from direct selection as a leaf task.
    /\| *(pending|completed|failed|blocked|proposed) *\|/ {
        parent = $11; gsub(/[[:space:]]/, "", parent)
        if (parent != "" && parent != "-") parent_tasks[parent] = 1
    }
    /\| *pending *\|/ {
        id    = $2;  gsub(/[[:space:]]/, "", id)
        score = $8;  gsub(/[[:space:]]/, "", score)
        deps  = $10; gsub(/[[:space:]]/, "", deps)
        if (id != "") {
            pending_ids[n_pending]    = id
            pending_scores[n_pending] = score + 0
            pending_deps[n_pending]   = deps
            pending_order[n_pending]  = NR
            n_pending++
        }
    }
    END {
        n_elig = 0
        for (i = 0; i < n_pending; i++) {
            id = pending_ids[i]
            if (id in parent_tasks) continue
            deps = pending_deps[i]
            ok = 1
            if (deps != "" && deps != "None" && deps != "-") {
                n = split(deps, da, ",")
                for (d = 1; d <= n; d++) {
                    dep = da[d]; gsub(/[[:space:]]/, "", dep)
                    if (dep != "" && dep != "None" && !(dep in completed)) { ok = 0; break }
                }
            }
            if (ok) {
                elig_ids[n_elig]    = id
                elig_scores[n_elig] = pending_scores[i]
                elig_order[n_elig]  = pending_order[i]
                n_elig++
            }
        }
        # Bubble sort: scored=desc score (asc order on tie), ordered=asc row order
        for (i = 0; i < n_elig - 1; i++) {
            for (j = 0; j < n_elig - 1 - i; j++) {
                sw = 0
                if (sel_mode == "ordered") {
                    if (elig_order[j] > elig_order[j+1]) sw = 1
                } else {
                    if (elig_scores[j] < elig_scores[j+1]) sw = 1
                    else if (elig_scores[j] == elig_scores[j+1] && elig_order[j] > elig_order[j+1]) sw = 1
                }
                if (sw) {
                    t = elig_ids[j];    elig_ids[j]    = elig_ids[j+1];    elig_ids[j+1]    = t
                    t = elig_scores[j]; elig_scores[j] = elig_scores[j+1]; elig_scores[j+1] = t
                    t = elig_order[j];  elig_order[j]  = elig_order[j+1];  elig_order[j+1]  = t
                }
            }
        }
        count = (n_elig < max) ? n_elig : max
        for (i = 0; i < count; i++) print elig_ids[i] ":" elig_scores[i]
    }
    ' "$spec"
}

# Return the last N failure log lines for a task from the main worktree's progress.md
get_retry_context() {
    local task_id="$1"
    # grep -F: fixed-string match so T1.1's dot does not act as a regex wildcard.
    # grep -v '^##': strip any markdown heading injections a prior agent may have written.
    [ -f ".ralph/progress.md" ] && grep -F "fail: ${task_id} failed" ".ralph/progress.md" | grep -v '^##' | tail -3 || true
}

# Build a prompt with an orchestrator preamble prepended to the base prompt.
# batch_size: number of tasks dispatched in this batch (determines mode label).
# base_prompt: pre-built base prompt string; if empty, build_prompt() is called once.
#   batch_size==1  -> Mode: sequential (agent still runs step 4 verification trigger)
#   batch_size > 1 -> Mode: parallel   (orchestrator handles step 4 + iteration counter)
build_agent_prompt() {
    local task_id="$1" iteration="$2" retry_context="$3" batch_size="${4:-1}" base_prompt="$5"
    local preamble mode_label

    if [ "$batch_size" -gt 1 ]; then
        mode_label="parallel"
    else
        mode_label="sequential"
    fi

    preamble="## Orchestrator Assignment
- **Assigned Task**: ${task_id}
- **Assigned Iteration**: ${iteration}
- **Mode**: ${mode_label}"

    if [ -n "$retry_context" ]; then
        preamble="${preamble}

## Retry Context
Prior failure entries for ${task_id}:
${retry_context}"
    fi

    preamble="${preamble}
---
"
    printf '%s\n%s' "$preamble" "${base_prompt:-$(build_prompt)}"
}

# Run one agent in a task worktree. Designed to be called as a background job (&).
# The cd affects only this subshell; the parent process stays in WORKTREE_PATH.
# prompt_file: absolute path to a temp file containing the full prompt; read and deleted here
# to avoid ARG_MAX limits on large prompts passed as positional arguments.
run_parallel_agent() {
    local task_id="$1" iteration="$2" task_worktree="$3" prompt_file="$4"
    local engine_code parser_code prompt

    cd "$task_worktree" || return 1
    mkdir -p ".ralph/logs"
    export LOG_FILE=".ralph/logs/iteration_${iteration}.log" ENGINE

    prompt=$(cat "$prompt_file") && rm -f "$prompt_file"

    dispatch_engine "$prompt"
    engine_code="${DISPATCH_PIPE_STATUSES[0]}"
    parser_code="${DISPATCH_PIPE_STATUSES[1]}"

    if   [ "$parser_code" -eq 10 ]; then return 10
    elif [ "$engine_code" -ne  0 ]; then return "$engine_code"
    elif [ "$parser_code" -ne  0 ]; then return "$parser_code"
    fi
    return 0
}

# Commit changes in a task worktree, then merge that branch into HEAD (main worktree).
# Returns 0 on success, 1 if a source-code merge conflict forces an abort.
commit_and_merge() {
    local task_id="$1" task_worktree="$2" task_branch="$3" iteration="$4"

    # Commit task worktree changes (if any)
    if [ -n "$(git -C "$task_worktree" status --porcelain)" ]; then
        local progress_line safe_summary
        progress_line=$(grep -m1 "(Iteration ${iteration})" "${task_worktree}/.ralph/progress.md" 2>/dev/null || true)
        extract_commit_parts "$progress_line"
        COMMIT_TYPE=${COMMIT_TYPE:-"chore"}
        COMMIT_SUMMARY=${COMMIT_SUMMARY:-"${task_id} automated progress"}
        safe_summary=$(printf '%s' "$COMMIT_SUMMARY" | tr -d '`$')

        git -C "$task_worktree" add -u
        git -C "$task_worktree" add \
            ".ralph/spec.md" ".ralph/progress.md" ".ralph/changelog.md" \
            ".ralph/agents.md" ".ralph/logs/" ".ralph/specs/" 2>/dev/null || true
        printf '%s\n' "${COMMIT_TYPE}(ralph): ${safe_summary}" | \
            git -C "$task_worktree" commit -F -
    fi

    # Attempt merge into main worktree (running from WORKTREE_PATH)
    if ! git merge --no-ff "$task_branch" -m "merge(ralph): ${task_id}"; then
        local conflicting has_source_conflict=false
        conflicting=$(git diff --name-only --diff-filter=U)
        while IFS= read -r f; do
            if [ -n "$f" ] && [[ "$f" != .ralph/* ]]; then
                has_source_conflict=true
                break
            fi
        done <<< "$conflicting"

        if [ "$has_source_conflict" = "true" ]; then
            git merge --abort
            echo "Merge conflict in source files for ${task_id} — aborting merge." >&2
            return 1
        else
            # Only .ralph/ files conflict: resolve per-file based on semantics
            while IFS= read -r f; do
                [ -z "$f" ] && continue
                case "$f" in
                    .ralph/progress.md|.ralph/changelog.md|.ralph/agents.md)
                        # Append-only files: keep both sides, remove only the three marker lines
                        sedi '/^<<<<<<</d; /^=======/d; /^>>>>>>>/d' "$f"
                        # Best-effort deduplication: if two agents appended identical lines
                        # (e.g. the same agents.md learning or same progress entry), remove
                        # subsequent occurrences. Empty lines are always preserved for formatting.
                        awk 'NF == 0 || seen[$0]++ == 0' "$f" > "${f}.tmp" && mv "${f}.tmp" "$f"
                        ;;
                    .ralph/spec.md)
                        # Preserve task progress: two-pass awk keeps the highest-ranked status
                        # per task ID across both conflict sides, then deduplicates task rows.
                        # Status rank: completed(5) > failed(4) > blocked(3) > pending(2) > proposed(1)
                        # This prevents a later-merged branch (with stale task statuses) from
                        # reverting completions recorded by earlier-merged branches in the batch.
                        awk -F'|' '
                        BEGIN { OFS="|" }
                        function rank(s) {
                            if (s == "completed") return 5
                            if (s == "failed")    return 4
                            if (s == "blocked")   return 3
                            if (s == "pending")   return 2
                            if (s == "proposed")  return 1
                            return 0
                        }
                        NR == FNR {
                            if (/^<<<<<<</ || /^=======/ || /^>>>>>>>/) next
                            if (/\| *(completed|failed|blocked|pending|proposed) *\|/) {
                                id = $2; gsub(/[[:space:]]/, "", id)
                                st = $9; gsub(/[[:space:]]/, "", st)
                                if (id != "" && rank(st) > rank(best[id])) best[id] = st
                            }
                            next
                        }
                        /^<<<<<<</ { in_theirs = 0; next }
                        /^=======/  { in_theirs = 1; next }
                        /^>>>>>>>/  { in_theirs = 0; next }
                        /\| *(completed|failed|blocked|pending|proposed) *\|/ {
                            id = $2; gsub(/[[:space:]]/, "", id)
                            st = $9; gsub(/[[:space:]]/, "", st)
                            if (id != "" && id in best) {
                                if (id in seen) next
                                seen[id] = 1
                                if (st != best[id]) $9 = " " best[id] " "
                            }
                            print; next
                        }
                        in_theirs { next }
                        { print }
                        ' "$f" "$f" > "${f}.tmp" && mv "${f}.tmp" "$f"
                        ;;
                    *)
                        # Other .ralph/ files: keep ours as safe default
                        sedi '/^<<<<<<</d; /^=======/,/^>>>>>>>/d' "$f"
                        ;;
                esac
            done <<< "$conflicting"
            git add .ralph/
            git commit -m "merge(ralph): ${task_id} (auto-resolved .ralph conflicts)"
        fi
    fi
    return 0
}

# Extract failure entry from a task worktree, optionally append to main progress.md,
# and block the task in spec.md if RALPH_MAX_RETRIES is reached.
# Pass skip_append=true when the caller has already written a synthetic failure entry.
handle_failed_agent() {
    local task_id="$1" task_worktree="$2" skip_append="${3:-false}"

    if [ "$skip_append" != "true" ]; then
        local failure_entry
        # Anchor to "fail: TASKID failed" to prevent T1 matching T10, T11, T1.1, etc.
        failure_entry=$(grep -F "fail: ${task_id} failed" "${task_worktree}/.ralph/progress.md" 2>/dev/null | tail -1)
        if [ -n "$failure_entry" ]; then
            printf '%s\n' "$failure_entry" >> ".ralph/progress.md"
        fi
    fi

    local failure_count
    failure_count=$(grep -cF "fail: ${task_id} failed" ".ralph/progress.md" 2>/dev/null || echo 0)
    if [ "$failure_count" -ge "$RALPH_MAX_RETRIES" ]; then
        echo "Task ${task_id} has failed ${failure_count} times — marking blocked." >&2
        awk -F'|' -v task="${task_id}" '
        BEGIN { OFS="|" }
        {
            id = $2; gsub(/[[:space:]]/, "", id)
            st = $9; gsub(/[[:space:]]/, "", st)
            if (id == task && (st == "pending" || st == "failed")) $9 = " blocked "
            print
        }
        ' ".ralph/spec.md" > ".ralph/spec.md.tmp" && mv ".ralph/spec.md.tmp" ".ralph/spec.md"
    fi
}

# Update Current Iteration and Last Update in spec.md after a parallel batch
reconcile_spec() {
    local base_iteration="$1" n_dispatched="$2"
    local new_iteration=$((base_iteration + n_dispatched))
    local now
    now=$(date '+%Y-%m-%d %H:%M')
    sedi -e "s/^\*\*Current Iteration\*\*: [0-9]*/\*\*Current Iteration\*\*: ${new_iteration}/" \
         -e "s/^\*\*Last Update\*\*: .*/\*\*Last Update\*\*: ${now}/" ".ralph/spec.md"
}

# After a batch, mark any parent task completed when all its sub-tasks are completed.
# Single two-pass awk: O(n) over spec.md regardless of the number of parent tasks.
update_parent_tasks() {
    awk -F'|' '
    BEGIN { OFS="|" }
    # Pass 1: build parent→{total, completed} maps from the Parent column
    NR == FNR {
        if (/\| *(pending|completed|failed|blocked|proposed) *\|/) {
            p  = $11; gsub(/[[:space:]]/, "", p)
            st = $9;  gsub(/[[:space:]]/, "", st)
            if (p != "" && p != "-") {
                parent_total[p]++
                if (st == "completed") parent_done[p]++
            }
        }
        next
    }
    # Pass 2: mark eligible parents (all children completed) as completed
    {
        id = $2; gsub(/[[:space:]]/, "", id)
        st = $9; gsub(/[[:space:]]/, "", st)
        if (id in parent_total && parent_total[id] > 0 \
            && (id in parent_done) && parent_done[id] == parent_total[id] \
            && (st == "pending" || st == "failed" || st == "blocked")) {
            $9 = " completed "
        }
        print
    }
    ' ".ralph/spec.md" ".ralph/spec.md" > ".ralph/spec.md.tmp" && mv ".ralph/spec.md.tmp" ".ralph/spec.md"
}

# =============================================================================
# Build mode worktree setup (runs once before the main loop)
# =============================================================================

if [ "$MODE" = "build" ]; then
    PROJECT_SLUG=$(grep -m1 "^# Ralph Project Specification:" "$SPEC_FILE" \
        | sed 's/^# Ralph Project Specification: //' \
        | tr '[:upper:]' '[:lower:]' \
        | tr -cs '[:alnum:]' '-' \
        | sed 's/^-//;s/-$//')
    PROJECT_SLUG=${PROJECT_SLUG:-loop}
    RALPH_BRANCH="ralph/${PROJECT_SLUG}"

    # Compute absolute worktree path: sibling directory of project root
    PROJECT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
    PROJECT_PARENT=$(dirname "$PROJECT_ROOT")
    PROJECT_NAME=$(basename "$PROJECT_ROOT")
    WORKTREE_PATH="${PROJECT_PARENT}/${PROJECT_NAME}-ralph-${PROJECT_SLUG}"

    # Create or reuse the ralph branch
    if ! git rev-parse --verify "$RALPH_BRANCH" &>/dev/null; then
        echo "Creating ralph branch $RALPH_BRANCH..."
        git branch "$RALPH_BRANCH"
    fi

    # Create or reuse the main ralph worktree
    if [ ! -d "$WORKTREE_PATH" ]; then
        echo "Creating main worktree at $WORKTREE_PATH (branch: $RALPH_BRANCH)..."
        git worktree add "$WORKTREE_PATH" "$RALPH_BRANCH"
    else
        echo "Reusing existing worktree at $WORKTREE_PATH..."
        ACTUAL_BRANCH=$(git -C "$WORKTREE_PATH" symbolic-ref --short HEAD 2>/dev/null || echo "DETACHED")
        if [ "$ACTUAL_BRANCH" != "$RALPH_BRANCH" ]; then
            echo "ERROR: Worktree at $WORKTREE_PATH is on branch '$ACTUAL_BRANCH', expected '$RALPH_BRANCH'." >&2
            echo "Remove the worktree and re-run: git worktree remove --force '$WORKTREE_PATH'" >&2
            exit 1
        fi
    fi

    # Switch to the worktree; all subsequent git operations run from here
    cd "$WORKTREE_PATH" || { echo "ERROR: Cannot cd to worktree $WORKTREE_PATH" >&2; exit 1; }
    BRANCH="$RALPH_BRANCH"
    mkdir -p "$LOG_DIR"
fi

ITERATION=$(sed -n 's/.*\*\*Current Iteration\*\*: \([0-9][0-9]*\).*/\1/p' "$SPEC_FILE" 2>/dev/null | head -1)
ITERATION=${ITERATION:-0}

echo "Starting Headless Ralph Loop [mode: $MODE] with $ENGINE on branch $BRANCH (resuming from iteration $ITERATION)..."
[ "$MODE" = "build" ] && echo "Worktree: $WORKTREE_PATH  |  Max parallel: $MAX_PARALLEL  |  Max retries: $RALPH_MAX_RETRIES"

# =============================================================================
# plan-work mode: fully sequential, no worktrees (unchanged behaviour)
# =============================================================================

if [ "$MODE" = "plan-work" ]; then
    while true; do
        ITERATION=$((ITERATION + 1))
        if [ "$ITERATION" -gt "$MAX_ITERATIONS" ]; then
            echo "WARNING: Max iterations reached ($MAX_ITERATIONS). Stopping loop."
            exit 1
        fi
        echo "--- Iteration $ITERATION ---"
        LOG_FILE="$LOG_DIR/iteration_$ITERATION.log"
        FULL_PROMPT=$(build_prompt)
        PENDING_BEFORE=$(grep -cE "\| *pending *\|" "$SPEC_FILE" 2>/dev/null || echo 0)

        invoke_engine "$FULL_PROMPT" "$LOG_FILE"
        ENGINE_EXIT=$?

        if [ "$ENGINE_EXIT" -eq 10 ]; then
            echo "Token rotate: context limit reached. Treating as clean iteration end."
        elif [ "$ENGINE_EXIT" -ne 0 ]; then
            echo "WARNING: Engine exited with code $ENGINE_EXIT." >&2
        fi

        if [ -n "$(git status --porcelain)" ]; then
            echo "Committing changes (branch: $BRANCH)..."
            PROGRESS_LINE=$(grep -m1 "(Iteration $ITERATION) [a-z]*:" ".ralph/progress.md" 2>/dev/null || true)
            extract_commit_parts "$PROGRESS_LINE"
            COMMIT_TYPE=${COMMIT_TYPE:-"chore"}
            COMMIT_SUMMARY=${COMMIT_SUMMARY:-"Iteration $ITERATION automated progress sync"}
            SAFE_SUMMARY=$(printf '%s' "$COMMIT_SUMMARY" | tr -d '`$')
            git add -u
            git add .ralph/spec.md .ralph/progress.md .ralph/changelog.md .ralph/agents.md \
                .ralph/logs/ .ralph/specs/ 2>/dev/null || true
            printf '%s\n' "${COMMIT_TYPE}(ralph): ${SAFE_SUMMARY}" | git commit -F -
            if [ "$PUSH_CHANGES" = "true" ]; then
                echo "Pushing to GitHub (branch: $BRANCH)..."
                git push origin "$BRANCH"
            fi
        fi

        PENDING_AFTER=$(grep -cE "\| *pending *\|" "$SPEC_FILE" 2>/dev/null || echo 0)
        if [ "$PENDING_AFTER" -gt "$PENDING_BEFORE" ]; then
            echo "Plan-work session complete. New pending tasks written to spec.md."
            echo "Switch to build mode: bash .ralph/loop.sh [engine] [max_iterations] [push] [model] build"
            exit 0
        fi
        echo "Iteration $ITERATION complete. Continuing plan-work session..."
    done
fi

# =============================================================================
# build mode: parallel batch execution with git worktrees
# =============================================================================

while true; do
    # Read current iteration counter from spec (so resuming after interruption works)
    BASE_ITERATION=$(sed -n 's/.*\*\*Current Iteration\*\*: \([0-9][0-9]*\).*/\1/p' "$SPEC_FILE" 2>/dev/null | head -1)
    BASE_ITERATION=${BASE_ITERATION:-0}

    TASK_SELECTION_MODE=$(sed -n '/Task Selection Mode/{ s/.*:[[:space:]]*//; s/[[:space:]].*//; p; }' "$SPEC_FILE" 2>/dev/null | head -1)
    case "$TASK_SELECTION_MODE" in
        scored|ordered) ;;
        *) TASK_SELECTION_MODE="" ;;
    esac
    TASK_SELECTION_MODE=${TASK_SELECTION_MODE:-scored}

    # Max iterations check: stop if we've already run enough iterations
    if [ "$BASE_ITERATION" -ge "$MAX_ITERATIONS" ]; then
        echo "WARNING: Max iterations reached ($MAX_ITERATIONS). Stopping loop."
        exit 1
    fi

    # --- VERIFICATION_PENDING: run a single sequential verification agent ---
    if grep -qE "\*\*Overall Status\*\*:\s*VERIFICATION_PENDING" "$SPEC_FILE"; then
        VERIFY_ITERATION=$((BASE_ITERATION + 1))
        echo "--- Verification Iteration $VERIFY_ITERATION ---"
        VERIFY_LOG="${LOG_DIR}/iteration_${VERIFY_ITERATION}.log"
        VERIFY_PROMPT=$(build_prompt)

        invoke_engine "$VERIFY_PROMPT" "$VERIFY_LOG"
        VERIFY_EXIT=$?

        if [ "$VERIFY_EXIT" -eq 10 ]; then
            echo "Token rotate during verification: treating as clean iteration end."
        elif [ "$VERIFY_EXIT" -ne 0 ]; then
            echo "WARNING: Verification agent exited with code $VERIFY_EXIT." >&2
        fi

        # Advance the iteration counter so the next batch starts after this verification slot.
        reconcile_spec "$BASE_ITERATION" 1

        if [ -n "$(git status --porcelain)" ]; then
            PROGRESS_LINE=$(grep -m1 "(Iteration ${VERIFY_ITERATION})" ".ralph/progress.md" 2>/dev/null || true)
            extract_commit_parts "$PROGRESS_LINE"
            COMMIT_TYPE=${COMMIT_TYPE:-"chore"}
            SAFE_SUMMARY=$(printf '%s' "${COMMIT_SUMMARY:-"Iteration ${VERIFY_ITERATION} verification"}" | tr -d '`$')
            git add -u
            git add .ralph/spec.md .ralph/progress.md .ralph/changelog.md .ralph/agents.md \
                .ralph/logs/ .ralph/specs/ 2>/dev/null || true
            printf '%s\n' "${COMMIT_TYPE}(ralph): ${SAFE_SUMMARY}" | git commit -F -
            if [ "$PUSH_CHANGES" = "true" ]; then
                git push origin "$BRANCH"
            fi
        fi

        if [ -f "$GUTTER" ] && ! RALPH_GUTTER_LOOKBACK=$((MAX_PARALLEL * 3)) bash "$GUTTER"; then
            echo "GUTTER DETECTED during verification. Human review needed." >&2
            exit 4
        fi

        if grep -qE "\*\*Overall Status\*\*:\s*MISSION_COMPLETE" "$SPEC_FILE"; then
            echo "Goal reached. Overall Status: MISSION_COMPLETE"
            exit 0
        fi
        echo "Verification iteration complete. Continuing..."
        continue
    fi

    # --- Select tasks for this batch ---
    # while-read loop used instead of mapfile for bash 3.2 compatibility (macOS default shell).
    TASK_PAIRS=()
    while IFS= read -r line; do
        [ -n "$line" ] && TASK_PAIRS+=("$line")
    done < <(select_parallel_tasks "$SPEC_FILE" "$MAX_PARALLEL" "$TASK_SELECTION_MODE")

    if [ ${#TASK_PAIRS[@]} -eq 0 ]; then
        if grep -qE "\*\*Overall Status\*\*:\s*MISSION_COMPLETE" "$SPEC_FILE"; then
            echo "Goal reached. Overall Status: MISSION_COMPLETE"
            exit 0
        fi
        if grep -qE "\| *proposed *\|" "$SPEC_FILE"; then
            echo "PAUSED: Proposed tasks require human review. Promote to 'pending' and re-run." >&2
            exit 3
        fi
        # If all tasks are in terminal states (completed/blocked/failed) but VERIFICATION_PENDING
        # has not been set yet, trigger it now. This handles batches where some tasks ended up
        # blocked/failed — the loop would otherwise spin or exit with code 2 incorrectly.
        if ! grep -qE "\| *(pending|proposed) *\|" "$SPEC_FILE" \
            && ! grep -qE "\*\*Overall Status\*\*:\s*VERIFICATION_PENDING" "$SPEC_FILE"; then
            if grep -qE "\| *failed *\|" "$SPEC_FILE"; then
                echo "WARNING: Tasks in 'failed' state remain unresolved. Human review needed." >&2
                exit 2
            fi
            echo "All tasks in terminal states. Triggering VERIFICATION_PENDING..."
            sedi 's/\*\*Overall Status\*\*: IN_PROGRESS/\*\*Overall Status\*\*: VERIFICATION_PENDING/' ".ralph/spec.md"
            echo "- **[$(date '+%Y-%m-%d %H:%M')]** (Iteration ${BASE_ITERATION}) chore: All tasks completed or blocked. Verification required." >> ".ralph/progress.md"
            git add -u
            git add .ralph/spec.md .ralph/progress.md 2>/dev/null || true
            git commit -m "chore(ralph): trigger verification (all tasks terminal)"
            [ "$PUSH_CHANGES" = "true" ] && git push origin "$BRANCH"
            continue
        fi
        echo "WARNING: No eligible pending tasks remain but mission is not complete. Stopping loop." >&2
        exit 2
    fi

    echo "--- Batch: base iteration $BASE_ITERATION, ${#TASK_PAIRS[@]} candidate(s): $(IFS=' '; echo "${TASK_PAIRS[*]}") ---"

    # Reset per-batch tracking arrays
    TASK_WORKTREES=()
    TASK_BRANCHES=()
    AGENT_ITERATIONS=()
    AGENT_PIDS=()
    AGENT_EXIT_CODES=()
    VALID_TASK_PAIRS=()

    # Create per-task branches and worktrees; populate VALID_TASK_PAIRS for valid IDs only.
    # Invalid IDs are skipped here and excluded from all subsequent spawn/wait/merge loops.
    # _valid_idx tracks insertion index into parallel arrays (TASK_WORKTREES, TASK_BRANCHES,
    # AGENT_ITERATIONS) independently of i (the TASK_PAIRS index used for iteration numbering).
    _valid_idx=0
    for i in "${!TASK_PAIRS[@]}"; do
        task_pair="${TASK_PAIRS[$i]}"
        task_id="${task_pair%%:*}"
        # Validate task ID: must be T<digits> or T<digits>.<digits> (e.g. T1, T1.2).
        # Rejects malformed IDs that could cause path traversal or awk injection.
        if [[ ! "$task_id" =~ ^T[0-9]+(\.[0-9]+)?$ ]]; then
            echo "ERROR: Invalid task ID '${task_id}' — skipping." >&2
            continue
        fi
        iteration=$((BASE_ITERATION + i + 1))
        task_branch="${RALPH_BRANCH}/${task_id}"
        task_worktree="${WORKTREE_PATH}-${task_id}"

        # Ensure a clean slate: remove stale worktree first (so the branch is no longer
        # checked out), then delete the branch, then recreate both from HEAD.
        # Correct order matters: git refuses to delete a checked-out branch.
        if [ -d "$task_worktree" ]; then
            git worktree remove --force "$task_worktree" 2>/dev/null || true
        fi
        if git rev-parse --verify "$task_branch" &>/dev/null; then
            git branch -D "$task_branch" 2>/dev/null || true
        fi
        git branch "$task_branch" HEAD
        git worktree add "$task_worktree" "$task_branch"

        TASK_WORKTREES[$_valid_idx]="$task_worktree"
        TASK_BRANCHES[$_valid_idx]="$task_branch"
        AGENT_ITERATIONS[$_valid_idx]="$iteration"
        VALID_TASK_PAIRS+=("$task_pair")
        _valid_idx=$((_valid_idx + 1))
        echo "  Worktree ready: ${task_id} -> ${task_worktree} (iteration: $iteration)"
    done

    # Recount using only valid (successfully set up) tasks
    N_TASKS=${#VALID_TASK_PAIRS[@]}

    if [ "$N_TASKS" -eq 0 ]; then
        echo "WARNING: No valid tasks after worktree setup. Skipping batch." >&2
        continue
    fi

    echo "  Dispatching $N_TASKS valid task(s)..."

    # Cache base prompt once per batch (all agents share identical base; only preamble differs)
    CACHED_BASE_PROMPT=$(build_prompt)

    # Restrict prompt file permissions: contains full task context, must not be world-readable
    umask 077

    # Spawn parallel agents (one per task)
    for _i in "${!VALID_TASK_PAIRS[@]}"; do
        task_pair="${VALID_TASK_PAIRS[$_i]}"
        task_id="${task_pair%%:*}"
        iteration="${AGENT_ITERATIONS[$_i]}"
        task_worktree="${TASK_WORKTREES[$_i]}"
        retry_ctx=$(get_retry_context "$task_id")

        # Write prompt to a temp file to avoid ARG_MAX limits on large agents.md payloads.
        # Use WORKTREE_PATH-anchored absolute path so the subshell can find it after cd.
        PROMPT_TMP="${WORKTREE_PATH}/${LOG_DIR}/prompt_${task_id}_${iteration}.txt"
        build_agent_prompt "$task_id" "$iteration" "$retry_ctx" "$N_TASKS" "$CACHED_BASE_PROMPT" > "$PROMPT_TMP"
        run_parallel_agent "$task_id" "$iteration" "$task_worktree" "$PROMPT_TMP" &
        AGENT_PIDS[$_i]=$!
        echo "  Agent spawned: ${task_id} (PID: ${AGENT_PIDS[$_i]})"
    done

    # Restore default umask after all prompt files have been written
    umask 022

    # Wait for all agents and collect exit codes
    for _i in "${!VALID_TASK_PAIRS[@]}"; do
        task_id="${VALID_TASK_PAIRS[$_i]%%:*}"
        wait "${AGENT_PIDS[$_i]}" 2>/dev/null
        AGENT_EXIT_CODES[$_i]=$?
        echo "  Agent done: ${task_id} -> exit ${AGENT_EXIT_CODES[$_i]}"
    done

    # Process results in score order (VALID_TASK_PAIRS preserves selection order)
    N_MERGED=0
    for _i in "${!VALID_TASK_PAIRS[@]}"; do
        task_pair="${VALID_TASK_PAIRS[$_i]}"
        task_id="${task_pair%%:*}"
        exit_code="${AGENT_EXIT_CODES[$_i]}"
        task_worktree="${TASK_WORKTREES[$_i]}"
        task_branch="${TASK_BRANCHES[$_i]}"
        iteration="${AGENT_ITERATIONS[$_i]}"

        if [ "$exit_code" -eq 0 ] || [ "$exit_code" -eq 10 ]; then
            if [ "$exit_code" -eq 10 ]; then
                # Token rotate: check whether the agent actually updated the task status.
                # If the task is still 'pending' in the worktree spec, the agent was cut off
                # before finishing — skip the merge so the task retries naturally next batch.
                task_wt_status=$(awk -F'|' -v id="$task_id" '
                    /\| *(completed|failed|blocked|pending|proposed) *\|/ {
                        tid = $2; gsub(/[[:space:]]/, "", tid)
                        if (tid == id) { st = $9; gsub(/[[:space:]]/, "", st); print st; exit }
                    }
                ' "${task_worktree}/.ralph/spec.md" 2>/dev/null)
                if [ "$task_wt_status" = "pending" ]; then
                    echo "  Token rotate: ${task_id} still pending — skipping merge, task will retry." >&2
                    printf '%s\n' "- **[$(date '+%Y-%m-%d %H:%M')]** (Iteration ${iteration}) chore: ${task_id} token-rotated before completion. Task will retry next batch." >> ".ralph/progress.md"
                    continue
                fi
                echo "  Token rotate for ${task_id}: task was updated, proceeding with merge."
            fi
            if commit_and_merge "$task_id" "$task_worktree" "$task_branch" "$iteration"; then
                N_MERGED=$((N_MERGED + 1))
                echo "  Merged: ${task_id}"
                # Detect protocol-compliant failure: agent exited 0 but marked task failed in spec
                if grep -qE "\| *${task_id} *\|.*\| *failed *\|" ".ralph/spec.md"; then
                    echo "  Protocol failure detected for ${task_id} — checking retry budget." >&2
                    handle_failed_agent "$task_id" "$task_worktree" "true"
                    # If max retries not yet exhausted (task still failed, not blocked), reset to pending
                    if grep -qE "\| *${task_id} *\|.*\| *failed *\|" ".ralph/spec.md"; then
                        awk -F'|' -v task="${task_id}" '
                        BEGIN { OFS="|" }
                        {
                            id = $2; gsub(/[[:space:]]/, "", id)
                            st = $9; gsub(/[[:space:]]/, "", st)
                            if (id == task && st == "failed") $9 = " pending "
                            print
                        }' ".ralph/spec.md" > ".ralph/spec.md.tmp" && mv ".ralph/spec.md.tmp" ".ralph/spec.md"
                        echo "  Reset ${task_id} from failed -> pending for retry." >&2
                    fi
                fi
            else
                echo "  Source conflict for ${task_id}: will retry next batch." >&2
                # Use merge-conflict: prefix (not fail:) so it is excluded from RALPH_MAX_RETRIES
                # counting. The agent itself succeeded; only the merge failed due to sibling conflict.
                echo "- **[$(date '+%Y-%m-%d %H:%M')]** (Iteration ${iteration}) merge-conflict: ${task_id} deferred. Reason: source file merge conflict with concurrent task." >> ".ralph/progress.md"
                # Do NOT call handle_failed_agent — task stays pending and will be retried next batch
            fi
        else
            echo "  Agent failed: ${task_id} (exit: $exit_code)" >&2
            # If the agent crashed without writing a failure entry, generate a synthetic one so
            # RALPH_MAX_RETRIES counting works and the task can eventually be auto-blocked.
            if ! grep -qF "fail: ${task_id} failed" "${task_worktree}/.ralph/progress.md" 2>/dev/null; then
                printf '%s\n' "- **[$(date '+%Y-%m-%d %H:%M')]** (Iteration ${iteration}) fail: ${task_id} failed. Reason: Agent exited with code ${exit_code} without writing a failure entry (possible crash or OOM). Avoid: check engine stability and reduce task scope." >> ".ralph/progress.md"
                handle_failed_agent "$task_id" "$task_worktree" "true"
            else
                handle_failed_agent "$task_id" "$task_worktree"
            fi
        fi
    done

    # Reconcile spec.md iteration counter and timestamp, then check parent completion.
    # Advance by N_MERGED (not N_TASKS) so failed-only batches don't wastefully consume
    # the entire max_iterations budget. Always advance by at least 1 to avoid infinite loops.
    reconcile_spec "$BASE_ITERATION" "$(( N_MERGED > 0 ? N_MERGED : 1 ))"
    update_parent_tasks

    # Check if all tasks are done — set VERIFICATION_PENDING for the next iteration
    if ! grep -qE "\| *pending *\|" "$SPEC_FILE" \
        && ! grep -qE "\| *failed *\|" "$SPEC_FILE" \
        && ! grep -qE "\*\*Overall Status\*\*:\s*VERIFICATION_PENDING" "$SPEC_FILE" \
        && ! grep -qE "\*\*Overall Status\*\*:\s*MISSION_COMPLETE" "$SPEC_FILE" \
        && ! grep -qE "\| *proposed *\|" "$SPEC_FILE"; then
        echo "All tasks completed. Triggering VERIFICATION_PENDING..."
        sedi 's/\*\*Overall Status\*\*: IN_PROGRESS/\*\*Overall Status\*\*: VERIFICATION_PENDING/' ".ralph/spec.md"
        echo "- **[$(date '+%Y-%m-%d %H:%M')]** (Iteration $((BASE_ITERATION + N_MERGED))) chore: All tasks completed. Verification iteration required next." >> ".ralph/progress.md"
    fi

    # Commit all batch results (reconciled spec + progress + any remaining changes)
    if [ -n "$(git status --porcelain)" ]; then
        git add -u
        git add .ralph/spec.md .ralph/progress.md .ralph/changelog.md .ralph/agents.md \
            .ralph/logs/ .ralph/specs/ 2>/dev/null || true
        git commit -m "chore(ralph): batch complete (base ${BASE_ITERATION}, merged ${N_MERGED}/${N_TASKS})"
    fi

    # Single push after the full batch (all merges + reconciliation complete)
    if [ "$PUSH_CHANGES" = "true" ]; then
        echo "Pushing to origin (branch: $BRANCH)..."
        git push origin "$BRANCH"
    fi

    # Cleanup per-task worktrees and branches
    cleanup_task_worktrees

    # Gutter detection (runs on merged spec).
    # Scale LOOKBACK to cover ≥3 full batches of history for effective pattern detection.
    if [ -f "$GUTTER" ]; then
        if ! RALPH_GUTTER_LOOKBACK=$((MAX_PARALLEL * 3)) bash "$GUTTER"; then
            echo "GUTTER DETECTED: Agent appears to be in a rut. Human review needed." >&2
            echo "Check .ralph/progress.md for repeated patterns, then re-run or adjust spec." >&2
            exit 4
        fi
    fi

    # Final exit condition checks
    if grep -qE "\*\*Overall Status\*\*:\s*MISSION_COMPLETE" "$SPEC_FILE"; then
        echo "Goal reached. Overall Status: MISSION_COMPLETE"
        exit 0
    fi

    if [ "$N_MERGED" -eq 0 ] && ! grep -qE "\| *pending *\|" "$SPEC_FILE"; then
        if grep -qE "\| *proposed *\|" "$SPEC_FILE"; then
            echo "PAUSED: Proposed tasks require human review. Promote to 'pending' and re-run." >&2
            exit 3
        fi
        echo "WARNING: No pending tasks remain and no progress made. Stopping loop." >&2
        exit 2
    fi

    echo "Batch complete (${N_MERGED}/${N_TASKS} merged). Reloading with fresh context..."
done
