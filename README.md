# Ralph Loop

Ralph Loop is a headless, iterative agent orchestration pattern. An AI agent reads a project spec, executes exactly one task, updates the spec with the result, commits progress to git, then exits. The loop script re-invokes the agent from scratch each iteration, giving it a fresh context window every turn. This continues until `MISSION_COMPLETE` is reached or the loop detects a stuck or failed state.

---

## Concepts

**Why one task per turn?**
Each agent invocation starts with no memory of prior sessions. The spec file is the only persistent state. Committing the spec after every task means any iteration failure loses at most one task's worth of work, and the next iteration can resume accurately from the spec.

**What is the spec?**
`.ralph/spec.md` is both the project plan and the live state document. The agent reads it to know what to do and writes to it to record what was done. It is the single source of truth.

**What is the prompt?**
`.ralph/prompt.md` contains the agent's standing instructions. It does not change between iterations. Do not modify it for a specific project -- put project-specific instructions in the spec's Technical Constraints section.

---

## Directory Structure

Copy this template into a `.ralph/` folder at your project root before starting:

```
<project-root>/
  .ralph/
    spec.md       # Project specification and live state -- edit before starting
    prompt.md     # Agent instructions -- copy as-is, do not modify
    loop.sh       # Bash orchestrator
    loop.ps1      # PowerShell orchestrator
    logs/         # Per-iteration agent output logs (auto-created at runtime)
```

---

## Setup

1. Copy the contents of this template folder into `<project-root>/.ralph/`.
2. Edit `.ralph/spec.md`:
   - Write the **Global Goal** as a single, unambiguous mission statement.
   - Define measurable **Acceptance Criteria for Exit** (these drive `MISSION_COMPLETE`).
   - Populate the **Task Matrix** with all known tasks and sub-tasks (see format below).
   - List all **Technical Constraints** the agent must obey every iteration.
3. Run the loop from the project root.

---

## Running the Loop

**Bash:**
```bash
bash .ralph/loop.sh [engine] [max_iterations] [push]
```
| Argument | Values | Default |
|:---|:---|:---|
| engine | `gemini` or `claude` | `gemini` |
| max_iterations | any integer | `20` |
| push | `true` or `false` | `true` |

Examples:
```bash
bash .ralph/loop.sh claude 15 true
bash .ralph/loop.sh gemini 20 false
```

**PowerShell:**
```powershell
.\.ralph\loop.ps1 [-Engine gemini|claude] [-MaxIterations 20] [-Push $true|$false]
```
Examples:
```powershell
.\.ralph\loop.ps1 -Engine claude -MaxIterations 15
.\.ralph\loop.ps1 -Engine gemini -Push $false
```

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
```
| ID   | Task Description     | Priority | Status  | Dependencies | Parent |
|:-----|:---------------------|:---------|:--------|:-------------|:-------|
| T1   | Parent task          | High     | pending | None         | -      |
| T1.1 | First sub-task       | High     | pending | None         | T1     |
| T1.2 | Second sub-task      | High     | pending | T1.1         | T1     |
| T2   | Another parent task  | Med      | pending | T1           | -      |
```

- Sub-task IDs use dot notation: `T1.1`, `T1.2`.
- A parent task is only marked `completed` when all its sub-tasks are `completed`.
- The Dependencies column lists task IDs that must be `completed` before this task can start. Use `None` for tasks with no dependencies.
- The Parent column lists the parent task ID for sub-tasks. Use `-` for top-level tasks.

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

## Loop Exit Conditions

| Condition | Exit Code | Meaning |
|:---|:---|:---|
| `MISSION_COMPLETE` in spec | `0` | Success |
| Max iterations reached | `1` | Safety cap hit -- review logs and raise the limit or fix the spec |
| No `pending` tasks but not complete | `2` | Stuck -- all remaining tasks are `blocked` or `failed`; human intervention required |
| Proposed tasks need review | `3` | Agent discovered new tasks; promote `proposed` to `pending` and re-run |

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
Each iteration adds one entry. The agent must not modify past entries. This log is the audit trail for the entire run.

**Human checkpoints.**
After the loop exits (any condition), review `.ralph/spec.md` and `.ralph/logs/` before re-running. The spec is your resume point -- correct any inaccurate task statuses before restarting the loop.
