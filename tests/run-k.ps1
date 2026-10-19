# Suite K: uninstall must remove exactly what the installer added.
#
# The user's rule: uninstalling may never remove a plugin they installed
# themselves - not even the same or a newer version of one we ship - and may
# never touch unrelated files.
#
# Fixture:
#   payload ships  kit-a 1.0.0, kit-b 1.0.0, kit-c 2.0.0
#   profile has    kit-a 3.0.0 (user's, newer), kit-c 1.0.0 (user's, older),
#                  user-x (unrelated), deps + bundles declaring them
# Expected after install:  kit-a kept at 3.0.0, kit-b created, kit-c upgraded to 2.0.0
# Expected after uninstall: kit-a 3.0.0 intact, user-x intact, kit-b removed,
#                           kit-c restored to 1.0.0, unrelated files intact
$ErrorActionPreference = 'Stop'
$PS51 = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
$ROOT = 'D:\_test'
$MINI = Join-Path $ROOT 'mini'
$LOG = Join-Path $ROOT 'results-k.txt'
$script:pass = 0; $script:fail = 0; $script:fails = @()
function Log([string]$s) { Write-Host $s; Add-Content -LiteralPath $LOG -Value $s -Encoding UTF8 }
function A($c, [string]$m) { if ($c) { $script:pass++; Log ('  PASS  ' + $m) } else { $script:fail++; $script:fails += $m; Log ('  FAIL  ' + $m) } }

function Run-Ps1([string]$script, [string[]]$argList, [string]$userHome, [string]$workDir, [int]$timeoutSec = 300) {
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $PS51; $psi.WorkingDirectory = $workDir
  $psi.UseShellExecute = $false; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.CreateNoWindow = $true
  $psi.EnvironmentVariables['USERPROFILE'] = $userHome
  $q = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $script) + $argList
  $psi.Arguments = ($q | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }) -join ' '
  $p = [System.Diagnostics.Process]::Start($psi)
  $o = $p.StandardOutput.ReadToEndAsync(); $e = $p.StandardError.ReadToEndAsync()
  $null = $p.WaitForExit($timeoutSec * 1000)
  return @{ code = $p.ExitCode; out = $o.Result; err = $e.Result }
}

Set-Content -LiteralPath $LOG -Value ('=== K suite ' + (Get-Date -Format 'HH:mm:ss') + ' ===') -Encoding UTF8

# ---------------------------------------------------------------- fixture
$pluginRoot = Join-Path $MINI 'payload\plugins'
if (Test-Path $pluginRoot) { Remove-Item $pluginRoot -Recurse -Force }
foreach ($spec in @(@{ n = 'kit-a'; v = '1.0.0' }, @{ n = 'kit-b'; v = '1.0.0' }, @{ n = 'kit-c'; v = '2.0.0' })) {
  $d = Join-Path $pluginRoot $spec.n
  New-Item -ItemType Directory $d -Force | Out-Null
  Set-Content -LiteralPath (Join-Path $d 'package.json') -Value ("{`"name`":`"" + $spec.n + "`",`"version`":`"" + $spec.v + "`"}") -Encoding UTF8
  Set-Content -LiteralPath (Join-Path $d 'index.js') -Value ('module.exports = "BUNDLED-' + $spec.v + '";') -Encoding UTF8
}
$null = Run-Ps1 (Join-Path $MINI 'pack.ps1') @('-Apply', '-PackageDir', $MINI) $env:USERPROFILE $MINI

$base = Join-Path $ROOT 'cases\k-uninstall'
if (Test-Path $base) { Remove-Item $base -Recurse -Force }
$fh = Join-Path $base 'home'
$prof = Join-Path $fh '.dsh\profiles\desktop'
$nm = Join-Path $prof 'node_modules'
New-Item -ItemType Directory $nm -Force | Out-Null
# the user's own plugins
foreach ($spec in @(@{ n = 'kit-a'; v = '3.0.0'; m = 'USER-3.0.0' }, @{ n = 'kit-c'; v = '1.0.0'; m = 'USER-1.0.0' }, @{ n = 'user-x'; v = '9.9.9'; m = 'UNRELATED' })) {
  $d = Join-Path $nm $spec.n
  New-Item -ItemType Directory $d -Force | Out-Null
  Set-Content -LiteralPath (Join-Path $d 'package.json') -Value ("{`"name`":`"" + $spec.n + "`",`"version`":`"" + $spec.v + "`"}") -Encoding UTF8
  Set-Content -LiteralPath (Join-Path $d 'index.js') -Value ('module.exports = "' + $spec.m + '";') -Encoding UTF8
}
$userPkg = @'
{
  "name": "dsh-profile-desktop",
  "private": true,
  "dependencies": { "kit-a": "^3.0.0", "kit-c": "^1.0.0", "user-x": "9.9.9" },
  "dsh": { "profile": { "bundles": [ "kit-a", "kit-c", "user-x" ] } }
}
'@
Set-Content -LiteralPath (Join-Path $prof 'package.json') -Value $userPkg -Encoding UTF8
# unrelated file the installer must never touch
Set-Content -LiteralPath (Join-Path $prof 'my-own-notes.md') -Value 'do not delete me' -Encoding UTF8
$target = Join-Path $base 'inst'

# ---------------------------------------------------------------- install
$r = Run-Ps1 (Join-Path $MINI 'install.ps1') @('-Apply','-TargetDir',$target,'-NoStartup','-NoSelfTest','-Runtime','cpu','-ForceProfile','none','-AllowMultiple','-WithPlugins','-PluginNames','kit-a,kit-b,kit-c') $fh $MINI
Log ('  install exit=' + $r.code)
A ($r.code -eq 0) 'K1 install exit 0'
A ((Get-Content (Join-Path $nm 'kit-a\index.js') -Raw) -match 'USER-3.0.0') 'K1 user kit-a 3.0.0 untouched (never downgraded)'
A ((Get-Content (Join-Path $nm 'kit-b\index.js') -Raw) -match 'BUNDLED-1.0.0') 'K1 kit-b (new) installed'
A ((Get-Content (Join-Path $nm 'kit-c\index.js') -Raw) -match 'BUNDLED-2.0.0') 'K1 kit-c upgraded 1.0.0 -> 2.0.0'
A (Test-Path (Join-Path $nm 'kit-c.dsh-llm-preserved')) 'K1 the user copy of kit-c was preserved before the upgrade'
$stateFile = Join-Path $prof '.dsh-local-llm-state.json'
A (Test-Path $stateFile) 'K1 state file written'
$st = if (Test-Path $stateFile) { Get-Content $stateFile -Raw -Encoding UTF8 | ConvertFrom-Json } else { $null }
A ($st -and (@($st.pluginsCreated) | Where-Object { $_.name -eq 'kit-b' })) 'K1 state records kit-b as created by us'
A ($st -and (@($st.pluginsUpgraded) | Where-Object { $_.name -eq 'kit-c' })) 'K1 state records kit-c as upgraded by us'
A ($st -and (@($st.pluginsCreated | ForEach-Object { $_.name }) -notcontains 'kit-a')) 'K1 kit-a is NOT recorded as ours'
A ($st -and ([string]$st.targetDir).TrimEnd('\') -eq $target.TrimEnd('\')) 'K1 state records the target dir'

# ---------------------------------------------------------------- uninstall
$u = Run-Ps1 (Join-Path $MINI 'uninstall.ps1') @('-Apply','-TargetDir',$target) $fh $MINI
Log ('  uninstall exit=' + $u.code)
A ($u.code -eq 0) 'K2 uninstall exit 0'
A (-not (Test-Path $target)) 'K2 install directory removed'
A (-not (Test-Path (Join-Path $nm 'kit-b'))) 'K2 the plugin WE installed (kit-b) is gone'
A ((Get-Content (Join-Path $nm 'kit-a\index.js') -Raw) -match 'USER-3.0.0') 'K2 user kit-a 3.0.0 survived the uninstall'
A ((Get-Content (Join-Path $nm 'kit-c\index.js') -Raw) -match 'USER-1.0.0') 'K2 user kit-c restored to their 1.0.0'
A (-not (Test-Path (Join-Path $nm 'kit-c.dsh-llm-preserved'))) 'K2 the preserved copy was moved back, not left behind'
A ((Get-Content (Join-Path $nm 'user-x\index.js') -Raw) -match 'UNRELATED') 'K2 unrelated user plugin untouched'
A (Test-Path (Join-Path $prof 'my-own-notes.md')) 'K2 unrelated profile file untouched'
$after = Get-Content (Join-Path $prof 'package.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$deps = @($after.dependencies.PSObject.Properties | ForEach-Object { $_.Name })
A ($deps -contains 'kit-a' -and $deps -contains 'kit-c' -and $deps -contains 'user-x') 'K2 user dependency entries kept'
A ($deps -notcontains 'kit-b') 'K2 only the entry we added was removed'
$bundles = @($after.dsh.profile.bundles)
A (($bundles -contains 'kit-a') -and ($bundles -contains 'user-x')) 'K2 user bundle entries kept'
A ($bundles -notcontains 'kit-b') 'K2 only the bundle we added was removed'
A (-not (Test-Path $stateFile)) 'K2 state file cleaned up'
$patchText = if (Test-Path (Join-Path $prof 'cordis.patch.yml')) { [System.IO.File]::ReadAllText((Join-Path $prof 'cordis.patch.yml'), [System.Text.Encoding]::UTF8) } else { '' }
A (([regex]::Matches($patchText, '(?m)^[ \t]*#[ \t]*>>>[ \t]*dsh-local-llm')).Count -eq 0) 'K2 config marker block removed'

# ---------------------------------------------------------------- no state file -> never delete plugins
$base2 = Join-Path $ROOT 'cases\k-nostate'
if (Test-Path $base2) { Remove-Item $base2 -Recurse -Force }
$fh2 = Join-Path $base2 'home'
$prof2 = Join-Path $fh2 '.dsh\profiles\desktop'
$nm2 = Join-Path $prof2 'node_modules'
New-Item -ItemType Directory (Join-Path $nm2 'kit-a') -Force | Out-Null
Set-Content -LiteralPath (Join-Path $nm2 'kit-a\package.json') -Value '{"name":"kit-a","version":"1.0.0"}' -Encoding UTF8
Set-Content -LiteralPath (Join-Path $prof2 'package.json') -Value '{"name":"p","dependencies":{},"dsh":{"profile":{"bundles":[]}}}' -Encoding UTF8
$t2 = Join-Path $base2 'inst'
$null = Run-Ps1 (Join-Path $MINI 'install.ps1') @('-Apply','-TargetDir',$t2,'-NoStartup','-NoSelfTest','-Runtime','cpu','-ForceProfile','none','-AllowMultiple') $fh2 $MINI
Remove-Item (Join-Path $prof2 '.dsh-local-llm-state.json') -Force -ErrorAction SilentlyContinue
$u2 = Run-Ps1 (Join-Path $MINI 'uninstall.ps1') @('-Apply','-TargetDir',$t2) $fh2 $MINI
A ($u2.code -eq 0) 'K3 uninstall without a state file still exits 0'
A (Test-Path (Join-Path $nm2 'kit-a')) 'K3 without the record, no plugin folder is deleted'
A (-not (Test-Path $t2)) 'K3 the install directory is still removed'
A (($u2.out + $u2.err) -match 'no install state file') 'K3 it says why it left the plugins alone'

Remove-Item $pluginRoot -Recurse -Force -ErrorAction SilentlyContinue
$null = Run-Ps1 (Join-Path $MINI 'pack.ps1') @('-Apply', '-PackageDir', $MINI) $env:USERPROFILE $MINI

Log ''
Log ('=== K RESULT pass=' + $script:pass + ' fail=' + $script:fail + ' ===')
Write-Host ('K RESULT pass=' + $script:pass + ' fail=' + $script:fail)
if ($script:fail -gt 0) { $script:fails | ForEach-Object { Write-Host ('  ' + $_) } }
