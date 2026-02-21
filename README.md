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
| `MISSION_COMPLETE` | All acceptance criteria met; loop exits on next check |

### Task Status values
| Value | Meaning |
|:---|:---|
| `pending` | Not yet started |
| `in_progress` | Agent is currently working on it (set before starting work) |
| `completed` | Done successfully |
| `failed` | Attempted but not achievable |
| `blocked` | Cannot proceed; dependency or external condition unresolved |

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

---

## Loop Exit Conditions

| Condition | Exit Code | Meaning |
|:---|:---|:---|
| `MISSION_COMPLETE` in spec | `0` | Success |
| Max iterations reached | `1` | Safety cap hit -- review logs and raise the limit or fix the spec |
| No `pending` tasks but not complete | `2` | Stuck -- all remaining tasks are `blocked` or `failed`; human intervention required |

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
