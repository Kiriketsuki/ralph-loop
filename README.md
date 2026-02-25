# Ralph Loop

Ralph Loop is a headless, iterative agent orchestration pattern. An AI agent reads a project spec, executes exactly one task, updates the spec with the result, commits progress to git, then exits. The loop script re-invokes the agent from scratch each iteration, giving it a fresh context window every turn. This continues until `MISSION_COMPLETE` is reached or the loop detects a stuck or failed state.

---

## Concepts

**Why one task per turn?**
Each agent invocation starts with no memory of prior sessions. The spec file is the only persistent state. Committing the spec after every task means any iteration failure loses at most one task's worth of work, and the next iteration can resume accurately from the spec.

**What is the spec?**
`.ralph/spec.md` is both the project plan and the live state document. The agent reads it to know what to do and writes to it to record what was done. It is the single source of truth.

**What are the prompts?**
`.ralph/prompts/build.md` contains the headless agent's standing instructions. `.ralph/prompts/guardrails.md` holds shared rules injected into every prompt by `loop.sh`. Neither file changes between iterations. Put project-specific instructions in the spec's Technical Constraints section.

**What is `agents.md`?**
`.ralph/agents.md` is an operational guide seeded during planning (Stage 6.5). It records project-specific build, test, and lint commands. Headless agents read it at the start of each iteration and may append new learnings under `## Agent Learnings`.

---

## Two-Phase Model

Ralph operates in two distinct phases. **Never run `loop.sh` before completing a planning session.**

### Phase 1 -- Planning

```bash
bash .ralph/plan.sh [engine] [model] [mode] [work_scope]
```

Launches an interactive session with the planning agent (`prompts/plan.md`). The agent conducts a ten-stage Q&A across two tiers:

- **Product discovery** (stages 0a–0d): vision & audience, optional research validation, feature scoping, technical architecture
- **Execution planning** (stages 1–6): goal alignment, constraints, acceptance criteria, task decomposition, scoring, spec write, agents.md write

The entire product discovery tier is skippable — say "skip to task planning" at any point. The agent then writes a complete `.ralph/spec.md` and `.ralph/agents.md`.

After the session ends, **review `spec.md` and `agents.md` manually** before proceeding.

| Argument | Values | Default |
|:---|:---|:---|
| engine | `gemini`, `claude`, or `copilot` | `gemini` |
| model | model ID string | engine default |
| mode | `plan` or `plan-work` | `plan` |
| work_scope | description of scoped work (required when mode=plan-work) | `""` |

**Overwrite guard**: If `spec.md` already exists, `plan.sh` will prompt before overwriting (plan mode only).

**plan-work mode**: Adds new tasks to an existing spec for a focused feature branch. Requires a non-main branch and a work_scope description.

**PowerShell:**
```powershell
.\.ralph\plan.ps1 [-Engine gemini|claude|copilot] [-Model <model-id>] [-Mode plan|plan-work] [-WorkScope "description"]
```

### Phase 2 -- Execution

```bash
bash .ralph/loop.sh [engine] [max_iterations] [push] [model] [mode] [work_scope]
```

Runs the headless loop. Each iteration: reads spec, selects the highest-scored eligible task, executes it, updates spec and `progress.md`, commits, exits. Repeats until `MISSION_COMPLETE`, max iterations, or stuck state.

**Debug -- dry-run mode** (prints full prompt, no engine invoked):
```bash
bash .ralph/loop.sh claude 20 true "" build --dry-run
```

---

## Directory Structure

Copy this template into a `.ralph/` folder at your project root before starting:

```
<project-root>/
  .ralph/
    loop.sh           # Bash execution orchestrator
    plan.sh           # Bash planning launcher
    loop.ps1          # PowerShell execution orchestrator
    plan.ps1          # PowerShell planning launcher

    prompts/
      build.md        # Headless agent instructions (read every execution iteration)
      plan.md         # Planning agent ten-stage Q&A instructions
      plan-work.md    # Feature-branch scoped planning instructions
      guardrails.md   # Shared rules injected into every prompt by loop.sh

    spec.md           # Project specification and live state (produced by plan.sh)
    agents.md         # Operational guide: build/test/lint commands (produced by plan.sh)
    progress.md       # Append-only iteration audit trail (never read by headless agents)
    changelog.md      # Append-only educational item log (never read by headless agents)

    stream/
      parser.sh       # Token counting stream middleware (exit 10 = rotate)
      gutter.sh       # Stuck-loop pattern detector (exit 1 = gutter)

    specs/            # Per-topic spec files (optional, for complex projects)
    logs/             # Per-iteration agent output logs (auto-created at runtime)
```

---

## Setup

1. Copy the contents of this template folder into `<project-root>/.ralph/`.
2. Run `bash .ralph/plan.sh [engine]` to start the planning session. The agent will guide you through the spec.
3. Review `.ralph/spec.md` and `.ralph/agents.md` after the planning session ends, then run `loop.sh`.

---

## Running the Loop

**Bash:**
```bash
bash .ralph/loop.sh [engine] [max_iterations] [push] [model] [mode] [work_scope]
```
| Argument | Values | Default |
|:---|:---|:---|
| engine | `gemini`, `claude`, or `copilot` | `gemini` |
| max_iterations | any integer | `20` |
| push | `true` or `false` | `true` |
| model | model ID string | engine default |
| mode | `build` or `plan-work` | `build` |
| work_scope | description of scoped work (required when mode=plan-work) | `""` |

Flags (can appear anywhere before positional args):

| Flag | Effect |
|:---|:---|
| `--dry-run` | Print full concatenated prompt and engine command, then exit without invoking the engine |

Examples:
```bash
bash .ralph/loop.sh claude 15 true
bash .ralph/loop.sh gemini 20 false
bash .ralph/loop.sh claude 5 false "" plan-work "add dark mode toggle"
bash .ralph/loop.sh claude 20 true "" build --dry-run
```

**PowerShell:**
```powershell
.\.ralph\loop.ps1 [-Engine gemini|claude|copilot] [-MaxIterations 20] [-Push $true|$false]
                  [-Model <model-id>] [-Mode build|plan-work] [-WorkScope "description"] [-DryRun]
```
Examples:
```powershell
.\.ralph\loop.ps1 -Engine claude -MaxIterations 15
.\.ralph\loop.ps1 -Engine gemini -Push $false
.\.ralph\loop.ps1 -Engine claude -Mode plan-work -WorkScope "add dark mode toggle"
.\.ralph\loop.ps1 -Engine claude -DryRun
```

---

## Token Awareness

All engine output is piped through `stream/parser.sh`, which estimates token usage (~4 chars/token). Configure thresholds via environment variables before running the loop:

| Variable | Default | Effect |
|:---|:---|:---|
| `RALPH_TOKEN_WARN` | `100000` tokens | Emits `[TOKEN WARNING]` to stderr |
| `RALPH_TOKEN_ROTATE` | `128000` tokens | Exits with code 10; loop treats as clean iteration end |

```bash
RALPH_TOKEN_WARN=80000 bash .ralph/loop.sh claude 20 true
```

Agents are instructed by `guardrails.md` to update `spec.md` and `progress.md` incrementally during task execution — this minimizes lost work if the parser terminates the stream early.

---

## Gutter Detection

After each iteration, `loop.sh` runs `stream/gutter.sh` to detect stuck-loop patterns in `progress.md`:

1. **Same-task repetition**: same task description 3+ times in a row → exit 4
2. **Ping-pong pattern**: A-B-A-B alternation → exit 4

On gutter detection, the loop exits with code 4 and prints a human review prompt. Configure the lookback window via `RALPH_GUTTER_LOOKBACK` (default: 6 entries).

---

## Spec Format Reference

### Overall Status values
| Value | Meaning |
|:---|:---|
| `IN_PROGRESS` | Loop is active |
| `VERIFICATION_PENDING` | All tasks completed; agent will verify acceptance criteria next iteration |
| `MISSION_COMPLETE` | All acceptance criteria met; loop exits on next check |

### Task Status values
| Value | Meaning |
|:---|:---|
| `pending` | Not yet started |
| `in_progress` | Agent is currently working on it (set before starting work) |
| `completed` | Done successfully |
| `failed` | Attempted but not achievable |
| `blocked` | Cannot proceed; dependency or external condition unresolved |
| `proposed` | Agent-discovered task awaiting human review; not selectable by agent |

### Task Matrix format

The Task Matrix has ten columns:

```
| ID | Task Description | Priority | Impact | Blocking | Risk | Score | Status | Dependencies | Parent |
|:---|:---|:---|:---|:---|:---|:---|:---|:---|:---|
| T1   | Parent task          | High | 4 | 2 | 2 | 18 | pending | None | -  |
| T1.1 | First sub-task       | High | 5 | 0 | 1 | 16 | pending | None | T1 |
| T1.2 | Second sub-task      | High | 3 | 1 | 2 | 13 | pending | T1.1 | T1 |
| T2   | Another parent task  | Med  | 3 | 0 | 1 | 10 | pending | T1   | -  |
```

- Sub-task IDs use dot notation: `T1.1`, `T1.2`.
- A parent task is only marked `completed` when all its sub-tasks are `completed`.
- The Dependencies column lists task IDs that must be `completed` before this task can start. Use `None` for tasks with no dependencies.
- The Parent column lists the parent task ID for sub-tasks. Use `-` for top-level tasks.
- Impact, Blocking, Risk, and Score are set during the planning session and never modified by headless agents.

### Progress Log

Progress is written to `.ralph/progress.md` (a separate file), not inside `spec.md`. Each iteration the headless agent appends one line:

```
- **[YYYY-MM-DD HH:MM]** (Iteration N) type: [one-line summary of what was done]
```

Valid `type` values: `feat`, `fix`, `refactor`, `test`, `docs`, `chore`.

Headless agents never read `progress.md` -- it is a human audit trail only.

### Known Issues format
```
## Known Issues
> Append-only. The agent logs problems, warnings, or concerns detected during work.

| Timestamp | Severity | Description | Related Task |
|:---|:---|:---|:---|
| 2025-01-15 10:42 | medium | Test coverage missing for edge case X | T3 |
```

Severity levels:
| Level | When to use |
|:---|:---|
| `low` | Minor concern; does not affect correctness |
| `medium` | Potential issue; worth addressing in a follow-up |
| `high` | Likely to cause failures; should be fixed soon |
| `critical` | Breaks acceptance criteria or constraints; must be fixed before completion |

Known Issues is **append-only**. Neither the agent nor humans should edit or delete existing rows. Add new rows only.

---

## Scoring System

Task scores are set during the planning session and **never modified by headless agents**. Scores break ties when multiple tasks are eligible (pending + all dependencies met).

```
Score = (Impact × 3) + (Blocking × 2) + (Risk × 1)
```

| Component | Range | Meaning |
|:---|:---|:---|
| Impact | 1-5 | How directly does this task satisfy an acceptance criterion? |
| Blocking | 0-N | How many other pending tasks list this as a dependency? (computed from task matrix) |
| Risk | 1-3 | How uncertain or complex is the implementation? Higher-risk tasks done early surface problems sooner. |

Higher score = selected first. Within equal scores, lowest task ID wins. If a parent task and a standalone task share the same top score, the lowest task ID wins first, then the sub-task rule applies within that parent.

---

## Loop Exit Conditions

| Condition | Exit Code | Meaning |
|:---|:---|:---|
| `MISSION_COMPLETE` in spec | `0` | Success |
| Max iterations reached | `1` | Safety cap hit -- review logs and raise the limit or fix the spec |
| No `pending` tasks but not complete | `2` | Stuck -- all remaining tasks are `blocked` or `failed`; human intervention required |
| Proposed tasks need review | `3` | Agent discovered new tasks; promote `proposed` to `pending` and re-run |
| Gutter detected | `4` | Agent in a stuck loop; review `progress.md` for repeated patterns |
| Ctrl+C / SIGTERM | `130` | Manual interruption; safe to re-run |

---

## Verification Phase

After all tasks in the Task Matrix reach `completed`, the agent does NOT immediately set `MISSION_COMPLETE`. Instead it sets Overall Status to `VERIFICATION_PENDING` and exits. The loop script detects this and triggers one more iteration.

In the Verification Iteration, the agent walks through every Acceptance Criterion and confirms it is genuinely satisfied -- running tests, checking file outputs, validating constraints. This separates "all tasks done" from "the project actually works".

**Verification pass**: Overall Status becomes `MISSION_COMPLETE`. Loop exits cleanly.

**Verification fail**: Each failed criterion is logged to `## Known Issues`. The agent adds `proposed` fix tasks to the Task Matrix and reverts Overall Status to `IN_PROGRESS`. The loop then exits with code `3`, prompting human review of the proposed tasks.

This two-phase completion prevents silent failures where the agent marks itself done without ever checking the outcome.

---

## Proposed Tasks and Human Review

During any iteration, the agent may discover additional work that was not anticipated in the original spec -- edge cases, test gaps, constraint violations found during verification. Rather than acting autonomously on undiscussed work, the agent adds these to the Task Matrix with status `proposed`.

**Proposed tasks are not selectable.** The agent will never pick up a `proposed` task. They exist only for human review.

When the loop detects no `pending` tasks remain but `proposed` tasks exist, it exits with code `3` and prints:

```
PAUSED: Proposed tasks require human review. Promote to 'pending' and re-run.
```

Between runs, open `.ralph/spec.md` and for each `proposed` task either:
- Promote it to `pending` to have the agent execute it next run.
- Delete the row if the task is not needed.
- Modify the description before promoting if the proposal needs adjustment.

---

## Agent Planning Notes

When setting up Ralph for a new project, follow these guidelines to ensure the loop runs effectively.

**Decompose the goal into discrete tasks.**
Each task should represent a meaningful, independently verifiable unit of work. Avoid tasks so large that a single agent turn cannot complete them.

**Use sub-tasks for complex work.**
If a task requires multiple steps, break it into T1.1, T1.2, etc. Keep each sub-task small enough for one agent turn. The agent will not proceed to T1.2 until T1.1 is `completed`.

**Order dependencies explicitly.**
The agent respects the Dependencies column. If T2 should only start after T1, write `T1` in T2's Dependencies cell. An agent will skip a task whose dependency is not yet `completed`.

**Write precise Technical Constraints.**
Constraints are enforced every iteration. Make them specific and non-contradictory. Examples: "Do not modify the database schema", "All new functions must have unit tests", "Only edit files under src/".

**Write measurable Acceptance Criteria.**
The agent uses these to decide when to set `MISSION_COMPLETE`. Vague criteria like "the code is good" will not work. Prefer: "All tests pass", "Feature X produces output Y given input Z".

**The Progress Log is append-only.**
Each iteration adds one entry to `progress.md`. The agent must not modify past entries. This log is the audit trail for the entire run. Headless agents never read it.

**Human checkpoints.**
After the loop exits (any condition), review `.ralph/spec.md` and `.ralph/logs/` before re-running. The spec is your resume point -- correct any inaccurate task statuses before restarting the loop.
