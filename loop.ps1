param(
    [string][ValidateSet("gemini", "claude", "copilot")]$Engine = "gemini",
    [int]$MaxIterations = 20,
    [bool]$Push = $true,
    [string]$Model = ""
)

# .ralph/loop.ps1 - Headless Ralph Loop Orchestrator (PowerShell)
# Run from the project root directory.
# Usage: .\.ralph\loop.ps1 [-Engine gemini|claude|copilot] [-MaxIterations 20] [-Push $true|$false] [-Model <model-id>]
#
# Exit codes:
#   0   MISSION_COMPLETE
#   1   Max iterations reached
#   2   Stuck -- no pending, no proposed tasks
#   3   Proposed tasks need human review

$SpecFile = ".ralph/spec.md"
$PromptFile = ".ralph/prompts/build.md"
$GuardrailsFile = ".ralph/prompts/guardrails.md"
$AgentsFile = ".ralph/agents.md"
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
    # Build full prompt: guardrails + build prompt + agents.md
    $Prompt = ""
    if (Test-Path $GuardrailsFile) {
        $Prompt = (Get-Content $GuardrailsFile -Raw) + "`n---`n"
    }
    $Prompt += Get-Content $PromptFile -Raw
    if (Test-Path $AgentsFile) {
        $Prompt += "`n---`n" + (Get-Content $AgentsFile -Raw)
    }
    $ModelArgs = @()
    if ($Model) { $ModelArgs = @("--model", $Model) }

    if ($Engine -eq "gemini") {
        gemini -p "$Prompt" -y @ModelArgs 2>&1 | Tee-Object -FilePath $LogFile
    } elseif ($Engine -eq "claude") {
        claude -p "$Prompt" --dangerously-skip-permissions @ModelArgs 2>&1 | Tee-Object -FilePath $LogFile
    } elseif ($Engine -eq "copilot") {
        copilot -p "$Prompt" --allow-all-tools @ModelArgs 2>&1 | Tee-Object -FilePath $LogFile
    } else {
        Write-Error "ERROR: Unknown engine '$Engine'. Use 'gemini', 'claude', or 'copilot'."
        exit 1
    }

    # Auto-sync to GitHub if there are changes
    if ($Push -and (git status --porcelain)) {
        Write-Host "Syncing changes to GitHub (branch: $Branch)..."
        # Stage tracked modified files + any new files under .ralph/ (avoids sweeping up
        # untracked secrets or build artifacts outside the agent's working area)
        git add -u; git add .ralph/
        git commit -m "Ralph Iteration $($Iteration): Automated Progress Sync"
        git push origin $Branch
    }

    # Check for mission completion
    if (Select-String -Path $SpecFile -Pattern "MISSION_COMPLETE" -Quiet) {
        Write-Host "Goal reached. Overall Status: MISSION_COMPLETE"
        exit 0
    }

    # Check for verification pending -- allow one more iteration
    if (Select-String -Path $SpecFile -Pattern "VERIFICATION_PENDING" -Quiet) {
        Write-Host "Verification iteration triggered. Agent will verify acceptance criteria..."
        continue
    }

    # Check for stuck state: no pending tasks remain but mission not complete
    if (-not (Select-String -Path $SpecFile -Pattern "\| *pending *\|" -Quiet)) {
        if (Select-String -Path $SpecFile -Pattern "\| *proposed *\|" -Quiet) {
            Write-Error "PAUSED: Proposed tasks require human review. Promote to 'pending' and re-run."
            exit 3
        }
        Write-Host "WARNING: No pending tasks remain but mission is not complete. Stopping loop." -ForegroundColor Yellow
        exit 2
    }

    Write-Host "Iteration $Iteration complete. Reloading with fresh context..."
}
