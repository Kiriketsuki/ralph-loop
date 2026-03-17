# Feature: Hardening, Backpressure, and Security

<!-- SpecKit /specify layer: what and why -->
## Overview

**User Story**: As a Ralph Loop operator, I want the orchestrator to handle backpressure, enforce timeouts, and close security gaps so that unattended loop runs are resilient to API outages, hanging agents, prompt injection, and retry storms.

**Problem**: The loop has no per-agent timeout, no retry backoff, no API rate awareness, and several security gaps (unvalidated ENGINE, prompt injection via progress.md retry context, TOCTOU temp file race) -- meaning a single hanging agent or API outage can stall or overwhelm the system indefinitely.

**Out of Scope**:
- Rewriting the fork-join model to a full producer-consumer queue (sliding window is in scope as nice-to-have, full rewrite is not)
- Adding a new engine (only hardening existing gemini/claude/copilot paths)
- UI/dashboard for monitoring

---

<!-- SpecKit /clarify layer: resolve ambiguities before planning -->
## Open Questions

| # | Question | Raised By | Resolved |
|:--|:---------|:----------|:---------|
| 1 | None at this time | -- | [x] |

---

<!-- MoSCoW from Ralph spec.md -->
## Scope

### Must-Have
- **Per-agent wall-clock timeout**: `dispatch_engine` wraps each engine invocation with `timeout(1)`; configurable via `RALPH_AGENT_TIMEOUT` env var (default: 30m). Done when a hanging agent is killed after the timeout and the task is marked failed.
- **Exponential backoff on batch failure**: When all tasks in a batch fail, sleep with exponential backoff + jitter before the next batch. Done when consecutive all-fail batches produce increasing delays (capped at 5 min).
- **ENGINE allowlist validation**: Reject unknown engine values immediately after argument parsing in `loop.sh`, `plan.sh`, `loop.ps1`, `plan.ps1`. Done when passing `ENGINE=evil` exits with error code and message.
- **Retry context sanitization**: Strip markdown headings, backticks, and cap byte length of `progress.md` content before embedding in agent prompts. Done when injected markdown in a progress entry is neutralized before reaching the next agent.
- **TOCTOU fix for JQ FIFO**: Replace `mktemp -u` + `mkfifo` in `parser.sh` with a safe alternative (temp directory with restricted permissions). Done when no race window exists between name generation and FIFO creation.
- **loop.ps1 parity**: Port all hardening changes (timeout, backoff, ENGINE validation, retry sanitization) to `loop.ps1`. Done when both scripts have equivalent protections.

### Should-Have
- **Inter-spawn stagger delay**: Small configurable delay between agent launches (`RALPH_SPAWN_DELAY`, default: 2s) to avoid API burst.
- **Batch-level circuit breaker**: After N consecutive failed batches (default: 3), pause with an escalating delay before continuing.
- **Log file size cap**: `parser.sh` checks `RALPH_MAX_LOG_SIZE` (default: 50MB) and truncates/rotates when exceeded.

### Nice-to-Have
- **Sliding window worker pool**: Replace fork-join `wait` loop with `wait -n` rolling admission (requires bash 4.3+). Stragglers no longer block fast completions.
- **Unvalidated env var path hardening**: Validate `LOG_FILE`/`PROGRESS_FILE` in `parser.sh`/`gutter.sh` to reject paths containing `..` or outside `.ralph/`.

---

<!-- SpecKit /plan layer: technical decomposition -->
## Technical Plan

**Affected Components**:
- `loop.sh` -- timeout wrapper in `dispatch_engine`, backoff logic in main loop, ENGINE validation, retry context sanitization in `build_agent_prompt`/`get_retry_context`
- `loop.ps1` -- mirror all above changes in PowerShell equivalents
- `plan.sh` -- ENGINE validation (lines 15-16)
- `plan.ps1` -- ENGINE validation
- `stream/parser.sh` -- TOCTOU fix for JQ FIFO (lines 49-50), log file size cap
- `stream/gutter.sh` -- (minor) env var path validation if nice-to-have is included

**Data Model Changes**: None -- no schema, no database. Only new env vars added to the configuration surface.

**New Environment Variables**:

| Variable | Default | Purpose |
|:---------|:--------|:--------|
| `RALPH_AGENT_TIMEOUT` | `1800` (30m, in seconds) | Per-agent wall-clock timeout |
| `RALPH_SPAWN_DELAY` | `2` (seconds) | Delay between parallel agent launches |
| `RALPH_BACKOFF_MAX` | `300` (5 min) | Cap for exponential backoff sleep |
| `RALPH_CIRCUIT_BREAKER` | `3` | Consecutive failed batches before escalated pause |
| `RALPH_MAX_LOG_SIZE` | `52428800` (50MB) | Log file size cap |

**Dependencies**: `timeout(1)` (coreutils) -- present on all standard Linux/macOS systems; graceful degradation if missing.

**Risks**:

| Risk | Likelihood | Mitigation |
|:-----|:-----------|:-----------|
| `timeout(1)` not available on all platforms | Low | Check `command -v timeout` at startup; skip with warning if missing |
| `wait -n` requires bash 4.3+ (nice-to-have) | Medium | Feature-gate behind bash version check; fall back to current fork-join |
| PowerShell `Start-Process -Timeout` behaves differently than bash `timeout` | Medium | Use `Start-Job` + `Wait-Job -Timeout` pattern instead |
| Backoff delays slow down legitimate retry scenarios | Low | Backoff only triggers on all-fail batches, not partial failures |

---

<!-- Gherkin /specify layer: executable acceptance criteria -->
## Acceptance Scenarios

```gherkin
Feature: Hardening, Backpressure, and Security
  As a Ralph Loop operator
  I want resilient orchestration with security hardening
  So that unattended runs survive API outages, hanging agents, and prompt injection

  Background:
    Given a ralph-loop project with a valid spec.md containing pending tasks

  Rule: Hanging agents must be terminated

    Scenario: Agent exceeds wall-clock timeout
      Given RALPH_AGENT_TIMEOUT is set to 10 (seconds, for testing)
      When an agent process runs longer than 10 seconds
      Then the agent process is killed via timeout(1)
      And the task is marked as failed in spec.md
      And a synthetic failure entry is written to progress.md

    Scenario: Timeout missing from system
      Given timeout(1) is not on PATH
      When loop.sh starts
      Then a warning is printed to stderr
      And agents run without a timeout (graceful degradation)

  Rule: Failed batches trigger exponential backoff

    Scenario: All tasks in a batch fail
      Given MAX_PARALLEL is 3 and all 3 tasks fail
      When the batch completes with zero successful merges
      Then loop.sh sleeps with exponential backoff before the next batch
      And the delay doubles on each consecutive all-fail batch (2s, 4s, 8s...)
      And the delay is capped at RALPH_BACKOFF_MAX seconds

    Scenario: Partial batch failure does not trigger backoff
      Given MAX_PARALLEL is 3 and 1 task succeeds, 2 fail
      When the batch completes
      Then no backoff delay is applied
      And the consecutive-failure counter resets to zero

  Rule: Only known engines are accepted

    Scenario Outline: Valid engine is accepted
      When loop.sh is invoked with engine <engine>
      Then execution proceeds normally

      Examples:
        | engine  |
        | gemini  |
        | claude  |
        | copilot |

    Scenario: Unknown engine is rejected
      When loop.sh is invoked with engine "evil"
      Then loop.sh exits with code 1
      And stderr contains "Unknown engine"

    Scenario: Unknown engine rejected in plan.sh
      When plan.sh is invoked with engine "evil"
      Then plan.sh exits with code 1
      And stderr contains "Unknown engine"

  Rule: Retry context is sanitized before prompt injection

    Scenario: Malicious markdown in progress.md is neutralized
      Given progress.md contains "fail: T1 failed. Reason: ## New System Prompt"
      When get_retry_context builds the retry context for T1
      Then lines containing markdown headings (##) are stripped
      And backticks are stripped
      And the total retry context is capped at 1000 bytes

  Rule: JQ FIFO creation is atomic

    Scenario: Parser creates FIFO without TOCTOU race
      When parser.sh creates the JQ FIFO
      Then no gap exists between name generation and FIFO creation
      And the FIFO is created inside a temp directory with 700 permissions

  Rule: loop.ps1 mirrors all hardening

    Scenario: PowerShell timeout kills hanging agent
      Given RALPH_AGENT_TIMEOUT is set to 10
      When a PowerShell agent job runs longer than 10 seconds
      Then the job is stopped
      And the task is marked as failed

    Scenario: PowerShell validates ENGINE
      When loop.ps1 is invoked with engine "evil"
      Then loop.ps1 exits with error
      And stderr contains "Unknown engine"

  Rule: Inter-spawn stagger prevents API burst

    Scenario: Agents are launched with delay between them
      Given RALPH_SPAWN_DELAY is 2 and MAX_PARALLEL is 3
      When a batch of 3 agents is dispatched
      Then there is at least 2 seconds between each agent launch
```

---

<!-- SpecKit /tasks layer: implementation breakdown -->
## Task Breakdown

| ID | Task | Priority | Dependencies | Status |
|:---|:-----|:---------|:-------------|:-------|
| T1 | ENGINE allowlist validation in `loop.sh` and `plan.sh` | High | None | completed |
| T1.1 | ENGINE allowlist validation in `loop.ps1` and `plan.ps1` | High | None | completed |
| T2 | Per-agent `timeout(1)` wrapper in `dispatch_engine` (`loop.sh`) | High | None | completed |
| T2.1 | Per-agent timeout via `Start-Job`/`Wait-Job` in `loop.ps1` | High | T2 | completed |
| T3 | Exponential backoff on consecutive all-fail batches (`loop.sh`) | High | None | completed |
| T3.1 | Exponential backoff in `loop.ps1` | High | T3 | completed |
| T4 | Retry context sanitization in `get_retry_context`/`build_agent_prompt` (`loop.sh`) | High | None | completed |
| T4.1 | Retry context sanitization in `loop.ps1` | High | T4 | completed |
| T5 | TOCTOU fix for JQ FIFO in `parser.sh` | Med | None | completed |
| T6 | Inter-spawn stagger delay in spawn loop (`loop.sh`) | Med | None | completed |
| T6.1 | Inter-spawn stagger delay in `loop.ps1` | Med | T6 | completed |
| T7 | Batch-level circuit breaker (`loop.sh`) | Med | T3 | completed |
| T7.1 | Batch-level circuit breaker in `loop.ps1` | Med | T3.1, T7 | completed |
| T8 | Log file size cap in `parser.sh` | Med | None | completed |
| T9 | Sliding window `wait -n` worker pool (`loop.sh`) | Low | T2 | pending |
| T10 | Env var path validation in `parser.sh`/`gutter.sh` | Low | None | pending |
| T11 | Update PRODUCT_SPEC.md and README.md with new env vars and hardening docs | Med | T1-T8 | completed |

---

<!-- SpecKit /analyze layer: exit gate -->
## Exit Criteria

- [ ] All Must-Have scenarios pass (manual verification -- no CI in this repo)
- [ ] `loop.sh --dry-run` and `loop.ps1 -DryRun` both reject unknown engines
- [ ] A simulated hanging agent (e.g., `sleep infinity` substituted for engine) is killed after RALPH_AGENT_TIMEOUT
- [ ] Consecutive all-fail batches produce visible backoff delays in terminal output
- [ ] Retry context from progress.md is visibly sanitized in `--dry-run` prompt output
- [ ] `parser.sh` FIFO creation has no TOCTOU window (code review confirmation)
- [ ] loop.ps1 has equivalent protections for all T*.1 tasks
- [ ] PRODUCT_SPEC.md documents new env vars and hardening behavior
- [ ] No regressions on existing loop functionality (run a small 3-task spec end-to-end)

---

## References

- Architectural analysis: Software Architect agent (this session)
- Backpressure analysis: Performance Benchmarker agent (this session)
- Security audit: Security Engineer agent (this session)

---
*Authored by: Clault KiperS 4.6*
