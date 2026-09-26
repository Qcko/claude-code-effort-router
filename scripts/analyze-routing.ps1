<#
.SYNOPSIS
  Analyze routing-log.jsonl against session transcripts to flag likely mis-routings.

.DESCRIPTION
  Heuristics only -- no LLM calls. Joins each routing decision with the
  assistant response that followed (from Claude Code's session jsonl files)
  and flags entries where the assigned budget probably didn't match the work:

    tier=think       and output >= 5000  -> under-served (model wanted to reason more)
    tier=think hard  and output >= 15000 -> probably under-served
    tier=ultrathink  and output <= 500   -> over-served (budget wasted)

  Surfaces candidates for keyword/box tuning. Does not modify the hook.

.PARAMETER RoutingLog
  Path to routing-log.jsonl. Default: %USERPROFILE%\.claude\hooks\routing-log.jsonl.

.PARAMETER ProjectsDir
  Claude Code projects dir. Default: %USERPROFILE%\.claude\projects.

.PARAMETER Days
  Only consider routing entries from the last N days. Default 7.

.EXAMPLE
  .\scripts\analyze-routing.ps1
  .\scripts\analyze-routing.ps1 -Days 30
#>
param(
  [string]$RoutingLog  = (Join-Path $env:USERPROFILE '.claude\hooks\routing-log.jsonl'),
  [string]$ProjectsDir = (Join-Path $env:USERPROFILE '.claude\projects'),
  [int]   $Days        = 7
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $RoutingLog)) {
  Write-Host "No routing log at $RoutingLog. Run a few prompts first." -ForegroundColor Yellow
  return
}

$cutoff = (Get-Date).ToUniversalTime().AddDays(-$Days)

function Read-Decisions {
  param([string]$Path, [datetime]$Cutoff)
  foreach ($line in Get-Content $Path) {
    if (-not $line.Trim()) { continue }
    try {
      $d = $line | ConvertFrom-Json
      $ts = [datetimeoffset]::Parse($d.ts).UtcDateTime
      if ($ts -lt $Cutoff) { continue }
      $d | Add-Member -Force -NotePropertyName _ts -NotePropertyValue $ts -PassThru
    } catch { }
  }
}

# One turn per user prompt, stamped with the prompt's own timestamp. Repeated
# prompts ("lets do 1") are separate turns, not one merged bucket.
function Get-AssistantTurns {
  param([string]$Path)
  $turns = New-Object System.Collections.ArrayList
  $current = $null
  foreach ($line in [IO.File]::ReadLines($Path)) {
    if ($line -notmatch '"type":"(user|assistant)"') { continue }
    if ($line.Contains('"tool_result"') -and -not $line.Contains('"type":"text"')) { continue }
    try { $d = $line | ConvertFrom-Json } catch { continue }
    if ($d.isSidechain) { continue }
    if ($d.type -eq 'user' -and $d.message) {
      $text = Get-TypedPromptText -Entry $d
      if (-not $text) { continue }
      $ts = [datetimeoffset]::MinValue
      if (-not [datetimeoffset]::TryParse([string]$d.timestamp, [ref]$ts)) { continue }
      $current = [pscustomobject]@{
        preview       = ($text.Substring(0, [Math]::Min(80, $text.Length))) -replace "[`r`n]+", ' '
        ts            = $ts.UtcDateTime
        output_tokens = 0
      }
      [void]$turns.Add($current)
    }
    elseif ($d.type -eq 'assistant' -and $d.message -and $d.message.usage -and $current) {
      $current.output_tokens += [int]$d.message.usage.output_tokens
    }
  }
  return $turns
}

# Mirrors hooks/route-hint.ps1: the same reminder strip and the same skip
# prefixes, so the transcript-side preview is cut from the text the hook
# scored. Harness-generated user entries return $null and do not open a turn.
function Get-TypedPromptText {
  param($Entry)
  if ($Entry.isMeta -or $Entry.isCompactSummary) { return $null }
  $content = $Entry.message.content
  $text = if ($content -is [string]) { $content }
          else { ($content | Where-Object { $_.type -eq 'text' } | ForEach-Object { $_.text }) -join ' ' }
  if (-not $text) { return $null }
  $text = $text -replace '^(\s*<system-reminder>[\s\S]*?</system-reminder>)+\s*', ''
  if ([string]::IsNullOrWhiteSpace($text)) { return $null }
  $head = $text.TrimStart()
  foreach ($prefix in @('<task-notification>', '<agent-message ', '<local-command-', '<command-name>', 'Caveat:')) {
    if ($head.StartsWith($prefix)) { return $null }
  }
  return $text
}

function Build-PreviewIndex {
  param([string]$ProjectsDir, [datetime]$Cutoff)
  $index = @{}
  if (-not (Test-Path $ProjectsDir)) { return $index }
  Get-ChildItem -Path $ProjectsDir -Recurse -Filter '*.jsonl' -ErrorAction SilentlyContinue |
    Where-Object { $_.LastWriteTimeUtc -ge $Cutoff } | ForEach-Object {
      foreach ($t in (Get-AssistantTurns -Path $_.FullName)) {
        if (-not $index.ContainsKey($t.preview)) { $index[$t.preview] = New-Object System.Collections.ArrayList }
        [void]$index[$t.preview].Add($t)
      }
    }
  return $index
}

# The hook logs just before the prompt lands in the transcript, so the matching
# turn is the same-preview turn closest in time; beyond the window it is some
# other occurrence of the same words, not this one.
function Find-Turn {
  param($Index, [string]$Preview, [datetime]$Ts, [int]$WindowSeconds = 120)
  $best = $null
  $bestGap = [double]::MaxValue
  foreach ($t in @($Index[$Preview])) {
    if (-not $t) { continue }
    $gap = [Math]::Abs(($t.ts - $Ts).TotalSeconds)
    if ($gap -lt $bestGap) { $best = $t; $bestGap = $gap }
  }
  if ($bestGap -gt $WindowSeconds) { return $null }
  [void]$Index[$Preview].Remove($best)
  return $best
}

function Flag-Row {
  param([string]$Tier, [int]$Output)
  if     ($Tier -eq 'think'      -and $Output -ge 5000)  { 'under-served' }
  elseif ($Tier -eq 'think hard' -and $Output -ge 15000) { 'under-served' }
  elseif ($Tier -eq 'ultrathink' -and $Output -le 500)   { 'over-served' }
  else { $null }
}

$decisions  = @(Read-Decisions -Path $RoutingLog -Cutoff $cutoff)
if ($decisions.Count -eq 0) {
  Write-Host "No routing entries in the last $Days days." -ForegroundColor Yellow
  return
}

$turnIndex = Build-PreviewIndex -ProjectsDir $ProjectsDir -Cutoff $cutoff

$rows = foreach ($d in $decisions) {
  $turn = Find-Turn -Index $turnIndex -Preview $d.preview -Ts $d._ts
  $output = if ($turn) { $turn.output_tokens } else { $null }
  $flag = if ($output -ne $null) { Flag-Row -Tier $d.tier -Output $output } else { $null }
  [pscustomobject]@{
    ts            = $d.ts
    tier          = $d.tier
    intent        = $d.intent
    score         = $d.score
    output_tokens = $output
    flag          = $flag
    preview       = $d.preview
  }
}

$total   = $rows.Count
$matched = ($rows | Where-Object { $_.output_tokens -ne $null }).Count
$flagged = @($rows | Where-Object flag)

Write-Host ''
Write-Host "Analyzed $total routing entries from the last $Days days; matched $matched to session transcripts." -ForegroundColor Cyan
Write-Host ("Flagged {0} possible mis-routings." -f $flagged.Count) -ForegroundColor Yellow
Write-Host ''

if ($flagged.Count -gt 0) {
  Write-Host '=== Flagged entries (deduped by preview) ===' -ForegroundColor Cyan
  # Collapse repeats of the same prompt to one row with a hit count. The
  # routing-log still records every individual decision; this is presentation
  # only, so the same prompt sent N times doesn't drown out distinct issues.
  $flagged |
    Group-Object preview |
    ForEach-Object {
      $first = $_.Group | Sort-Object ts | Select-Object -First 1
      [pscustomobject]@{
        hits          = $_.Count
        last_ts       = ($_.Group | Sort-Object ts -Descending | Select-Object -First 1).ts
        tier          = $first.tier
        intent        = $first.intent
        score         = $first.score
        output_tokens = $first.output_tokens
        flag          = $first.flag
        preview       = $first.preview
      }
    } |
    Sort-Object @{Expression='flag';Descending=$false}, @{Expression='output_tokens';Descending=$true} |
    Format-Table hits, last_ts, tier, intent, score, output_tokens, flag, preview -AutoSize -Wrap |
    Out-String | Write-Host
}

Write-Host '=== Counts by tier ===' -ForegroundColor Cyan
$rows | Group-Object tier | Select-Object Name, Count | Sort-Object Name | Format-Table -AutoSize | Out-String | Write-Host

Write-Host '=== Counts by intent ===' -ForegroundColor Cyan
$rows | Where-Object intent | Group-Object intent | Select-Object Name, Count | Sort-Object Name | Format-Table -AutoSize | Out-String | Write-Host

Write-Host '=== Average output tokens by tier ===' -ForegroundColor Cyan
$rows | Where-Object { $_.output_tokens -ne $null } |
  Group-Object tier |
  ForEach-Object {
    [pscustomobject]@{
      Tier  = $_.Name
      Count = $_.Count
      AvgOutput = [int](($_.Group | Measure-Object output_tokens -Average).Average)
      MaxOutput = ($_.Group | Measure-Object output_tokens -Maximum).Maximum
    }
  } | Sort-Object Tier | Format-Table -AutoSize | Out-String | Write-Host
