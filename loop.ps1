param(
    [string][ValidateSet("gemini", "claude")]$Engine = "gemini",
    [int]$MaxIterations = 20,
    [bool]$Push = $true
)

# .ralph/loop.ps1 - Headless Ralph Loop Orchestrator (PowerShell)
# Run from the project root directory.
# Usage: .\.ralph\loop.ps1 [-Engine gemini|claude] [-MaxIterations 20] [-Push $true|$false]

$SpecFile = ".ralph/spec.md"
$PromptFile = ".ralph/prompt.md"
$LogDir = ".ralph/logs"
$Iteration = 0

if (-not (Test-Path $SpecFile)) {
    Write-Error "ERROR: $SpecFile not found. Run from the project root."
    exit 1
}

if (-not (Test-Path $PromptFile)) {
    Write-Error "ERROR: $PromptFile not found. Run from the project root."
    exit 1
}

$Branch = git rev-parse --abbrev-ref HEAD 2>$null
if (-not $Branch) { $Branch = "main" }

if (-not (Test-Path $LogDir)) {
    New-Item -ItemType Directory -Path $LogDir | Out-Null
}

Write-Host "Starting Headless Ralph Loop with $Engine on branch $Branch..."

while ($true) {
    $Iteration++

    if ($Iteration -gt $MaxIterations) {
        Write-Host "WARNING: Max iterations reached ($MaxIterations). Stopping loop."
        exit 1
    }

    Write-Host "--- Iteration $Iteration ---"

    $LogFile = "$LogDir/iteration_$Iteration.log"
    $Prompt = Get-Content $PromptFile -Raw

    if ($Engine -eq "gemini") {
        gemini -p "$Prompt" -y 2>&1 | Tee-Object -FilePath $LogFile
    } elseif ($Engine -eq "claude") {
        claude -p "$Prompt" --dangerously-skip-permissions 2>&1 | Tee-Object -FilePath $LogFile
    }

    # Auto-sync to GitHub if there are changes
    if ($Push -and (git status --porcelain)) {
        Write-Host "Syncing changes to GitHub (branch: $Branch)..."
        git add .
        git commit -m "Ralph Iteration $($Iteration): Automated Progress Sync"
        git push origin $Branch
    }

    # Check for mission completion
    if (Select-String -Path $SpecFile -Pattern "MISSION_COMPLETE" -Quiet) {
        Write-Host "Goal reached. Overall Status: MISSION_COMPLETE"
        exit 0
    }

    # Check for stuck state: no pending tasks remain but mission not complete
    if (-not (Select-String -Path $SpecFile -Pattern "\| *pending *\|" -Quiet)) {
        Write-Host "WARNING: No pending tasks remain but mission is not complete. All tasks may be BLOCKED or FAILED. Stopping loop." -ForegroundColor Yellow
        exit 2
    }

    Write-Host "Iteration $Iteration complete. Reloading with fresh context..."
}
