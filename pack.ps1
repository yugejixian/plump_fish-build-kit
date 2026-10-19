<#
.SYNOPSIS
  Rebuild manifest.json for the turnkey package from the payload on disk.

.DESCRIPTION
  The first version of this script assembled a package from outside sources
  (D:\llama_cpp, D:\models). Those directories are gone, so it could not run at
  all - and it could never have reproduced the current layout anyway: it ignored
  payload\profile-snapshot, payload\tools, user-settings, licenses and src.

  This version inverts the direction: payload\ is the source of truth, and the
  script re-hashes it and rewrites manifest.json. Everything that made the
  manifest trustworthy is carried over verbatim:

    upstream        official llama.cpp release assets and digests
    modelUpstream   ModelScope sha256 per weight file
    verification    binary / model / plugin verification flags
    pluginUpstream  npm dist.integrity record for the 4 plugins

  kind/provenance are derived from the top-level payload directory, so a rebuild
  reproduces the same classification the package shipped with:

    llama_cpp -> runtime    models -> model      plugins -> plugin
    gateway   -> gateway    profile-snapshot -> snapshot    tools -> tool

  payload\tools used to be "extra files" in every verify.ps1 run; classifying it
  as a first-class kind makes the peer restorer part of the integrity check.

  Dry run by default: nothing is written without -Apply.

.PARAMETER PackageDir
  Package root holding payload\ and manifest.json.

.PARAMETER OutDir
  Clone the whole package here first, then rebuild its manifest. Target must be
  absent or empty.

.PARAMETER Only
  Re-hash only these payload subpaths and merge into the existing manifest. Much
  faster when a few gateway files changed. Example: -Only gateway

.PARAMETER Apply
  Write manifest.json. A timestamped backup is taken first.

.PARAMETER RefreshUpstream
  Re-query GitHub Releases and ModelScope for the recorded targets. Needs
  network; failures are reported, never fatal.

.PARAMETER RunVerify
  Run verify.ps1 on the result afterwards.

.EXAMPLE
  .\pack.ps1                                   # report only
  .\pack.ps1 -Apply -Only gateway              # I edited gateway files
  .\pack.ps1 -Apply -RunVerify                 # full rebuild plus verification
  .\pack.ps1 -OutDir D:\pkg-v2 -Apply          # clone and rebuild there
#>
[CmdletBinding()]
param(
  [string]$PackageDir = 'D:\新手向大肥鱼build整合',
  [string]$OutDir = '',
  [string[]]$Only = @(),
  [switch]$Apply,
  [switch]$RefreshUpstream,
  [switch]$RunVerify,
  [switch]$NoBackup
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Say($msg, $color = 'Gray') { Write-Host $msg -ForegroundColor $color }
function Fail($msg) { Write-Host $msg -ForegroundColor Red; exit 2 }
function Get-Prop($obj, [string]$name, $default = $null) {
  if ($null -eq $obj) { return $default }
  $p = $obj.PSObject.Properties[$name]
  if ($null -eq $p) { return $default }
  if ($null -eq $p.Value) { return $default }
  return $p.Value
}

# Streaming SHA256 with a 4 MB buffer: Get-FileHash's 4 KB buffer is needlessly
# slow over 6 GB, and Node's readFileSync cannot touch >2 GB at all.
function Get-Sha256([string]$path) {
  $sha = [System.Security.Cryptography.SHA256]::Create()
  $fs = $null
  try {
    $fs = [System.IO.File]::Open($path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
    $buf = New-Object byte[] (4 * 1024 * 1024)
    while ($true) {
      $n = $fs.Read($buf, 0, $buf.Length)
      if ($n -le 0) { break }
      $null = $sha.TransformBlock($buf, 0, $n, $null, 0)
    }
    $null = $sha.TransformFinalBlock($buf, 0, 0)
    $sb = New-Object System.Text.StringBuilder 64
    foreach ($b in $sha.Hash) { $null = $sb.Append($b.ToString('x2')) }
    return $sb.ToString()
  } finally {
    if ($null -ne $fs) { $fs.Dispose() }
    $sha.Dispose()
  }
}

$KindMap = @{
  'llama_cpp'        = @{ kind = 'runtime';  provenance = 'prebuilt llama.cpp release (record version via llama-server.exe --version)' }
  'llama_cpp_cpu'    = @{ kind = 'runtime';  provenance = 'prebuilt llama.cpp release (record version via llama-server.exe --version)' }
  'llama_cpp_vulkan' = @{ kind = 'runtime';  provenance = 'prebuilt llama.cpp release (record version via llama-server.exe --version)' }
  'models'           = @{ kind = 'model';    provenance = 'GGUF from ModelScope (see PROVENANCE.txt next to the weights)' }
  'plugins'          = @{ kind = 'plugin';   provenance = 'restored' }
  'gateway'          = @{ kind = 'gateway';  provenance = 'restored' }
  'profile-snapshot' = @{ kind = 'snapshot'; provenance = 'restored' }
  'tools'            = @{ kind = 'tool';     provenance = 'restored' }
}

# ---------------------------------------------------------------- 0. locate
$PackageDir = [System.IO.Path]::GetFullPath($PackageDir)
if (-not (Test-Path $PackageDir)) { Fail "package dir not found: $PackageDir" }

if (-not [string]::IsNullOrWhiteSpace($OutDir)) {
  $OutDir = [System.IO.Path]::GetFullPath($OutDir)
  if ($OutDir.TrimEnd('\') -eq $PackageDir.TrimEnd('\')) { Fail 'OutDir is the same as PackageDir' }
  if ((Test-Path $OutDir) -and (Get-ChildItem $OutDir -Force -ErrorAction SilentlyContinue)) { Fail "OutDir is not empty: $OutDir" }
  Say "`n=== clone package -> $OutDir ===" 'Cyan'
  if (-not $Apply) { Say '  (dry run: nothing copied)' 'Cyan' }
  else {
    $swC = [Diagnostics.Stopwatch]::StartNew()
    $null = robocopy $PackageDir $OutDir /E /NFL /NDL /NJH /NJS /NP /R:2 /W:1
    if ($LASTEXITCODE -ge 8) { Fail "robocopy failed ($LASTEXITCODE)" }
    Say ("  copied in {0:N0}s" -f $swC.Elapsed.TotalSeconds) 'Green'
  }
  $PackageDir = $OutDir
}

$payload = Join-Path $PackageDir 'payload'
$manifestPath = Join-Path $PackageDir 'manifest.json'
if (-not (Test-Path $payload)) { Fail "no payload directory under $PackageDir" }

Say "`n=== pack.ps1 : payload -> manifest.json ===" 'Cyan'
Say "  package : $PackageDir"
Say "  payload : $payload"
Say ("  mode    : {0}" -f $(if ($Apply) { 'APPLY (writes manifest.json)' } else { 'dry run (nothing is written)' }))

# ---------------------------------------------------------------- 1. previous manifest
$old = $null
if (Test-Path $manifestPath) {
  $old = Get-Content $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
  Say ("  previous: {0} entries, {1:N2} GB, packed {2}" -f (Get-Prop $old 'fileCount' 0), ((Get-Prop $old 'totalBytes' 0) / 1GB), (Get-Prop $old 'packedAt' '?'))
} else {
  Say '  previous: none (a fresh manifest will be written)' 'Yellow'
}
$oldByPath = @{}
if ($null -ne $old) { foreach ($e in (Get-Prop $old 'files' @())) { $oldByPath[$e.path] = $e } }

# ---------------------------------------------------------------- 2. targets
$filesOnDisk = @(Get-ChildItem $payload -Recurse -File -Force -ErrorAction SilentlyContinue)
Say ("  on disk : {0} files under payload" -f $filesOnDisk.Count)

$selected = @()
$untouched = 0
foreach ($f in $filesOnDisk) {
  $rel = $f.FullName.Substring($payload.Length).TrimStart('\', '/')
  if ($Only.Count -gt 0) {
    $hit = $false
    foreach ($o in $Only) {
      $o2 = $o.TrimEnd('\', '/')
      if ($rel -eq $o2 -or $rel.StartsWith($o2 + '\') -or $rel.StartsWith($o2 + '/')) { $hit = $true; break }
    }
    if (-not $hit) { $untouched++; continue }
  }
  $selected += [pscustomobject]@{ rel = $rel; full = $f.FullName; bytes = $f.Length }
}
if ($Only.Count -gt 0) { Say ("  -Only {0}: {1} selected, {2} left untouched" -f ($Only -join ','), $selected.Count, $untouched) }

# ---------------------------------------------------------------- 3. hash
Say "`n=== hashing ===" 'Cyan'
$entries = New-Object System.Collections.ArrayList
$added = 0; $changed = 0; $same = 0
$sw = [Diagnostics.Stopwatch]::StartNew()
$done = 0
foreach ($s in $selected) {
  $sha = Get-Sha256 $s.full
  $top = ($s.rel -split '[\\/]')[0]
  $k = $KindMap[$top]
  if ($null -eq $k) { $k = @{ kind = $top; provenance = 'restored' } }
  $null = $entries.Add([pscustomobject]@{
      path = $s.rel; kind = $k.kind; bytes = $s.bytes; sha256 = $sha; provenance = $k.provenance
    })
  $prev = $oldByPath[$s.rel]
  if ($null -eq $prev) { $added++ }
  elseif (($prev.sha256 -ne $sha) -or ($prev.bytes -ne $s.bytes)) { $changed++ }
  else { $same++ }
  $done++
  if ($done % 2000 -eq 0) { Say ("  {0}/{1} ..." -f $done, $selected.Count) }
}
Say ("  {0} files in {1:N0}s   new {2} / changed {3} / unchanged {4}" -f $selected.Count, $sw.Elapsed.TotalSeconds, $added, $changed, $same) 'Green'

# ---------------------------------------------------------------- 4. merge
$final = New-Object System.Collections.ArrayList
if (($Only.Count -gt 0) -and ($null -ne $old)) {
  $sel = @{}
  foreach ($s in $selected) { $sel[$s.rel] = $true }
  $keep = 0
  foreach ($e in (Get-Prop $old 'files' @())) { if (-not $sel.ContainsKey($e.path)) { $null = $final.Add($e); $keep++ } }
  foreach ($e in $entries) { $null = $final.Add($e) }
  Say ("  merged: {0} re-hashed + {1} carried over" -f $entries.Count, $keep)
} else {
  foreach ($e in $entries) { $null = $final.Add($e) }
  if ($null -ne $old) {
    $disk = @{}
    foreach ($e in $entries) { $disk[$e.path] = $true }
    $gone = @()
    foreach ($e in (Get-Prop $old 'files' @())) { if (-not $disk.ContainsKey($e.path)) { $gone += $e.path } }
    if ($gone.Count -gt 0) {
      Say ("  {0} manifest entries no longer exist on disk and will be dropped:" -f $gone.Count) 'Yellow'
      foreach ($g in ($gone | Select-Object -First 10)) { Say ("    - " + $g) 'Yellow' }
      if ($gone.Count -gt 10) { Say ("    ... and {0} more" -f ($gone.Count - 10)) 'Yellow' }
    }
  }
}

$totalBytes = ($final | Measure-Object -Property bytes -Sum).Sum
Say "`n=== result ===" 'Cyan'
foreach ($g in ($final | Group-Object kind | Sort-Object Name)) { Say ("  {0,-10} {1,6} files" -f $g.Name, $g.Count) }
Say ("  {0,16} files, {1:N2} GB" -f $final.Count, ($totalBytes / 1GB))

# ---------------------------------------------------------------- 5. document
# Rebuild the envelope, then carry over EVERY other top-level block from the
# previous manifest verbatim (upstream, modelUpstream, verification,
# pluginUpstream, upstreamCpu, upstreamVulkan, ...). Adding a new runtime
# record must never require editing this script again.
$rebuiltKeys = @('format', 'packedAt', 'packedOn', 'fileCount', 'totalBytes', 'files')
$carry = [ordered]@{}
if ($null -ne $old) {
  foreach ($prop in $old.PSObject.Properties) {
    if ($rebuiltKeys -contains $prop.Name) { continue }
    $carry[$prop.Name] = $prop.Value
  }
}
$docOrdered = [ordered]@{
  format     = 1
  packedAt   = (Get-Date -Format o)
  packedOn = 'local'
  fileCount  = $final.Count
  totalBytes = $totalBytes
}
foreach ($k in $carry.Keys) { $docOrdered[$k] = $carry[$k] }
$docOrdered['files'] = $final
$doc = [pscustomobject]$docOrdered
if ($null -ne $old) { Say ("  carried over manifest blocks: {0}" -f $(if ($carry.Count) { ($carry.Keys -join ', ') } else { 'none' })) }

# ---------------------------------------------------------------- 6. optional refresh
if ($RefreshUpstream) {
  Say "`n=== refreshing upstream records (network) ===" 'Cyan'
  $up = (Get-Prop $old 'upstream')
  if ($null -ne $up) {
    $rel = Get-Prop $up 'release'
    $cuda = Get-Prop $up 'cudaMajor' '13'
    if ($rel) {
      try {
        $api = Invoke-RestMethod -Uri "https://api.github.com/repos/ggml-org/llama.cpp/releases/tags/$rel" -Headers @{ 'User-Agent' = 'dsh-turnkey' } -TimeoutSec 30
        $assets = @()
        foreach ($a in $api.assets) {
          $hit = $false
          foreach ($w in @("^llama-$rel-bin-win-cuda-$cuda\.\d+-x64\.zip$", "^cudart-llama-bin-win-cuda-$cuda\.\d+-x64\.zip$")) { if ($a.name -match $w) { $hit = $true } }
          if (-not $hit) { continue }
          $assets += [pscustomobject]@{ name = $a.name; size = $a.size; digest = $a.digest; url = $a.browser_download_url }
          Say ("    {0}  {1}" -f $a.name, $a.digest) 'Green'
        }
        if ($assets.Count -gt 0) { $up.assets = $assets; $doc.upstream = $up; Say '    upstream.assets updated' 'Green' }
        else { Say '    no matching asset in that release, left unchanged' 'Yellow' }
      } catch { Say ("    GitHub query failed: " + $_.Exception.Message) 'Yellow' }
    }
  } else { Say '    no upstream block recorded' 'Yellow' }

  $mu = @(Get-Prop $old 'modelUpstream' @())
  if ($mu.Count -gt 0) {
    $repos = @{}
    foreach ($m in $mu) { if ($m.repo) { $repos[$m.repo] = $true } }
    $fresh = @{}
    foreach ($repo in $repos.Keys) {
      try {
        $resp = Invoke-RestMethod -Uri "https://www.modelscope.cn/api/v1/models/$repo/repo/files?Revision=master" -TimeoutSec 30
        $n = 0
        foreach ($f in $resp.Data.Files) { if ($f.Name -like '*.gguf') { $fresh[$repo + '|' + $f.Name] = $f.Sha256; $n++ } }
        Say ("    {0}: {1} published weights" -f $repo, $n) 'Green'
      } catch { Say ("    ModelScope query failed ($repo): " + $_.Exception.Message) 'Yellow' }
    }
    $updated = 0
    foreach ($m in $mu) {
      $k = $m.repo + '|' + $m.file
      if ($fresh.ContainsKey($k)) { $m.upstreamSha256 = $fresh[$k]; $m.match = ($m.sha256 -eq $fresh[$k]); $updated++ }
    }
    $doc.modelUpstream = $mu
    Say ("    modelUpstream re-checked: {0}/{1}" -f $updated, $mu.Count) 'Green'
    if (($updated -eq $mu.Count) -and (@($mu | Where-Object { -not $_.match }).Count -eq 0)) {
      $ver = Get-Prop $old 'verification'
      if ($null -ne $ver) { $ver.modelVerified = $true; $doc.verification = $ver }
    }
  }
}

# ---------------------------------------------------------------- 7. write
Say "`n=== writing ===" 'Cyan'
if (-not $Apply) { Say '  dry run: manifest.json was NOT written. Re-run with -Apply.' 'Cyan'; exit 0 }

if ((Test-Path $manifestPath) -and (-not $NoBackup)) {
  $bak = "$manifestPath.bak-" + (Get-Date -Format 'yyyyMMdd-HHmmss')
  Copy-Item -LiteralPath $manifestPath -Destination $bak -Force
  Say ("  backup : $bak")
}
$json = $doc | ConvertTo-Json -Depth 6
[System.IO.File]::WriteAllText($manifestPath, $json, (New-Object System.Text.UTF8Encoding($false)))
Say ("  wrote  : manifest.json   {0} files, {1:N2} GB" -f $final.Count, ($totalBytes / 1GB)) 'Green'

if ($RunVerify) {
  Say "`n=== verify.ps1 ===" 'Cyan'
  $verify = Join-Path $PackageDir 'verify.ps1'
  if (-not (Test-Path $verify)) { Say '  verify.ps1 not found, skipped' 'Yellow' }
  else {
    $psExe = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    & $psExe -NoProfile -ExecutionPolicy Bypass -File $verify
    $vc = $LASTEXITCODE
    Say ("  verify.ps1 exit {0}" -f $vc) $(if ($vc -eq 0) { 'Green' } else { 'Red' })
    if ($vc -ne 0) { exit $vc }
  }
}
