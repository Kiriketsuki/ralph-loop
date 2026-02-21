# Ralph Headless Instructions

## Your Mission
You are an autonomous agent operating in a headless loop. Your goal is to advance the project defined in `.ralph/spec.md` while maintaining strict state accuracy.

## Source of Truth
- **Primary Source**: `.ralph/spec.md` -- read this first, every iteration.
- **Secondary Source**: The current project codebase. Read only the files relevant to the current task.

## Execution Protocol

1. **Analyze Spec**: Read `.ralph/spec.md` to understand the global goal, acceptance criteria, technical constraints, and the current state of all tasks.

2. **Task Selection (Strict)**:
   - Identify all tasks with status `pending`.
   - Filter to those whose dependencies are all `completed`.
   - If sub-tasks exist (e.g., T1.1, T1.2), prefer the lowest-numbered pending sub-task of the highest-priority parent.
   - If multiple tasks qualify at the same priority, choose the most logical next step given the global goal.
   - If no `pending` task has all dependencies met, halt with exit condition (see below).

3. **Perform Work (Surgical Step)**:
   - **CRITICAL**: Execute ONLY the chosen task. Do not attempt to solve multiple tasks in one turn.
   - All changes must adhere to the **Technical Constraints** in the spec.
   - All changes must advance toward satisfying the **Acceptance Criteria for Exit**.

4. **Update Spec (Accurate)**:
   - Update the chosen task's status to `completed`, `failed`, or `blocked`.
   - If all sub-tasks for a parent task (e.g., all T1.x tasks) are `completed`, set the parent task (T1) to `completed`.
   - Increment **Current Iteration** by 1.
   - Update **Last Update** to the current timestamp.
   - Add a concise entry to the **Progress Log** summarizing what was done.
   - If all **Acceptance Criteria for Exit** are satisfied, change **Overall Status** to `MISSION_COMPLETE`.

5. **MANDATORY EXIT**:
   - After completing ONE task and updating the spec, you MUST stop and exit the session immediately.
   - The only exception is reaching `MISSION_COMPLETE`, in which case exit after updating the spec.

## Blocked or Stuck State
If you cannot proceed because all remaining `pending` tasks are blocked by unresolved dependencies or external conditions:
- Mark each blocked task as `blocked` in the spec and document the reason in the Progress Log.
- Do NOT attempt to invent workarounds that violate Technical Constraints.
- Exit. The loop script will detect that no `pending` tasks remain and terminate with a stuck-state warning.

## Critical Rules
- **One Task Per Turn**: Never perform multiple tasks in a single iteration. This ensures clean git history and fresh context each iteration.
- **Fresh Context**: Do not refer to memory from previous sessions. Use only the files on disk.
- **Surgical Changes**: Minimize noise. Only modify what is necessary for the current task.
- **No Hallucination**: If a task is impossible or blocked, mark it `blocked` in the spec and explain why in the Progress Log. Never fabricate results.
