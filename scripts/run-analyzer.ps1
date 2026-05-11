<#
.SYNOPSIS
  Wrapper that runs analyze-routing.ps1 and writes the output to a dated log
  file under %USERPROFILE%\.claude\hooks\. Designed to be invoked from a
  Windows scheduled task; output redirection lives here so the task action
  stays a simple File invocation.
#>

$ErrorActionPreference = 'Stop'

$logDir = Join-Path $env:USERPROFILE '.claude\hooks'
New-Item -ItemType Directory -Force -Path $logDir | Out-Null

$logFile = Join-Path $logDir ("routing-analysis-{0}.log" -f (Get-Date -Format 'yyyy-MM-dd'))

& "$PSScriptRoot\analyze-routing.ps1" -Days 7 *>&1 | Out-File -FilePath $logFile -Encoding utf8
