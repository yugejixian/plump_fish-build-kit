# Suite I: "increment only" - the kit must never damage a profile that already
# has plugins of the user's own.
#
# The dangerous step is install section 8.4: it lays the shipped
# payload\profile-snapshot over the live profile. If that is done with
# robocopy /E it replaces package.json and pnpm-lock.yaml outright, so every
# plugin the user installed themselves silently stops being declared.
#
# This suite builds a fixture snapshot containing a "kit-plugin" and a fake user
# profile containing "user-plugin" plus a same-named file with different bytes,
# then asserts the user's world is intact after -WithPlugins.
$ErrorActionPreference = 'Stop'
$PS51 = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
$ROOT = 'D:\_test'
$MINI = Join-Path $ROOT 'mini'
$REAL = 'D:\新手向大肥鱼build整合'
$LOG  = Join-Path $ROOT 'results-i.txt'
$script:pass = 0; $script:fail = 0; $script:fails = @(); $script:caseName = ''

function Log([string]$m) { Write-Host $m; Add-Content -LiteralPath $LOG -Value $m -Encoding UTF8 }
function Assert-True($c, [string]$m) { if ($c) { $script:pass++; Log ('  PASS  ' + $m) } else { $script:fail++; $script:fails += ('[' + $script:caseName + '] ' + $m); Log ('  FAIL  ' + $m) } }
function Assert-Equal($a, $b, [string]$m) { if ("$a" -eq "$b") { $script:pass++; Log ('  PASS  ' + $m) } else { $script:fail++; $script:fails += ('[' + $script:caseName + '] ' + $m + ' got=[' + $a + '] want=[' + $b + ']'); Log ('  FAIL  ' + $m + '  got=[' + $a + '] want=[' + $b + ']') } }
function Read-Any([string]$p) { if (Test-Path $p) { return [System.IO.File]::ReadAllText($p, [System.Text.Encoding]::UTF8) } else { return $null } }

function Build-Fixture {
  # a snapshot that pretends to be the shipped one
  $snap = Join-Path $MINI 'payload\profile-snapshot'
  if (Test-Path $snap) { Remove-Item $snap -Recurse -Force }
  $nm = Join-Path $snap 'node_modules'
  New-Item -ItemType Directory (Join-Path $nm 'kit-plugin') -Force | Out-Null
  Set-Content -LiteralPath (Join-Path $nm 'kit-plugin\package.json') -Value '{"name":"kit-plugin","version":"1.0.0"}' -Encoding UTF8
  Set-Content -LiteralPath (Join-Path $nm 'kit-plugin\index.js') -Value 'module.exports = "SNAPSHOT VERSION";' -Encoding UTF8
  New-Item -ItemType Directory (Join-Path $nm 'kit-only-lib') -Force | Out-Null
  Set-Content -LiteralPath (Join-Path $nm 'kit-only-lib\package.json') -Value '{"name":"kit-only-lib","version":"1.0.0"}' -Encoding UTF8
  $snapPkg = @'
{
  "name": "dsh-profile-desktop",
  "private": true,
  "dependencies": { "kit-plugin": "1.0.0", "kit-only-lib": "1.0.0" },
  "dsh": { "profile": { "bundles": [ "@deepseek-ai/dsh-base", "kit-plugin", "kit-only-lib" ] } }
}
'@
  Set-Content -LiteralPath (Join-Path $snap 'package.json') -Value $snapPkg -Encoding UTF8
  Set-Content -LiteralPath (Join-Path $snap 'pnpm-lock.yaml') -Value "# SNAPSHOT LOCKFILE`r`nlockfileVersion: '9.0'`r`n" -Encoding UTF8
  Set-Content -LiteralPath (Join-Path $snap 'pnpm-workspace.yaml') -Value "packages:`r`n  - .`r`n" -Encoding UTF8
  # keep the fixture manifest honest
  $null = Run-Ps1 (Join-Path $MINI 'pack.ps1') @('-Apply', '-PackageDir', $MINI) $env:USERPROFILE $MINI
}

function New-Case([string]$n) {
  $script:caseName = $n
  $base = Join-Path (Join-Path $ROOT 'cases') $n
  if (Test-Path $base) { Remove-Item $base -Recurse -Force }
  $fh = Join-Path $base 'home'
  $prof = Join-Path $fh '.dsh\profiles\desktop'
  $nm = Join-Path $prof 'node_modules'
  New-Item -ItemType Directory (Join-Path $nm 'user-plugin') -Force | Out-Null
  # the user already installed their own plugin
  $userPkg = @'
{
  "name": "dsh-profile-desktop",
  "private": true,
  "dependencies": { "user-plugin": "2.0.0" },
  "dsh": { "profile": { "bundles": [ "@deepseek-ai/dsh-base", "user-plugin" ] } }
}
'@
  Set-Content -LiteralPath (Join-Path $prof 'package.json') -Value $userPkg -Encoding UTF8
  Set-Content -LiteralPath (Join-Path $prof 'pnpm-lock.yaml') -Value "# USER LOCKFILE`r`nlockfileVersion: '9.0'`r`n" -Encoding UTF8
  Set-Content -LiteralPath (Join-Path $nm 'user-plugin\package.json') -Value '{"name":"user-plugin","version":"2.0.0"}' -Encoding UTF8
  Set-Content -LiteralPath (Join-Path $nm 'user-plugin\index.js') -Value 'module.exports = "USER VERSION";' -Encoding UTF8
  # a same-named file as the snapshot has, with different bytes: must NOT be overwritten
  New-Item -ItemType Directory (Join-Path $nm 'kit-plugin') -Force | Out-Null
  Set-Content -LiteralPath (Join-Path $nm 'kit-plugin\package.json') -Value '{"name":"kit-plugin","version":"0.9.0"}' -Encoding UTF8
  Set-Content -LiteralPath (Join-Path $nm 'kit-plugin\index.js') -Value 'module.exports = "USER INSTALLED THIS FIRST";' -Encoding UTF8
  # a user directory the snapshot knows nothing about
  New-Item -ItemType Directory (Join-Path $nm 'user-extra') -Force | Out-Null
  Set-Content -LiteralPath (Join-Path $nm 'user-extra\keep.txt') -Value 'keep me' -Encoding UTF8
  # user rows in the DSH config
  Set-Content -LiteralPath (Join-Path $prof 'cordis.patch.yml') -Value ("- id: user-own-setting`r`n  name: `"someone/thing`"`r`n  config:`r`n    keep: me`r`n") -Encoding UTF8 -NoNewline
  Set-Content -LiteralPath (Join-Path $fh '.dsh\AGENTS.md') -Value "# my own rules`r`n- keep these`r`n" -Encoding UTF8 -NoNewline
  return @{ base = $base; fakeHome = $fh; prof = $prof; nm = $nm; target = (Join-Path $base 'inst') }
}
function Run-Ps1([string]$script, [string[]]$argList, [string]$userHome, [string]$workDir) {
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $PS51; $psi.WorkingDirectory = $workDir
  $psi.UseShellExecute = $false; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.CreateNoWindow = $true
  $psi.EnvironmentVariables['USERPROFILE'] = $userHome
  $q = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $script) + $argList
  $psi.Arguments = ($q | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }) -join ' '
  $p = [System.Diagnostics.Process]::Start($psi)
  $o = $p.StandardOutput.ReadToEnd(); $e = $p.StandardError.ReadToEnd(); $p.WaitForExit(300000) | Out-Null
  return @{ code = $p.ExitCode; out = $o; err = $e }
}
function Install-Mini($case, [string[]]$extra) {
  $a = @('-Apply', '-TargetDir', $case.target, '-NoStartup', '-AllowMultiple', '-NoSelfTest', '-Runtime', 'cpu', '-ForceProfile', 'none') + $extra
  $res = Run-Ps1 (Join-Path $MINI 'install.ps1') $a $case.fakeHome $MINI
  if ($res.out -match 'dry-run only') { throw 'HARNESS BUG: dry run' }
  return $res
}

Set-Content -LiteralPath $LOG -Value ('=== I suite ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + ' ===') -Encoding UTF8
Write-Host 'building fixture snapshot...'
Build-Fixture

# ---------------------------------------------------------------- i1: user plugin survives
$c = New-Case 'i1-user-plugin'
$lockBefore = Read-Any (Join-Path $c.prof 'pnpm-lock.yaml')
$pkgBefore = Read-Any (Join-Path $c.prof 'package.json')
$r = Install-Mini $c @('-WithPlugins', '-PluginNames', 'kit-plugin')
Write-Host ('  install exit=' + $r.code)
$pkgAfter = Read-Any (Join-Path $c.prof 'package.json')
$p = $pkgAfter | ConvertFrom-Json
Assert-True ($null -ne $p.dependencies.PSObject.Properties['user-plugin']) 'i1: user-plugin still declared'
Assert-Equal ($p.dependencies.PSObject.Properties['user-plugin'].Value) '2.0.0' 'i1: user-plugin version untouched'
Assert-True (@($p.dsh.profile.bundles) -contains 'user-plugin') 'i1: user-plugin still in bundles'
Assert-True ($null -ne $p.dependencies.PSObject.Properties['kit-plugin']) 'i1: kit-plugin added to dependencies'
Assert-True (@($p.dsh.profile.bundles) -contains 'kit-plugin') 'i1: kit-plugin added to bundles'
Assert-True (@($p.dsh.profile.bundles) -contains '@deepseek-ai/dsh-base') 'i1: base bundle still there'

# ---------------------------------------------------------------- i2: same-named file not overwritten
$idx = Read-Any (Join-Path $c.nm 'kit-plugin\index.js')
Assert-True ($idx -match 'USER INSTALLED THIS FIRST') 'i2: existing file with the same name was NOT overwritten'
$kp = Read-Any (Join-Path $c.nm 'kit-plugin\package.json') | ConvertFrom-Json
Assert-Equal $kp.version '0.9.0' 'i2: existing package version untouched'

# ---------------------------------------------------------------- i3: user-only dir and kit-only dir
Assert-True (Test-Path (Join-Path $c.nm 'user-extra\keep.txt')) 'i3: user directory the snapshot does not know survives'
Assert-True (Test-Path (Join-Path $c.nm 'kit-only-lib\package.json')) 'i3: missing snapshot package was added'
Assert-True (Test-Path (Join-Path $c.nm 'user-plugin\index.js')) 'i3: user plugin files survive'

# ---------------------------------------------------------------- i4: lockfile not replaced
$lockAfter = Read-Any (Join-Path $c.prof 'pnpm-lock.yaml')
if ($lockBefore -ne $lockAfter) {
  Log ('  note: lockfile changed. before=[' + ($lockBefore -replace "`r`n", '|') + '] after=[' + ($lockAfter -replace "`r`n", '|') + ']')
}
Assert-True ($lockAfter -match 'USER LOCKFILE') 'i4: the profile keeps its own pnpm-lock.yaml'

# ---------------------------------------------------------------- i5: config rows and AGENTS.md survive
$cfgg = Read-Any (Join-Path $c.prof 'cordis.patch.yml')
Assert-True ($cfgg -match 'user-own-setting') 'i5: user row in cordis.patch.yml survives'
Assert-Equal ([regex]::Matches($cfgg, '(?m)^[ \t]*#[ \t]*>>>[ \t]*dsh-local-llm').Count) 1 'i5: exactly one BEGIN marker'
$ag = Read-Any (Join-Path $c.fakeHome '.dsh\AGENTS.md')
Assert-True ($ag -match 'my own rules') 'i5: user text in AGENTS.md survives'
Assert-Equal ([regex]::Matches($ag, '(?m)^[ \t]*<!--[ \t]*>>>[ \t]*dsh-local-llm').Count) 1 'i5: exactly one md BEGIN'

# ---------------------------------------------------------------- i6: idempotent with plugins too
$pkgOnce = Read-Any (Join-Path $c.prof 'package.json')
$null = Install-Mini $c @('-WithPlugins', '-PluginNames', 'kit-plugin')
$pkgTwice = Read-Any (Join-Path $c.prof 'package.json')
Assert-Equal $pkgTwice $pkgOnce 'i6: second -WithPlugins run leaves package.json byte-identical'
Assert-True ((Read-Any (Join-Path $c.nm 'kit-plugin\index.js')) -match 'USER INSTALLED THIS FIRST') 'i6: still not overwritten after a second run'

Log ''
# ---------------------------------------------------------------- i7: the first backup is immortal
$c = New-Case 'i7-orig-backup'
$existing = Read-Any (Join-Path $c.prof 'cordis.patch.yml')
Set-Content -LiteralPath (Join-Path $c.prof 'cordis.patch.yml') -Value ("# ORIGINAL-USER-CONFIG`r`n" + $existing) -Encoding UTF8 -NoNewline
$origPath = Join-Path $c.prof 'cordis.patch.yml.orig.bak'
$rollPath = Join-Path $c.prof 'cordis.patch.yml.dsh-llm.bak'
$r = Install-Mini $c @('-RestoreSettings')
Assert-True (Test-Path $origPath) 'i7: first run created .orig.bak'
$origAfter1 = Read-Any $origPath
Assert-True ($origAfter1 -match 'ORIGINAL-USER-CONFIG') 'i7: .orig.bak holds the real pre-kit file'
$r2 = Install-Mini $c @('-RestoreSettings')
$origAfter2 = Read-Any $origPath
Assert-Equal $origAfter2 $origAfter1 'i7: second run did not touch .orig.bak'
$rollAfter2 = Read-Any $rollPath
Assert-True ($rollAfter2 -ne $origAfter2) 'i7: the rolling .dsh-llm.bak moved on (it is not the original any more)'
Assert-True ($rollAfter2 -match 'ui-settings-account') 'i7: the rolling backup is the previous run, as designed'

# ---------------------------------------------------------------- i8: uninstall says what it keeps
$c = New-Case 'i8-uninstall-report'
$null = Install-Mini $c @()
$u = Run-Ps1 (Join-Path $MINI 'uninstall.ps1') @('-TargetDir', $c.target, '-Apply') $c.fakeHome $MINI
Assert-True ($u.code -eq 0) 'i8: uninstall exit 0'
Assert-True (($u.out + $u.err) -match "keeping the profile's node_modules") 'i8: it reports the node_modules it leaves behind'
Assert-True ($u.out -match 'could break plugins this kit did not install') 'i8: it explains why it does not delete them'
Assert-True (Test-Path $c.nm) 'i8: node_modules is still there (shared dependencies are never removed)'
Assert-True (Test-Path (Join-Path $c.nm 'user-plugin\index.js')) 'i8: the user plugin survived uninstall'
Assert-True ((Read-Any (Join-Path $c.nm 'kit-plugin\index.js')) -match 'USER INSTALLED THIS FIRST') 'i8: uninstall did not overwrite anything either'

Log ('=== I RESULT pass=' + $script:pass + ' fail=' + $script:fail + ' ===')
Write-Host ''
Write-Host ('I RESULT pass=' + $script:pass + ' fail=' + $script:fail)
if ($script:fail -gt 0) { Write-Host 'FAILURES:'; $script:fails | ForEach-Object { Write-Host ('  ' + $_) } }
