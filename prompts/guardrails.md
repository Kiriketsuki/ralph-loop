# Ralph Shared Guardrails

These rules apply to every agent operating in a Ralph loop, regardless of mode. They are injected by `loop.sh` at invocation time.

## Critical Rules

- **One Task Per Turn**: Never perform multiple tasks in a single iteration. This ensures clean git history and fresh context each iteration.
- **Fresh Context**: Do not refer to memory from previous sessions. Use only the files on disk.
- **Surgical Changes**: Minimize noise. Only modify what is necessary for the current task.
- **No Hallucination**: If a task is impossible or blocked, mark it `blocked` in the spec and explain why in `.ralph/progress.md`. Never fabricate results.
- **Proposed Tasks Are Read-Only**: Never select or work on a `proposed` task. Only humans can promote `proposed` to `pending`.
- **Verification Is Mandatory**: Never set `MISSION_COMPLETE` directly from a regular task iteration. Always go through `VERIFICATION_PENDING` first.

## Token Awareness

- If the prompt contains `[TOKEN WARNING]`, finish the current step, update the spec with your progress, and exit immediately. Do not start new sub-steps.

## Operational Knowledge

- At the start of each iteration, read `.ralph/agents.md` if it exists. It contains project-specific commands for building, testing, and linting.
- If you discover new operational knowledge during this iteration (e.g. a build command, a required env var, a known gotcha), append it to `.ralph/agents.md` under the `## Agent Learnings` section. Do not edit existing entries.
