# Suites C-G: restore-settings, install footprint, uninstall, pack edges, path/param abuse.
# Same isolation rules as run-ab.ps1: everything under D:\_test, fake USERPROFILE,
# targets deeper than the installer's 2-level scan, never -PurgeOthers.
$ErrorActionPreference = 'Stop'
$PS51  = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
$ROOT  = 'D:\_test'
$MINI  = Join-Path $ROOT 'mini'
$REAL  = 'D:\新手向大肥鱼build整合'
$LOG   = Join-Path $ROOT 'results-cg.txt'
$script:pass = 0; $script:fail = 0; $script:fails = @(); $script:caseName = ''

function Log([string]$m) { Write-Host $m; Add-Content -LiteralPath $LOG -Value $m -Encoding UTF8 }
function Section([string]$m) { Log ''; Log ('=== ' + $m + ' ===') }
function Assert-True($cond, [string]$msg) {
  if ($cond) { $script:pass++; Log ('  PASS  ' + $msg) } else { $script:fail++; $script:fails += ('[' + $script:caseName + '] ' + $msg); Log ('  FAIL  ' + $msg) }
}
function Assert-Equal($a, $b, [string]$msg) {
  if ("$a" -eq "$b") { $script:pass++; Log ('  PASS  ' + $msg) }
  else { $script:fail++; $sa = [string]$a; $sb = [string]$b; if ($sa.Length -gt 160) { $sa = $sa.Substring(0,160) + '...(len ' + $sa.Length + ')' }; if ($sb.Length -gt 160) { $sb = $sb.Substring(0,160) + '...(len ' + $sb.Length + ')' }; $script:fails += ('[' + $script:caseName + '] ' + $msg + ' got=[' + $sa + '] want=[' + $sb + ']'); Log ('  FAIL  ' + $msg + '  got=[' + $sa + '] want=[' + $sb + ']') }
}
function Get-Markers([string]$t) {
  $y = if ($t) { $t } else { '' }
  return @{
    yB = ([regex]::Matches($y, '(?m)^[ \t]*#[ \t]*>>>[ \t]*dsh-local-llm[ \t]+BEGIN')).Count
    yE = ([regex]::Matches($y, '(?m)^[ \t]*#[ \t]*<<<[ \t]*dsh-local-llm[ \t]+END')).Count
    mB = ([regex]::Matches($y, '(?m)^[ \t]*<!--[ \t]*>>>[ \t]*dsh-local-llm')).Count
    mE = ([regex]::Matches($y, '(?m)^[ \t]*<!--[ \t]*<<<[ \t]*dsh-local-llm')).Count
  }
}
function Get-RowIds([string]$t) { if (-not $t) { return @() }; return @([regex]::Matches($t, '(?m)^- id:[ \t]*(\S+)') | ForEach-Object { $_.Groups[1].Value }) }
function Count-Of($arr, [string]$i) { return @($arr | Where-Object { $_ -eq $i }).Count }

function New-Case([string]$name) {
  $script:caseName = $name
  $base = Join-Path (Join-Path $ROOT 'cases') $name
  if (Test-Path $base) { Remove-Item $base -Recurse -Force }
  $fakeHomeRoot = Join-Path $base 'home'
  $prof = Join-Path $fakeHomeRoot '.dsh\profiles\desktop'
  New-Item -ItemType Directory $prof -Force | Out-Null
  Set-Content -LiteralPath (Join-Path $prof 'package.json') -Value '{"name":"dsh-profile-desktop","private":true,"dependencies":{}}' -Encoding UTF8
  return @{ base = $base; fakeHome = $fakeHomeRoot; prof = $prof; target = (Join-Path $base 'inst') }
}
function Run-Ps1([string]$script, [string[]]$argList, [string]$userHome, [string]$workDir) {
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $PS51
  $psi.WorkingDirectory = $workDir
  $psi.UseShellExecute = $false
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.CreateNoWindow = $true
  $psi.EnvironmentVariables['USERPROFILE'] = $userHome
  $psi.EnvironmentVariables['LOCALAPPDATA'] = (Join-Path $userHome 'AppData\Local')
  $psi.EnvironmentVariables['APPDATA'] = (Join-Path $userHome 'AppData\Roaming')
  $q = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $script) + $argList
  $psi.Arguments = ($q | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }) -join ' '
  $p = [System.Diagnostics.Process]::Start($psi)
  $out = $p.StandardOutput.ReadToEnd()
  $err = $p.StandardError.ReadToEnd()
  $p.WaitForExit(300000) | Out-Null
  return @{ code = $p.ExitCode; out = $out; err = $err }
}
function Install-Mini($case, [string[]]$extra) {
  $a = @('-Apply', '-TargetDir', $case.target, '-NoStartup', '-AllowMultiple', '-NoSelfTest') + $extra
  $res = Run-Ps1 (Join-Path $MINI 'install.ps1') $a $case.fakeHome $MINI
  if ($res.out -match 'dry-run only') { throw 'HARNESS BUG: dry run' }
  return $res
}
function Read-Any([string]$p) { if (Test-Path $p) { return [System.IO.File]::ReadAllText($p, [System.Text.Encoding]::UTF8) } else { return $null } }

New-Item -ItemType Directory $ROOT -Force | Out-Null
Set-Content -LiteralPath $LOG -Value ('=== C-G suite ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + ' ===') -Encoding UTF8
Log ('mini fixture present: ' + (Test-Path (Join-Path $MINI 'manifest.json')))

# ---------------------------------------------------------------- C. restore settings
Section 'C. restore settings (-RestoreSettings)'
$snapDir = Join-Path $MINI 'user-settings'
if (-not (Test-Path $snapDir)) {
  New-Item -ItemType Directory $snapDir -Force | Out-Null
  Copy-Item -LiteralPath (Join-Path $REAL 'user-settings\cordis.patch.yml') -Destination $snapDir -Force
  Copy-Item -LiteralPath (Join-Path $REAL 'user-settings\package.json') -Destination $snapDir -Force
  $null = Run-Ps1 (Join-Path $MINI 'pack.ps1') @('-Apply', '-PackageDir', $MINI) $env:USERPROFILE $MINI
}
$snapshotText = Read-Any (Join-Path $snapDir 'cordis.patch.yml')

# C1 fresh profile
$c = New-Case 'c1-fresh-restore'
$r = Install-Mini $c @('-Runtime', 'cpu', '-ForceProfile', 'none', '-RestoreSettings')
Assert-Equal $r.code 0 'c1: exit 0'
$after = Read-Any (Join-Path $c.prof 'cordis.patch.yml')
$m = Get-Markers $after
Assert-Equal $m.yB 1 'c1: one BEGIN'; Assert-Equal $m.yE 1 'c1: one END'
$ids = Get-RowIds $after
foreach ($want in 'agent-default-model', 'ui-settings-account', 'ui-chat', 'ui-settings') { Assert-Equal (Count-Of $ids $want) 1 ("c1: exactly one $want") }
Assert-True ($after -match '(?m)^\s*purpose:\s*both\s*$') 'c1: purpose both'
Assert-True ($after -match '(?m)^\s*process:\s*detailed\s*$') 'c1: process detailed'
Assert-True ($after -match '(?m)^\s*step:\s*done\s*$') 'c1: step done'
# C2 idempotent
$null = Install-Mini $c @('-Runtime', 'cpu', '-ForceProfile', 'none', '-RestoreSettings')
$after2 = Read-Any (Join-Path $c.prof 'cordis.patch.yml')
Assert-Equal $after2 $after 'c2: second -RestoreSettings is byte-identical'

# C3 the historical bug output: two ui-settings rows, no account row
$c = New-Case 'c3-history-bug'
$broken = @"
- id: agent-default-model
  name: "@deepseek-ai/dsh-agent-default-model"
  config:
    provider: deepseek-account
- id: ui-settings
  name: "@deepseek-ai/dsh-client-ui-settings"
  config:
    enabled: true
- id: ui-chat
  name: "@deepseek-ai/dsh-client-ui-chat"
  config:
    transcriptView: compact
- id: ui-settings
  name: "@deepseek-ai/dsh-client-ui-settings"
  config:
    enabled: true
"@
Set-Content -LiteralPath (Join-Path $c.prof 'cordis.patch.yml') -Value $broken -Encoding UTF8 -NoNewline
$r = Install-Mini $c @('-Runtime', 'cpu', '-ForceProfile', 'none', '-RestoreSettings')
$after = Read-Any (Join-Path $c.prof 'cordis.patch.yml')
$ids = Get-RowIds $after
Assert-Equal (Count-Of $ids 'ui-settings') 1 'c3: duplicate ui-settings collapsed to one'
Assert-Equal (Count-Of $ids 'ui-settings-account') 1 'c3: missing account row restored'
Assert-True ($after -match '(?m)^\s*purpose:\s*both\s*$') 'c3: onboarding answers restored'
$mu = Get-Markers $after
Assert-Equal $mu.yB 1 'c3: one BEGIN'; Assert-Equal $mu.yE 1 'c3: one END'

# C4 user rows survive
$c = New-Case 'c4-user-rows'
$seed = @"
- id: my-own-thing
  name: "someone/else"
  config:
    keep: me
- id: ui-chat
  name: "@deepseek-ai/dsh-client-ui-chat"
  config:
    transcriptView: compact
"@
Set-Content -LiteralPath (Join-Path $c.prof 'cordis.patch.yml') -Value $seed -Encoding UTF8 -NoNewline
$null = Install-Mini $c @('-Runtime', 'cpu', '-ForceProfile', 'none', '-RestoreSettings')
$after = Read-Any (Join-Path $c.prof 'cordis.patch.yml')
$ids = Get-RowIds $after
Assert-Equal (Count-Of $ids 'my-own-thing') 1 'c4: unknown user row preserved'
Assert-True ($after -match 'keep: me') 'c4: user row body intact'
Assert-Equal (Count-Of $ids 'ui-chat') 1 'c4: ui-chat replaced, not duplicated'

# ---------------------------------------------------------------- D. install footprint
Section 'D. install footprint'
$c = New-Case 'd1-footprint'
$r = Install-Mini $c @('-Runtime', 'cpu', '-ForceProfile', 'none')
Assert-Equal $r.code 0 'd1: exit 0'
Assert-True (Test-Path (Join-Path $c.target 'gateway\config.json')) 'd1: gateway config written'
Assert-True (Test-Path (Join-Path $c.target 'llama_cpp_cpu\llama-server.exe')) 'd1: cpu runtime copied'
Assert-True (-not (Test-Path (Join-Path $c.target 'llama_cpp'))) 'd1: no cuda dir when backend is cpu'
$cfg = Read-Any (Join-Path $c.target 'gateway\config.json') | ConvertFrom-Json
Assert-True ($cfg.llamaServer.exe -like '*llama_cpp_cpu*') 'd1: config points at the cpu runtime'
$argLine = ($cfg.llamaServer.args -join ' ')
Assert-True ($argLine -match '-ngl\s+0') 'd1: -ngl 0 present for cpu'
Assert-True ($argLine -match '-t\s+\d+') 'd1: -t <cores> present for cpu'
Assert-True (-not ($argLine -match '--fit')) 'd1: no --fit for cpu'
$c1 = Read-Any (Join-Path $c.target 'gateway\config.json')
$null = Install-Mini $c @('-Runtime', 'cpu', '-ForceProfile', 'none')
$c2 = Read-Any (Join-Path $c.target 'gateway\config.json')
Assert-Equal $c2 $c1 'd2: second install leaves config.json identical'
$dirs = @(Get-ChildItem $c.target -Directory | ForEach-Object { $_.Name } | Sort-Object)
Assert-Equal (Count-Of $dirs 'llama_cpp_cpu') 1 'd2: exactly one runtime dir'
$r = Install-Mini $c @('-Runtime', 'vulkan', '-ForceProfile', 'none')
Assert-True ($r.code -ne 0) 'd4: forcing a runtime that is not in the package fails'
Assert-True (($r.err + $r.out) -match 'no vulkan runtime') 'd4: error names the missing runtime'

# ---------------------------------------------------------------- E. uninstall
Section 'E. uninstall'
$c = New-Case 'e1-uninstall'
$seed = "- id: my-own-thing`r`n  name: `"someone/else`"`r`n  config:`r`n    keep: me`r`n"
Set-Content -LiteralPath (Join-Path $c.prof 'cordis.patch.yml') -Value $seed -Encoding UTF8 -NoNewline
$null = Install-Mini $c @('-Runtime', 'cpu', '-ForceProfile', 'none')
Assert-True (Test-Path $c.target) 'e1: installed'
$before = Read-Any (Join-Path $c.prof 'cordis.patch.yml')
# dry run first: nothing may change
$dry = Run-Ps1 (Join-Path $MINI 'uninstall.ps1') @('-TargetDir', $c.target) $c.fakeHome $MINI
Assert-Equal $dry.code 0 'e1: uninstall dry-run exit 0'
Assert-True (Test-Path $c.target) 'e1: dry-run kept the directory'
Assert-Equal (Read-Any (Join-Path $c.prof 'cordis.patch.yml')) $before 'e1: dry-run kept the config'
# real uninstall
$real = Run-Ps1 (Join-Path $MINI 'uninstall.ps1') @('-TargetDir', $c.target, '-Apply') $c.fakeHome $MINI
Assert-Equal $real.code 0 'e1: uninstall -Apply exit 0'
Assert-True (-not (Test-Path $c.target)) 'e1: install directory removed'
$after = Read-Any (Join-Path $c.prof 'cordis.patch.yml')
$m = Get-Markers $after
Assert-Equal $m.yB 0 'e1: our block removed from cordis.patch.yml'
Assert-Equal (Count-Of (Get-RowIds $after) 'my-own-thing') 1 'e1: user row survived uninstall'
$agents = Read-Any (Join-Path $c.fakeHome '.dsh\AGENTS.md')
$ma = Get-Markers $agents
Assert-Equal $ma.mB 0 'e1: rule block removed from AGENTS.md'
# keep files
$c = New-Case 'e2-keepfiles'
$null = Install-Mini $c @('-Runtime', 'cpu', '-ForceProfile', 'none')
$k = Run-Ps1 (Join-Path $MINI 'uninstall.ps1') @('-TargetDir', $c.target, '-Apply', '-KeepFiles') $c.fakeHome $MINI
Assert-True (Test-Path $c.target) 'e2: -KeepFiles left the directory'
$after = Read-Any (Join-Path $c.prof 'cordis.patch.yml')
Assert-Equal (Get-Markers $after).yB 0 'e2: block still removed with -KeepFiles'
# uninstall when nothing is there
$c = New-Case 'e3-nothing'
$n = Run-Ps1 (Join-Path $MINI 'uninstall.ps1') @('-TargetDir', $c.target, '-Apply') $c.fakeHome $MINI
Assert-Equal $n.code 0 'e3: uninstall of a non-existent target is a clean no-op'

# ---------------------------------------------------------------- F. pack edges
Section 'F. pack.ps1 edges'
$c = New-Case 'f1-pack'
Copy-Item -LiteralPath $MINI -Destination (Join-Path $c.base 'pkg') -Recurse -Force
$pkg = Join-Path $c.base 'pkg'
$manPath = Join-Path $pkg 'manifest.json'
$h0 = (Get-FileHash $manPath -Algorithm SHA256).Hash
$r1 = Run-Ps1 (Join-Path $pkg 'pack.ps1') @('-Only', 'does-not-exist', '-PackageDir', $pkg) $c.fakeHome $pkg
Assert-Equal $r1.code 0 'f1: -Only with an unknown prefix exits 0'
Assert-Equal ((Get-FileHash $manPath -Algorithm SHA256).Hash) $h0 'f1: dry run left the manifest untouched'
$r2 = Run-Ps1 (Join-Path $pkg 'pack.ps1') @('-Apply', '-Only', 'does-not-exist', '-PackageDir', $pkg) $c.fakeHome $pkg
Assert-Equal $r2.code 0 'f2: -Apply -Only unknown exits 0'
Assert-True (($r2.out -match '0 selected') -or ($r2.out -match 'left untouched')) 'f2: it reports nothing selected'
$r3 = Run-Ps1 (Join-Path $pkg 'pack.ps1') @('-Apply', '-PackageDir', $pkg, '-OutDir', $pkg) $c.fakeHome $pkg
Assert-True ($r3.code -ne 0) 'f3: OutDir == PackageDir is refused'
$nonEmpty = Join-Path $c.base 'notempty'
New-Item -ItemType Directory $nonEmpty -Force | Out-Null
Set-Content -LiteralPath (Join-Path $nonEmpty 'x.txt') -Value 'x'
$r4 = Run-Ps1 (Join-Path $pkg 'pack.ps1') @('-Apply', '-PackageDir', $pkg, '-OutDir', $nonEmpty) $c.fakeHome $pkg
Assert-True ($r4.code -ne 0) 'f4: non-empty OutDir is refused'
$r5 = Run-Ps1 (Join-Path $pkg 'pack.ps1') @('-Apply', '-Only', 'gateway', '-PackageDir', $pkg, '-RunVerify') $c.fakeHome $pkg
Assert-Equal $r5.code 0 'f5: -Only gateway + -RunVerify passes'
Remove-Item -LiteralPath $manPath -Force
$r6 = Run-Ps1 (Join-Path $pkg 'pack.ps1') @('-Apply', '-PackageDir', $pkg) $c.fakeHome $pkg
Assert-Equal $r6.code 0 'f6: missing manifest is rebuilt from scratch'
Assert-True (Test-Path $manPath) 'f6: manifest recreated'

# ---------------------------------------------------------------- G. path / param abuse
Section 'G. path and parameter abuse'
$c = New-Case 'g1-spaces'
$odd = Join-Path $c.base '带 app 的 目录\inst'
$r = Run-Ps1 (Join-Path $MINI 'install.ps1') @('-Apply', '-TargetDir', $odd, '-NoStartup', '-AllowMultiple', '-NoSelfTest', '-Runtime', 'cpu', '-ForceProfile', 'none') $c.fakeHome $MINI
Assert-Equal $r.code 0 'g1: install into a path with spaces and CJK succeeds'
Assert-True (Test-Path (Join-Path $odd 'gateway\config.json')) 'g1: files landed in the odd path'
$c = New-Case 'g2-bad-runtime'
$r = Run-Ps1 (Join-Path $MINI 'install.ps1') @('-Apply', '-TargetDir', $c.target, '-NoStartup', '-AllowMultiple', '-NoSelfTest', '-Runtime', 'bogus', '-ForceProfile', 'none') $c.fakeHome $MINI
Assert-True ($r.code -ne 0) 'g2: -Runtime bogus is rejected'
Assert-True (($r.err + $r.out) -match 'Runtime must be') 'g2: the error explains the allowed values'
$c = New-Case 'g3-bad-profile'
$r = Run-Ps1 (Join-Path $MINI 'install.ps1') @('-Apply', '-TargetDir', $c.target, '-NoStartup', '-AllowMultiple', '-NoSelfTest', '-Runtime', 'cpu', '-ForceProfile', '7b') $c.fakeHome $MINI
Assert-True ($r.code -ne 0) 'g3: -ForceProfile 7b is rejected'
$c = New-Case 'g4-missing-drive'
$r = Run-Ps1 (Join-Path $MINI 'install.ps1') @('-Apply', '-TargetDir', 'Z:\nowhere\inst', '-NoStartup', '-AllowMultiple', '-NoSelfTest', '-Runtime', 'cpu', '-ForceProfile', 'none') $c.fakeHome $MINI
Assert-True ($r.code -ne 0) 'g4: a target on a missing drive fails cleanly'
Assert-True (-not (Test-Path $c.target)) 'g4: nothing was created in the sandbox'
$c = New-Case 'g5-target-is-file'
$f = Join-Path $c.base 'iamafile'
Set-Content -LiteralPath $f -Value 'x'
$r = Run-Ps1 (Join-Path $MINI 'install.ps1') @('-Apply', '-TargetDir', $f, '-NoStartup', '-AllowMultiple', '-NoSelfTest', '-Runtime', 'cpu', '-ForceProfile', 'none') $c.fakeHome $MINI
Assert-True ($r.code -ne 0) 'g5: target that is a regular file fails cleanly'
$c = New-Case 'g6-readonly-config'
$null = Install-Mini $c @('-Runtime', 'cpu', '-ForceProfile', 'none')
$cfgp = Join-Path $c.target 'gateway\config.json'
$good = Read-Any $cfgp
(Get-Item $cfgp).IsReadOnly = $true
$r = Install-Mini $c @('-Runtime', 'cpu', '-ForceProfile', 'none')
(Get-Item $cfgp).IsReadOnly = $false
Log ('  (read-only config run exit=' + $r.code + ')')
Assert-Equal (Read-Any $cfgp) $good 'g6: read-only config is not corrupted'
try { $null = Read-Any $cfgp | ConvertFrom-Json; Assert-True $true 'g6: config is still valid JSON' } catch { Assert-True $false ('g6: config no longer parses: ' + $_.Exception.Message) }

Log ''
Log ('=== C-G RESULT pass=' + $script:pass + ' fail=' + $script:fail + ' ===')
Write-Host ''
Write-Host ('C-G RESULT pass=' + $script:pass + ' fail=' + $script:fail)
if ($script:fail -gt 0) { Write-Host 'FAILURES:'; $script:fails | ForEach-Object { Write-Host ('  ' + $_) } }
