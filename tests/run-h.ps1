# Suite H: -PruneRuntimes.
# Proves the one deleting code path is narrow: it removes only llama_cpp*
# directories that really hold a runtime, never the active one, never the CPU
# fallback, never anything that merely looks similar, and never runs without
# -Apply.
$ErrorActionPreference = 'Stop'
$PS51 = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
$ROOT = 'D:\_test'
$MINI = Join-Path $ROOT 'mini'
$REAL = 'D:\新手向大肥鱼build整合'
$LOG  = Join-Path $ROOT 'results-h.txt'
$script:pass = 0; $script:fail = 0; $script:fails = @(); $script:caseName = ''

function Log([string]$m) { Write-Host $m; Add-Content -LiteralPath $LOG -Value $m -Encoding UTF8 }
function Assert-True($c, [string]$m) { if ($c) { $script:pass++; Log ('  PASS  ' + $m) } else { $script:fail++; $script:fails += ('[' + $script:caseName + '] ' + $m); Log ('  FAIL  ' + $m) } }
function New-Case([string]$n) {
  $script:caseName = $n
  $base = Join-Path (Join-Path $ROOT 'cases') $n
  if (Test-Path $base) { Remove-Item $base -Recurse -Force }
  $fh = Join-Path $base 'home'
  $prof = Join-Path $fh '.dsh\profiles\desktop'
  New-Item -ItemType Directory $prof -Force | Out-Null
  Set-Content -LiteralPath (Join-Path $prof 'package.json') -Value '{"name":"p","dependencies":{}}' -Encoding UTF8
  return @{ base = $base; fakeHome = $fh; prof = $prof; target = (Join-Path $base 'inst') }
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
function Plant-Runtime($case, [string]$name) {
  $d = Join-Path $case.target $name
  New-Item -ItemType Directory $d -Force | Out-Null
  [System.IO.File]::WriteAllBytes((Join-Path $d 'llama-server.exe'), [byte[]](0x4D, 0x5A, 0x00))
  Set-Content -LiteralPath (Join-Path $d 'filler.bin') -Value ('x' * 2000) -Encoding ASCII
  return $d
}

Set-Content -LiteralPath $LOG -Value ('=== H suite ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + ' ===') -Encoding UTF8

# h1: prune removes a stale runtime, keeps the active one, the CPU fallback and everything else
$c = New-Case 'h1-prune'
$null = Install-Mini $c @()
Assert-True (Test-Path (Join-Path $c.target 'llama_cpp_cpu\llama-server.exe')) 'h1: cpu runtime installed'
$null = Plant-Runtime $c 'llama_cpp_vulkan'
$null = Plant-Runtime $c 'llama_cpp_cuda_old'
# sentinel: pruning must not touch anything outside llama_cpp*
New-Item -ItemType Directory (Join-Path $c.target 'models') -Force | Out-Null
Set-Content -LiteralPath (Join-Path $c.target 'models\keepme.txt') -Value 'sentinel'
Assert-True (Test-Path (Join-Path $c.target 'llama_cpp_vulkan')) 'h1: planted a stale vulkan runtime'
$r = Install-Mini $c @('-PruneRuntimes')
Assert-True ($r.code -eq 0) 'h1: prune run exits 0'
Assert-True (-not (Test-Path (Join-Path $c.target 'llama_cpp_vulkan'))) 'h1: stale vulkan runtime removed'
Assert-True (-not (Test-Path (Join-Path $c.target 'llama_cpp_cuda_old'))) 'h1: stale cuda runtime removed'
Assert-True (Test-Path (Join-Path $c.target 'llama_cpp_cpu\llama-server.exe')) 'h1: active runtime kept'
Assert-True (Test-Path (Join-Path $c.target 'gateway\config.json')) 'h1: gateway untouched'
Assert-True (Test-Path (Join-Path $c.target 'models\keepme.txt')) 'h1: sentinel file outside llama_cpp* survives'
Assert-True ($r.out -match 'MB freed') 'h1: reports the freed size'

# h2: without the switch nothing is deleted
$c = New-Case 'h2-noprune'
$null = Install-Mini $c @()
$null = Plant-Runtime $c 'llama_cpp_vulkan'
$r = Install-Mini $c @()
Assert-True ($r.code -eq 0) 'h2: exit 0'
Assert-True (Test-Path (Join-Path $c.target 'llama_cpp_vulkan')) 'h2: runtime survives without -PruneRuntimes'

# h3: dry run never deletes, even when asked
$c = New-Case 'h3-dryrun'
$null = Install-Mini $c @()
$null = Plant-Runtime $c 'llama_cpp_vulkan'
$r = Run-Ps1 (Join-Path $MINI 'install.ps1') @('-TargetDir', $c.target, '-NoStartup', '-AllowMultiple', '-NoSelfTest', '-Runtime', 'cpu', '-ForceProfile', 'none', '-PruneRuntimes') $c.fakeHome $MINI
Assert-True ($r.out -match 'dry-run only') 'h3: it is a dry run'
Assert-True (Test-Path (Join-Path $c.target 'llama_cpp_vulkan')) 'h3: dry run deleted nothing'

# h4: a llama_cpp* directory without llama-server.exe is not a runtime and is left alone
$c = New-Case 'h4-lookalike'
$null = Install-Mini $c @()
$fake = Join-Path $c.target 'llama_cpp_notes'
New-Item -ItemType Directory $fake -Force | Out-Null
Set-Content -LiteralPath (Join-Path $fake 'readme.txt') -Value 'not a runtime'
$r = Install-Mini $c @('-PruneRuntimes')
Assert-True ($r.code -eq 0) 'h4: exit 0'
Assert-True (Test-Path $fake) 'h4: lookalike directory without llama-server.exe survives'
Assert-True ($r.out -match 'left alone') 'h4: it says why it left it alone'

# h5: pruning is a no-op on a fresh single-runtime install
$c = New-Case 'h5-noop'
$null = Install-Mini $c @()
$r = Install-Mini $c @('-PruneRuntimes')
Assert-True ($r.code -eq 0) 'h5: exit 0'
Assert-True (Test-Path (Join-Path $c.target 'llama_cpp_cpu\llama-server.exe')) 'h5: active runtime still there'
$dirs = @(Get-ChildItem $c.target -Directory | Where-Object { $_.Name -like 'llama_cpp*' })
Assert-True ($dirs.Count -eq 1) ('h5: exactly one runtime dir remains (' + $dirs.Count + ')')

Log ''
Log ('=== H RESULT pass=' + $script:pass + ' fail=' + $script:fail + ' ===')
Write-Host ''
Write-Host ('H RESULT pass=' + $script:pass + ' fail=' + $script:fail)
if ($script:fail -gt 0) { $script:fails | ForEach-Object { Write-Host ('  ' + $_) } }
