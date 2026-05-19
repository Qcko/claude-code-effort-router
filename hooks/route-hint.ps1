#requires -Version 5.1
<#
UserPromptSubmit hook: scores the prompt and emits a thinking-budget hint.

Reads JSON payload from stdin (Claude Code hook contract).
Writes a short context block to stdout when escalation is warranted; otherwise stays silent.
Appends a one-line decision record to %USERPROFILE%\.claude\hooks\routing-log.jsonl (best-effort).

This file is the canonical source. It is installed as a user-global hook at
%USERPROFILE%\.claude\hooks\route-hint.ps1 (see README). Edit here, then re-deploy.

Set EFFORT_ROUTER_DISABLED=1 to bypass the hook without uninstalling.
#>

[Console]::InputEncoding = [System.Text.Encoding]::UTF8
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

if ($env:EFFORT_ROUTER_DISABLED -eq '1') { exit 0 }

$inputJson = [Console]::In.ReadToEnd()
if ([string]::IsNullOrWhiteSpace($inputJson)) { exit 0 }

try {
    $payload = $inputJson | ConvertFrom-Json
} catch {
    exit 0
}

$promptText = [string]$payload.prompt
if ([string]::IsNullOrWhiteSpace($promptText)) { exit 0 }

# Skip internal tool-result echoes — they aren't user prompts and shouldn't
# consume a routing decision or pollute the log.
if ($promptText.TrimStart().StartsWith('<task-notification>')) { exit 0 }

# Peek at the prior assistant turn from the session transcript. The hook
# payload's transcript_path points at the jsonl. A short user prompt like
# "yes lets do that" carries no signal alone, but if the model just asked a
# question the answer commits to whatever was proposed — usually real work.
# Read tail-only so this stays cheap on long sessions.
$priorTail = $null
$priorEndedWithQuestion = $false
$transcriptPath = [string]$payload.transcript_path
if ($transcriptPath -and (Test-Path -LiteralPath $transcriptPath)) {
    try {
        # @() forces array context — single-line files otherwise come back as a
        # bare [string], and $tail[$i] then indexes characters instead of lines.
        $tail = @(Get-Content -LiteralPath $transcriptPath -Tail 50 -Encoding utf8 -ErrorAction Stop)
        for ($i = $tail.Count - 1; $i -ge 0; $i--) {
            $line = $tail[$i]
            if (-not $line -or -not $line.Trim()) { continue }
            try { $obj = $line | ConvertFrom-Json } catch { continue }
            if ($obj.type -ne 'assistant') { continue }
            if (-not $obj.message -or -not $obj.message.content) { continue }
            $textBlocks = @($obj.message.content | Where-Object { $_.type -eq 'text' -and $_.text })
            if ($textBlocks.Count -eq 0) { continue }
            $fullText = (($textBlocks | ForEach-Object { $_.text }) -join "`n").TrimEnd()
            if (-not $fullText) { continue }
            $priorEndedWithQuestion = $fullText.EndsWith('?')
            $sentence = if ($fullText.Length -gt 500) { $fullText.Substring($fullText.Length - 500) } else { $fullText }
            $priorTail = ($sentence -replace "[`r`n]+", ' ').Trim()
            if ($priorTail.Length -gt 400) { $priorTail = $priorTail.Substring($priorTail.Length - 400) }
            break
        }
    } catch { }
}

$lower = $promptText.ToLowerInvariant()
$score = 0
$suggestSubagent = $false
$strongFired = $false
$executeFired = $false

$strong = @(
    'architecture', 'redesign', 'refactor', 'debug ', 'investigate', 'root cause',
    'race condition', 'deadlock', 'performance', 'optimize', 'security',
    'vulnerability', 'comprehensive', 'thoroughly', 'system-wide', 'audit',
    'review the entire', 'across the codebase', 'why does', 'why is',
    'design ', 'strategy', 'analyze', 'plan ',
    'trade-offs', 'preserve behavior', 'preserve current behavior'
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
# Trigger phrases — explicit user signals to execute a previously discussed plan.
# Designed to be deliberate, not accidental. Score boost is enough to clear
# think hard even on a very short prompt; length-penalty is skipped for them.
$execute = @(
    'yes do that', 'lets do that', "let's do that",
    'go ahead and do it', 'apply the plan', 'apply the changes'
)

foreach ($kw in $strong)   { if ($lower.Contains($kw)) { $score += 3; $strongFired = $true } }
foreach ($kw in $subagent) { if ($lower.Contains($kw)) { $score += 2; $suggestSubagent = $true } }
foreach ($kw in $medium)   { if ($lower.Contains($kw)) { $score += 1 } }
foreach ($kw in $execute)  { if ($lower.Contains($kw)) { $score += 3; $executeFired = $true; $strongFired = $true } }

# Short affirmative answering a question the model just asked. "yes lets do
# that" is in the execute list already; this catches the bare "yes" / "ok" /
# "yep" / "do it" forms that carry no signal alone but commit to whatever was
# proposed in the prior turn. Also catches numeric picks ("1", "do 1",
# "option 2", "go with 1") and "go with your rec[ommendation]" — these
# typically follow a ranked list of candidates per the GLaDOS offer-next-step
# pattern. Same weight as the explicit execute phrases.
if (-not $executeFired -and $priorEndedWithQuestion) {
    $affirmativePatterns = @(
        '^\s*(yes|yep|yeah|sure|ok|okay|go|go ahead|do it|please do)\W*$',
        '^\s*(do|go with|option|pick|choice)?\s*#?\s*[1-9]\W*$',
        '^\s*go with (your |the )?(rec|recommendation|suggestion)\W*$',
        '^\s*(your |the )?(rec|recommendation)\W*$'
    )
    foreach ($pat in $affirmativePatterns) {
        if ($promptText -imatch $pat) {
            $score += 3
            $executeFired = $true
            $strongFired = $true
            break
        }
    }
}

# Extra weight on 'refactor': analyzer showed typical refactor prompts produce
# 28-48k output but were scoring 3 -> think. The +1 on top of the strong-list +3
# nudges a bare "refactor X" prompt over the think-hard boundary (>=4).
if ($lower.Contains('refactor')) { $score += 1 }

# Trivial penalties only apply when no strong/subagent signal fired. Keeps the
# trivial bucket precise without docking complex prompts that happen to contain
# a soft word like "list" or "what does" alongside an "audit" or "investigate".
if (-not $strongFired -and -not $suggestSubagent) {
    foreach ($kw in $trivial) { if ($lower.Contains($kw)) { $score -= 2 } }
}

# Length signal — long prompts usually carry more context/intent. Trigger
# phrases are short by design, so the short-prompt penalty is skipped for them.
$len = $promptText.Length
if     ($len -ge 1500)                          { $score += 3 }
elseif ($len -ge 500)                           { $score += 2 }
elseif ($len -ge 150)                           { $score += 1 }
elseif ($len -lt 60 -and -not $executeFired)    { $score -= 2 }

# File-ref regex: extension starts with a letter then 0-4 alnum, so .ps1, .py3,
# .h264, .mp4 all count. Previous regex required all-letter extensions.
$fileRefs = ([regex]::Matches($promptText, '@[\w./\\-]+|\b[\w-]+\.[a-zA-Z][a-zA-Z0-9]{0,4}\b')).Count
if     ($fileRefs -ge 3) { $score += 2 }
elseif ($fileRefs -ge 1) { $score += 1 }

$tier = 'none'
if     ($score -ge 7) { $tier = 'ultrathink' }
elseif ($score -ge 4) { $tier = 'think hard' }
elseif ($score -ge 1) { $tier = 'think' }

# Gated intent classification: only at think hard / ultrathink. Cheap path
# (none/think) stays token-free. Priority order is most-specific first, so a
# "refactor and explain..." prompt is tagged refactor, not explain. Each box
# is per-tier eligible — add new boxes here when the routing log shows misses.
$intent = $null

if ($tier -eq 'think hard' -or $tier -eq 'ultrathink') {
    # 1. execute — explicit user signal to follow through on a discussed plan
    if ($executeFired) { $intent = 'execute' }

    # 2. audit — research-heavy work, both tiers
    if (-not $intent -and $suggestSubagent) { $intent = 'audit' }

    # 3. refactor — both tiers
    if (-not $intent) {
        foreach ($kw in @('refactor', 'restructure', 'extract ', 'split into')) {
            if ($lower.Contains($kw)) { $intent = 'refactor'; break }
        }
    }

    # 3. architecture — ultrathink only (broad redesign work)
    if (-not $intent -and $tier -eq 'ultrathink') {
        foreach ($kw in @('architecture', 'redesign', 'design ', 'strategy')) {
            if ($lower.Contains($kw)) { $intent = 'architecture'; break }
        }
    }

    # 4. debug — both tiers
    if (-not $intent) {
        foreach ($kw in @('why does', 'why is', 'root cause', 'fails', 'failing', 'broken', 'debug ')) {
            if ($lower.Contains($kw)) { $intent = 'debug'; break }
        }
    }

    # 5. implement — both tiers
    if (-not $intent) {
        foreach ($kw in @('implement', 'build ', 'create ', 'add ', 'write ', 'generate')) {
            if ($lower.Contains($kw)) { $intent = 'implement'; break }
        }
    }

    # 6. explain — both tiers (most generic, last)
    if (-not $intent) {
        foreach ($kw in @('explain', 'how does', 'what does')) {
            if ($lower.Contains($kw)) { $intent = 'explain'; break }
        }
    }
}

$intentHints = @{
    'execute'      = '[execute] Follow through on the previously discussed plan in this conversation. Re-read the relevant earlier turns for the agreed design. Execute precisely what was agreed; ask before deviating.'
    'debug'        = '[debug] Frame as root-cause analysis. Reproduce the failure mentally before proposing a fix. Cite the line that breaks the invariant.'
    'implement'    = '[implement] Prefer editing existing files over creating new ones. Match surrounding style. Add minimal abstractions.'
    'explain'      = '[explain] Direct answer first, then evidence with file:line citations. Skip preamble.'
    'audit'        = '[audit] Read full files, not snippets. Group findings by severity with file:line citations. Don''t stop at obvious matches. If the work is separable, prefer spawning a Task subagent (with "ultrathink") over handling everything in this turn.'
    'refactor'     = '[refactor] Preserve observable behavior. Show the full refactored code (or a complete diff) so it can be applied directly — don''t just describe the splits. Note trade-offs per change. Avoid introducing abstractions beyond what was asked.'
    'architecture' = '[architecture] Sketch alternatives before committing to one. Name trade-offs explicitly.'
}

if ($tier -ne 'none') {
    Write-Output "[auto-router] complexity score $score -> applying thinking budget: $tier"
    Write-Output ""
    Write-Output $tier
    if ($intent) {
        Write-Output ""
        Write-Output $intentHints[$intent]
    }
}

try {
    $logDir = Join-Path $env:USERPROFILE '.claude\hooks'
    $logPath = Join-Path $logDir 'routing-log.jsonl'
    $preview = if ($promptText.Length -gt 80) { $promptText.Substring(0, 80) } else { $promptText }
    $preview = $preview -replace "[`r`n]+", ' '
    $project = $env:CLAUDE_PROJECT_DIR
    if ([string]::IsNullOrWhiteSpace($project)) { $project = (Get-Location).Path }
    $entry = [ordered]@{
        ts                     = (Get-Date).ToUniversalTime().ToString('o')
        project                = $project
        score                  = $score
        tier                   = $tier
        intent                 = $intent
        promptLen              = $len
        fileRefs               = $fileRefs
        subagentHint           = $suggestSubagent
        priorEndedWithQuestion = $priorEndedWithQuestion
        priorTail              = $priorTail
        preview                = $preview
    } | ConvertTo-Json -Compress
    Add-Content -Path $logPath -Value $entry -Encoding utf8
} catch {
    # swallow
}

exit 0
