param(
    [string][ValidateSet("gemini", "claude", "copilot")]$Engine = "gemini",
    [string]$Model = "",
    [string][ValidateSet("plan", "plan-work")]$Mode = "plan",
    [string]$WorkScope = ""
)

$env:CLAUDE_CODE_MAX_OUTPUT_TOKENS = "64000"

# .ralph/plan.ps1 - Interactive Ralph Loop Planning Session (PowerShell) v2
# Run from the project root directory.
# Usage: .\.ralph\plan.ps1 [-Engine gemini|claude|copilot] [-Model <model-id>]
#                           [-Mode plan|plan-work] [-WorkScope "description of work"]

$SpecFile = ".ralph/spec.md"

# Resolve planner file from mode
$PlannerFile = if ($Mode -eq "plan-work") { ".ralph/prompts/plan-work.md" } else { ".ralph/prompts/plan.md" }

if (-not (Test-Path $PlannerFile)) {
    Write-Error "ERROR: $PlannerFile not found. Run from the project root."
    exit 1
}

# Overwrite guard (only for full plan mode)
if ($Mode -eq "plan" -and (Test-Path $SpecFile)) {
    Write-Host "WARNING: $SpecFile already exists."
    $confirm = Read-Host "Overwrite existing spec? (y/N)"
    if ($confirm -notmatch '^[Yy]$') {
        Write-Host "Aborted. Existing spec preserved."
        exit 0
    }
    Write-Host "Proceeding with overwrite..."
}

# plan-work validation
if ($Mode -eq "plan-work") {
    if (-not (Test-Path $SpecFile)) {
        Write-Error "ERROR: $SpecFile not found. Run '.\.ralph\plan.ps1' first to create a spec."
        exit 1
    }
    $CurrentBranch = git rev-parse --abbrev-ref HEAD 2>$null
    if (-not $CurrentBranch) { $CurrentBranch = "main" }
    if ($CurrentBranch -in @("main", "master", "HEAD")) {
        Write-Error "ERROR: plan-work mode requires a feature branch. You are on '$CurrentBranch'."
        Write-Error "Create a feature branch first: git checkout -b feature/<name>"
        exit 1
    }
    if (-not $WorkScope) {
        Write-Error "ERROR: plan-work mode requires -WorkScope argument."
        Write-Error "Usage: .\.ralph\plan.ps1 [...] -Mode plan-work -WorkScope 'description of work'"
        exit 1
    }
    if ($WorkScope.Length -gt 500) {
        Write-Error "ERROR: WorkScope exceeds 500 characters."
        exit 1
    }
    if ($WorkScope -match '[`]|\$\(') {
        Write-Error "ERROR: WorkScope contains unsafe characters (backticks or `$())."
        exit 1
    }
}

# Mode-specific user messaging
if ($Mode -eq "plan") {
    Write-Host "Starting Ralph Planning Session with $Engine..."
    Write-Host "The agent will guide you through goal alignment, constraints, criteria, task decomposition, and scoring."
    Write-Host "spec.md and agents.md will be written at the end of the session."
    Write-Host "Review spec.md before running: .\.ralph\loop.ps1"
} else {
    Write-Host "Starting Ralph Feature-Branch Planning Session with $Engine..."
    Write-Host "The agent will help you scope and plan a focused piece of work."
    Write-Host "New tasks will be appended to spec.md."
    Write-Host "When done, run: .\.ralph\loop.ps1 [...] -Mode build"
}
Write-Host ""

# Prepare prompt content (substitute `$WORK_SCOPE for plan-work mode)
$PlannerContent = Get-Content $PlannerFile -Raw
if ($Mode -eq "plan-work") {
    $PlannerContent = $PlannerContent -replace [regex]::Escape('$WORK_SCOPE'), $WorkScope
}

$ModelArgs = @()
if ($Model) { $ModelArgs = @("--model", $Model) }

switch ($Engine) {
    "gemini"  { $PlannerContent | gemini  @ModelArgs }
    "claude"  { $PlannerContent | claude  @ModelArgs }
    "copilot" { $PlannerContent | copilot @ModelArgs }
    default {
        Write-Error "ERROR: Unknown engine '$Engine'. Use 'gemini', 'claude', or 'copilot'."
        exit 1
    }
}

$EngineExit = $LASTEXITCODE

Write-Host ""
if ($EngineExit -eq 0) {
    Write-Host "Planning session ended."
    if ($Mode -eq "plan") {
        Write-Host "Next step: review .ralph/spec.md and .ralph/agents.md, then run: .\.ralph\loop.ps1 [-Engine ...] [-MaxIterations 20] [-Push `$true]"
    } else {
        Write-Host "Next step: review .ralph/spec.md (new tasks appended), then run: .\.ralph\loop.ps1 [...] -Mode build"
    }
} else {
    Write-Warning "Engine exited with code $EngineExit. Check that the planning session completed and spec.md was written before running loop.ps1."
}
