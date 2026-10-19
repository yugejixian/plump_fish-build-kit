<#
.SYNOPSIS
  Remove what the turnkey installer added: stop the gateway, delete the install
  directory, strip the marker blocks from DSH config, remove the Startup shortcut.

.DESCRIPTION
  Removes only the installer's own footprint:
    * the BEGIN/END marker blocks in profiles\desktop\cordis.patch.yml and
      .dsh\AGENTS.md (a *.dsh-llm.bak backup is left in place)
    * the shortcut in the Startup folder
    * the target directory

  DSH's own files and anything the user wrote stay untouched. Dry-run by
  default; nothing is deleted unless -Apply is given.

.EXAMPLE
  .\uninstall.ps1 -TargetDir "$env:LOCALAPPDATA\dsh-local-llm"
  .\uninstall.ps1 -TargetDir "$env:LOCALAPPDATA\dsh-local-llm" -Apply
#>
[CmdletBinding()]
param(
  [string]$TargetDir = '',
  [switch]$Apply,
  [switch]$KeepFiles,
  [switch]$KeepDshConfig = $false,
  [switch]$KeepStartup,
  # Explicit: also remove the plugins this package ships, when the installed copy
  # still matches the version in the package. Off by default because a plugin the
  # user installed themselves - even the same version - must survive a plain
  # uninstall.
  [switch]$RemovePlugins
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Run from inside an installed folder, uninstall should target THAT folder. The
# old default sent it to %LOCALAPPDATA%\dsh-local-llm, so double-clicking the
# installed copy stripped the config blocks of a different (or absent) install
# while leaving the files where they were.
if ([string]::IsNullOrWhiteSpace($TargetDir)) {
  if (Test-Path (Join-Path $PSScriptRoot 'gateway\config.json')) { $TargetDir = $PSScriptRoot }
  else { $TargetDir = Join-Path $env:LOCALAPPDATA 'dsh-local-llm' }
}

# Whole-line, variant tolerant: older builds wrote longer marker lines (with a
# Chinese tail, with or without the closing -->), and some files carry several
# duplicate BEGIN lines. Matching the whole line collapses all of them, so an
# uninstall still works after an upgrade.
$RE_YML_BEGIN = '(?m)^[ \t]*#[ \t]*>>>[ \t]*dsh-local-llm[ \t]+BEGIN[^\r\n]*\r?\n?'
$RE_YML_END = '(?m)^[ \t]*#[ \t]*<<<[ \t]*dsh-local-llm[ \t]+END[^\r\n]*\r?\n?'
$RE_MD_BEGIN = '(?m)^[ \t]*<!--[ \t]*>>>[ \t]*dsh-local-llm[ \t]+BEGIN[^\r\n]*\r?\n?'
$RE_MD_END = '(?m)^[ \t]*<!--[ \t]*<<<[ \t]*dsh-local-llm[ \t]+END[^\r\n]*\r?\n?'
$dshHome = Join-Path $env:USERPROFILE '.dsh'

function Step($msg) { Write-Host ($(if ($Apply) { "  " } else { "  (dry-run) " }) + $msg) -ForegroundColor $(if ($Apply) { 'Gray' } else { 'Cyan' }) }

# What did the installer actually add? Without this file we refuse to delete any
# plugin folder, because we cannot tell ours from the user's.
$profDir = Join-Path $dshHome 'profiles\desktop'
$statePath = Join-Path $profDir '.dsh-local-llm-state.json'
$state = $null
if (Test-Path $statePath) {
  try { $state = Get-Content $statePath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $state = $null }
}
if ($state -and $state.PSObject.Properties['targetDir']) {
  if (-not (Test-Path $TargetDir) -and (Test-Path ([string]$state.targetDir))) {
    $TargetDir = [string]$state.targetDir
    Write-Host ("  (no install at the given path; using the one recorded at " + $TargetDir + ")") -ForegroundColor Yellow
  }
}

Write-Host "`n=== Uninstalling $TargetDir ===" 'Cyan'

# 1. stop the gateway
try {
  Invoke-RestMethod -Uri 'http://127.0.0.1:8099/gateway/unload' -Method Post -TimeoutSec 10 | Out-Null
  Step 'asked the gateway to unload the model'
} catch { Step 'gateway not running (skipped)' }
$listeners = netstat -ano 2>$null | Select-String ':8099\s+\S+\s+LISTENING\s+(\d+)'
if ($listeners) {
  $procId = [int]([regex]::Match($listeners[0].Line, ':8099\s+\S+\s+LISTENING\s+(\d+)').Groups[1].Value)
  Step "ending gateway process $procId"
  if ($Apply) { Stop-Process -Id $procId -Force -ErrorAction SilentlyContinue }
}

# 2. remove the Startup shortcut
$startupDir = [Environment]::GetFolderPath('Startup')
if ($KeepStartup) {
  Step 'keeping the Startup shortcut (-KeepStartup)'
} elseif ([string]::IsNullOrWhiteSpace($startupDir)) {
  Step 'Startup folder is unknown on this machine (skipped)'
} else {
  $lnk = Join-Path $startupDir 'DSH Local LLM Gateway.lnk'
  if (Test-Path $lnk) { Step "removing Startup shortcut $lnk"; if ($Apply) { Remove-Item $lnk -Force } }
}

# 3. clean DSH config
if (-not $KeepDshConfig) {
  $patchPath = Join-Path $dshHome 'profiles\desktop\cordis.patch.yml'
  if (Test-Path $patchPath) {
    $text = [System.IO.File]::ReadAllText($patchPath, [System.Text.Encoding]::UTF8)
    $before = ([regex]::Matches($text, $RE_YML_BEGIN)).Count
    $region = $RE_YML_BEGIN + '[\s\S]*' + $RE_YML_END
    if ([regex]::IsMatch($text, $region)) {
      Step "removing the marker block from cordis.patch.yml ($before BEGIN line(s) found; .dsh-llm.bak kept)"
      if ($Apply) {
        $new = [regex]::Replace($text, $region, '')
        # a BEGIN that never got its END, plus any stray marker lines
        $new = [regex]::Replace($new, $RE_YML_BEGIN + '[\s\S]*\z', '')
        $new = [regex]::Replace($new, $RE_YML_BEGIN, '')
        $new = [regex]::Replace($new, $RE_YML_END, '')
        $new = [regex]::Replace($new, '(?:[ \t]*\r?\n){3,}', "`r`n`r`n").Trim()
        [System.IO.File]::WriteAllText($patchPath, $new + "`r`n", (New-Object System.Text.UTF8Encoding($false)))
      }
    } else { Step 'no marker block in cordis.patch.yml (skipped)' }
  }
  $agentsPath = Join-Path $dshHome 'AGENTS.md'
  if (Test-Path $agentsPath) {
    $text = [System.IO.File]::ReadAllText($agentsPath, [System.Text.Encoding]::UTF8)
    $region = $RE_MD_BEGIN + '[\s\S]*' + $RE_MD_END
    if ([regex]::IsMatch($text, $region)) {
      Step 'removing the rule block from AGENTS.md'
      if ($Apply) {
        $new = [regex]::Replace($text, $region, '')
        $new = [regex]::Replace($new, $RE_MD_BEGIN + '[\s\S]*\z', '')
        $new = [regex]::Replace($new, $RE_MD_BEGIN, '')
        $new = [regex]::Replace($new, $RE_MD_END, '')
        [System.IO.File]::WriteAllText($agentsPath, $new.TrimEnd() + "`r`n", (New-Object System.Text.UTF8Encoding($false)))
      }
    } else { Step 'no rule block in AGENTS.md (skipped)' }
  }
}

# 4.4 remove only what the installer created in the profile
$nmDir = Join-Path $profDir 'node_modules'
if ($state) {
  $pkgPath = Join-Path $profDir 'package.json'
  $pkg = $null
  if (Test-Path $pkgPath) { try { $pkg = Get-Content $pkgPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $pkg = $null } }
  $removedNames = @()
  $keptNotes = @()

  foreach ($p in @($state.pluginsCreated)) {
    if (-not $p) { continue }
    $name = [string]$p.name
    $dir = Join-Path $nmDir $name
    if (-not $name -or -not (Test-Path $dir)) { continue }
    $cur = ''
    try { $cur = (Get-Content (Join-Path $dir 'package.json') -Raw -Encoding UTF8 | ConvertFrom-Json).version } catch { $cur = '' }
    $want = [string]$p.version
    if ($cur -and $want -and ($cur -ne $want)) {
      $keptNotes += ($name + ' ' + $cur + ' (version changed after we installed it - left alone)')
      continue
    }
    Step ('removing the plugin this kit installed: ' + $name + ' ' + $want)
    if ($Apply) { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
    $removedNames += $name
  }

  foreach ($u in @($state.pluginsUpgraded)) {
    if (-not $u) { continue }
    $name = [string]$u.name
    $pres = Join-Path $nmDir ($name + '.dsh-llm-preserved')
    if ($name -and (Test-Path $pres)) {
      Step ('restoring your own copy of ' + $name + ' (' + [string]$u.from + '), which we had upgraded')
      if ($Apply) {
        $cur = Join-Path $nmDir $name
        if (Test-Path $cur) { Remove-Item -LiteralPath $cur -Recurse -Force -ErrorAction SilentlyContinue }
        try { Rename-Item -LiteralPath $pres -NewName $name -ErrorAction Stop }
        catch { Step ('  [warn] could not restore ' + $name + ': ' + $_.Exception.Message) }
      }
      $removedNames += $name
    } elseif ($name) {
      $keptNotes += ($name + ' ' + [string]$u.to + ' (we upgraded it and kept no copy - left alone)')
    }
  }

  # unregister only the entries this kit added
  if ($pkg) {
    foreach ($d in @($state.depsAdded)) {
      if ($d -and $pkg.dependencies -and $pkg.dependencies.PSObject.Properties[[string]$d]) {
        $pkg.dependencies.PSObject.Properties.Remove([string]$d)
      }
    }
    $hasBundles = $pkg.PSObject.Properties['dsh'] -and $pkg.dsh.PSObject.Properties['profile'] -and $pkg.dsh.profile.PSObject.Properties['bundles']
    if ($hasBundles) {
      foreach ($b in @($state.bundlesAdded)) {
        if ($b -and (@($pkg.dsh.profile.bundles) -contains [string]$b)) {
          $pkg.dsh.profile.bundles = @(@($pkg.dsh.profile.bundles) | Where-Object { $_ -ne [string]$b })
        }
      }
    }
    if ($Apply) {
      [System.IO.File]::WriteAllText($pkgPath, ($pkg | ConvertTo-Json -Depth 8), (New-Object System.Text.UTF8Encoding($false)))
      Step 'package.json: only the entries this kit added were removed'
    }
  }

  foreach ($f in @($state.profileFilesCreated)) {
    if (-not $f) { continue }
    $fp = Join-Path $profDir ([string]$f)
    if (Test-Path $fp) { Step ('removing ' + [string]$f + ' (created by the installer)'); if ($Apply) { Remove-Item -LiteralPath $fp -Force -ErrorAction SilentlyContinue } }
  }

  foreach ($k in $keptNotes) { Step ('  kept: ' + $k) }
  Step ('removed ' + $removedNames.Count + ' plugin(s) that this kit had installed')
  if ($Apply -and (Test-Path $statePath)) { Remove-Item -LiteralPath $statePath -Force -ErrorAction SilentlyContinue }
} elseif (-not $RemovePlugins) {
  Step 'no install state file: no plugin folder will be deleted (it could be yours)'
  Step '  only the marker blocks, the Startup shortcut and the install directory are removed'
  Step '  pass -RemovePlugins to also drop the four plugins this package ships'
}

# 4.5 explicit: remove the four plugins this package ships
if ($RemovePlugins) {
  $nm2 = Join-Path $profDir 'node_modules'
  # Prefer the package next to this script; fall back to the names this kit ships.
  $bundled = @{}
  $pkgPlugins = Join-Path $PSScriptRoot 'payload\plugins'
  if (Test-Path $pkgPlugins) {
    foreach ($d in (Get-ChildItem $pkgPlugins -Directory -ErrorAction SilentlyContinue)) {
      $v = ''
      try { $v = (Get-Content (Join-Path $d.FullName 'package.json') -Raw -Encoding UTF8 | ConvertFrom-Json).version } catch { $v = '' }
      $bundled[$d.Name] = $v
    }
  } else {
    foreach ($n in 'dsh-better-sidebar', 'dsh-context', 'dsh-whale-widget', 'dshmarket') { $bundled[$n] = '' }
  }
  $removedCount = 0
  $keptCount = 0
  foreach ($name in @($bundled.Keys)) {
    $dir = Join-Path $nm2 $name
    if (-not (Test-Path $dir)) { continue }
    $cur = ''
    try { $cur = (Get-Content (Join-Path $dir 'package.json') -Raw -Encoding UTF8 | ConvertFrom-Json).version } catch { $cur = '' }
    $want = [string]$bundled[$name]
    if (-not $want) {
      # We cannot tell which version we ship (uninstall was run away from the
      # package), so deleting would be a guess. Keep it and say why.
      Step ('  kept ' + $name + ' ' + $cur + ' - the package next to this script has no payload\plugins, so the version cannot be verified')
      $keptCount++
      continue
    }
    if ((-not $cur) -or ($cur -ne $want)) {
      Step ('  kept ' + $name + ' ' + $cur + ' (package ships ' + $want + ', so this copy is not ours)')
      $keptCount++
      continue
    }
    Step ('removing bundled plugin ' + $name + ' ' + $cur)
    if ($Apply) { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
    $removedCount++
  }
  # unregister the removed ones
  $pkgPath2 = Join-Path $profDir 'package.json'
  if ((Test-Path $pkgPath2) -and $removedCount -gt 0) {
    $pkg2 = $null
    try { $pkg2 = Get-Content $pkgPath2 -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $pkg2 = $null }
    if ($pkg2) {
      foreach ($name in @($bundled.Keys)) {
        if (-not (Test-Path (Join-Path $nm2 $name))) {
          if ($pkg2.dependencies -and $pkg2.dependencies.PSObject.Properties[$name]) { $pkg2.dependencies.PSObject.Properties.Remove($name) }
          $hasB = $pkg2.PSObject.Properties['dsh'] -and $pkg2.dsh.PSObject.Properties['profile'] -and $pkg2.dsh.profile.PSObject.Properties['bundles']
          if ($hasB -and (@($pkg2.dsh.profile.bundles) -contains $name)) {
            $pkg2.dsh.profile.bundles = @(@($pkg2.dsh.profile.bundles) | Where-Object { $_ -ne $name })
          }
        }
      }
      if ($Apply) { [System.IO.File]::WriteAllText($pkgPath2, ($pkg2 | ConvertTo-Json -Depth 8), (New-Object System.Text.UTF8Encoding($false))) }
    }
  }
  Step ('bundled plugins: removed ' + $removedCount + ', kept ' + $keptCount)
}

# 5. what stays in the profile on purpose
# The kit adds a peer graph and host dependencies to the DSH profile. They are
# shared with every other plugin, so uninstall must not remove them: doing so
# could break plugins this kit never installed. Report the size instead.
$nmLive = Join-Path $dshHome 'profiles\desktop\node_modules'
if (Test-Path $nmLive) {
  $nmMB = [int](((Get-ChildItem $nmLive -Recurse -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum) / 1MB)
  $hasPeer = Test-Path (Join-Path $nmLive '@deepseek-ai')
  Step ("keeping the profile's node_modules ({0} MB) on purpose" -f $nmMB)
  if ($hasPeer) { Step '  it holds the @deepseek-ai peer graph and the host dependencies that every DSH plugin loads' }
  Step '  removing it could break plugins this kit did not install - see RECOVERY.md scenario 4 if you really want a clean profile'
}

# 3.5 We cannot delete the folder we are running from.
# Windows keeps this .ps1 open, so Remove-Item on its parent fails and the folder
# survives. Hand the deletion to a copy of ourselves in TEMP, which can then
# remove everything including this script's original location.
if (-not $KeepFiles) {
  $selfDir = $PSScriptRoot
  $targetFull = ''
  try { $targetFull = [System.IO.Path]::GetFullPath($TargetDir).TrimEnd('\') } catch { $targetFull = '' }
  if (($selfDir -ne '') -and ($targetFull -ne '') -and ($selfDir.TrimEnd('\') -eq $targetFull)) {
    if (-not $Apply) {
      Step 'uninstall.ps1 is running from inside the target; with -Apply it re-launches itself from TEMP to delete the folder'
    } else {
      Step 'uninstall.ps1 is running from inside the target - re-launching from TEMP so the folder can be removed'
      $selfPath = $PSCommandPath
      if ([string]::IsNullOrWhiteSpace($selfPath)) { $selfPath = $MyInvocation.MyCommand.Path }
      $tmpScript = Join-Path $env:TEMP ('dafiyu-uninstall-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.ps1')
      try {
        Copy-Item -LiteralPath $selfPath -Destination $tmpScript -Force -ErrorAction Stop
        $psExe = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
        & $psExe -NoProfile -ExecutionPolicy Bypass -File $tmpScript -Apply -TargetDir $TargetDir -KeepDshConfig -KeepStartup
        $childCode = $LASTEXITCODE
        if ($childCode -eq 0) {
          Write-Host 'Uninstalled. Restart DSH to take effect.' -ForegroundColor Green
        } else {
          Write-Host ('the re-launched uninstall exited ' + $childCode) -ForegroundColor Yellow
        }
        exit $childCode
      } catch {
        Write-Host ('  [warn] could not re-launch from TEMP: ' + $_.Exception.Message) -ForegroundColor Yellow
        Write-Host ('  [warn] delete the folder by hand: ' + $TargetDir) -ForegroundColor Yellow
      }
    }
  }
}

# 4. delete the directory
if (-not $KeepFiles) {
  if (Test-Path $TargetDir) { Step "deleting install directory $TargetDir"; if ($Apply) { Remove-Item $TargetDir -Recurse -Force } }
  else { Step 'install directory does not exist (skipped)' }
}

Write-Host $(if ($Apply) { "`nUninstalled. Restart DSH to take effect.`n" } else { "`ndry-run only, nothing was changed. add -Apply to execute.`n" }) `
  -ForegroundColor $(if ($Apply) { 'Green' } else { 'Cyan' })

# A re-launched copy lives in TEMP and cannot delete itself while running, so
# schedule the removal from a detached shell.
$selfPath = $PSCommandPath
if (-not [string]::IsNullOrWhiteSpace($selfPath)) {
  if ((Split-Path $selfPath -Leaf) -like 'dafiyu-uninstall-*.ps1') {
    try {
      Start-Process -FilePath 'cmd.exe' -ArgumentList ('/c ping -n 3 127.0.0.1 >nul & del /f /q "' + $selfPath + '"') -WindowStyle Hidden
    } catch { }
  }
}