# .ralph/plan.ps1 - Interactive Ralph Loop Planning Session (PowerShell)
# Run from the project root directory.
# Usage: .\.ralph\plan.ps1 [-Engine gemini|claude|copilot]

param(
    [string][ValidateSet("gemini", "claude", "copilot")]$Engine = "gemini"
)

$SpecFile = ".ralph/spec.md"
$PlannerFile = ".ralph/planner.md"

if (-not (Test-Path $PlannerFile)) {
    Write-Error "ERROR: $PlannerFile not found. Run from the project root."
    exit 1
}

# Overwrite guard
if (Test-Path $SpecFile) {
    Write-Host "WARNING: $SpecFile already exists."
    $confirm = Read-Host "Overwrite existing spec? (y/N)"
    if ($confirm -notmatch '^[Yy]$') {
        Write-Host "Aborted. Existing spec preserved."
        exit 0
    }
    Write-Host "Proceeding with overwrite..."
}

Write-Host "Starting Ralph Planning Session with $Engine..."
Write-Host "The agent will guide you through goal alignment, constraints, criteria, task decomposition, and scoring."
Write-Host "spec.md will be written at the end of the session."
Write-Host "Review spec.md before running: .\.ralph\loop.ps1"
Write-Host ""

switch ($Engine) {
    "gemini"  { Get-Content $PlannerFile | gemini }
    "claude"  { Get-Content $PlannerFile | claude }
    "copilot" { Get-Content $PlannerFile | copilot }
    default {
        Write-Error "ERROR: Unknown engine '$Engine'. Use 'gemini', 'claude', or 'copilot'."
        exit 1
    }
}

$EngineExit = $LASTEXITCODE

Write-Host ""
if ($EngineExit -eq 0) {
    Write-Host "Planning session ended."
    Write-Host "Next step: review .ralph/spec.md, then run: .\.ralph\loop.ps1 [-Engine ...] [-MaxIterations 20] [-Push `$true]"
} else {
    Write-Warning "Engine exited with code $EngineExit. Check that the planning session completed and spec.md was written before running loop.ps1."
}
