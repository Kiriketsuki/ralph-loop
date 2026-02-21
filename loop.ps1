param(
    [string][ValidateSet("gemini", "claude")] = "gemini",
    [int] = 20
)

# .ralph/loop.ps1 - Headless Ralph Loop Orchestrator (PowerShell)
# This script runs the agent in a context-free loop until the goal is reached.

 = ".ralph/spec.md"
 = ".ralph/prompt.md"
 = ".ralph/logs"
 = 0

if (-not (Test-Path )) {
    New-Item -ItemType Directory -Path  | Out-Null
}

Write-Host "🚀 Starting Headless Ralph Loop with ..." -ForegroundColor Cyan

while (True) {
    ++
    
    if ( -gt ) {
        Write-Host "⚠️ Max iterations reached (). Stopping loop." -ForegroundColor Yellow
        exit 1
    }

    Write-Host "--- Iteration  ---" -ForegroundColor Green
    
     = "/iteration_.log"
     = Get-Content  -Raw

    if ( -eq "gemini") {
        # Run Gemini in headless mode
        # -p is for headless prompt, -y for YOLO mode
        gemini -p "" -y 2>&1 | Tee-Object -FilePath 
    } elseif ( -eq "claude") {
        # Run Claude Code in headless mode
        # -p is for print (non-interactive), --dangerously-skip-permissions for YOLO-like behavior
        claude -p "" --dangerously-skip-permissions 2>&1 | Tee-Object -FilePath 
    }

    # Check for Mission Completion in the spec file
    if (Select-String -Path  -Pattern "MISSION_COMPLETE" -Quiet) {
        Write-Host "🎉 Goal Reached! Overall Status: MISSION_COMPLETE" -ForegroundColor Cyan
        Write-Host "Final check of acceptance criteria..."
        exit 0
    }

    Write-Host "Iteration  complete. Resetting context for next turn." -ForegroundColor Gray
}