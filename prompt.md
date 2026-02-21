# Ralph Headless Instructions

## Your Mission
You are an autonomous agent operating in a headless loop. Your goal is to advance the project defined in `.ralph/spec.md` while maintaining strict state accuracy.

## Source of Truth
- **Primary Source**: `.ralph/spec.md`
- **Secondary Source**: The current project codebase.

## Execution Protocol

1.  **Analyze Spec**: Read `.ralph/spec.md` to understand the global goal and task status.
2.  **Task Selection**:
    -   Identify all `pending` tasks.
    -   Choose the highest priority task whose dependencies are `completed`.
    -   If multiple tasks qualify, choose the most logical next step.
3.  **Perform Work**:
    -   Execute the chosen task surgically.
    -   Ensure all changes adhere to the "Technical Constraints" in the spec.
4.  **Update Spec**:
    -   Mark the task as `completed` (or `failed` with a reason).
    -   Add a concise entry to the "Progress Log".
5.  **Evaluate Exit Criteria**:
    -   Check the "Acceptance Criteria for Exit".
    -   If and ONLY if every criterion is fully satisfied, update the **Overall Status** to `MISSION_COMPLETE`.

## Critical Rules
- **Fresh Context**: Do not refer to previous conversations. Use only the files on disk.
- **Surgical Changes**: Minimize noise. Only modify what is necessary for the current task.
- **No Hallucination**: If you are blocked or a task is impossible, mark it as `blocked` in the spec and explain why.

Authored by Vault Gemper at 2026-02-21 17:47
