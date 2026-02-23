# Ralph Project Specification: [Project Name]

## Global Goal
[Define the ultimate mission of this Ralph loop]

## Project Status
- **Overall Status**: IN_PROGRESS
- **Current Iteration**: 0
- **Last Update**: [YYYY-MM-DD HH:MM]

## Acceptance Criteria for Exit
> These criteria are verified in a dedicated verification iteration after all tasks complete. The agent must not set MISSION_COMPLETE without passing verification.

- [ ] [Criterion 1]
- [ ] [Criterion 2]
- [ ] [Criterion 3]

## Task Matrix
| ID | Task Description | Priority | Impact | Blocking | Risk | Score | Status | Dependencies | Parent |
|:---|:---|:---|:---|:---|:---|:---|:---|:---|:---|
| T1 | [Task 1] | High | 5 | 1 | 2 | 17 | pending | None | - |
| T1.1 | [Sub-task 1.1] | High | 4 | 0 | 1 | 13 | pending | None | T1 |
| T1.2 | [Sub-task 1.2] | High | 4 | 0 | 2 | 14 | pending | T1.1 | T1 |
| T2 | [Task 2] | Med | 3 | 0 | 1 | 10 | pending | T1 | - |
| T3 | [Agent-discovered task] | Low | 2 | 0 | 1 | 7 | proposed | T1 | - |

## Technical Constraints
- [Constraint 1]
- [Constraint 2]

## Known Issues
> Append-only. The agent logs problems, warnings, or concerns detected during work.

| Timestamp | Severity | Description | Related Task |
|:---|:---|:---|:---|
