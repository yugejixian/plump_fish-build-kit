# Monkey cases M15-M18 only, with the deadlock-free Run-Ps1.
# (M15 hung the first suite because stdout was drained before stderr; a truncated
# manifest makes PowerShell emit a multi-KB error record, which filled the stderr
# pipe buffer and blocked the child forever.)
$ErrorActionPreference = 'Stop'
$PS51 = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
$ROOT = 'D:\_test'
$MINI = Join-Path $ROOT 'mini'
$REAL = 'D:\新手向大肥鱼build整合'
$M = Join-Path $ROOT 'm2'
$LOG = Join-Path $ROOT 'results-m2.txt'
$rows = @()
function Log([string]$s) { Add-Content -LiteralPath $LOG -Value $s -Encoding UTF8; Write-Host $s }
function New-Lab([string]$name) {
  $base = Join-Path $M $name
  if (Test-Path $base) { Remove-Item $base -Recurse -Force }
  $fh = Join-Path $base 'home'
  $prof = Join-Path $fh '.dsh\profiles\desktop'
  New-Item -ItemType Directory $prof -Force | Out-Null
  Set-Content -LiteralPath (Join-Path $prof 'package.json') -Value '{"name":"p","dependencies":{}}' -Encoding UTF8
  return @{ base = $base; fakeHome = $fh; prof = $prof; target = (Join-Path $base 'inst') }
}
function Run-Ps1([string]$script, [string[]]$argList, [string]$userHome, [string]$workDir, [int]$timeoutSec = 900) {
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $PS51; $psi.WorkingDirectory = $workDir
  $psi.UseShellExecute = $false; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.CreateNoWindow = $true
  $psi.EnvironmentVariables['USERPROFILE'] = $userHome
  $q = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $script) + $argList
  $psi.Arguments = ($q | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }) -join ' '
  $p = [System.Diagnostics.Process]::Start($psi)
  $outTask = $p.StandardOutput.ReadToEndAsync()
  $errTask = $p.StandardError.ReadToEndAsync()
  if (-not $p.WaitForExit($timeoutSec * 1000)) {
    try { $p.Kill() } catch { }
    return @{ code = -99; out = 'TIMEOUT'; err = 'TIMEOUT' }
  }
  return @{ code = $p.ExitCode; out = $outTask.Result; err = $errTask.Result }
}
function Record([string]$name, [string]$outcome, [string]$verdict) {
  $script:rows += [pscustomobject]@{ case = $name; outcome = $outcome; verdict = $verdict }
  Log ("  [{0}] {1}  -> {2}" -f $verdict, $name, $outcome)
}
function Config-State([string]$prof) {
  $f = Join-Path $prof 'cordis.patch.yml'
  if (-not (Test-Path $f)) { return 'missing' }
  $t = [System.IO.File]::ReadAllText($f, [System.Text.Encoding]::UTF8)
  return ("markers={0}/{1}" -f ([regex]::Matches($t, '(?m)^[ \t]*#[ \t]*>>>[ \t]*dsh-local-llm')).Count, ([regex]::Matches($t, '(?m)^[ \t]*#[ \t]*<<<[ \t]*dsh-local-llm')).Count)
}

Set-Content -LiteralPath $LOG -Value ('=== M15-M18 ' + (Get-Date -Format 'HH:mm:ss') + ' ===') -Encoding UTF8

# ---------------------------------------------------------------- M15: truncated manifest
$c = New-Lab 'm15-manifest-truncated'
$pkg = Join-Path $c.base 'pkg'
Copy-Item -LiteralPath $MINI -Destination $pkg -Recurse -Force
$man = Join-Path $pkg 'manifest.json'
$t = [System.IO.File]::ReadAllText($man)
[System.IO.File]::WriteAllText($man, $t.Substring(0, [int]($t.Length / 2)), (New-Object System.Text.UTF8Encoding($false)))
$outDir = Join-Path $c.base 'out'
$r = Run-Ps1 (Join-Path $pkg 'install.ps1') @('-Apply','-TargetDir',$outDir,'-NoStartup','-AllowMultiple','-NoSelfTest','-Runtime','cpu','-ForceProfile','none','-SkipConfig') $c.fakeHome $pkg 300
$err1 = if ($r.err.Trim()) { (($r.err -split "`r?`n") | Where-Object { $_.Trim() } | Select-Object -First 1) } else { '-' }
Log ("  stderr: " + $err1)
Record 'M15 manifest truncated' ("exit=" + $r.code + " targetCreated=" + (Test-Path $outDir)) $(if (($r.code -ne 0) -and (-not (Test-Path $outDir))) { 'refused-clean' } elseif ($r.code -ne 0) { 'refused-after-writing' } else { 'SURVIVED' })

# ---------------------------------------------------------------- M16: payload file deleted
$c = New-Lab 'm16-payload-missing'
$pkg = Join-Path $c.base 'pkg'
Copy-Item -LiteralPath $MINI -Destination $pkg -Recurse -Force
$victim = Join-Path $pkg 'payload\gateway\gateway.js'
Log ("  victim exists before: " + (Test-Path $victim))
Remove-Item -LiteralPath $victim -Force
$outDir = Join-Path $c.base 'out'
$r = Run-Ps1 (Join-Path $pkg 'install.ps1') @('-Apply','-TargetDir',$outDir,'-NoStartup','-AllowMultiple','-NoSelfTest','-Runtime','cpu','-ForceProfile','none','-SkipConfig') $c.fakeHome $pkg 300
Record 'M16 one payload file deleted' ("exit=" + $r.code + " targetCreated=" + (Test-Path $outDir)) $(if (($r.code -ne 0) -and (-not (Test-Path $outDir))) { 'refused-clean' } elseif ($r.code -ne 0) { 'refused-after-writing' } else { 'SURVIVED' })

# ---------------------------------------------------------------- M17: two installs racing
$c = New-Lab 'm17-race'
$procs = @()
foreach ($i in 1..2) {
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $PS51
  $psi.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path $REAL 'install.ps1') + '" -Apply -TargetDir "' + $c.target + '" -NoStartup -AllowMultiple -NoSelfTest -ForceProfile none'
  $psi.UseShellExecute = $false; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.CreateNoWindow = $true
  $psi.WorkingDirectory = $REAL
  $psi.EnvironmentVariables['USERPROFILE'] = $c.fakeHome
  $procs += @{ p = [System.Diagnostics.Process]::Start($psi); outTask = $null; errTask = $null }
}
# start draining immediately (both children run concurrently)
foreach ($rec in $procs) { $rec.outTask = $rec.p.StandardOutput.ReadToEndAsync(); $rec.errTask = $rec.p.StandardError.ReadToEndAsync() }
$codes = @()
foreach ($rec in $procs) { if (-not $rec.p.WaitForExit(900000)) { try { $rec.p.Kill() } catch { } ; $codes += -99 } else { $codes += $rec.p.ExitCode } }
$st = Config-State $c.prof
$copies = @(Get-ChildItem 'D:\DSH-LocalLLM' -Directory -EA SilentlyContinue).Count
Record 'M17 two installs racing' ("exits=" + ($codes -join ',') + " cfg=" + $st + " targetExists=" + (Test-Path $c.target)) $(if ($st -match 'markers=1/1') { 'SURVIVED' } else { 'BROKE' })

# ---------------------------------------------------------------- M18: absurd arguments
$fuzz = @(
  @{ n = 'missing value for -TargetDir'; a = @('-Apply','-TargetDir') },
  @{ n = '-Runtime nonsense';            a = @('-Apply','-TargetDir','X:\nope','-Runtime','nonsense') },
  @{ n = '-ForceProfile 900b';           a = @('-Apply','-TargetDir','X:\nope','-ForceProfile','900b') },
  @{ n = 'empty -PluginNames';           a = @('-Apply','-TargetDir','X:\nope','-WithPlugins','-PluginNames','') },
  @{ n = 'unknown switch';               a = @('-Apply','-TargetDir','X:\nope','-WhatIsThis','1') }
)
foreach ($fz in $fuzz) {
  $c = New-Lab ('m18-' + ($fz.n -replace '[^a-zA-Z0-9]', ''))
  $r = Run-Ps1 (Join-Path $MINI 'install.ps1') $fz.a $c.fakeHome $MINI 120
  $msg = if ($r.err.Trim()) { (($r.err -split "`r?`n") | Where-Object { $_.Trim() } | Select-Object -First 1) } elseif ($r.out.Trim()) { (($r.out -split "`r?`n") | Where-Object { $_.Trim() } | Select-Object -Last 1) } else { '-' }
  Log ("      " + ($msg.Substring(0, [Math]::Min(110, $msg.Length))))
  Record ('M18 ' + $fz.n) ("exit=" + $r.code) $(if ($r.code -ne 0) { 'refused' } else { 'ACCEPTED' })
}

Log ''
Log '=== M15-M18 SUMMARY ==='
foreach ($row in $script:rows) { Log ("  {0,-18} {1,-32} {2}" -f $row.verdict, $row.case, $row.outcome) }
