# Monkey suite: abuse the installer the way a real user (or a real disaster) would.
# Everything stays under D:\_test\m\. Nothing outside the sandbox is touched.
# Each case records an OUTCOME; the point is to see what breaks, not to assert.
$ErrorActionPreference = 'Stop'
$PS51 = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
$ROOT = 'D:\_test'
$MINI = Join-Path $ROOT 'mini'
$REAL = 'D:\新手向大肥鱼build整合'
$M = Join-Path $ROOT 'm'
$LOG = Join-Path $ROOT 'results-m.txt'
$rows = @()

function Log([string]$s) { Add-Content -LiteralPath $LOG -Value $s -Encoding UTF8; Write-Host $s }
function Mark([string]$t) { Write-Host ''; Write-Host ("=== " + $t + " ===") -ForegroundColor Cyan; Add-Content -LiteralPath $LOG -Value ("`r`n=== " + $t + " ===") -Encoding UTF8 }

function New-Lab([string]$name) {
  $base = Join-Path $M $name
  if (Test-Path $base) {
    Get-ChildItem $base -Recurse -Force -ErrorAction SilentlyContinue | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint } | ForEach-Object { cmd /c rmdir "$($_.FullName)" 2>$null }
    Remove-Item $base -Recurse -Force
  }
  $fh = Join-Path $base 'home'
  $prof = Join-Path $fh '.dsh\profiles\desktop'
  New-Item -ItemType Directory $prof -Force | Out-Null
  Set-Content -LiteralPath (Join-Path $prof 'package.json') -Value '{"name":"p","dependencies":{}}' -Encoding UTF8
  return @{ base = $base; fakeHome = $fh; prof = $prof; target = (Join-Path $base 'inst') }
}
function Run-Ps1([string]$script, [string[]]$argList, [string]$userHome, [string]$workDir, [int]$timeoutSec = 600) {
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $PS51; $psi.WorkingDirectory = $workDir
  $psi.UseShellExecute = $false; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.CreateNoWindow = $true
  $psi.EnvironmentVariables['USERPROFILE'] = $userHome
  $q = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $script) + $argList
  $psi.Arguments = ($q | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }) -join ' '
  $p = [System.Diagnostics.Process]::Start($psi)
  # Drain both pipes concurrently. Reading stdout to the end first deadlocks as
  # soon as the child fills the stderr pipe buffer (M15 proved it: a truncated
  # manifest makes PowerShell write a multi-KB error record).
  $outTask = $p.StandardOutput.ReadToEndAsync()
  $errTask = $p.StandardError.ReadToEndAsync()
  if (-not $p.WaitForExit($timeoutSec * 1000)) {
    try { $p.Kill() } catch { }
    return @{ code = -99; out = 'TIMEOUT'; err = 'TIMEOUT' }
  }
  return @{ code = $p.ExitCode; out = $outTask.Result; err = $errTask.Result }
}
function Mini-Install($case, [string[]]$extra) {
  $a = @('-Apply', '-TargetDir', $case.target, '-NoStartup', '-AllowMultiple', '-NoSelfTest', '-Runtime', 'cpu', '-ForceProfile', 'none') + $extra
  return Run-Ps1 (Join-Path $MINI 'install.ps1') $a $case.fakeHome $MINI
}
function Config-State([string]$prof) {
  $f = Join-Path $prof 'cordis.patch.yml'
  if (-not (Test-Path $f)) { return 'missing' }
  try { $t = [System.IO.File]::ReadAllText($f, [System.Text.Encoding]::UTF8) } catch { return 'unreadable' }
  $b = ([regex]::Matches($t, '(?m)^[ \t]*#[ \t]*>>>[ \t]*dsh-local-llm')).Count
  $e = ([regex]::Matches($t, '(?m)^[ \t]*#[ \t]*<<<[ \t]*dsh-local-llm')).Count
  return ("markers={0}/{1} len={2}" -f $b, $e, $t.Length)
}
function Record([string]$name, [string]$outcome, [string]$verdict) {
  $script:rows += [pscustomobject]@{ case = $name; outcome = $outcome; verdict = $verdict }
  Log ("  [{0}] {1}  -> {2}" -f $verdict, $name, $outcome)
}

Set-Content -LiteralPath $LOG -Value ('=== MONKEY suite ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + ' ===') -Encoding UTF8

# ---------------------------------------------------------------- M1/M2: killed mid-install
Mark 'M1/M2 kill the installer mid-copy, then re-run'
$c = New-Lab 'm1-kill'
$wmi = 'cmd.exe /c "' + (Join-Path $REAL 'install.ps1') + '"'
# launch detached (WMI) so killing it cannot disturb the tool host
$cmd = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path $REAL 'install.ps1') + '" -Apply -TargetDir "' + $c.target + '" -NoStartup -AllowMultiple -NoSelfTest -ForceProfile none'
$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = $PS51; $psi.Arguments = ('-NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path $REAL 'install.ps1') + '" -Apply -TargetDir "' + $c.target + '" -NoStartup -AllowMultiple -NoSelfTest -ForceProfile none')
$psi.UseShellExecute = $false; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.CreateNoWindow = $true
$psi.WorkingDirectory = $REAL
$psi.EnvironmentVariables['USERPROFILE'] = $c.fakeHome
$p = [System.Diagnostics.Process]::Start($psi)
Start-Sleep -Milliseconds 1500
$killed = $false
try { $p.Kill(); $killed = $true } catch { }
$null = $p.WaitForExit(30000)
Log ("  killed mid-run: " + $killed)
$partial = if (Test-Path $c.target) { [int](((Get-ChildItem $c.target -Recurse -File -EA SilentlyContinue | Measure-Object Length -Sum).Sum)/1MB) } else { 0 }
Log ("  partial target after kill: " + $partial + " MB   config=" + (Config-State $c.prof))
$r = Run-Ps1 (Join-Path $REAL 'install.ps1') @('-Apply','-TargetDir',$c.target,'-NoStartup','-AllowMultiple','-NoSelfTest','-ForceProfile','none') $c.fakeHome $REAL 1800
Record 'M1 kill mid-copy then re-install' ("exit=" + $r.code + " cfg=" + (Config-State $c.prof)) $(if ($r.code -eq 0) { 'SURVIVED' } else { 'BROKE' })
# kill twice more, then a clean run
foreach ($i in 1..2) {
  $psi2 = New-Object System.Diagnostics.ProcessStartInfo
  $psi2.FileName = $PS51
  $psi2.Arguments = ('-NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path $REAL 'install.ps1') + '" -Apply -TargetDir "' + $c.target + '" -NoStartup -AllowMultiple -NoSelfTest -ForceProfile none')
  $psi2.UseShellExecute = $false; $psi2.RedirectStandardOutput = $true; $psi2.RedirectStandardError = $true; $psi2.CreateNoWindow = $true
  $psi2.WorkingDirectory = $REAL
  $psi2.EnvironmentVariables['USERPROFILE'] = $c.fakeHome
  $pp = [System.Diagnostics.Process]::Start($psi2)
  Start-Sleep -Milliseconds 900
  try { $pp.Kill() } catch { }
  $null = $pp.WaitForExit(20000)
}
$r = Run-Ps1 (Join-Path $REAL 'install.ps1') @('-Apply','-TargetDir',$c.target,'-NoStartup','-AllowMultiple','-NoSelfTest','-ForceProfile','none') $c.fakeHome $REAL 1800
$cfgOk = (Config-State $c.prof) -match 'markers=1/1'
Record 'M2 killed 3x then clean run' ("exit=" + $r.code + " cfg=" + (Config-State $c.prof)) $(if (($r.code -eq 0) -and $cfgOk) { 'SURVIVED' } else { 'BROKE' })

# ---------------------------------------------------------------- M3-M6: hostile config files
Mark 'M3-M6 hostile cordis.patch.yml contents'
$c = New-Lab 'm3-random-bytes'
$bytes = New-Object byte[] 4096
(New-Object Random 42).NextBytes($bytes)
[System.IO.File]::WriteAllBytes((Join-Path $c.prof 'cordis.patch.yml'), $bytes)
$r = Mini-Install $c @()
Record 'M3 config = 4 KB random bytes' ("exit=" + $r.code + " cfg=" + (Config-State $c.prof)) $(if ((Config-State $c.prof) -match 'markers=1/1') { 'SURVIVED' } else { 'BROKE' })

$c = New-Lab 'm4-bad-utf8'
$cp1252 = [System.Text.Encoding]::GetEncoding(1252)
[System.IO.File]::WriteAllBytes((Join-Path $c.prof 'cordis.patch.yml'), $cp1252.GetBytes("- id: cafi`r`n  name: `"naive`"`r`n  config:`r`n    note: 0xE9 0xE8 0xFF`r`n"))
$r = Mini-Install $c @()
Record 'M4 config = Windows-1252 bytes' ("exit=" + $r.code + " cfg=" + (Config-State $c.prof)) $(if ((Config-State $c.prof) -match 'markers=1/1') { 'SURVIVED' } else { 'BROKE' })

$c = New-Lab 'm5-2000-rows'
$sb = New-Object System.Text.StringBuilder
for ($i = 0; $i -lt 2000; $i++) { $null = $sb.AppendLine("- id: junk-$i"); $null = $sb.AppendLine("  name: `"x/$i`""); $null = $sb.AppendLine("  config:"); $null = $sb.AppendLine("    v: $i") }
Set-Content -LiteralPath (Join-Path $c.prof 'cordis.patch.yml') -Value $sb.ToString() -Encoding UTF8 -NoNewline
$sw = [Diagnostics.Stopwatch]::StartNew()
$r = Mini-Install $c @()
$ms = [int]$sw.Elapsed.TotalSeconds
$txt = [System.IO.File]::ReadAllText((Join-Path $c.prof 'cordis.patch.yml'), [System.Text.Encoding]::UTF8)
$still = ([regex]::Matches($txt, '(?m)^- id:[ \t]*junk-')).Count
Record 'M5 config with 2000 junk rows' ("exit=" + $r.code + " ${ms}s rows kept=" + $still + " cfg=" + (Config-State $c.prof)) $(if (($r.code -eq 0) -and ($still -eq 2000) -and ((Config-State $c.prof) -match 'markers=1/1')) { 'SURVIVED' } else { 'BROKE' })

$c = New-Lab 'm6-one-meg-line'
$big = '- id: giant' + "`r`n  config: `"" + ('A' * 1048576) + "`"`r`n"
Set-Content -LiteralPath (Join-Path $c.prof 'cordis.patch.yml') -Value $big -Encoding UTF8 -NoNewline
$sw = [Diagnostics.Stopwatch]::StartNew()
$r = Run-Ps1 (Join-Path $MINI 'install.ps1') @('-Apply','-TargetDir',$c.target,'-NoStartup','-AllowMultiple','-NoSelfTest','-Runtime','cpu','-ForceProfile','none') $c.fakeHome $MINI 300
Record 'M6 config with one 1 MB line' ("exit=" + $r.code + " " + [int]$sw.Elapsed.TotalSeconds + "s cfg=" + (Config-State $c.prof)) $(if ($r.code -eq 0) { 'SURVIVED' } else { 'BROKE' })

# ---------------------------------------------------------------- M7: huge AGENTS.md
Mark 'M7 AGENTS.md = 8 MB'
$c = New-Lab 'm7-huge-agents'
$fb = New-Object System.Text.StringBuilder
for ($i = 0; $i -lt 200000; $i++) { $null = $fb.AppendLine("- filler line $i") }
[System.IO.File]::WriteAllText((Join-Path $c.fakeHome '.dsh\AGENTS.md'), $fb.ToString(), (New-Object System.Text.UTF8Encoding($false)))
$sw = [Diagnostics.Stopwatch]::StartNew()
$r = Run-Ps1 (Join-Path $MINI 'install.ps1') @('-Apply','-TargetDir',$c.target,'-NoStartup','-AllowMultiple','-NoSelfTest','-Runtime','cpu','-ForceProfile','none') $c.fakeHome $MINI 300
$ag = [System.IO.File]::ReadAllText((Join-Path $c.fakeHome '.dsh\AGENTS.md'), [System.Text.Encoding]::UTF8)
Record 'M7 AGENTS.md 8 MB' ("exit=" + $r.code + " " + [int]$sw.Elapsed.TotalSeconds + "s mdMarkers=" + ([regex]::Matches($ag,'(?m)^[ \t]*<!--[ \t]*>>>[ \t]*dsh-local-llm')).Count + " filler kept=" + [bool]($ag -match 'filler line 42')) $(if (($r.code -eq 0) -and ([regex]::Matches($ag,'(?m)^[ \t]*<!--[ \t]*>>>[ \t]*dsh-local-llm')).Count -eq 1) { 'SURVIVED' } else { 'BROKE' })

# ---------------------------------------------------------------- M8/M9: broken package.json
Mark 'M8/M9 profile package.json broken'
$c = New-Lab 'm8-bad-json'
Set-Content -LiteralPath (Join-Path $c.prof 'package.json') -Value '{ this is not json ' -Encoding UTF8 -NoNewline
$r = Mini-Install $c @('-RestoreSettings')
Record 'M8 package.json = invalid JSON' ("exit=" + $r.code + " cfg=" + (Config-State $c.prof)) $(if ((Config-State $c.prof) -match 'markers=1/1') { 'SURVIVED' } else { 'BROKE' })

$c = New-Lab 'm9-json-array'
Set-Content -LiteralPath (Join-Path $c.prof 'package.json') -Value '[1,2,3]' -Encoding UTF8 -NoNewline
$r = Mini-Install $c @('-RestoreSettings')
Record 'M9 package.json = JSON array' ("exit=" + $r.code + " cfg=" + (Config-State $c.prof)) $(if ((Config-State $c.prof) -match 'markers=1/1') { 'SURVIVED' } else { 'BROKE' })

# ---------------------------------------------------------------- M10: node_modules\@deepseek-ai is a file
Mark 'M10 node_modules\@deepseek-ai is a regular file'
$c = New-Lab 'm10-peer-is-file'
New-Item -ItemType Directory (Join-Path $c.prof 'node_modules') -Force | Out-Null
Set-Content -LiteralPath (Join-Path $c.prof 'node_modules\@deepseek-ai') -Value 'i am a file, not a directory' -Encoding ASCII
$r = Mini-Install $c @()
Record 'M10 @deepseek-ai is a file' ("exit=" + $r.code + " cfg=" + (Config-State $c.prof) + " fileIntact=" + (Test-Path (Join-Path $c.prof 'node_modules\@deepseek-ai') -PathType Leaf)) $(if ((Config-State $c.prof) -match 'markers=1/1') { 'SURVIVED' } else { 'BROKE' })

# ---------------------------------------------------------------- M11: runtime path is a file
Mark 'M11 target\llama_cpp_cpu is a file'
$c = New-Lab 'm11-runtime-is-file'
New-Item -ItemType Directory $c.target -Force | Out-Null
Set-Content -LiteralPath (Join-Path $c.target 'llama_cpp_cpu') -Value 'not a directory' -Encoding ASCII
$r = Mini-Install $c @()
$kind = if (Test-Path (Join-Path $c.target 'llama_cpp_cpu') -PathType Leaf) { 'still a file' } elseif (Test-Path (Join-Path $c.target 'llama_cpp_cpu') -PathType Container) { 'became a directory' } else { 'gone' }
Record 'M11 runtime dir is a file' ("exit=" + $r.code + " -> " + $kind) $(if ($r.code -ne 0) { 'refused' } else { 'SURVIVED' })

# ---------------------------------------------------------------- M12: read-only config
Mark 'M12 config file is read-only'
$c = New-Lab 'm12-readonly'
$null = Mini-Install $c @()
$cfg = Join-Path $c.prof 'cordis.patch.yml'
$good = [System.IO.File]::ReadAllText($cfg, [System.Text.Encoding]::UTF8)
(Get-Item $cfg).IsReadOnly = $true
$r = Mini-Install $c @()
(Get-Item $cfg).IsReadOnly = $false
$now = [System.IO.File]::ReadAllText($cfg, [System.Text.Encoding]::UTF8)
Record 'M12 read-only config' ("exit=" + $r.code + " unchanged=" + ($now -eq $good)) $(if ($now -eq $good) { 'SURVIVED' } else { 'BROKE' })

# ---------------------------------------------------------------- M13/M14: silly target paths
Mark 'M13/M14 silly target paths'
$c = New-Lab 'm13-long-path'
$deep = $c.base + '\' + ('a' * 90) + '\' + ('b' * 90) + '\' + ('c' * 40) + '\inst'
$r = Run-Ps1 (Join-Path $MINI 'install.ps1') @('-Apply','-TargetDir',$deep,'-NoStartup','-AllowMultiple','-NoSelfTest','-Runtime','cpu','-ForceProfile','none') $c.fakeHome $MINI 300
$exists = Test-Path -LiteralPath $deep
Record ('M13 target path ' + $deep.Length + ' chars') ("exit=" + $r.code + " created=" + $exists) $(if ($r.code -eq 0) { 'SURVIVED' } else { 'refused' })

$c = New-Lab 'm14-reserved'
$r = Run-Ps1 (Join-Path $MINI 'install.ps1') @('-Apply','-TargetDir','NUL','-NoStartup','-AllowMultiple','-NoSelfTest','-Runtime','cpu','-ForceProfile','none') $c.fakeHome $MINI 120
Record 'M14 target = NUL' ("exit=" + $r.code + " stderr1=" + $(if ($r.err.Trim()) { (($r.err -split "`r?`n")[0]).Substring(0, [Math]::Min(60, (($r.err -split "`r?`n")[0]).Length)) } else { '-' })) $(if ($r.code -ne 0) { 'refused' } else { 'SURVIVED' })

# ---------------------------------------------------------------- M15: tampered manifest / payload
Mark 'M15/M16 tampered package copy'
$c = New-Lab 'm15-manifest-truncated'
$pkg = Join-Path $c.base 'pkg'
Copy-Item -LiteralPath $MINI -Destination $pkg -Recurse -Force
$man = Join-Path $pkg 'manifest.json'
$t = [System.IO.File]::ReadAllText($man)
[System.IO.File]::WriteAllText($man, $t.Substring(0, [int]($t.Length / 2)), (New-Object System.Text.UTF8Encoding($false)))
$r = Run-Ps1 (Join-Path $pkg 'install.ps1') @('-Apply','-TargetDir',(Join-Path $c.base 'out'),'-NoStartup','-AllowMultiple','-NoSelfTest','-Runtime','cpu','-ForceProfile','none') $c.fakeHome $pkg 300
Record 'M15 manifest truncated' ("exit=" + $r.code + " targetCreated=" + (Test-Path (Join-Path $c.base 'out'))) $(if ($r.code -ne 0) { 'refused' } else { 'SURVIVED' })

$c = New-Lab 'm16-payload-missing'
$pkg = Join-Path $c.base 'pkg'
Copy-Item -LiteralPath $MINI -Destination $pkg -Recurse -Force
Remove-Item (Join-Path $pkg 'payload\gateway\gateway.js') -Force -ErrorAction SilentlyContinue
$r = Run-Ps1 (Join-Path $pkg 'install.ps1') @('-Apply','-TargetDir',(Join-Path $c.base 'out'),'-NoStartup','-AllowMultiple','-NoSelfTest','-Runtime','cpu','-ForceProfile','none') $c.fakeHome $pkg 300
Record 'M16 one payload file deleted' ("exit=" + $r.code + " targetCreated=" + (Test-Path (Join-Path $c.base 'out'))) $(if ($r.code -ne 0) { 'refused' } else { 'SURVIVED' })

# ---------------------------------------------------------------- M17: two installs racing
Mark 'M17 two installers at the same target'
$c = New-Lab 'm17-race'
$procs = @()
foreach ($i in 1..2) {
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $PS51
  $psi.Arguments = ('-NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path $REAL 'install.ps1') + '" -Apply -TargetDir "' + $c.target + '" -NoStartup -AllowMultiple -NoSelfTest -ForceProfile none')
  $psi.UseShellExecute = $false; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.CreateNoWindow = $true
  $psi.WorkingDirectory = $REAL
  $psi.EnvironmentVariables['USERPROFILE'] = $c.fakeHome
  $procs += [System.Diagnostics.Process]::Start($psi)
}
$codes = @()
foreach ($pp in $procs) { $null = $pp.WaitForExit(900000); $codes += $pp.ExitCode }
$st = Config-State $c.prof
Record 'M17 two installs racing' ("exits=" + ($codes -join ',') + " cfg=" + $st) $(if ($st -match 'markers=1/1') { 'SURVIVED' } else { 'BROKE' })

# ---------------------------------------------------------------- M18: random CLI abuse
Mark 'M18 random/absurd arguments'
$fuzz = @(
  @{ n = 'missing value for -TargetDir'; a = @('-Apply','-TargetDir') },
  @{ n = '-Runtime = nonsense';          a = @('-Apply','-TargetDir','X:\nope','-Runtime','nonsense') },
  @{ n = '-ForceProfile = 900b';         a = @('-Apply','-TargetDir','X:\nope','-ForceProfile','900b') },
  @{ n = '-PluginNames = nothing';       a = @('-Apply','-TargetDir','X:\nope','-WithPlugins','-PluginNames','') },
  @{ n = 'unknown switch';               a = @('-Apply','-TargetDir','X:\nope','-WhatIsThis','1') }
)
foreach ($fz in $fuzz) {
  $c = New-Lab ('m18-' + ($fz.n -replace '[^a-zA-Z0-9]', ''))
  $r = Run-Ps1 (Join-Path $MINI 'install.ps1') $fz.a $c.fakeHome $MINI 120
  $first = if ($r.err.Trim()) { (($r.err -split "`r?`n")[0]) } elseif ($r.out.Trim()) { (($r.out -split "`r?`n") | Where-Object { $_.Trim() } | Select-Object -Last 1) } else { '-' }
  Record ('M18 ' + $fz.n) ("exit=" + $r.code) $(if ($r.code -ne 0) { 'refused' } else { 'accepted' })
}

Log ''
Log '=== MONKEY SUMMARY ==='
foreach ($r in $script:rows) { Log ("  {0,-10} {1,-40} {2}" -f $r.verdict, $r.case, $r.outcome) }
$broke = @($script:rows | Where-Object { $_.verdict -eq 'BROKE' })
Log ('  broke: ' + $broke.Count + ' / ' + $script:rows.Count)
Write-Host ''
Write-Host ('MONKEY done, broke=' + $broke.Count + ' of ' + $script:rows.Count)
