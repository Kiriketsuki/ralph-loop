# Ralph Shared Guardrails

These rules apply to every agent operating in a Ralph loop, regardless of mode. They are injected by `loop.sh` at invocation time.

## Critical Rules

- **One Task Per Turn**: Never perform multiple tasks in a single iteration. This ensures clean git history and fresh context each iteration.
- **Fresh Context**: Do not refer to memory from previous sessions. Use only the files on disk.
- **Surgical Changes**: Minimize noise. Only modify what is necessary for the current task.
- **No Hallucination**: If a task is impossible or blocked, mark it `blocked` in the spec and explain why in `.ralph/progress.md`. Never fabricate results.
- **Proposed Tasks Are Read-Only**: Never select or work on a `proposed` task. Only humans can promote `proposed` to `pending`.
- **Verification Is Mandatory**: Never set `MISSION_COMPLETE` directly from a regular task iteration. Always go through `VERIFICATION_PENDING` first.
- **No Commits, No Pushes**: Do NOT run `git commit` or `git push`. The loop orchestrator handles all git operations after you exit. You may stage files with `git add <specific-file>` if needed for your work, but do not commit. Prefer narrow staging (`git add <specific-file>`) over broad staging (`git add .` or `git add -A`) to avoid accidentally including unrelated changes.
- **Failure Analysis Is Mandatory**: If you cannot complete a task, you MUST write a structured failure entry to `.ralph/progress.md` before exiting. Include what went wrong (`Reason:`) and what to avoid on retry (`Avoid:`). An exit without a failure entry for an incomplete task is a protocol violation.

## Token Awareness

- The loop orchestrator monitors token usage via `stream/parser.sh`. If your session approaches the context limit, the parser terminates the stream and the loop treats it as a clean iteration end. To minimize lost work, update `spec.md` and `progress.md` incrementally during task execution, not only at the end.

## Operational Knowledge

- At the start of each iteration, read `.ralph/agents.md` if it exists. It contains project-specific commands for building, testing, and linting.
- If you discover new operational knowledge during this iteration (e.g. a build command, a required env var, a known gotcha), append it to `.ralph/agents.md` under the `## Agent Learnings` section. Do not edit existing entries.
