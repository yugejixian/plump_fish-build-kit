<#
.SYNOPSIS
  Restore every host dependency the DSH profile needs, out of DSH's app.asar.

.DESCRIPTION
  The profile's @deepseek-ai/* packages - the plugin peer graph, cordis,
  dsh-base, dsh-web-app - only ship inside app.asar. pnpm prune deletes them and
  the plugins then fail silently. Their ORDINARY npm dependencies (koffi for
  @deepseek-ai/dsh-win32-process, node-pty, sharp, @swc/helpers, ...) are just as
  important and were the reason a freshly restarted DSH lost every shell tool:

      Cannot find module 'koffi'

  This script restores both groups. It is additive only: existing files are
  never overwritten or deleted, so it is safe to run any time, including while
  DSH is running. Nothing is written outside <profile>\node_modules.

.PARAMETER Asar
  Path to app.asar. Auto-detected when omitted.

.PARAMETER NodeModules
  Target node_modules. Defaults to the desktop profile.

.PARAMETER DryRun
  Report what would be restored without writing anything.

.EXAMPLE
  .\restore-peers.ps1

.EXAMPLE
  .\restore-peers.ps1 -DryRun
#>
[CmdletBinding()]
param(
  [string]$Asar = '',
  [string]$NodeModules = '',
  [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($Asar)) {
  foreach ($c in @('D:\DeepseekHarness\resources\app.asar',
                   "$env:LOCALAPPDATA\Programs\DeepSeek Harness\resources\app.asar",
                   "$env:PROGRAMFILES\DeepSeek Harness\resources\app.asar")) {
    if (Test-Path $c) { $Asar = $c; break }
  }
}
if (-not $Asar -or -not (Test-Path $Asar)) { throw 'app.asar not found; pass -Asar <path>' }

if ([string]::IsNullOrWhiteSpace($NodeModules)) {
  $NodeModules = Join-Path $env:USERPROFILE '.dsh\profiles\desktop\node_modules'
}
if (-not (Test-Path $NodeModules)) { throw "node_modules not found: $NodeModules" }

$nc = @(Get-ChildItem (Join-Path $env:USERPROFILE '.dsh\dsh-runtimes') -Directory -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending |
        ForEach-Object { Join-Path $_.FullName 'dependencies\node\bin\node.exe' } |
        Where-Object { Test-Path $_ })
if ($nc.Count) {
  $nodeExe = $nc[0]
} else {
  $fallback = Get-Command node -ErrorAction SilentlyContinue
  if (-not $fallback) {
    throw 'no node.exe found: DSH''s bundled runtime is missing (~\.dsh\dsh-runtimes\*\dependencies\node\bin\node.exe) and node is not on PATH. Start DSH once so it unpacks its runtime, or pass a node.exe on PATH.'
  }
  $nodeExe = $fallback.Source
}

# The tool sits next to this script, under payload\tools\ in the delivered
# package, or in the install directory for an installed copy.
$tool = ''
foreach ($c in @((Join-Path $PSScriptRoot 'extract-peers.cjs'),
                 (Join-Path $PSScriptRoot 'payload\tools\extract-peers.cjs'),
                 (Join-Path $PSScriptRoot 'tools\extract-peers.cjs'))) {
  if (Test-Path $c) { $tool = $c; break }
}
if (-not $tool) { throw 'extract-peers.cjs not found next to this script (looked in ., payload\tools\, tools\)' }

Write-Host "asar        : $Asar"
Write-Host "node        : $nodeExe"
Write-Host "node_modules: $NodeModules"
Write-Host "tool        : $tool"
Write-Host ''

$extra = @()
if ($DryRun) { $extra = @('--dry-run') }
& $nodeExe $tool $Asar $NodeModules @extra
$code = $LASTEXITCODE
Write-Host ''
if ($code -ne 0) {
  Write-Host 'FAILED: at least one host dependency still cannot be loaded. Nothing was deleted; re-run after fixing the cause.' -ForegroundColor Red
} else {
  Write-Host 'OK: the profile host dependency graph loads.' -ForegroundColor Green
}
exit $code
