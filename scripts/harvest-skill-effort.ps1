<#
.SYNOPSIS
  Mine session transcripts to learn which user-prompt phrases precede which
  skill / MCP-tool invocations, and what effort (output tokens) those turns
  actually cost. Read-only evidence-gathering for the phrase -> effort table.

.DESCRIPTION
  For each user prompt, collects the Skill names and mcp__* tool names invoked
  in the assistant turn(s) that follow (until the next user prompt), plus the
  summed output tokens. Then aggregates per invoked skill/tool: hit count, the
  output-token distribution (avg / median / p90), and sample triggering
  prompts. Core tools (Read/Bash/Edit/Write/Grep/Glob) are ignored -- the
  router does not key on those.

.PARAMETER Days
  Only consider turns whose user prompt is within the last N days. Default 30
  (wider than the weekly window: phrase->effort wants more evidence).
#>
param(
  [string]$ProjectsDir = (Join-Path $env:USERPROFILE '.claude\projects'),
  [int]   $Days        = 30
)
$ErrorActionPreference = 'Stop'
$cutoff = (Get-Date).ToUniversalTime().AddDays(-$Days)

$coreTools = @('Read','Bash','Edit','Write','Grep','Glob','TodoWrite','NotebookEdit','PowerShell')

function Get-PromptText {
  param($msg)
  $content = $msg.content
  if ($content -is [string]) { return $content }
  ($content | Where-Object { $_.type -eq 'text' } | ForEach-Object { $_.text }) -join ' '
}

$records = New-Object System.Collections.Generic.List[object]

Get-ChildItem -Path $ProjectsDir -Recurse -Filter '*.jsonl' -ErrorAction SilentlyContinue | ForEach-Object {
  $curPrompt = $null; $curTs = $null; $curInvoked = $null; $curOut = 0; $haveTurn = $false

  function Flush {
    if ($script:haveTurn -and $script:curPrompt -and $script:curInvoked.Count -gt 0 -and $script:curTs -ge $cutoff) {
      foreach ($inv in $script:curInvoked) {
        $records.Add([pscustomobject]@{ invoked=$inv; out=$script:curOut; prompt=$script:curPrompt })
      }
    }
  }

  foreach ($line in Get-Content $_.FullName) {
    if (-not $line.Trim()) { continue }
    try { $d = $line | ConvertFrom-Json } catch { continue }

    if ($d.type -eq 'user' -and $d.message) {
      $text = Get-PromptText $d.message
      # A user turn closes the previous assistant turn. Tool_result user rows
      # have array content and no text -- skip those, they aren't new prompts.
      if ($text) {
        Flush
        $script:curPrompt = ($text.Substring(0,[Math]::Min(100,$text.Length))) -replace "[`r`n]+", ' '
        $script:curTs = try { [datetimeoffset]::Parse($d.timestamp).UtcDateTime } catch { Get-Date }
        $script:curInvoked = New-Object System.Collections.Generic.HashSet[string]
        $script:curOut = 0; $script:haveTurn = $true
      }
    }
    elseif ($d.type -eq 'assistant' -and $d.message -and $script:haveTurn) {
      if ($d.message.usage) { $script:curOut += [int]$d.message.usage.output_tokens }
      foreach ($c in $d.message.content) {
        if ($c.type -ne 'tool_use') { continue }
        if ($c.name -eq 'Skill' -and $c.input.skill) { [void]$script:curInvoked.Add('skill:' + $c.input.skill) }
        elseif ($c.name -like 'mcp__*')               { [void]$script:curInvoked.Add($c.name) }
        elseif ($coreTools -notcontains $c.name)      { [void]$script:curInvoked.Add('builtin:' + $c.name) }
      }
    }
  }
  Flush
}

function Pct { param($vals,$p) $s=@($vals|Sort-Object); if($s.Count -eq 0){return 0}; $s[[Math]::Min($s.Count-1,[int][Math]::Floor($p*($s.Count-1)))] }

Write-Host ("Harvested {0} (prompt -> invocation) records over the last {1} days.`n" -f $records.Count, $Days) -ForegroundColor Cyan

$records | Group-Object invoked | Sort-Object Count -Descending | ForEach-Object {
  $outs = @($_.Group.out)
  [pscustomobject]@{
    invoked = $_.Name
    hits    = $_.Count
    avgOut  = [int](($outs | Measure-Object -Average).Average)
    medOut  = [int](Pct $outs 0.5)
    p90Out  = [int](Pct $outs 0.9)
  }
} | Format-Table -AutoSize | Out-String | Write-Host

Write-Host '=== Sample triggering prompts per invocation (lightest by avg first) ===' -ForegroundColor Cyan
$records | Group-Object invoked |
  Sort-Object @{Expression={ ($_.Group.out | Measure-Object -Average).Average }} |
  ForEach-Object {
    $avg = [int](($_.Group.out | Measure-Object -Average).Average)
    Write-Host ("`n[{0}]  hits={1}  avgOut={2}" -f $_.Name, $_.Count, $avg) -ForegroundColor Yellow
    $_.Group | Select-Object -ExpandProperty prompt -Unique | Select-Object -First 6 | ForEach-Object { Write-Host ("   - " + $_) }
  }
