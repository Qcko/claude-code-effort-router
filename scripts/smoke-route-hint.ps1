<#
.SYNOPSIS
  Smoke-test hooks/route-hint.ps1 end to end in a child Windows PowerShell 5.1.

.DESCRIPTION
  Pipes fixture prompts into the hook exactly as Claude Code does (JSON on
  stdin), with USERPROFILE pointed at a throwaway directory so the live
  routing log is never touched. Checks the tier, the emitted text, and the
  logged fields. Exits 1 on any failure.

.EXAMPLE
  powershell.exe -NoProfile -File .\scripts\smoke-route-hint.ps1
#>
$ErrorActionPreference = 'Stop'

$hook = Join-Path $PSScriptRoot '..\hooks\route-hint.ps1'
$sandbox = Join-Path ([IO.Path]::GetTempPath()) ("route-hint-smoke-" + [guid]::NewGuid().ToString('N'))
$logPath = Join-Path $sandbox '.claude\hooks\routing-log.jsonl'
New-Item -ItemType Directory -Force -Path (Split-Path $logPath) | Out-Null

$cases = @(
    @{ name = 'trivial';            prompt = 'rename the variable';                                   effort = 'low';  tier = 'none';       depth = $null;            skipped = $false }
    @{ name = 'think tier silent';  prompt = 'implement a retry helper for the download client and write unit tests for it';effort = 'low';  tier = 'think';      depth = $null;            skipped = $false }
    @{ name = 'multi-work floor';   prompt = 'lets fix both';                                         effort = 'low';  tier = 'think hard'; depth = 'high depth';     skipped = $false }
    @{ name = 'ultrathink';         prompt = 'refactor the auth module and redesign the architecture across the codebase thoroughly'; effort = 'low'; tier = 'ultrathink'; depth = 'maximum depth'; skipped = $false }
    @{ name = 'high effort quiet';  prompt = 'lets fix both';                                         effort = 'high'; tier = 'think hard'; depth = $null;            skipped = $false }
    @{ name = 'unset effort';       prompt = 'lets fix both';                                         effort = '';     tier = 'think hard'; depth = 'high depth';     skipped = $false }
    @{ name = 'reminder stripped';  prompt = "<system-reminder>`nrefactor and redesign the architecture across the codebase thoroughly`n</system-reminder>`nnew session"; effort = 'low'; tier = 'none'; depth = $null; skipped = $false }
    @{ name = 'transcript high quiet'; prompt = 'lets fix both'; effort = '';    transcriptEffort = 'high'; tier = 'think hard'; depth = $null;        skipped = $false }
    @{ name = 'transcript beats env';  prompt = 'lets fix both'; effort = 'high'; transcriptEffort = 'low'; tier = 'think hard'; depth = 'high depth'; skipped = $false }
    @{ name = 'agent hand-back';    prompt = '<agent-message from="x"> refactor the architecture</agent-message>'; effort = 'low'; tier = $null; depth = $null; skipped = $true }
)

function Invoke-Hook {
    param([string]$Prompt, [string]$Effort, [string]$TranscriptEffort)
    $payload = @{ prompt = $Prompt }
    if ($TranscriptEffort) {
        $transcript = Join-Path $sandbox 'transcript.jsonl'
        $turn = @{ type = 'assistant'; effort = $TranscriptEffort; message = @{ content = @(@{ type = 'text'; text = 'Done.' }) } }
        [IO.File]::WriteAllText($transcript, ($turn | ConvertTo-Json -Compress -Depth 5))
        $payload.transcript_path = $transcript
    }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'powershell.exe'
    $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$hook`""
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.EnvironmentVariables['USERPROFILE'] = $sandbox
    $psi.EnvironmentVariables['CLAUDE_EFFORT'] = $Effort
    $psi.EnvironmentVariables.Remove('EFFORT_ROUTER_DISABLED')
    $proc = [System.Diagnostics.Process]::Start($psi)
    $proc.StandardInput.Write(($payload | ConvertTo-Json -Compress))
    $proc.StandardInput.Close()
    $stdout = $proc.StandardOutput.ReadToEnd()
    $proc.WaitForExit()
    return $stdout
}

function Get-LogLineCount {
    if (-not (Test-Path $logPath)) { return 0 }
    return @(Get-Content -Encoding UTF8 $logPath).Count
}

function Test-Case {
    param($Case)
    $problems = @()
    $before = Get-LogLineCount
    $stdout = Invoke-Hook -Prompt $Case.prompt -Effort $Case.effort -TranscriptEffort $Case.transcriptEffort
    $expectedEffort = if ($Case.transcriptEffort) { $Case.transcriptEffort } else { $Case.effort }
    $after = Get-LogLineCount

    if ($Case.skipped) {
        if ($after -ne $before) { $problems += 'expected no log entry' }
        if ($stdout.Trim()) { $problems += 'expected no stdout' }
        return $problems
    }
    if ($after -ne $before + 1) { return @('expected exactly one log entry') }

    $entry = @(Get-Content -Encoding UTF8 $logPath)[-1] | ConvertFrom-Json
    if ($entry.tier -ne $Case.tier) { $problems += "tier $($entry.tier), expected $($Case.tier)" }
    if ($entry.emitVersion -ne 2) { $problems += 'emitVersion missing' }
    $expectedSource = if ($Case.transcriptEffort) { 'transcript' } elseif ($Case.effort) { 'env' } else { '' }
    if ([string]$entry.effortSource -ne $expectedSource) { $problems += "effortSource '$($entry.effortSource)', expected '$expectedSource'" }
    if ([string]$entry.sessionEffort -ne $expectedEffort) { $problems += "sessionEffort '$($entry.sessionEffort)', expected '$expectedEffort'" }
    if ($Case.depth -and -not $entry.emitted) { $problems += 'emitted false despite a depth line' }
    if ($entry.preview -match 'system-reminder') { $problems += 'reminder leaked into preview' }
    if ($stdout -match '(?m)^(think|think hard|ultrathink)\s*$') { $problems += 'bare keyword line emitted' }
    if ($stdout -match 'thinking budget') { $problems += 'stale status line' }
    if ($Case.depth -and $stdout -notmatch [regex]::Escape("auto-router: $($Case.depth)")) { $problems += "missing '$($Case.depth)' line" }
    if (-not $Case.depth -and $stdout -match 'auto-router: \w+ depth') { $problems += 'unexpected depth line' }
    if ($stdout -match '[^\x00-\x7F]') { $problems += 'non-ASCII output' }
    return $problems
}

$failed = 0
try {
    foreach ($case in $cases) {
        $problems = @(Test-Case -Case $case)
        if ($problems.Count -eq 0) {
            Write-Host "PASS  $($case.name)"
        } else {
            $failed++
            Write-Host "FAIL  $($case.name): $($problems -join '; ')" -ForegroundColor Red
        }
    }
} finally {
    Remove-Item -Recurse -Force $sandbox -ErrorAction SilentlyContinue
}

Write-Host ("{0} of {1} passed" -f ($cases.Count - $failed), $cases.Count)
if ($failed) { exit 1 }
