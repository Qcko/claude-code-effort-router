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

# Harness-injected context (e.g. the worktree notice on a session's first
# prompt) arrives prepended to the user's words. Score only what the user typed.
$promptText = $promptText -replace '^(\s*<system-reminder>[\s\S]*?</system-reminder>)+\s*', ''
if ([string]::IsNullOrWhiteSpace($promptText)) { exit 0 }

# Skip internal tool-result echoes -- they aren't user prompts and shouldn't
# consume a routing decision or pollute the log.
if ($promptText.TrimStart().StartsWith('<task-notification>')) { exit 0 }
if ($promptText.TrimStart().StartsWith('<agent-message ')) { exit 0 }

# Peek at the prior assistant turn from the session transcript. The hook
# payload's transcript_path points at the jsonl. A short user prompt like
# "yes lets do that" carries no signal alone, but if the model just asked a
# question the answer commits to whatever was proposed -- usually real work.
# Read tail-only so this stays cheap on long sessions.
$priorTail = $null
$priorEndedWithQuestion = $false
$transcriptEffort = ''
$transcriptPath = [string]$payload.transcript_path
if ($transcriptPath -and (Test-Path -LiteralPath $transcriptPath)) {
    try {
        # @() forces array context -- single-line files otherwise come back as a
        # bare [string], and $tail[$i] then indexes characters instead of lines.
        $tail = @(Get-Content -LiteralPath $transcriptPath -Tail 50 -Encoding utf8 -ErrorAction Stop)
        for ($i = $tail.Count - 1; $i -ge 0; $i--) {
            $line = $tail[$i]
            if (-not $line -or -not $line.Trim()) { continue }
            try { $obj = $line | ConvertFrom-Json } catch { continue }
            if ($obj.type -ne 'assistant' -or $obj.isSidechain) { continue }
            if (-not $transcriptEffort -and $obj.effort) { $transcriptEffort = ([string]$obj.effort).Trim() }
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
$strongKeywordFired = $false
$executeFired = $false
$affirmativeFired = $false
$mediumFired = $false

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
# Trigger phrases -- explicit user signals to execute a previously discussed plan.
# Designed to be deliberate, not accidental. Score boost is enough to clear
# think hard even on a very short prompt; length-penalty is skipped for them.
$execute = @(
    'yes do that', 'lets do that', "let's do that",
    'go ahead and do it', 'apply the plan', 'apply the changes'
)

foreach ($kw in $strong)   { if ($lower.Contains($kw)) { $score += 3; $strongFired = $true; $strongKeywordFired = $true } }
foreach ($kw in $subagent) { if ($lower.Contains($kw)) { $score += 2; $suggestSubagent = $true } }
foreach ($kw in $medium)   { if ($lower.Contains($kw)) { $score += 1; $mediumFired = $true } }
foreach ($kw in $execute)  { if ($lower.Contains($kw)) { $score += 3; $executeFired = $true; $strongFired = $true } }

# Short affirmative answering a question the model just asked. "yes lets do
# that" is in the execute list already; this catches the forms that carry no
# signal alone but commit to whatever was proposed in the prior turn. Three
# shapes, all per the GLaDOS offer-next-step pattern:
#   - bare affirmations ("yes" / "ok" / "do it" / "go ahead")
#   - affirmation + restatement ("yeah lets go for it", "yes please do")
#   - committal directives ("lets do this", "lets fix both")
#   - numeric / rec picks, with optional affirmation+commitment prefix
#     ("1", "do 1", "lets do 1", "yeah lets do 1+3", "lets go with option 2",
#      "go with your rec")
# Analyzer (2026-06-01 weekly) showed the prior $-anchored patterns missed any
# reply with a restatement tail or a lets/yeah-lets prefix -- the dominant
# real-world reply shape. Guarded so a question-back ("how can I do 1?") or a
# negation ("nah I am already at 4") never fires. Same weight as execute phrases.
if (-not $executeFired -and $priorEndedWithQuestion) {
    $promptTrimmed = $promptText.Trim()
    $isQuestionBack = $promptTrimmed.EndsWith('?')
    $isNegation = $promptTrimmed -imatch '^\s*(no|nah|nope|dont|don''t|do not|not)\b'
    if (-not $isQuestionBack -and -not $isNegation) {
        $affirmativePatterns = @(
            '^\s*(yes|yep|yeah|ya|sure|ok|okay|k|go|go ahead|do it|please do|sounds good|sgtm)\W*$',
            '^\s*(yes|yep|yeah|ya|sure|ok|okay|fine|alright|perfect|great)\s+\S',
            '^\s*(lets|let''s)\s',
            '^\s*(yes|yep|yeah|sure|ok|okay)?\s*(lets|let''s)?\s*(?:(?:do|go with|going with|option|opt|pick|choice|try|number|no\.?)\s*)*#?\s*[1-9](\s*\+\s*[1-9])?\W*$',
            '^\s*(go with |use |pick )?(your |the )?(rec|recommendation|recommended|suggestion|suggested)\W*$'
        )
        foreach ($pat in $affirmativePatterns) {
            if ($promptText -imatch $pat) {
                $score += 3
                $executeFired = $true
                $strongFired = $true
                $affirmativeFired = $true
                break
            }
        }
    }
}

# priorTail weighting: a committal pick scores a clean +3 -> think, one point
# under the think-hard boundary. But when the prior turn was a ranked list or
# multi-option planning turn, the pick commits to large work -- the 2026-06-08
# weekly pass showed these committal picks ("lets do 1", "lets go with v3 slice
# 3b", "yeah lets do the cleanup") routinely drove 30k-215k-token runs while
# sitting at think/3. +1 here pushes them over the boundary, but only when
# priorTail shows real scope (2+ ranked markers or an option/slice/approach
# word), so bare "yes"/"ok" answering a small question stays at think. priorTail
# was captured + logged but unused in scoring until now.
if ($affirmativeFired -and $priorTail) {
    $rankedMarkers = ([regex]::Matches($priorTail, '(?:^|\s)#?[1-9][.):]')).Count
    $hasOptionWord = $priorTail -imatch '\b(option|options|slice|approach|alternative)\b'
    if ($rankedMarkers -ge 2 -or $hasOptionWord) { $score += 1 }
}

# Scoping starter: signals that the prompt is opening a multi-thread
# planning/scoping turn. Analyzer (2026-05-25 weekly) showed ~20 of 36
# under-served flags start with one of these phrases and produced 5-25k output
# despite scoring 1-3. +2 nudges substantive ones over the think-hard boundary
# while leaving truly short chatter at think. The 2026-06-01 pass showed a
# leading preamble was defeating the old strict ^\s* anchor ("ok lets...",
# "then lets...", "did we keep the logs? we should..."), so an optional short
# filler word and an optional brief opening clause are allowed ahead of the
# starter. Skipped entirely when the affirmative path already fired, so a
# committal "lets do 1" reply scores a clean +3 (think) instead of stacking to
# think hard on a possibly-trivial directive.
if (-not $executeFired) {
    $preClause = '(?:[^?.!]{0,60}[?.!]\s+)?'
    $pre = '(?:(?:ok|okay|so|then|well|now|also|and|but|right|alright|hmm|hey)\b[\s,]+){0,2}'
    $scopingStarters = @(
        "^\s*$preClause$pre(lets|let's)\s",
        "^\s*$preClause$pre(we should|should we)\s",
        "^\s*$preClause$pre(can we|could we)\s",
        "^\s*$preClause$pre(we want|we need to|we either)\b",
        "^\s*$preClause$pre(imagine)\s",
        "^\s*$preClause$pre(another feature)\b",
        '^\s*before .{0,40}(we|i) need\b'
    )
    foreach ($pat in $scopingStarters) {
        if ($promptText -imatch $pat) { $score += 2; break }
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

# Length signal -- long prompts usually carry more context/intent. Trigger
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

# Multi-work floor: a work verb plus a sequencing or plural marker ("fix X
# first, then Y", "lets fix both", "lets do 1 and then 2", "sort out all of
# them") queues several pieces of work in one short prompt. The 2026-09-26
# replay (60 days, timestamp-joined) found 47 such prompts scoring -2..3 with
# median output 20-29k, against 4.9k/7.2k for none/think overall. The short
# prompt is what hides the scale, so this floors at think hard rather than
# adding points. Question-backs ("do you need all 12?") are excluded. Counted
# items only count when they are work items ("the 2 bugs", not "the 3 typos").
$multiWorkVerbs = 'fix|add|design|implement|build|update|sort out|do|handle|tackle|address|clean up|refactor|wire|finish'
$multiWorkVerb = "\b($multiWorkVerbs)\b"
$multiWorkMarker = '(\bboth\b|\ball (of )?(them|these|those|\d+)\b' +
    '|\bthe (\d+|two|three|four|other) (bugs|issues|threads|findings|tasks|fixes|problems|items)\b' +
    '|\bfirst\b.{0,40}\bthen\b|\band then\b|,\s*then\b' +
    "|\bthen ($multiWorkVerbs|the)\b)"
$rawScore = $score
$multiWorkFired = $false
if (-not $promptText.Trim().EndsWith('?') -and $promptText -imatch $multiWorkVerb -and $promptText -imatch $multiWorkMarker) {
    $multiWorkFired = $true
    if ($score -lt 4) { $score = 4 }
}

$tier = 'none'
if     ($score -ge 7) { $tier = 'ultrathink' }
elseif ($score -ge 4) { $tier = 'think hard' }
elseif ($score -ge 1) { $tier = 'think' }

# Mechanical-skill override (override-DOWN only). Lifecycle/session skills
# (start/stop/restart/status of local services, end-session, restart-claude)
# have intrinsically low effort regardless of phrasing -- the 2026-06-15 harvest
# (scripts/harvest-skill-effort.ps1) showed end-session at median 264 output
# over 113 calls and every comfyui/ollama/glados lifecycle skill <2k median,
# yet several were routing to think/think-hard off the "lets" scoping bonus.
# The table lives in skill-effort.psd1 (deploy it alongside this hook). Fires
# only when the directive dominates (matched phrase within the first 60 chars)
# and the prompt carries no competing work signal -- no strong/subagent/medium
# keyword, no numeric pick, not a question-back or negation -- so a bundled
# "lets do 2 and then end session" or "stop glados then refactor auth" keeps
# its real-work score. Tagged in the log (mechanical=<skill>) so the weekly
# pass can audit the none-routed overrides the output heuristic can't see.
$mechanicalSkill = $null
$promptTrim = $promptText.Trim()
$pickPresent = $promptText -imatch '\b(do|option|opt|number|no\.?|slice|step|pick|choice)\s*#?\s*[1-9]\b'
$overrideGateClear = (-not $strongKeywordFired) -and (-not $suggestSubagent) -and (-not $mediumFired) `
    -and (-not $pickPresent) -and (-not $multiWorkFired) -and (-not $promptTrim.EndsWith('?')) `
    -and ($promptTrim -inotmatch '^\s*(no|nah|nope|dont|don''t|do not|not)\b')
if ($overrideGateClear) {
    $skillTablePath = Join-Path $PSScriptRoot 'skill-effort.psd1'
    if (Test-Path -LiteralPath $skillTablePath) {
        try {
            $skillTable = Import-PowerShellDataFile -LiteralPath $skillTablePath
            $tierRank = @{ 'none' = 0; 'think' = 1; 'think hard' = 2; 'ultrathink' = 3 }
            foreach ($name in $skillTable.Keys) {
                $entry = $skillTable[$name]
                foreach ($phrase in $entry.phrases) {
                    $idx = $lower.IndexOf([string]$phrase)
                    if ($idx -ge 0 -and $idx -le 60) {
                        if ($tierRank[$entry.tier] -lt $tierRank[$tier]) {
                            $tier = $entry.tier
                            $mechanicalSkill = $name
                        }
                        break
                    }
                }
                if ($mechanicalSkill) { break }
            }
        } catch { }
    }
}

# Gated intent classification: only at think hard / ultrathink. Cheap path
# (none/think) stays token-free. Priority order is most-specific first, so a
# "refactor and explain..." prompt is tagged refactor, not explain. Each box
# is per-tier eligible -- add new boxes here when the routing log shows misses.
$intent = $null

if ($tier -eq 'think hard' -or $tier -eq 'ultrathink') {
    # 1. execute -- explicit user signal to follow through on a discussed plan
    if ($executeFired) { $intent = 'execute' }

    # 2. audit -- research-heavy work, both tiers
    if (-not $intent -and $suggestSubagent) { $intent = 'audit' }

    # 3. refactor -- both tiers
    if (-not $intent) {
        foreach ($kw in @('refactor', 'restructure', 'extract ', 'split into')) {
            if ($lower.Contains($kw)) { $intent = 'refactor'; break }
        }
    }

    # 3. architecture -- ultrathink only (broad redesign work)
    if (-not $intent -and $tier -eq 'ultrathink') {
        foreach ($kw in @('architecture', 'redesign', 'design ', 'strategy')) {
            if ($lower.Contains($kw)) { $intent = 'architecture'; break }
        }
    }

    # 4. debug -- both tiers
    if (-not $intent) {
        foreach ($kw in @('why does', 'why is', 'root cause', 'fails', 'failing', 'broken', 'debug ')) {
            if ($lower.Contains($kw)) { $intent = 'debug'; break }
        }
    }

    # 5. implement -- both tiers
    if (-not $intent) {
        foreach ($kw in @('implement', 'build ', 'create ', 'add ', 'write ', 'generate')) {
            if ($lower.Contains($kw)) { $intent = 'implement'; break }
        }
    }

    # 6. explain -- both tiers (most generic, last)
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
    'audit'        = '[audit] Read full files, not snippets. Group findings by severity with file:line citations. Don''t stop at obvious matches. If the work is separable, prefer spawning a Task subagent (told explicitly to reason thoroughly) over handling everything in this turn.'
    'refactor'     = '[refactor] Preserve observable behavior. Show the full refactored code (or a complete diff) so it can be applied directly -- don''t just describe the splits. Note trade-offs per change. Avoid introducing abstractions beyond what was asked.'
    'architecture' = '[architecture] Sketch alternatives before committing to one. Name trade-offs explicitly.'
}

# Only 'ultrathink' is a Claude Code keyword, and only when the user types it:
# hook output is plain context text, so each tier emits an explicit steering
# line instead of a bare keyword (verified 2026-09-26, Claude Code 2.1.281).
# Effort, not text, sets depth; the line nudges within the session's effort.
# 'think' deliberately emits nothing until the v2 data shows it is worth it.
function Get-DepthLine {
    param([string]$Tier, [string]$SessionEffort, [hashtable]$Lines)
    if (@('high', 'xhigh', 'max', 'ultracode') -contains $SessionEffort) { return $null }
    return $Lines[$Tier]
}

$emitVersion = 2
$depthLines = @{
    'think hard' = '[auto-router: high depth] Think this through before acting: consider alternatives, trade-offs and edge cases. If you change code or files, verify the result (test, script or re-read) before calling it done. Keep the reply concise.'
    'ultrathink' = '[auto-router: maximum depth] This turn warrants careful, thorough reasoning before acting: compare approaches before committing, and consider failure modes. If you change code or files, verify before calling it done. Put the depth into reasoning, not reply length; if it proves simpler than it looked, proceed directly.'
}
# UserPromptSubmit hooks get neither the payload's effort object nor
# CLAUDE_EFFORT (both are tool-use-context only), so take the level the
# previous assistant turn ran at from the transcript. The env var stays as a
# fallback in case a future Claude Code version exports it here.
$envEffort = ([string]$env:CLAUDE_EFFORT).Trim()
$sessionEffort = if ($transcriptEffort) { $transcriptEffort } else { $envEffort }
$effortSource = if ($transcriptEffort) { 'transcript' } elseif ($envEffort) { 'env' } else { '' }
$depthLine = Get-DepthLine -Tier $tier -SessionEffort $sessionEffort -Lines $depthLines
$emitted = [bool]$depthLine

if ($tier -ne 'none') {
    Write-Output "[auto-router] score $score -> tier=$tier"
    if ($depthLine) {
        Write-Output ""
        Write-Output $depthLine
    }
    if ($intent) {
        Write-Output ""
        Write-Output $intentHints[$intent]
        $emitted = $true
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
        mechanical             = $mechanicalSkill
        multiWork              = $multiWorkFired
        rawScore               = $rawScore
        emitVersion            = $emitVersion
        emitted                = $emitted
        sessionEffort          = $sessionEffort
        effortSource           = $effortSource
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
