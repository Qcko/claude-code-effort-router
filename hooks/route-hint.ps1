#requires -Version 5.1
<#
UserPromptSubmit hook: scores the prompt and emits a thinking-budget hint.

Reads JSON payload from stdin (Claude Code hook contract).
Writes a short context block to stdout when escalation is warranted; otherwise stays silent.
Appends a one-line decision record to hooks/routing-log.jsonl (best-effort).
#>

[Console]::InputEncoding = [System.Text.Encoding]::UTF8
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$inputJson = [Console]::In.ReadToEnd()
if ([string]::IsNullOrWhiteSpace($inputJson)) { exit 0 }

try {
    $payload = $inputJson | ConvertFrom-Json
} catch {
    exit 0
}

$promptText = [string]$payload.prompt
if ([string]::IsNullOrWhiteSpace($promptText)) { exit 0 }

$lower = $promptText.ToLowerInvariant()
$score = 0
$suggestSubagent = $false

# Keyword sets — tuned to escalate effort only when the prompt actually warrants it.
$strong = @(
    'architecture', 'redesign', 'refactor', 'debug ', 'investigate', 'root cause',
    'race condition', 'deadlock', 'performance', 'optimize', 'security',
    'vulnerability', 'comprehensive', 'thoroughly', 'system-wide', 'audit',
    'review the entire', 'across the codebase', 'why does', 'why is',
    'design ', 'strategy', 'analyze', 'plan '
)
$medium = @(
    'implement', 'build ', 'create ', 'add ', 'write ', 'generate',
    'fix ', 'update', 'modify', 'change ', 'integrate', 'migrate'
)
$trivial = @(
    'rename', 'format', 'show me', 'list ', 'what does', 'what is',
    'print ', 'display ', 'add a comment', 'add comment', 'tell me'
)
$subagent = @(
    'research', 'audit', 'investigate the codebase', 'find all',
    'review every', 'every file', 'all files', 'all references',
    'search the codebase', 'across the project'
)

foreach ($kw in $strong)   { if ($lower.Contains($kw)) { $score += 3 } }
foreach ($kw in $medium)   { if ($lower.Contains($kw)) { $score += 1 } }
foreach ($kw in $trivial)  { if ($lower.Contains($kw)) { $score -= 2 } }
foreach ($kw in $subagent) { if ($lower.Contains($kw)) { $score += 2; $suggestSubagent = $true } }

# Length signal — long prompts usually carry more context/intent.
$len = $promptText.Length
if     ($len -ge 1500) { $score += 3 }
elseif ($len -ge 500)  { $score += 2 }
elseif ($len -ge 200)  { $score += 1 }
elseif ($len -lt 60)   { $score -= 2 }

# File-reference heuristic: @mentions and dotted filenames.
$fileRefs = ([regex]::Matches($promptText, '@[\w./\\-]+|\b[\w-]+\.[a-zA-Z]{1,5}\b')).Count
if     ($fileRefs -ge 3) { $score += 2 }
elseif ($fileRefs -ge 1) { $score += 1 }

# Map score to thinking trigger.
$tier = 'none'
if     ($score -ge 7) { $tier = 'ultrathink' }
elseif ($score -ge 4) { $tier = 'think hard' }
elseif ($score -ge 1) { $tier = 'think' }

# Emit hint to stdout (becomes additional context for the current turn only).
if ($tier -ne 'none') {
    Write-Output "[auto-router] complexity score $score -> applying thinking budget: $tier"
    Write-Output ""
    Write-Output $tier
    if ($suggestSubagent -and $tier -eq 'ultrathink') {
        Write-Output ""
        Write-Output 'Routing note: this prompt looks separable and research-heavy. If the work can be isolated, prefer spawning a Task subagent (with "ultrathink" in its prompt) over handling it all in this turn - keeps the driver context clean and parallelizes if there are multiple angles.'
    }
}

# Best-effort decision log (never block the turn on failure).
try {
    $projectDir = $env:CLAUDE_PROJECT_DIR
    if ([string]::IsNullOrWhiteSpace($projectDir)) { $projectDir = (Get-Location).Path }
    $logPath = Join-Path $projectDir 'hooks\routing-log.jsonl'
    $preview = if ($promptText.Length -gt 80) { $promptText.Substring(0, 80) } else { $promptText }
    $preview = $preview -replace "[`r`n]+", ' '
    $entry = [ordered]@{
        ts           = (Get-Date).ToUniversalTime().ToString('o')
        score        = $score
        tier         = $tier
        promptLen    = $len
        fileRefs     = $fileRefs
        subagentHint = $suggestSubagent
        preview      = $preview
    } | ConvertTo-Json -Compress
    Add-Content -Path $logPath -Value $entry -Encoding utf8
} catch {
    # swallow
}

exit 0
