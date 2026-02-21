param(
    [string][ValidateSet("gemini", "claude")]$Engine = "gemini",
    [int]$MaxIterations = 20,
    [switch]$Push = $true
)

# .ralph/loop.ps1 - Headless Ralph Loop Orchestrator (PowerShell)
# This script runs the agent in a context-free loop until the goal is reached.

$SpecFile = ".ralph/spec.md"
$PromptFile = ".ralph/prompt.md"
$LogDir = ".ralph/logs"
$Iteration = 0

if (-not (Test-Path $LogDir)) {
    New-Item -ItemType Directory -Path $LogDir | Out-Null
}

Write-Host "ðŸš€ Starting Headless Ralph Loop with $Engine..." -ForegroundColor Cyan

while ($true) {
    $Iteration++
    
    if ($Iteration -gt $MaxIterations) {
        Write-Host "âš ï¸ Max iterations reached ($MaxIterations). Stopping loop." -ForegroundColor Yellow
        exit 1
    }

    Write-Host "--- Iteration $Iteration ---" -ForegroundColor Green
    
    $LogFile = "$LogDir/iteration_$Iteration.log"
    $Prompt = Get-Content $PromptFile -Raw

    if ($Engine -eq "gemini") {
        gemini -p "$Prompt" -y 2>&1 | Tee-Object -FilePath $LogFile
    } elseif ($Engine -eq "claude") {
        claude -p "$Prompt" --dangerously-skip-permissions 2>&1 | Tee-Object -FilePath $LogFile
    }

    # Auto-sync to GitHub if there are changes
    if ($Push -and (git status --porcelain)) {
        Write-Host "ðŸ”„ Syncing changes to GitHub..." -ForegroundColor Gray
        git add .
        # Using $($Iteration) to safely interpolate inside here-string
        git commit -m "Ralph Iteration $($Iteration): Automated Progress Sync"
        git push origin main
    }

    # Check for Mission Completion in the spec file
    if (Select-String -Path $SpecFile -Pattern "MISSION_COMPLETE" -Quiet) {
        Write-Host "ðŸŽ‰ Goal Reached! Overall Status: MISSION_COMPLETE" -ForegroundColor Cyan
        exit 0
    }

    Write-Host "Iteration $Iteration complete. Fresh context reload starting..." -ForegroundColor Gray
}