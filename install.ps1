<#
.SYNOPSIS
  DSH local-model turnkey installer. Dry-run by default; nothing is written
  unless -Apply is given.

.DESCRIPTION
  Safety contract (guaranteed by this script):
    * No network access. Only files inside the package payload are used, and
      every one of them is SHA256-checked against manifest.json before install;
      any mismatch aborts immediately.
    * Only two DSH files are written: profiles\desktop\cordis.patch.yml and
      .dsh\AGENTS.md. Both are wrapped in BEGIN/END marker blocks, both are
      backed up to *.dsh-llm.bak first, and uninstall removes only the blocks.
    * No elevation, no registry, no services. Autostart is a single .lnk in the
      user's Startup folder.
    * If the hardware is too small, no model is installed (gateway only), and
      the reason is printed.
    * Every write is printed before it happens; a dry run changes nothing.
    * Destructive work (deleting a duplicate install) additionally requires an
      explicit switch (-PurgeOthers) on top of -Apply.

.PARAMETER Apply
  Actually execute. Without it the script only prints the plan.

.PARAMETER TargetDir
  Install destination. Default: %LOCALAPPDATA%\dsh-local-llm.

.PARAMETER SkipConfig
  Copy files only; leave DSH's cordis.patch.yml and AGENTS.md alone.

.PARAMETER NoStartup
  Do not create the logon autostart shortcut.

.PARAMETER WithPlugins
  Also install the DSH plugins shipped in the package (edits the profile
  package.json, which is backed up first).

.PARAMETER RestoreSettings
  Restore the captured official-plugin settings (onboarding answers, default
  model, chat verbosity) into cordis.patch.yml.

.PARAMETER PurgeOthers
  Delete other existing installs of this package. Requires -Apply as well.

.PARAMETER Force
  Target directory exists, is not empty, and does not look like our own
  output: continue anyway.

.EXAMPLE
  .\install.ps1                      # plan only
  .\install.ps1 -Apply               # do it
#>
[CmdletBinding()]
param(
  [switch]$Apply,
  [string]$TargetDir = (Join-Path $env:LOCALAPPDATA 'dsh-local-llm'),
  [switch]$SkipConfig,
  [switch]$NoStartup,
  [switch]$WithPlugins,
  [string]$PluginNames = '',
  [string]$ForceProfile = '',
  [string]$Runtime = 'auto',
  [switch]$RestoreSettings,
  [switch]$PurgeOthers,
  [switch]$Force,
  [switch]$AllowMultiple,
  [switch]$PruneRuntimes,
  [switch]$NoSelfTest,
  [string]$PackageRoot = ''
)

# $PSScriptRoot is not available inside param() defaults, so resolve it here.
if ([string]::IsNullOrWhiteSpace($PackageRoot)) { $PackageRoot = $PSScriptRoot }
if ([string]::IsNullOrWhiteSpace($PackageRoot)) { $PackageRoot = (Get-Location).Path }

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Canonical marker text written by this installer.
$MARK_BEGIN = '# >>> dsh-local-llm BEGIN'
$MARK_END = '# <<< dsh-local-llm END <<<'
# The Markdown markers must be CLOSED HTML comments. An earlier build dropped
# the closing "-->" from the BEGIN marker, which turned the whole rule block
# into one giant HTML comment: the rules were written to disk but never reached
# the model.
$MARK_MD_BEGIN = '<!-- >>> dsh-local-llm BEGIN (installer-generated, do not edit) >>> -->'
$MARK_MD_END = '<!-- <<< dsh-local-llm END <<< -->'

# Tolerant matchers: older builds wrote a longer marker line, and some files
# ended up with several duplicate BEGIN lines. These match any variant, whole
# line included, so a cleaning pass can collapse all of them.
$RE_YML_BEGIN = '(?m)^[ \t]*#[ \t]*>>>[ \t]*dsh-local-llm[ \t]+BEGIN[^\r\n]*\r?\n?'
$RE_YML_END = '(?m)^[ \t]*#[ \t]*<<<[ \t]*dsh-local-llm[ \t]+END[^\r\n]*\r?\n?'
$RE_MD_BEGIN = '(?m)^[ \t]*<!--[ \t]*>>>[ \t]*dsh-local-llm[ \t]+BEGIN[^\r\n]*\r?\n?'
$RE_MD_END = '(?m)^[ \t]*<!--[ \t]*<<<[ \t]*dsh-local-llm[ \t]+END[^\r\n]*\r?\n?'

$script:steps = 0
function Say($msg, $color = 'Gray') { Write-Host $msg -ForegroundColor $color }
function Act($msg) { $script:steps++; Say ("  [{0}] {1}" -f $script:steps, $msg) }
function Plan($msg) { $script:steps++; Say ("  [{0}] (dry-run) {1}" -f $script:steps, $msg) 'Cyan' }

# ---------------------------------------------------------------- helpers
# Remove every top-level "- id: <id>" row, whole block, exact id match only.
# Returns a hashtable: text = new text, index = offset of the first removal
# (-1 when the id was absent), count = number of rows removed.
function Remove-YmlEntry([string]$text, [string]$id) {
  # A row is its "- id: <id>" line plus the indented lines after it. Any other
  # line ends the row - in particular a top-level marker comment. The first
  # version swept every line up to the next "- id:", so deleting a row that sat
  # directly above our block also deleted the "# >>> dsh-local-llm BEGIN" line
  # and left a half block behind (stress case c3).
  # The removal splices the original string, so every byte outside the row is
  # preserved and repeated runs stay byte-identical (a line-array rebuild would
  # silently normalise line endings).
  if ([string]::IsNullOrEmpty($text)) { return @{ text = $text; index = -1; count = 0 } }
  $pat = '(?m)^- id:[ \t]*' + [regex]::Escape($id) + '[ \t]*(?=\r?$)(?:\r?\n(?:[ \t][^\r\n]*)?)*'
  $first = -1
  $removed = 0
  $m = [regex]::Match($text, $pat)
  while ($m.Success) {
    if ($first -lt 0) { $first = $m.Index }
    $text = $text.Remove($m.Index, $m.Length)
    $removed++
    $m = [regex]::Match($text, $pat)
  }
  if ($removed -eq 0) { return @{ text = $text; index = -1; count = 0 } }
  return @{ text = $text; index = $first; count = $removed }
}

# Collapse any number of our marker lines into nothing.
function Remove-YmlMarkers([string]$text) {
  $text = [regex]::Replace($text, $RE_YML_BEGIN, '')
  $text = [regex]::Replace($text, $RE_YML_END, '')
  return $text
}

# Squash runs of blank lines left behind by a removal.
function Squash-Blank([string]$text) {
  $text = [regex]::Replace($text, '(?:[ \t]*\r?\n){3,}', "`r`n`r`n")
  return $text.Trim()
}

# Remove every copy of our Markdown block, including nested/duplicated pairs.
function Remove-MdBlock([string]$text) {
  $region = $RE_MD_BEGIN + '[\s\S]*' + $RE_MD_END
  if ([regex]::IsMatch($text, $region)) { $text = [regex]::Replace($text, $region, '') }
  # A BEGIN that never got its END: drop everything from it to end of file.
  $text = [regex]::Replace($text, $RE_MD_BEGIN + '[\s\S]*\z', '')
  $text = [regex]::Replace($text, $RE_MD_BEGIN, '')
  $text = [regex]::Replace($text, $RE_MD_END, '')
  return $text.TrimEnd()
}

# Two-level backup. *.dsh-llm.bak is the rolling "state before the last run".
# *.orig.bak is written once, the first time we ever touch the file, and is never
# overwritten again - that is the only copy of the user's pre-kit configuration.
function Save-Backup([string]$path) {
  if (-not (Test-Path -LiteralPath $path)) { return }
  $orig = "$path.orig.bak"
  if (-not (Test-Path -LiteralPath $orig)) {
    Copy-Item -LiteralPath $path -Destination $orig -Force -ErrorAction SilentlyContinue
  }
  Copy-Item -LiteralPath $path -Destination "$path.dsh-llm.bak" -Force -ErrorAction SilentlyContinue
}

# Minimal semver compare for plugin versions: numbers first, pre-release/build
# tails ignored. Returns -1, 0 or 1. Non-numeric junk counts as 0.
function Compare-Ver([string]$a, [string]$b) {
  $clean = { param($v) if ([string]::IsNullOrWhiteSpace($v)) { return @(0) }; $core = ($v.Trim() -replace '^[vV]', '') -split '[-+]' ; return ($core[0] -split '\.') }
  $pa = & $clean $a
  $pb = & $clean $b
  $n = [Math]::Max($pa.Count, $pb.Count)
  for ($i = 0; $i -lt $n; $i++) {
    $x = 0; $y = 0
    if ($i -lt $pa.Count) { $null = [int]::TryParse(($pa[$i] -replace '[^0-9]', ''), [ref]$x) }
    if ($i -lt $pb.Count) { $null = [int]::TryParse(($pb[$i] -replace '[^0-9]', ''), [ref]$y) }
    if ($x -lt $y) { return -1 }
    if ($x -gt $y) { return 1 }
  }
  return 0
}

# Guarantee the profile package.json has the fields the installer merges into.
# A profile written by an older DSH (or hand edited) may have no `dsh` key at
# all, and under Set-StrictMode reading it aborts the whole install.
function Ensure-ProfileShape($pkg) {
  if ($null -eq $pkg) { return }
  if ($null -eq $pkg.PSObject.Properties['dependencies']) {
    $pkg | Add-Member -NotePropertyName 'dependencies' -NotePropertyValue ([pscustomobject]@{}) -Force
  }
  $dsh = $pkg.PSObject.Properties['dsh']
  if ($null -eq $dsh -or $null -eq $dsh.Value) {
    $pkg | Add-Member -NotePropertyName 'dsh' -NotePropertyValue ([pscustomobject]@{ profile = [pscustomobject]@{ bundles = @() } }) -Force
    return
  }
  $prof = $dsh.Value.PSObject.Properties['profile']
  if ($null -eq $prof -or $null -eq $prof.Value) {
    $dsh.Value | Add-Member -NotePropertyName 'profile' -NotePropertyValue ([pscustomobject]@{ bundles = @() }) -Force
    return
  }
  $bund = $prof.Value.PSObject.Properties['bundles']
  if ($null -eq $bund -or $null -eq $bund.Value) {
    $prof.Value | Add-Member -NotePropertyName 'bundles' -NotePropertyValue @() -Force
  }
}
# Copy only the files that are NOT already there. Used by the profile-snapshot
# step: the snapshot must fill holes, never replace something the user installed.
function Copy-MissingTree([string]$Source, [string]$Dest) {
  $made = 0
  $kept = 0
  $skipped = 0
  if (-not (Test-Path $Dest)) { New-Item -ItemType Directory -Path $Dest -Force | Out-Null }
  foreach ($f in (Get-ChildItem $Source -Recurse -File -Force -ErrorAction SilentlyContinue)) {
    $rel = $f.FullName.Substring($Source.Length).TrimStart('\', '/')
    $target = Join-Path $Dest $rel
    if (Test-Path -LiteralPath $target) { $kept++; continue }
    try {
      $dir = Split-Path $target -Parent
      if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
      Copy-Item -LiteralPath $f.FullName -Destination $target -Force -ErrorAction Stop
      $made++
    } catch { $skipped++ }
  }
  return @{ made = $made; kept = $kept; skipped = $skipped }
}

# Merge a snapshot package.json into the live one. The live file stays the
# owner: existing dependencies and bundles keep their values and order, the
# snapshot only contributes entries that are missing.
function Merge-ProfilePackage([string]$SnapshotPath, [string]$LivePath) {
  if (-not (Test-Path $SnapshotPath)) { return @{ addedDep = 0; addedBundle = 0 } }
  if (-not (Test-Path $LivePath)) {
    Copy-Item -LiteralPath $SnapshotPath -Destination $LivePath -Force
    return @{ addedDep = -1; addedBundle = -1 }
  }
  $want = Get-Content $SnapshotPath -Raw -Encoding UTF8 | ConvertFrom-Json
  $cur = Get-Content $LivePath -Raw -Encoding UTF8 | ConvertFrom-Json
  $null = Ensure-ProfileShape $cur
  $null = Ensure-ProfileShape $want
  $ad = 0
  $ab = 0
  foreach ($d in $want.dependencies.PSObject.Properties) {
    if (-not $cur.dependencies.PSObject.Properties[$d.Name]) {
      $cur.dependencies | Add-Member -NotePropertyName $d.Name -NotePropertyValue $d.Value -Force
      $ad++
    }
  }
  foreach ($bn in @($want.dsh.profile.bundles)) {
    if (@($cur.dsh.profile.bundles) -notcontains $bn) { $cur.dsh.profile.bundles += $bn; $ab++ }
  }
  [System.IO.File]::WriteAllText($LivePath, ($cur | ConvertTo-Json -Depth 8), (New-Object System.Text.UTF8Encoding($false)))
  return @{ addedDep = $ad; addedBundle = $ab }
}

# What this run actually added to the profile. uninstall.ps1 reads the file these
# end up in and removes ONLY those entries, so a plugin the user installed
# themselves is never deleted - not even the same or a newer version of ours.
$stateCreatedPlugins = @()
$stateUpgradedPlugins = @()
$stateAddedDeps = @()
$stateAddedBundles = @()
$stateProfileFiles = @()

# ---------------------------------------------------------------- 0. Environment
Say "`n=== 0. Environment ===" 'Cyan'
$payload = Join-Path $PackageRoot 'payload'
$manifestPath = Join-Path $PackageRoot 'manifest.json'
foreach ($need in @($payload, $manifestPath)) {
  if (-not (Test-Path $need)) { throw "package incomplete, missing: $need" }
}
$manifest = Get-Content $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
Say ("  package: {0} files, {1:N2} GB, packed {2}" -f $manifest.fileCount, ($manifest.totalBytes / 1GB), $manifest.packedAt)

$dshHome = Join-Path $env:USERPROFILE '.dsh'
$dshInstalled = Test-Path (Join-Path $dshHome 'profiles\desktop')

# Pre-flight: a profile whose package.json cannot be parsed would make the merge
# steps throw halfway through the install, after files were already copied.
# Refuse up front instead - never touch a profile we cannot read.
if ($dshInstalled) {
  $preflightPkg = Join-Path $dshHome 'profiles\desktop\package.json'
  if (Test-Path $preflightPkg) {
    try {
      $null = Get-Content $preflightPkg -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
      throw ("DSH profile package.json cannot be parsed: " + $preflightPkg + " - fix or restore it first. The installer will not modify a profile it cannot read. Look for package.json.orig.bak or package.json.dsh-llm.bak next to it.")
    }
  }
}
if (-not $dshInstalled) { Say "  [warn] no DSH profile found ($dshHome\profiles\desktop). Install and run DSH once first." 'Yellow' }

$nodeCandidates = @(Get-ChildItem (Join-Path $dshHome 'dsh-runtimes') -Directory -ErrorAction SilentlyContinue |
  Sort-Object Name -Descending |
  ForEach-Object { Join-Path $_.FullName 'dependencies\node\bin\node.exe' } |
  Where-Object { Test-Path $_ })
$nodeExe = if ($nodeCandidates.Count) { $nodeCandidates[0] } else { $null }
if ($nodeExe) { Say "  Node: $nodeExe" } else { Say "  [warn] DSH bundled Node runtime not found; the gateway cannot start." 'Yellow' }

# ---------------------------------------------------------------- 1. Hardware and runtime
Say "`n=== 1. Hardware and runtime ===" 'Cyan'
$ramGB = 0
try { $ramGB = [math]::Round((Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).TotalPhysicalMemory / 1GB) } catch { $ramGB = 0 }
$physCores = 0
try { $physCores = [int](Get-CimInstance Win32_Processor -ErrorAction Stop | Measure-Object -Property NumberOfCores -Sum).Sum } catch { $physCores = 0 }
if ($physCores -le 0) { $physCores = [int][Environment]::ProcessorCount }

# Which llama.cpp builds are in this package? Each one answers for itself:
# "llama-server.exe --list-devices" is the authoritative probe. On a machine
# with no NVIDIA driver the CUDA build cannot load its cublas DLL and prints
# nothing - that failure IS the detection, so nvidia-smi is not needed at all.
$rtTable = @(
  @{ name = 'cuda';   dir = 'llama_cpp';        label = 'CUDA';   present = $false; devices = @() },
  @{ name = 'vulkan'; dir = 'llama_cpp_vulkan'; label = 'Vulkan'; present = $false; devices = @() },
  @{ name = 'cpu';    dir = 'llama_cpp_cpu';    label = 'CPU';    present = $false; devices = @() }
)
foreach ($rt in $rtTable) { $rt.present = Test-Path (Join-Path $payload "$($rt.dir)\llama-server.exe") }
Say ("  runtimes in package: " + (($rtTable | Where-Object { $_.present } | ForEach-Object { $_.label }) -join ', '))

foreach ($rt in $rtTable) {
  if (-not $rt.present) { continue }
  $exe = Join-Path $payload "$($rt.dir)\llama-server.exe"
  $txt = ''
  try { $txt = (& $exe --list-devices 2>&1 | Out-String) } catch { $txt = '' }
  $found = @()
  foreach ($mm in [regex]::Matches($txt, '(?im)^\s*(CUDA|Vulkan)(\d+):\s*(.+?)\s*\((\d+)\s*MiB,\s*(\d+)\s*MiB free\)')) {
    $found += @{ index = $mm.Groups[2].Value; name = $mm.Groups[3].Value.Trim(); total = [int]$mm.Groups[4].Value; free = [int]$mm.Groups[5].Value }
  }
  $rt.devices = $found
  if ($found.Count -gt 0) {
    Say ("  {0,-6} -> {1} device(s): {2} ({3} MB total, {4} MB free)" -f $rt.label, $found.Count, $found[0].name, $found[0].total, $found[0].free)
  } else {
    Say ("  {0,-6} -> no device" -f $rt.label) 'Gray'
  }
}
Say ("  RAM: {0} GB    physical cores: {1}" -f $(if ($ramGB) { $ramGB } else { '(unreadable, treated as unknown)' }), $physCores)

# Preference: CUDA, then Vulkan (works on AMD / Intel / any GPU with a Vulkan
# driver), then CPU. -Runtime forces one.
$backend = ''
$rtReason = ''
if ($Runtime -and $Runtime -ne 'auto') {
  $wanted = $Runtime.ToLower()
  if (@('cuda', 'vulkan', 'cpu') -notcontains $wanted) { throw "Runtime must be auto / cuda / vulkan / cpu, got: $Runtime" }
  $picked = $rtTable | Where-Object { $_.name -eq $wanted } | Select-Object -First 1
  if (-not $picked.present) { throw "this package has no $wanted runtime (payload\$($picked.dir) is missing)" }
  if ($wanted -ne 'cpu' -and $picked.devices.Count -eq 0) { throw "Runtime $wanted was forced but that build reports no usable device" }
  $backend = $wanted
  $rtReason = 'forced by -Runtime'
}
elseif (($rtTable[0].present) -and (@($rtTable[0].devices).Count -gt 0)) { $backend = 'cuda'; $rtReason = 'an NVIDIA GPU answered the CUDA build' }
elseif (($rtTable[1].present) -and (@($rtTable[1].devices).Count -gt 0)) { $backend = 'vulkan'; $rtReason = 'a GPU answered the Vulkan build (non-CUDA card)' }
elseif ($rtTable[2].present) { $backend = 'cpu'; $rtReason = 'no usable GPU, falling back to the CPU build' }
else { throw 'no usable llama.cpp runtime in payload (need llama_cpp, llama_cpp_vulkan or llama_cpp_cpu)' }

$rtRow = $rtTable | Where-Object { $_.name -eq $backend } | Select-Object -First 1
$runtimeDir = $rtRow.dir
$vramTotal = 0; $vramFree = 0; $gpuName = '(none)'
if (@($rtRow.devices).Count -gt 0) {
  $vramTotal = [int]$rtRow.devices[0].total
  $vramFree = [int]$rtRow.devices[0].free
  $gpuName = $rtRow.devices[0].name
}
Say ("  => runtime: {0} ({1})" -f $backend.ToUpper(), $rtReason) 'Green'

# Model choice depends on the runtime that will actually run it.
# Measured on this project: 4B with --fit peaks near 2.7 GB VRAM, 2B near 1.9 GB.
$profile = 'none'
$reason = ''
if ($ForceProfile) {
  $profile = $ForceProfile.ToLower()
  if (@('4b', '2b', 'none') -notcontains $profile) { throw "ForceProfile must be 4b / 2b / none, got: $ForceProfile" }
  $reason = 'manual (auto-select disabled, at your own risk)'
  Say ("  [warn] manual mode: ignoring the probe, forcing {0}" -f $profile) 'Yellow'
}
elseif ($backend -eq 'cpu') {
  if ($ramGB -eq 0 -or $ramGB -ge 8) { $profile = '2b'; $reason = 'CPU only: 2B is the smallest weights, about 2 GB RAM, slow but usable' }
  else { $profile = 'none'; $reason = "CPU only and just $ramGB GB RAM: 2B needs about 2 GB" }
}
elseif ($vramFree -ge 3000 -and ($ramGB -eq 0 -or $ramGB -ge 12)) { $profile = '4b'; $reason = "free VRAM $vramFree MB >= 3.0 GB, enough for 4B (measured 2.7 GB)" }
elseif ($vramFree -ge 1500 -and ($ramGB -eq 0 -or $ramGB -ge 8)) { $profile = '2b'; $reason = "free VRAM $vramFree MB >= 1.5 GB, 2B only" }
else { $profile = 'none'; $reason = "free VRAM $vramFree MB is too small for either model" }
Say ("  => profile: {0} ({1})" -f $profile, $reason) 'Green'
$modelMap = @{ '4b' = 'qwen3-vl-4b'; '2b' = 'qwen3-vl-2b'; 'none' = $null }
$chosenModel = $modelMap[$profile]
if ($chosenModel -and -not (Test-Path (Join-Path $payload "models\$chosenModel"))) {
  Say ("  [warn] package has no weights for {0}, falling back to no model" -f $chosenModel) 'Yellow'
  $profile = 'none'; $chosenModel = $null
}

# ---------------------------------------------------------------- 2. Verify payload
Say "`n=== 2. Verifying package (SHA256) ===" 'Cyan'
$bad = 0; $checked = 0
foreach ($entry in $manifest.files) {
  if ($entry.kind -eq 'model' -and -not $chosenModel) { continue }
  if ($entry.kind -eq 'model' -and $entry.path -notlike "*$chosenModel*") { continue }
  $full = Join-Path $payload $entry.path
  if (-not (Test-Path $full)) { Say ("  [fail] missing: {0}" -f $entry.path) 'Red'; $bad++; continue }
  $hash = (Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash
  if ($hash -ne $entry.sha256) { Say ("  [fail] hash mismatch: {0}" -f $entry.path) 'Red'; $bad++ }
  $checked++
}
if ($bad -gt 0) { throw "$bad file(s) failed verification, install aborted (package modified or copied incompletely)" }
Say ("  [ok] {0} files match the manifest" -f $checked) 'Green'

# ---------------------------------------------------------------- 3. Target
Say "`n=== 3. Target location ===" 'Cyan'
Say "  target: $TargetDir"
if ((Test-Path (Join-Path $TargetDir 'gateway\gateway.js')) -or (Test-Path (Join-Path $TargetDir 'gateway\config.json')) -or ([bool](Get-ChildItem (Join-Path $TargetDir 'llama_cpp*') -Directory -ErrorAction SilentlyContinue | Where-Object { Test-Path (Join-Path $_.FullName 'llama-server.exe') }))) {
  Say "  existing install detected, overwriting gateway files (config and logs kept)" 'Yellow'
} elseif ((Test-Path $TargetDir) -and (Get-ChildItem $TargetDir -Force -ErrorAction SilentlyContinue) -and -not $Force) {
  throw "target directory is not empty and does not look like our output: $TargetDir (add -Force to override)"
}

$script:modelLabel = if ($chosenModel) { $chosenModel } else { 'none' }
# ---------------------------------------------------------------- 3.5 Scan for other installs
function Find-ExistingInstalls {
  $found = New-Object System.Collections.Generic.List[string]
  $roots = New-Object System.Collections.Generic.List[string]
  foreach ($d in [System.IO.DriveInfo]::GetDrives()) {
    if ($d.DriveType -ne 'Fixed' -or -not $d.IsReady) { continue }
    $roots.Add($d.RootDirectory.FullName)
  }
  $roots.Add($env:LOCALAPPDATA)
  $roots.Add($env:ProgramData)
  foreach ($r in $roots) {
    if (-not (Test-Path $r)) { continue }
    $looksLikeInstall = {
      param($p)
      if ([System.IO.Path]::GetFileName($p) -eq 'payload') { return $false }
      if (-not (Test-Path (Join-Path $p 'gateway\config.json'))) { return $false }
      $runtimeDirs = @(Get-ChildItem (Join-Path $p 'llama_cpp*') -Directory -ErrorAction SilentlyContinue | Where-Object { Test-Path (Join-Path $_.FullName 'llama-server.exe') })
      return ($runtimeDirs.Count -gt 0)
    }
    foreach ($d1 in (Get-ChildItem $r -Directory -ErrorAction SilentlyContinue)) {
      if (& $looksLikeInstall $d1.FullName) { $found.Add($d1.FullName); continue }
      foreach ($d2 in (Get-ChildItem $d1.FullName -Directory -ErrorAction SilentlyContinue)) {
        if (& $looksLikeInstall $d2.FullName) { $found.Add($d2.FullName) }
      }
    }
  }
  return @($found | Sort-Object -Unique)
}

Say "`n=== 3.5 Scanning for existing installs ===" 'Cyan'
$installs = @(Find-ExistingInstalls)
$targetFull = [System.IO.Path]::GetFullPath($TargetDir).TrimEnd('\')
$others = @($installs | Where-Object { $_.TrimEnd('\') -ne $targetFull })

if ($installs.Count -eq 0) {
  Say '  no existing install found - clean machine' 'Gray'
} else {
  foreach ($p in $installs) {
    $sz = (Get-ChildItem $p -Recurse -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum / 1GB
    $tag = if ($p.TrimEnd('\') -eq $targetFull) { ' <- this is the target, will be reused' } else { '' }
    Say ("  found: {0}  ({1:N2} GB){2}" -f $p, $sz, $tag)
  }
}

if ($AllowMultiple) {
  Say ("  -AllowMultiple: {0} other install(s) intentionally ignored (lab / side-by-side installs only, never for end users)" -f $others.Count) 'Yellow'
} elseif ($others.Count -gt 0) {
  Say ("  {0} other install(s) exist. Only one copy is allowed." -f $others.Count) 'Yellow'
  if (-not $PurgeOthers) {
    Say ''
    Say '  STOP: another install already exists. Refusing to create a second copy.' 'Red'
    Say '  pick one of these:' 'Yellow'
    Say '    A) reuse the existing one:  -TargetDir "<path printed above>"' 'Yellow'
    Say '    B) delete it and install here:  -Apply -PurgeOthers' 'Yellow'
    Say ''
    if ($Apply) { throw 'aborted: duplicate install would be created (use -PurgeOthers or -TargetDir)' }
    Say '  (dry run: nothing was deleted)' 'Gray'
  } elseif (-not $Apply) {
    Say '  would remove them, but -Apply was not given. Nothing deleted.' 'Yellow'
  } else {
    foreach ($p in $others) {
      $sz = (Get-ChildItem $p -Recurse -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum / 1GB
      try {
        Remove-Item $p -Recurse -Force -ErrorAction Stop
        Say ("  removed old install: {0}  ({1:N2} GB)" -f $p, $sz) 'Gray'
      } catch {
        Say ("  FAILED to remove {0}: {1}" -f $p, $_.Exception.Message) 'Red'
        Say '  close any running gateway for that folder, then re-run.' 'Red'
      }
    }
  }
}
if (-not $Apply) {
  Plan "create directory $TargetDir"
  Plan "copy gateway (scripts / tools / rules) -> $TargetDir"
  if ($chosenModel) { Plan "copy model $chosenModel -> $TargetDir\models" }
  else { Plan "copy no model weights" }
  Plan "copy the $backend runtime -> $TargetDir\$runtimeDir"
  if (($backend -ne 'cpu') -and ($rtTable | Where-Object { $_.name -eq 'cpu' -and $_.present })) { Plan "copy the CPU runtime as a fallback -> $TargetDir\llama_cpp_cpu" }
if ($PruneRuntimes) { Plan "prune every runtime except $runtimeDir and llama_cpp_cpu" }
  Plan "write config.json (model $script:modelLabel, paths resolved for this machine)"
  if (-not $SkipConfig) {
    Plan "rewrite $dshHome\profiles\desktop\cordis.patch.yml (marker block, backed up first)"
    Plan "rewrite $dshHome\AGENTS.md (marker block, backed up first)"
  } else { Plan "skip DSH config (-SkipConfig)" }
  if (-not $NoStartup) { Plan "create the Startup shortcut" } else { Plan "no autostart" }
  if ($WithPlugins) { Plan "install plugins and update profile\package.json (backed up)" }
  Say "`ndry-run only. nothing was changed. add -Apply to execute.`n" 'Cyan'
  return
}

# ---------------------------------------------------------------- 4. Copy files
Say "`n=== 4. Copying files ===" 'Cyan'
New-Item -ItemType Directory -Path $TargetDir -Force | Out-Null
$gwSrc = Join-Path $payload 'gateway'
$gwDst = Join-Path $TargetDir 'gateway'
Act "copying gateway -> $gwDst"
New-Item -ItemType Directory -Path $gwDst -Force | Out-Null
$null = robocopy $gwSrc $gwDst /E /NJH /NJS /NP /R:1 /W:1

$llamaDst = Join-Path $TargetDir $runtimeDir
Act "copying the $backend runtime -> $llamaDst"
New-Item -ItemType Directory -Path $llamaDst -Force | Out-Null
$swCopy = [Diagnostics.Stopwatch]::StartNew()
$null = robocopy (Join-Path $payload $runtimeDir) $llamaDst /E /NJH /NJS /NP /R:2 /W:1
Say ("    done in {0:N0}s" -f $swCopy.Elapsed.TotalSeconds)
if ($LASTEXITCODE -ge 8) { throw "failed to copy the $backend runtime (robocopy $LASTEXITCODE)" }

# Always keep a CPU runtime next to it: if the GPU driver breaks later,
# switching config.json to the CPU build is a one-line edit, not a reinstall.
$cpuRow = $rtTable | Where-Object { $_.name -eq 'cpu' } | Select-Object -First 1
if (($backend -ne 'cpu') -and $cpuRow.present) {
  $cpuDst = Join-Path $TargetDir $cpuRow.dir
  if (-not (Test-Path (Join-Path $cpuDst 'llama-server.exe'))) {
    Act "copying the CPU runtime as a fallback -> $cpuDst"
    New-Item -ItemType Directory -Path $cpuDst -Force | Out-Null
    $null = robocopy (Join-Path $payload $cpuRow.dir) $cpuDst /E /NJH /NJS /NP /R:2 /W:1
  } else { Say "    CPU fallback already present: $cpuDst" 'Gray' }
}

# ------------------------------------------------------------- 4.5 Prune stale runtimes
# Everything else in this installer is additive on purpose. This is the one
# place it deletes, so it needs BOTH -Apply (already required to reach section
# 4) and -PruneRuntimes, it only touches llama_cpp* directories that really
# contain a llama-server.exe, and it never removes the active runtime or the
# CPU fallback.
if ($PruneRuntimes) {
  Say "`n=== 4.5 Pruning stale runtimes ===" 'Cyan'
  $keepRuntimes = @($runtimeDir, 'llama_cpp_cpu')
  $freedMB = 0
  foreach ($rd in @(Get-ChildItem $TargetDir -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'llama_cpp*' })) {
    if ($keepRuntimes -contains $rd.Name) { Say ("    keep   " + $rd.Name + "  (in use or CPU fallback)") 'Gray'; continue }
    if (-not (Test-Path (Join-Path $rd.FullName 'llama-server.exe'))) { Say ("    [warn] " + $rd.Name + " has no llama-server.exe, left alone") 'Yellow'; continue }
    $mb = [int](((Get-ChildItem $rd.FullName -Recurse -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum) / 1MB)
    try {
      Remove-Item -LiteralPath $rd.FullName -Recurse -Force -ErrorAction Stop
      $freedMB += $mb
      Say ("    removed " + $rd.Name + "  (" + $mb + " MB)")
    } catch {
      Say ("    [warn] could not remove " + $rd.Name + ": " + $_.Exception.Message) 'Yellow'
    }
  }
  Act ("stale runtimes pruned: {0} MB freed (kept {1})" -f $freedMB, ($keepRuntimes -join ' + '))
}
$modelRoot = Join-Path $TargetDir 'models'
if ($chosenModel) {
  Act "copying model $chosenModel (GB scale, please wait) -> $modelRoot\$chosenModel"
  New-Item -ItemType Directory -Path (Join-Path $modelRoot $chosenModel) -Force | Out-Null
  $swCopy2 = [Diagnostics.Stopwatch]::StartNew()
  Say ("    copying model weights (this takes a while)...")
  $null = robocopy (Join-Path $payload "models\$chosenModel") (Join-Path $modelRoot $chosenModel) /E /NJH /NJS /NP /R:2 /W:1
  Say ("    done in {0:N0}s" -f $swCopy2.Elapsed.TotalSeconds)
  if ($LASTEXITCODE -ge 8) { throw "failed to copy model weights (robocopy $LASTEXITCODE)" }
}

# ---- copy installer, docs and licenses into the target so the extracted
# ---- package can be deleted afterwards
$supportFiles = @('install.ps1', 'uninstall.ps1', 'verify.ps1', 'plugins-verify.ps1', 'restore-peers.ps1', 'manifest.json',
  'README.md', 'DISCLAIMER.md', 'THIRD-PARTY-NOTICES.md', 'UPSTREAM-VERIFIED.txt', 'plugins-verified.json')
foreach ($sf in $supportFiles) {
  $s = Join-Path $PackageRoot $sf
  if (Test-Path $s) { Copy-Item -LiteralPath $s -Destination $TargetDir -Force -ErrorAction SilentlyContinue }
}
foreach ($sd in @('licenses', 'src')) {
  $s = Join-Path $PackageRoot $sd
  if (Test-Path $s) { $null = robocopy $s (Join-Path $TargetDir $sd) /E /NJH /NJS /NP /R:1 /W:1 }
}
Act "installer and documents copied to target (the extracted package can now be deleted)"
# ---------------------------------------------------------------- 5. Config
Say "`n=== 5. Writing config ===" 'Cyan'
$configPath = Join-Path $gwDst 'config.json'

$modelId = 'local-vl'
$modelPath = ''
$mmprojPath = ''
$llamaArgs = @('-c', '16384', '-np', '2', '-b', '1024', '-ub', '256', '-fa', 'on',
  '--cache-type-k', 'q8_0', '--cache-type-v', 'q8_0', '--image-min-tokens', '512')
if ($backend -eq 'cpu') {
  # Nothing to fit into: force CPU-only inference and use the physical cores.
  $llamaArgs += @('-ngl', '0', '-t', [string]$physCores)
} else {
  $llamaArgs += @('--fit', 'on', '--fit-target', '1024')
}
if ($chosenModel) {
  $dir = Join-Path $modelRoot $chosenModel
  $gguf = Get-ChildItem $dir -Filter '*Q4_K_M.gguf' -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $gguf) { $gguf = Get-ChildItem $dir -Filter '*.gguf' | Where-Object { $_.Name -notlike '*mmproj*' } | Select-Object -First 1 }
  $mm = Get-ChildItem $dir -Filter '*mmproj*.gguf' -ErrorAction SilentlyContinue | Select-Object -First 1
  $modelPath = $gguf.FullName
  $mmprojPath = $mm.FullName
}

# Whitelist for [[file:]] and [[save:]]. It used to be the install directory only,
# which silently rejected every path the rules advertise (D:\工作区, the user's own
# folders): the model saw the literal "[[file:...]]" text, and results could not be
# written to disk - so batch output had to be pasted back into the main context.
$targetRoot = ([string]$TargetDir).TrimEnd('\')
$workRoots = @($targetRoot, (Join-Path $targetRoot 'work'), 'D:\工作区')
foreach ($wr in $workRoots) {
  if (-not (Test-Path $wr)) { try { New-Item -ItemType Directory -Path $wr -Force | Out-Null } catch { } }
}
# llama.cpp gives each slot -c / -np, so with -c 16384 -np 2 a request only has
# 8192 tokens. Advertising 16384 made big batches fail with HTTP 502
# ("exceeds the available context size (8192)"). Advertise the per-slot value.
$ctxPerSlot = 8192
$newConfig = [ordered]@{
  '$comment'   = 'DSH local GGUF gateway (generated by the turnkey installer). Editing this file does not need a gateway restart - save and it reloads.'
  listen       = [ordered]@{ host = '127.0.0.1'; port = 8099 }
  model        = [ordered]@{
    id = $modelId; displayName = "Local VLM ($chosenModel, auto start/stop)"
    contextWindow = $ctxPerSlot; maxTokens = 2048; input = @('text', 'image')
  }
  llamaServer  = [ordered]@{
    exe = (Join-Path $llamaDst 'llama-server.exe')
    modelPath = $modelPath
    mmprojPath = $mmprojPath
    host = '127.0.0.1'; port = 18080
    startTimeoutMs = 180000; stopTimeoutMs = 8000
    args = $llamaArgs
  }
  lifecycle    = [ordered]@{
    idleTimeoutMs = 300000; reapIntervalMs = 10000; unloadOnGatewayExit = $true
    maxConsecutiveStartFailures = 2; failureCooldownMs = 60000
  }
  features     = [ordered]@{
    autoAttachImages = $true; maxAutoAttachImages = 8; maxImageBytes = 12582912
    systemPrompt = [ordered]@{ mode = 'strip' }
    saveDirective = [ordered]@{ enabled = $true; roots = $workRoots }
    inlineFiles = [ordered]@{ enabled = $true; maxBytes = 262144; roots = $workRoots }
    imageSearchDirs = $workRoots
  }
  logging      = [ordered]@{
    file = (Join-Path $TargetDir 'logs\gateway.log'); maxBytes = 5242880
    upstreamLog = (Join-Path $TargetDir 'logs\llama-server.log')
  }
}
[System.IO.File]::WriteAllText($configPath, ($newConfig | ConvertTo-Json -Depth 8), (New-Object System.Text.UTF8Encoding($false)))
Act "wrote config.json (model $script:modelLabel)"

$vbsNode = if ($nodeExe) { $nodeExe } else { '' }
$vbs = @"
' DSH local LLM gateway launcher (generated by the turnkey installer)
Option Explicit
Dim fso, sh, base, nodeExe
Set fso = CreateObject("Scripting.FileSystemObject")
Set sh = CreateObject("WScript.Shell")
base = fso.GetParentFolderName(WScript.ScriptFullName)
nodeExe = "$vbsNode"
If nodeExe = "" Or Not fso.FileExists(nodeExe) Then
  nodeExe = sh.ExpandEnvironmentStrings("%USERPROFILE%") & "\.dsh\dsh-runtimes\dsh-primary-runtime\dependencies\node\bin\node.exe"
End If
If Not fso.FileExists(nodeExe) Then
  sh.Popup "node.exe not found - the DSH bundled runtime may have moved. Reinstall DSH or edit this file.", 10, "DSH local LLM"
  WScript.Quit 1
End If
sh.Run """" & nodeExe & """ """ & base & "\gateway.js""", 0, False
"@
[System.IO.File]::WriteAllText((Join-Path $gwDst 'launch-gateway.vbs'), $vbs, (New-Object System.Text.UnicodeEncoding($false, $true)))
Act "wrote launch-gateway.vbs (node path resolved for this machine)"

# ---------------------------------------------------------------- 6. DSH config
if (-not $SkipConfig -and $dshInstalled) {
  Say "`n=== 6. Patching DSH config ===" 'Cyan'
  $patchPath = Join-Path $dshHome 'profiles\desktop\cordis.patch.yml'
  $patchBlock = @"
$MARK_BEGIN
- id: llm-pi-ai
  name: "@deepseek-ai/dsh-llm-pi-ai"
  config:
    providers:
      local-gguf:
        displayName: Local VLM (auto start/stop)
        api: openai-completions
        baseURL: http://127.0.0.1:8099/v1
        headers:
          Authorization: "Bearer sk-local-gguf"
        defaultContextWindow: $ctxPerSlot
        defaultMaxTokens: 2048
        retryPolicy:
          mode: normal
          maxRetries: 1
        streamIdleTimeoutMs: 90000
        models:
          - id: $modelId
            name: Local VLM ($chosenModel)
            contextWindow: $ctxPerSlot
            maxTokens: 2048
            input: [ text, image ]
            reasoningEfforts: false
- id: tool-subagent
  name: "@deepseek-ai/dsh-tool-subagent"
  config:
    provider: spawn
    toolName: subagent
    modelSelectionSettings: true
- id: subagent-model-selection-settings
  name: "@deepseek-ai/dsh-tool-subagent/model-selection-settings"
  config:
    enabled: true
    allowedModels:
      - provider: local-gguf
        model: $modelId
$MARK_END
"@
  # Order matters: normalise FIRST (drop every stale row and every stale
  # marker line, whatever variant it was written with), then append exactly
  # one fresh block. The previous build stripped the rows after the marker
  # search, which destroyed the END line and left a fresh BEGIN behind on
  # every run - that is where the duplicated marker blocks came from.
  $original = if (Test-Path $patchPath) { [System.IO.File]::ReadAllText($patchPath, [System.Text.Encoding]::UTF8) } else { '' }
  Save-Backup $patchPath

  foreach ($oid in @('tool-subagent', 'llm-pi-ai', 'subagent-model-selection-settings')) {
    $r = Remove-YmlEntry $original $oid
    $original = $r.text
  }
  $original = Remove-YmlMarkers $original
  $original = Squash-Blank $original

  $updated = if ($original.Length -gt 0) { $original.TrimEnd() + "`r`n`r`n" + $patchBlock.Trim() + "`r`n" }
             else { $patchBlock.Trim() + "`r`n" }
  $cB = ([regex]::Matches($updated, $RE_YML_BEGIN)).Count
  $cE = ([regex]::Matches($updated, $RE_YML_END)).Count
  if ($cB -ne 1 -or $cE -ne 1) { throw "marker normalisation failed: $cB BEGIN / $cE END (expected 1/1)" }
  [System.IO.File]::WriteAllText($patchPath, $updated, (New-Object System.Text.UTF8Encoding($false)))
  Act "cordis.patch.yml updated (backup: .dsh-llm.bak; markers: $cB BEGIN / $cE END)"

  $agentsPath = Join-Path $dshHome 'AGENTS.md'
  $rulesSrc = Join-Path $gwSrc 'rules\AGENTS.block.md'
  if (Test-Path $rulesSrc) {
    $rules = [System.IO.File]::ReadAllText($rulesSrc, [System.Text.Encoding]::UTF8).Trim()
    # The shipped rules file is itself a complete block (it starts with a BEGIN
    # marker and ends with an END marker). Wrapping that verbatim used to nest a
    # pair inside a pair - that is where the repeated AGENTS.md blocks came from.
    # Strip its own markers and wrap exactly once.
    $rules = [regex]::Replace($rules, $RE_MD_BEGIN, '')
    $rules = [regex]::Replace($rules, $RE_MD_END, '')
    $rules = $rules.Trim()
    if ($rules.Length -eq 0) { throw "rules file is empty after stripping markers: $rulesSrc" }
    $existing = if (Test-Path $agentsPath) { [System.IO.File]::ReadAllText($agentsPath, [System.Text.Encoding]::UTF8) } else { '' }
    Save-Backup $agentsPath
    # The shipped rules use {{NODE}} / {{VLMTOOL}} instead of any machine's real
    # paths, so the package is portable and carries no directory names. Fill them
    # in with this install's paths.
    $nodeForRules = if ($nodeExe) { $nodeExe } else { 'node' }
    $vlmToolForRules = Join-Path $gwDst 'tools\vlm-task.mjs'
    $rules = $rules.Replace('{{NODE}}', $nodeForRules).Replace('{{VLMTOOL}}', $vlmToolForRules)
    $mdBlock = "$MARK_MD_BEGIN`r`n$rules`r`n$MARK_MD_END"
    # Same rule: strip every previous copy of the block first, then append one.
    $mdText = Remove-MdBlock $existing
    $mdText = Squash-Blank $mdText
    $mdUpdated = if ($mdText.Length -gt 0) { $mdText.TrimEnd() + "`r`n`r`n" + $mdBlock + "`r`n" }
                 else { $mdBlock + "`r`n" }
    $mB = ([regex]::Matches($mdUpdated, $RE_MD_BEGIN)).Count
    $mE = ([regex]::Matches($mdUpdated, $RE_MD_END)).Count
    if ($mB -ne 1 -or $mE -ne 1) { throw "AGENTS.md marker normalisation failed: $mB BEGIN / $mE END (expected 1/1)" }
    [System.IO.File]::WriteAllText($agentsPath, $mdUpdated, (New-Object System.Text.UTF8Encoding($false)))
    Act "AGENTS.md rule block written (backup: .dsh-llm.bak; markers: $mB BEGIN / $mE END)"
  }
} elseif ($SkipConfig) { Say "`n=== 6. DSH config skipped (-SkipConfig) ===" 'Yellow' }

# ---------------------------------------------------------------- 7. Autostart
$startup = [Environment]::GetFolderPath('Startup')
if ($NoStartup) {
  Say "`n=== 7. Startup shortcut skipped (-NoStartup) ===" 'Gray'
} elseif ([string]::IsNullOrWhiteSpace($startup)) {
  Say "`n=== 7. Startup shortcut: unknown Startup folder on this machine, skipped ===" 'Yellow'
} else {
  Say "`n=== 7. Startup shortcut ===" 'Cyan'
  $lnk = Join-Path $startup 'DSH Local LLM Gateway.lnk'
  $shell = New-Object -ComObject WScript.Shell
  $sc = $shell.CreateShortcut($lnk)
  $sc.TargetPath = "$env:WINDIR\System32\wscript.exe"
  $sc.Arguments = '"' + (Join-Path $gwDst 'launch-gateway.vbs') + '"'
  $sc.WorkingDirectory = $gwDst
  $sc.WindowStyle = 7
  $sc.Description = 'DSH local model gateway'
  $sc.Save()
  Act "startup shortcut created: $lnk"
}

# ---------------------------------------------------------------- 8. Plugins
if ($WithPlugins) {
  Say "`n=== 8. Plugins ===" 'Cyan'
  $profilePath = Join-Path $dshHome 'profiles\desktop'
  $pkgPath = Join-Path $profilePath 'package.json'
  Save-Backup $pkgPath
  $pkg = Get-Content $pkgPath -Raw -Encoding UTF8 | ConvertFrom-Json
  foreach ($dir in (Get-ChildItem (Join-Path $payload 'plugins') -Directory -ErrorAction SilentlyContinue)) {
    $name = $dir.Name
    if ($PluginNames) {
      $want = $PluginNames -split '[,;]' | ForEach-Object { $_.Trim() } | Where-Object { $_ }
      if ($want -notcontains $name) { Say ("    skipped (not selected): {0}" -f $name) 'Yellow'; continue }
    }
    $dest = Join-Path $profilePath "node_modules\$name"
    $destPkg = Join-Path $dest 'package.json'
    $weCreated = -not (Test-Path $dest)
    $preserved = $dest + '.dsh-llm-preserved'
    $haveVer = ''
    $bundledVer = ''
    try { $bundledVer = (Get-Content (Join-Path $dir.FullName 'package.json') -Raw -Encoding UTF8 | ConvertFrom-Json).version } catch { $bundledVer = '' }
    if (Test-Path $destPkg) {
      try { $haveVer = (Get-Content $destPkg -Raw -Encoding UTF8 | ConvertFrom-Json).version } catch { $haveVer = '' }
    }
    $kept = $false
    if (($haveVer -ne '') -and ($bundledVer -ne '') -and ((Compare-Ver $haveVer $bundledVer) -ge 0)) {
      # Already installed at the same or a newer version: leave the files alone.
      Say ("    keeping " + $name + " " + $haveVer + " (already installed; the package ships " + $bundledVer + ")") 'Gray'
      $kept = $true
    } else {
      if (-not $weCreated) {
        # The user's own copy, ours is newer. Keep theirs so uninstall can put it back.
        if (Test-Path $preserved) { Remove-Item -LiteralPath $preserved -Recurse -Force -ErrorAction SilentlyContinue }
        try {
          Copy-Item -LiteralPath $dest -Destination $preserved -Recurse -Force -ErrorAction Stop
          Say ("    preserved your " + $name + " " + $haveVer + " so uninstall can restore it") 'Gray'
        } catch {
          Say ("    [warn] could not preserve your copy of " + $name + ": " + $_.Exception.Message) 'Yellow'
        }
      }
      if ($haveVer -ne '') { Say ("    upgrading " + $name + " " + $haveVer + " -> " + $bundledVer) 'Gray' }
      # Copy the CONTENTS, not the directory: Copy-Item <dir> <existing dir> -Recurse
      # nests it (node_modules\<plugin>\<plugin>\), which left the old version in
      # place while creating a useless subdirectory. Found by suite J.
      New-Item -ItemType Directory -Path $dest -Force | Out-Null
      foreach ($item in (Get-ChildItem -LiteralPath $dir.FullName -Force)) {
        Copy-Item -LiteralPath $item.FullName -Destination $dest -Recurse -Force
      }
    }
    if ($weCreated) {
      $stateCreatedPlugins += [pscustomobject]@{ name = $name; version = $bundledVer }
    } elseif (-not $kept) {
      $stateUpgradedPlugins += [pscustomobject]@{ name = $name; from = $haveVer; to = $bundledVer; preserved = (Test-Path $preserved) }
    }
    if (-not $pkg.dependencies.PSObject.Properties[$name]) {
      $pkg.dependencies | Add-Member -NotePropertyName $name -NotePropertyValue '*' -Force
      $stateAddedDeps += $name
    }
    $null = Ensure-ProfileShape $pkg
    if ($pkg.dsh.profile.bundles -notcontains $name) { $pkg.dsh.profile.bundles += $name; $stateAddedBundles += $name }
    Act "plugin $name copied and registered"
  }
  [System.IO.File]::WriteAllText($pkgPath, ($pkg | ConvertTo-Json -Depth 8), (New-Object System.Text.UTF8Encoding($false)))
  Act "package.json updated (backup: package.json.dsh-llm.bak)"
}

# ---------------------------------------------------------------- 8.4 Snapshot
if ($WithPlugins) {
  $snapDir = Join-Path $PackageRoot 'payload\profile-snapshot'
  if (Test-Path (Join-Path $snapDir 'node_modules')) {
    Say "`n=== 8.4 Plugins from the snapshot (additive) ===" 'Cyan'
    $profDir2 = Join-Path $dshHome 'profiles\desktop'
    $pkgLive = Join-Path $profDir2 'package.json'
    $lockLive = Join-Path $profDir2 'pnpm-lock.yaml'
    $wsLive = Join-Path $profDir2 'pnpm-workspace.yaml'
    foreach ($f in @($pkgLive, $lockLive)) {
      Save-Backup $f
    }
    # This step used to be `robocopy $snapDir $profDir2 /E`, which replaced the
    # profile's package.json and pnpm-lock.yaml outright: every plugin the user
    # had installed themselves lost its declaration and stopped loading, and any
    # same-named file was overwritten with the snapshot's copy. It is additive
    # now - the profile owns its files, the snapshot only fills holes.
    $swP = [Diagnostics.Stopwatch]::StartNew()
    $nmStats = Copy-MissingTree (Join-Path $snapDir 'node_modules') (Join-Path $profDir2 'node_modules')
    Say ("    node_modules: added {0} files, kept {1} that already existed ({2:N0}s)" -f $nmStats.made, $nmStats.kept, $swP.Elapsed.TotalSeconds)
    $mergeStats = Merge-ProfilePackage (Join-Path $snapDir 'package.json') $pkgLive
    Say ("    package.json: +{0} dependencies, +{1} bundles - your existing entries were left as they were" -f $mergeStats.addedDep, $mergeStats.addedBundle)
    if (Test-Path $wsLive) {
      Say '    pnpm-workspace.yaml: kept the profile''s own file'
    } elseif (Test-Path (Join-Path $snapDir 'pnpm-workspace.yaml')) {
      Copy-Item -LiteralPath (Join-Path $snapDir 'pnpm-workspace.yaml') -Destination $wsLive -Force
      $stateProfileFiles += 'pnpm-workspace.yaml'
      Say '    pnpm-workspace.yaml: profile had none, copied from the snapshot'
    }
    if (Test-Path $lockLive) {
      Say '    pnpm-lock.yaml: kept the profile''s own lockfile (a snapshot lock would prune your packages)' 'Gray'
    } elseif (Test-Path (Join-Path $snapDir 'pnpm-lock.yaml')) {
      Copy-Item -LiteralPath (Join-Path $snapDir 'pnpm-lock.yaml') -Destination $lockLive -Force
      $stateProfileFiles += 'pnpm-lock.yaml'
      Say '    pnpm-lock.yaml: profile had none, copied from the snapshot'
    }
    Act 'plugins laid down additively (nothing that already existed was overwritten)'
  }
}
# ---------------------------------------------------------------- 8.5 User settings
if ($RestoreSettings) {
  Say "`n=== 8.5 Restoring user settings ===" 'Cyan'
  $snapDir = Join-Path $PackageRoot 'user-settings'
  $profDir = Join-Path $dshHome 'profiles\desktop'
  if (-not (Test-Path $snapDir)) { Say '  package has no user-settings, skipped' 'Yellow' }
  elseif (-not (Test-Path $profDir)) { Say '  target profile does not exist, skipped' 'Yellow' }
  else {
    # 8.5.1 cordis.patch.yml: replace row by row, in place, exact id only.
    # The old build matched "- id: ui-settings" against "- id: ui-settings-account"
    # because it had no id boundary, so the onboarding row (purpose / process /
    # step) was silently overwritten by a second ui-settings row - which is why
    # the first-run wizard kept coming back. Matching the whole id line fixes it.
    $snapPatch = Join-Path $snapDir 'cordis.patch.yml'
    $livePatch = Join-Path $profDir 'cordis.patch.yml'
    if (Test-Path $snapPatch) {
      $live = if (Test-Path $livePatch) { [System.IO.File]::ReadAllText($livePatch, [System.Text.Encoding]::UTF8) } else { '' }
      Save-Backup $livePatch
      $snapText = [System.IO.File]::ReadAllText($snapPatch, [System.Text.Encoding]::UTF8)
      $items = [regex]::Matches($snapText, '(?ms)^- id:[ \t]*(\S+)[ \t]*\r?\n.*?(?=^- id:|\z)')
      $applied = 0
      foreach ($m in $items) {
        $id = $m.Groups[1].Value
        $block = $m.Value.TrimEnd() + "`r`n"
        $r = Remove-YmlEntry $live $id
        $live = $r.text
        if ($r.count -gt 0) {
          $live = $live.Insert($r.index, $block)
        } else {
          # Put the restored rows ABOVE our marker block. Appending them after it
          # made the file flip order on the next run (section 6 strips and
          # re-appends the block at the end), so two consecutive installs were
          # not byte-identical. They stay outside the block, so uninstall leaves
          # them alone - which is correct, they are the user's own settings.
          $mk = [regex]::Match($live, $RE_YML_BEGIN)
          if ($mk.Success) { $live = $live.Insert($mk.Index, $block) }
          else { $live = $live.TrimEnd() + "`r`n`r`n" + $block }
        }
        $applied++
        $dup = if ($r.count -gt 1) { " (removed $($r.count) stale copies)" } else { '' }
        Say ("    setting restored: {0}{1}" -f $id, $dup) 'Gray'
      }
      $live = Squash-Blank $live
      [System.IO.File]::WriteAllText($livePatch, $live + "`r`n", (New-Object System.Text.UTF8Encoding($false)))
      Act ("cordis.patch.yml: {0} settings restored" -f $applied)
      $still = @()
      foreach ($wantId in @('agent-default-model', 'ui-settings-account', 'ui-chat', 'ui-settings')) {
        if ($live -notmatch ('(?m)^- id:[ \t]*' + [regex]::Escape($wantId) + '[ \t]*\r?$')) { $still += $wantId }
      }
      if ($still.Count -gt 0) { Say ("    [warn] missing after restore: {0}" -f ($still -join ', ')) 'Yellow' }
      else { Say '    [ok] all 4 settings rows present and unique' 'Green' }
      if ($live -match '(?m)^\s*purpose:\s*both\s*$' -and $live -match '(?m)^\s*process:\s*detailed\s*$') {
        Say '    [ok] onboarding: purpose=both, process=detailed' 'Green'
      } else { Say '    [warn] onboarding answers not found in the patch' 'Yellow' }
    }

    # 8.5.3 Re-create plugin folders that package.json registers but that are
    # missing from node_modules (a DSH reinstall or pnpm prune leaves that
    # state, and the plugin then simply never appears in the UI).
    $pluginSrc = Join-Path $PackageRoot 'payload\plugins'
    if (Test-Path $pluginSrc) {
      $livePj = Join-Path $profDir 'package.json'
      $cur = Get-Content $livePj -Raw -Encoding UTF8 | ConvertFrom-Json
      foreach ($pd in (Get-ChildItem $pluginSrc -Directory)) {
        $name = $pd.Name
        $destDir = Join-Path $profDir "node_modules\$name"
        if (Test-Path $destDir) { continue }
        $registered = $cur.dependencies.PSObject.Properties[$name]
        if (-not $registered) { continue }   # only replace what is registered
        Say ("    restoring missing plugin: {0}" -f $name) 'Gray'
        New-Item -ItemType Directory (Join-Path $profDir 'node_modules') -Force | Out-Null
        $null = robocopy $pd.FullName $destDir /E /NJH /NJS /NP /R:1 /W:1
      }
      Act 'missing plugin files restored'
    }
    # 8.5.2 package.json: top up dependencies and bundles
    $snapPkg = Join-Path $snapDir 'package.json'
    $livePkg = Join-Path $profDir 'package.json'
    if ((Test-Path $snapPkg) -and (Test-Path $livePkg)) {
      Save-Backup $livePkg
      $want = Get-Content $snapPkg -Raw -Encoding UTF8 | ConvertFrom-Json
      $cur = Get-Content $livePkg -Raw -Encoding UTF8 | ConvertFrom-Json
      $addedDep = 0; $addedBundle = 0
      foreach ($d in $want.dependencies.PSObject.Properties) {
        if (-not $cur.dependencies.PSObject.Properties[$d.Name]) {
          $cur.dependencies | Add-Member -NotePropertyName $d.Name -NotePropertyValue $d.Value -Force
          $addedDep++
        }
      }
      $null = Ensure-ProfileShape $cur
      $null = Ensure-ProfileShape $want
      foreach ($b in $want.dsh.profile.bundles) {
        if ($cur.dsh.profile.bundles -notcontains $b) { $cur.dsh.profile.bundles += $b; $addedBundle++ }
      }
      [System.IO.File]::WriteAllText($livePkg, ($cur | ConvertTo-Json -Depth 8), (New-Object System.Text.UTF8Encoding($false)))
      Act ("package.json: +{0} deps, +{1} bundles" -f $addedDep, $addedBundle)
    }
  }
}
# ---------------------------------------------------------------- 8.6 Host dependencies
# The profile's @deepseek-ai/* tree is only half of a dependency graph. Those
# packages also need ordinary npm dependencies that ship inside app.asar - koffi
# for @deepseek-ai/dsh-win32-process, plus node-pty, sharp, @swc/helpers and
# friends. Without them the first DSH restart after an install leaves every
# shell, write and edit tool dead with "Cannot find module 'koffi'", and the
# only thing that still works is reading files. Restore them here and prove it
# now, at install time, instead of letting the user discover it after a restart.
if ($dshInstalled) {
  $profDir3 = Join-Path $dshHome 'profiles\desktop'
  if (Test-Path (Join-Path $profDir3 'node_modules\@deepseek-ai')) {
    Say "`n=== 8.6 Host dependencies (peer graph) ===" 'Cyan'
    $peerTool = Join-Path $PackageRoot 'extract-peers.cjs'
    if (-not (Test-Path $peerTool)) { $peerTool = Join-Path $payload 'tools\extract-peers.cjs' }
    $peerRestore = Join-Path $PackageRoot 'restore-peers.ps1'
    foreach ($pf in @($peerTool, $peerRestore)) {
      if (Test-Path $pf) {
        $already = Test-Path (Join-Path $profDir3 (Split-Path $pf -Leaf))
        Copy-Item -LiteralPath $pf -Destination $profDir3 -Force -ErrorAction SilentlyContinue
        if (-not $already) { $stateProfileFiles += (Split-Path $pf -Leaf) }
      }
    }
    if (-not $nodeExe) {
      Say '    [warn] DSH''s bundled node runtime was not found, so the peer graph cannot be restored now' 'Yellow'
      Say '    the rest of the install is complete; run restore-peers.ps1 once DSH''s node runtime is available' 'Yellow'
    } elseif (-not (Test-Path $peerRestore)) {
      Say '    restore-peers.ps1 not found next to the installer, skipped' 'Yellow'
    } else {
      # Run it in a child process: the script ends with exit, which would
      # terminate this installer if it ran in-process.
      $psExe = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
      $peerOut = & $psExe -NoProfile -ExecutionPolicy Bypass -File $peerRestore 2>&1
      $peerCode = $LASTEXITCODE
      foreach ($l in $peerOut) {
        $s = ([string]$l).Trim()
        if ($s -match '^"(made|skipped|failed|unpackedMissing|packages)"' -or $s -match '^OK:' -or $s -match '^FAILED:') { Say ("    " + $s) }
      }
      if ($peerCode -ne 0) {
        throw "host dependency self-check failed: the profile cannot load koffi / dsh-win32-process. Run restore-peers.ps1 in $profDir3 and re-run the installer."
      }
      if ($nodeExe) { Act 'host dependency graph restored and loadable (shell / write / edit stay usable after a restart)' }
    }
  } else {
    Say "`n=== 8.6 Host dependencies: skipped (profile has no @deepseek-ai tree) ===" 'Gray'
  }
}
# ---------------------------------------------------------------- 8.9 State
# What this run added, so uninstall removes exactly that and nothing else.
if ($dshInstalled -and -not $SkipConfig) {
  $statePath = Join-Path $dshHome 'profiles\desktop\.dsh-local-llm-state.json'
  try {
    $targetFullPath = ''
    try { $targetFullPath = [System.IO.Path]::GetFullPath($TargetDir).TrimEnd('\') } catch { $targetFullPath = $TargetDir }
    $state = [ordered]@{
      version             = 1
      installedAt         = (Get-Date).ToString('yyyy-MM-ddTHH:mm:sszzz')
      targetDir           = $targetFullPath
      model               = [string]$chosenModel
      pluginsCreated      = @($stateCreatedPlugins)
      pluginsUpgraded     = @($stateUpgradedPlugins)
      depsAdded           = @($stateAddedDeps)
      bundlesAdded        = @($stateAddedBundles)
      profileFilesCreated = @($stateProfileFiles)
    }
    [System.IO.File]::WriteAllText($statePath, ($state | ConvertTo-Json -Depth 6), (New-Object System.Text.UTF8Encoding($false)))
    Act 'install state recorded (uninstall will remove exactly this)'
  } catch {
    Say ('    [warn] could not write the install state file: ' + $_.Exception.Message) 'Yellow'
  }
}

# ---------------------------------------------------------------- 9. Self-test
Say "`n=== 9. Self-test ===" 'Cyan'
if ($NoSelfTest) {
  Say '  self-test skipped (-NoSelfTest)' 'Yellow'
} elseif ($nodeExe -and $chosenModel) {
  Act "starting gateway and self-test (~30 s)"
  try {
    Start-Process -FilePath 'wscript.exe' -ArgumentList ('"' + (Join-Path $gwDst 'launch-gateway.vbs') + '"') -WindowStyle Hidden
    Start-Sleep -Seconds 5
    $selftest = Join-Path $gwDst 'selftest.mjs'
    if (-not (Test-Path $selftest)) {
      Say '    no selftest.mjs in the gateway copy, self-test skipped' 'Yellow'
    } else {
      $job = Start-Job -ScriptBlock {
        param($n, $s)
        & $n $s 2>&1
      } -ArgumentList $nodeExe, $selftest
      if (Wait-Job $job -Timeout 120) {
        Receive-Job $job 2>&1 | Select-Object -Last 8 | ForEach-Object { Say "    $_" }
      } else {
        Say '    self-test timed out (120 s), skipped. Port busy or slow first model load.' 'Yellow'
      }
      Remove-Job $job -Force -ErrorAction SilentlyContinue
    }
  } catch {
    # The self-test is a report, not an install step. If its plumbing breaks - a
    # locked-down shell, a shell whose temp paths disagree, anything - the user
    # still got a complete install and must not see a failure exit code.
    Say ('    [warn] the self-test could not run here: ' + $_.Exception.Message) 'Yellow'
    Say '    the rest of the install is complete. Check the stack by hand with:' 'Yellow'
    Say ('      cd "' + $gwDst + '"') 'Yellow'
    Say ('      "' + $nodeExe + '" selftest.mjs') 'Yellow'
  }
} else {
  Say "  self-test skipped (no model deployed)" 'Yellow'
}

Say "`n=== 10. Final check: only one install? ===" 'Cyan'
$after = @(Find-ExistingInstalls)
Say ("  installs now on disk: {0}" -f $after.Count)
foreach ($p in $after) { Say ("    {0}" -f $p) 'Gray' }
if ($after.Count -gt 1) { Say '  WARNING: more than one copy still exists.' 'Yellow' } else { Say '  OK - exactly one copy.' 'Green' }
Say "`nINSTALL COMPLETE: $TargetDir" 'Green'
Say "  restart DSH and local-gguf / $modelId appears in the model list"
Say ("  uninstall: .\uninstall.ps1 -TargetDir {0} -Apply" -f $TargetDir)
