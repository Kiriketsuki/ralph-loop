param(
    [string][ValidateSet("gemini", "claude", "copilot")]$Engine = "gemini",
    [int]$MaxIterations = 20,
    [bool]$Push = $true,
    [string]$Model = "",
    [string][ValidateSet("build", "plan-work")]$Mode = "build",
    [string]$WorkScope = "",
    [switch]$DryRun
)

# .ralph/loop.ps1 - Headless Ralph Loop Orchestrator (PowerShell) v2
# Run from the project root directory.
# Usage: .\.ralph\loop.ps1 [-Engine gemini|claude|copilot] [-MaxIterations 20] [-Push $true|$false]
#                           [-Model <model-id>] [-Mode build|plan-work] [-WorkScope "description"] [-DryRun]
#
# Exit codes:
#   0   MISSION_COMPLETE (build mode); plan written to spec (plan-work mode)
#   1   Max iterations reached
#   2   Stuck -- no pending, no proposed tasks
#   3   Proposed tasks need human review
#   4   Gutter detected -- agent in a rut
#   130 Ctrl+C / SIGTERM

# ENGINE allowlist validation (T1.1)
if ($Engine -notin @("gemini", "claude", "copilot")) {
    Write-Error "ERROR: Unknown engine '$Engine'. Use 'gemini', 'claude', or 'copilot'."
    exit 1
}

# Backpressure and timeout configuration (T2.1, T3.1, T6.1)
$AgentTimeout   = if ($env:RALPH_AGENT_TIMEOUT)   { [int]$env:RALPH_AGENT_TIMEOUT }   else { 1800 }
$BackoffMax     = if ($env:RALPH_BACKOFF_MAX)      { [int]$env:RALPH_BACKOFF_MAX }     else { 300 }
$CircuitBreaker = if ($env:RALPH_CIRCUIT_BREAKER)  { [int]$env:RALPH_CIRCUIT_BREAKER } else { 3 }
$SpawnDelay     = if ($env:RALPH_SPAWN_DELAY)      { [int]$env:RALPH_SPAWN_DELAY }     else { 2 }

$SpecFile      = ".ralph/spec.md"
$GuardrailsFile = ".ralph/prompts/guardrails.md"
$AgentsFile    = ".ralph/agents.md"
$LogDir        = ".ralph/logs"

# Resolve prompt file from mode
$PromptFile = if ($Mode -eq "plan-work") { ".ralph/prompts/plan-work.md" } else { ".ralph/prompts/build.md" }

# --- plan-work validation ---
if ($Mode -eq "plan-work") {
    $CurrentBranch = git rev-parse --abbrev-ref HEAD 2>$null
    if (-not $CurrentBranch) { $CurrentBranch = "main" }
    if ($CurrentBranch -in @("main", "master", "HEAD")) {
        Write-Error "ERROR: plan-work mode requires a feature branch. You are on '$CurrentBranch'."
        Write-Error "Create a feature branch first: git checkout -b feature/<name>"
        exit 1
    }
    if (-not $WorkScope) {
        Write-Error "ERROR: plan-work mode requires -WorkScope argument."
        Write-Error "Usage: .\.ralph\loop.ps1 [...] -Mode plan-work -WorkScope 'description of work'"
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

# --- Required file checks ---
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

# --- Build full prompt ---
function Build-Prompt {
    $content = ""
    if (Test-Path $GuardrailsFile) {
        $content = (Get-Content $GuardrailsFile -Raw) + "`n---`n"
    }
    $promptContent = Get-Content $PromptFile -Raw
    if ($Mode -eq "plan-work") {
        $promptContent = $promptContent -replace [regex]::Escape('$WORK_SCOPE'), $WorkScope
    }
    $content += $promptContent
    if (Test-Path $AgentsFile) {
        $content += "`n---`n" + (Get-Content $AgentsFile -Raw)
    }
    return $content
}

# --- Dry-run mode ---
if ($DryRun) {
    Write-Host "=== DRY RUN: Full Concatenated Prompt ==="
    Write-Host ""
    Write-Host (Build-Prompt)
    Write-Host ""
    Write-Host "=== Engine Command ==="
    $modelStr = if ($Model) { " --model $Model" } else { "" }
    switch ($Engine) {
        "gemini"  { Write-Host "gemini -p `"`$Prompt`" -y$modelStr" }
        "claude"  { Write-Host "claude -p `"`$Prompt`" --dangerously-skip-permissions --output-format stream-json --verbose$modelStr" }
        "copilot" { Write-Host "copilot -p `"`$Prompt`" --allow-all-tools$modelStr" }
    }
    Write-Host ""
    Write-Host "=== No engine invoked (-DryRun). ==="
    exit 0
}

# --- Seed iteration counter from spec ---
$iterMatch = Select-String -Path $SpecFile -Pattern '\*\*Current Iteration\*\*:\s*(\d+)' | Select-Object -First 1
$Iteration = if ($iterMatch -and $iterMatch.Matches.Count -gt 0) {
    [int]$iterMatch.Matches[0].Groups[1].Value
} else { 0 }

# --- On fresh loop (iteration 0), create ralph/<slug> branch ---
if ($Iteration -eq 0 -and $Mode -eq "build") {
    $titleMatch = Select-String -Path $SpecFile -Pattern '^# Ralph Project Specification:\s*(.+)' | Select-Object -First 1
    $Slug = if ($titleMatch -and $titleMatch.Matches.Count -gt 0) {
        $titleMatch.Matches[0].Groups[1].Value.ToLower() -replace '[^a-z0-9]+', '-' -replace '^-|-$', ''
    } else { "loop" }
    $RalphBranch = "ralph/$Slug"
    $branchExists = git rev-parse --verify $RalphBranch 2>$null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "Branch $RalphBranch already exists. Switching to it..."
        git checkout $RalphBranch
    } else {
        Write-Host "Fresh loop detected (iteration 0). Creating branch $RalphBranch from $Branch..."
        git checkout -b $RalphBranch
    }
    $Branch = $RalphBranch
}

# --- Token counting thresholds (mirrors stream/parser.sh logic) ---
# IMPORTANT: defaults MUST stay in sync with stream/parser.sh lines 24-25.
# PowerShell's [int] cast is safe against arithmetic injection (unlike bash arithmetic).
$WarnTokens   = if ($env:RALPH_TOKEN_WARN)   { [int]$env:RALPH_TOKEN_WARN }   else { 100000 }
$RotateTokens = if ($env:RALPH_TOKEN_ROTATE) { [int]$env:RALPH_TOKEN_ROTATE } else { 128000 }
$WarnChars   = $WarnTokens * 4
$RotateChars = $RotateTokens * 4

$ModelArgs = @()
if ($Model) { $ModelArgs = @("--model", $Model) }

Write-Host "Starting Headless Ralph Loop [mode: $Mode] with $Engine on branch $Branch (resuming from iteration $Iteration)..."

# Consecutive no-progress iteration counter for exponential backoff (T3.1 + T7.1)
$ConsecutiveFailBatches = 0

while ($true) {
    $Iteration++

    if ($Iteration -gt $MaxIterations) {
        Write-Host "WARNING: Max iterations reached ($MaxIterations). Stopping loop."
        exit 1
    }

    # Inter-iteration stagger delay (T6.1): prevents API burst on consecutive iterations
    if ($SpawnDelay -gt 0 -and $Iteration -gt 1) {
        Start-Sleep -Seconds $SpawnDelay
    }

    Write-Host "--- Iteration $Iteration ---"

    $LogFile    = "$LogDir/iteration_$Iteration.log"
    $FullPrompt = Build-Prompt

    # Snapshot pending task count before invocation for plan-work completion detection.
    $PendingBefore = (Select-String -Path $SpecFile -Pattern '\|\s*pending\s*\|' -AllMatches |
        Measure-Object).Count

    # --- Invoke engine with per-agent wall-clock timeout via Start-Job (T2.1) ---
    $TotalChars     = 0
    $Warned         = $false
    $TokenRotate    = $false
    $EngineExitCode = 0
    $TimedOut       = $false

    $engineJob = Start-Job -ScriptBlock {
        param($Eng, $Prompt, $MArgs, $EnvPath)
        $env:PATH = $EnvPath  # propagate PATH so engine CLIs are resolvable in the job runspace
        switch ($Eng) {
            "gemini"  { & gemini  -p $Prompt -y @MArgs 2>&1 }
            "claude"  { & claude  -p $Prompt --dangerously-skip-permissions @MArgs 2>&1 }
            "copilot" { & copilot -p $Prompt --allow-all-tools @MArgs 2>&1 }
        }
        "__RALPH_EXITCODE__:$LASTEXITCODE"  # sentinel line to propagate exit code back to parent
    } -ArgumentList $Engine, $FullPrompt, $ModelArgs, $env:PATH

    $deadline  = (Get-Date).AddSeconds($AgentTimeout)
    $LogWriter = [System.IO.StreamWriter]::new($LogFile, $false, [System.Text.Encoding]::UTF8)
    try {
        # Poll job output at 200ms intervals while respecting the timeout deadline
        while ($engineJob.State -eq 'Running') {
            if ((Get-Date) -gt $deadline) {
                Stop-Job -Job $engineJob
                $TimedOut = $true
                Write-Warning "[AGENT TIMEOUT] Agent exceeded ${AgentTimeout}s wall-clock limit. Stopping."
                break
            }
            foreach ($line in @(Receive-Job -Job $engineJob -ErrorAction SilentlyContinue)) {
                if ($line -match '^__RALPH_EXITCODE__:(\d+)$') { $EngineExitCode = [int]$Matches[1]; continue }
                $LogWriter.WriteLine($line)
                if (-not $TokenRotate) {
                    Write-Host $line
                    $TotalChars += $line.Length + 1
                    if (-not $Warned -and $TotalChars -ge $WarnChars) {
                        $Warned = $true
                        Write-Warning "[TOKEN WARNING] Approaching context limit. Finish current step and exit."
                    }
                    if ($TotalChars -ge $RotateChars) {
                        Write-Warning "[TOKEN ROTATE] Context limit reached. Stopping display."
                        $TokenRotate = $true
                    }
                }
            }
            Start-Sleep -Milliseconds 200
        }
        # Drain remaining output after job completes or is stopped
        foreach ($line in @(Receive-Job -Job $engineJob -ErrorAction SilentlyContinue)) {
            if ($line -match '^__RALPH_EXITCODE__:(\d+)$') { $EngineExitCode = [int]$Matches[1]; continue }
            $LogWriter.WriteLine($line)
            if (-not $TokenRotate) {
                Write-Host $line
                $TotalChars += $line.Length + 1
                if (-not $Warned -and $TotalChars -ge $WarnChars) {
                    $Warned = $true
                    Write-Warning "[TOKEN WARNING] Approaching context limit. Finish current step and exit."
                }
                if ($TotalChars -ge $RotateChars) {
                    Write-Warning "[TOKEN ROTATE] Context limit reached. Stopping display."
                    $TokenRotate = $true
                }
            }
        }
    } finally {
        $LogWriter.Dispose()
        Remove-Job -Job $engineJob -Force 2>$null
    }

    if ($TimedOut) {
        $EngineExitCode = 1
        $now = Get-Date -Format "yyyy-MM-dd HH:mm"
        Add-Content ".ralph/progress.md" "- **[$now]** (Iteration $Iteration) fail: Iteration $Iteration timeout. Reason: Agent exceeded RALPH_AGENT_TIMEOUT=${AgentTimeout}s. Avoid: reduce task scope or increase RALPH_AGENT_TIMEOUT."
    }

    if ($TokenRotate) {
        Write-Host "Token rotate: context limit reached. Treating as clean iteration end."
    } elseif ($EngineExitCode -ne 0) {
        Write-Warning "Engine exited with code $EngineExitCode."
    }

    # --- Commit block: always commit if changes exist; push only when requested ---
    # Committing before gutter detection ensures diagnostics are preserved on exit 4.
    $gitStatus = git status --porcelain
    if ($gitStatus) {
        Write-Host "Committing changes (branch: $Branch)..."
        # Parse semantic commit info from progress.md
        $ProgressMatch = Select-String -Path ".ralph/progress.md" -Pattern "\(Iteration $Iteration\)\s+([a-z]+):\s*(.+)" |
            Select-Object -First 1
        if ($ProgressMatch -and $ProgressMatch.Matches.Count -gt 0) {
            $CommitType    = $ProgressMatch.Matches[0].Groups[1].Value
            $CommitSummary = $ProgressMatch.Matches[0].Groups[2].Value.Trim()
        } else {
            $CommitType    = "chore"
            $CommitSummary = "Iteration $Iteration automated progress sync"
        }
        # Sanitize commit message (T4.1): strip markdown headings, backticks, $, cap at 1000 chars.
        $SafeSummary = $CommitSummary -replace '(?m)^##[^\r\n]*', '' -replace '[`$]', ''
        if ($SafeSummary.Length -gt 1000) { $SafeSummary = $SafeSummary.Substring(0, 1000) }
        $CommitMsg   = "${CommitType}(ralph): $SafeSummary"

        git add -u
        # Stage explicit agent-writable paths only (avoids staging secrets or build artifacts).
        @(".ralph/spec.md", ".ralph/progress.md", ".ralph/changelog.md",
          ".ralph/agents.md", ".ralph/logs", ".ralph/specs") | ForEach-Object {
            if (Test-Path $_) { git add $_ }
        }
        git commit -m $CommitMsg

        if ($Push) {
            Write-Host "Pushing to GitHub (branch: $Branch)..."
            git push origin $Branch
        }
    }

    # --- Gutter detection (after commit so diagnostics are preserved on exit 4) ---
    $GutterScript = ".ralph/stream/gutter.sh"
    $bashCmd = Get-Command bash -ErrorAction SilentlyContinue
    if ($bashCmd -and (Test-Path $GutterScript)) {
        bash $GutterScript
        if ($LASTEXITCODE -ne 0) {
            Write-Error "GUTTER DETECTED: Agent appears to be in a rut. Human review needed."
            Write-Error "Check .ralph/progress.md for repeated patterns, then re-run or adjust spec."
            exit 4
        }
    }

    # --- plan-work exit condition ---
    if ($Mode -eq "plan-work") {
        $PendingAfter = (Select-String -Path $SpecFile -Pattern '\|\s*pending\s*\|' -AllMatches |
            Measure-Object).Count
        if ($PendingAfter -gt $PendingBefore) {
            Write-Host "Plan-work session complete. New pending tasks written to spec.md."
            Write-Host "Switch to build mode: .\.ralph\loop.ps1 [...] -Mode build"
            exit 0
        }
        Write-Host "Iteration $Iteration complete. Continuing plan-work session..."
        continue
    }

    # --- MISSION_COMPLETE check (anchored to Overall Status field) ---
    if (Select-String -Path $SpecFile -Pattern '\*\*Overall Status\*\*:.*MISSION_COMPLETE' -Quiet) {
        Write-Host "Goal reached. Overall Status: MISSION_COMPLETE"
        exit 0
    }

    # --- VERIFICATION_PENDING check (anchored to Overall Status field) ---
    if (Select-String -Path $SpecFile -Pattern '\*\*Overall Status\*\*:.*VERIFICATION_PENDING' -Quiet) {
        Write-Host "Verification iteration triggered. Agent will verify acceptance criteria..."
        continue
    }

    # --- Stuck check: no pending tasks remain but mission not complete ---
    if (-not (Select-String -Path $SpecFile -Pattern '\|\s*pending\s*\|' -Quiet)) {
        if (Select-String -Path $SpecFile -Pattern '\|\s*proposed\s*\|' -Quiet) {
            Write-Error "PAUSED: Proposed tasks require human review. Promote to 'pending' and re-run."
            exit 3
        }
        Write-Host "WARNING: No pending tasks remain but mission is not complete. Stopping loop." -ForegroundColor Yellow
        exit 2
    }

    # Exponential backoff on consecutive no-progress iterations (T3.1 + T7.1)
    $madeProgress = [bool]$gitStatus
    if (-not $madeProgress) {
        $ConsecutiveFailBatches++
        $backoffBase = [Math]::Pow(2, [Math]::Min($ConsecutiveFailBatches, 30))
        if ($ConsecutiveFailBatches -ge $CircuitBreaker) {
            $backoffBase = $backoffBase * $ConsecutiveFailBatches
        }
        $jitter   = Get-Random -Minimum 0 -Maximum 5
        $sleepSec = [int][Math]::Min($backoffBase + $jitter, $BackoffMax)
        Write-Host "No-progress iteration #${ConsecutiveFailBatches}. Backing off for ${sleepSec}s..."
        Start-Sleep -Seconds $sleepSec
    } else {
        $ConsecutiveFailBatches = 0
    }

    Write-Host "Iteration $Iteration complete. Reloading with fresh context..."
}
