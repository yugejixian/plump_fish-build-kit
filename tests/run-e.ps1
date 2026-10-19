# Suite E: what happens on a machine where the GPU builds cannot load at all.
#
# This is the "no NVIDIA driver / nothing to offload to" case. The real detector
# is `llama-server.exe --list-devices`: on such a machine the CUDA binary cannot
# even load its cublas DLL and prints nothing. The stub runtimes in this fixture
# reproduce exactly that - the executable exists, but it can never report a
# device - so the fallback chain is exercised for real instead of being forced.
$ErrorActionPreference = 'Stop'
$PS51 = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
$ROOT = 'D:\_test'
$MINI = Join-Path $ROOT 'mini'
$LOG = Join-Path $ROOT 'results-e.txt'
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
  return @{ base = $base; fakeHome = $fh; target = (Join-Path $base 'inst') }
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
function Repack { $null = Run-Ps1 (Join-Path $MINI 'pack.ps1') @('-Apply', '-PackageDir', $MINI) $env:USERPROFILE $MINI }
function Plant-Stub([string]$name) {
  $d = Join-Path $MINI "payload\$name"
  New-Item -ItemType Directory $d -Force | Out-Null
  # an MZ header that is not a runnable program: --list-devices fails, exactly
  # like a CUDA build without a driver
  [System.IO.File]::WriteAllBytes((Join-Path $d 'llama-server.exe'), [byte[]](0x4D, 0x5A, 0x00))
}

Set-Content -LiteralPath $LOG -Value ('=== E suite ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + ' ===') -Encoding UTF8
Log 'planting non-loadable CUDA and Vulkan builds into the fixture...'
Plant-Stub 'llama_cpp'
Plant-Stub 'llama_cpp_vulkan'
Repack

# ---------------------------------------------------------------- e1/e2: auto falls through to CPU
$c = New-Case 'e1-auto-fallback'
$r = Run-Ps1 (Join-Path $MINI 'install.ps1') @('-Apply', '-TargetDir', $c.target, '-NoStartup', '-AllowMultiple', '-NoSelfTest', '-ForceProfile', 'none') $c.fakeHome $MINI
Log ('  install exit=' + $r.code)
($r.out -split "`n") | Where-Object { $_ -match 'CUDA|Vulkan|CPU|runtime:' } | ForEach-Object { Log ('    ' + $_.Trim()) }
Assert-True ($r.code -eq 0) 'e1: auto install succeeds with no loadable GPU build'
Assert-True ($r.out -match 'CUDA\s+-> no device') 'e1: the CUDA build was probed and reported no device'
Assert-True ($r.out -match 'Vulkan\s+-> no device') 'e1: the Vulkan build was probed and reported no device'
Assert-True ($r.out -match '=> runtime: CPU') 'e1: it fell through to the CPU runtime'
Assert-True (Test-Path (Join-Path $c.target 'llama_cpp_cpu\llama-server.exe')) 'e2: the CPU runtime was copied'
Assert-True (-not (Test-Path (Join-Path $c.target 'llama_cpp\llama-server.exe'))) 'e2: the unusable CUDA runtime was NOT copied'
$cfg = Get-Content (Join-Path $c.target 'gateway\config.json') -Raw | ConvertFrom-Json
Assert-True ($cfg.llamaServer.exe -like '*llama_cpp_cpu*') 'e2: config points at the CPU build'
Assert-True (($cfg.llamaServer.args -join ' ') -match '-ngl\s+0') 'e2: CPU args (-ngl 0) applied'

# ---------------------------------------------------------------- e3/e4: forcing an unusable GPU refuses
$c = New-Case 'e3-force-cuda'
$r = Run-Ps1 (Join-Path $MINI 'install.ps1') @('-Apply', '-TargetDir', $c.target, '-NoStartup', '-AllowMultiple', '-NoSelfTest', '-Runtime', 'cuda', '-ForceProfile', 'none') $c.fakeHome $MINI
Assert-True ($r.code -ne 0) 'e3: -Runtime cuda is refused when the build reports no device'
Assert-True (($r.err + $r.out) -match 'reports no usable device') 'e3: the error explains why'
$c = New-Case 'e4-force-vulkan'
$r = Run-Ps1 (Join-Path $MINI 'install.ps1') @('-Apply', '-TargetDir', $c.target, '-NoStartup', '-AllowMultiple', '-NoSelfTest', '-Runtime', 'vulkan', '-ForceProfile', 'none') $c.fakeHome $MINI
Assert-True ($r.code -ne 0) 'e4: -Runtime vulkan is refused too'

# ---------------------------------------------------------------- e5: control, cpu still fine
$c = New-Case 'e5-force-cpu'
$r = Run-Ps1 (Join-Path $MINI 'install.ps1') @('-Apply', '-TargetDir', $c.target, '-NoStartup', '-AllowMultiple', '-NoSelfTest', '-Runtime', 'cpu', '-ForceProfile', 'none') $c.fakeHome $MINI
Assert-True ($r.code -eq 0) 'e5: -Runtime cpu still works on the same fixture'

# ---------------------------------------------------------------- e6: only a broken CUDA build present
Remove-Item (Join-Path $MINI 'payload\llama_cpp_vulkan') -Recurse -Force
Repack
$c = New-Case 'e6-cuda-only'
$r = Run-Ps1 (Join-Path $MINI 'install.ps1') @('-Apply', '-TargetDir', $c.target, '-NoStartup', '-AllowMultiple', '-NoSelfTest', '-ForceProfile', 'none') $c.fakeHome $MINI
Assert-True ($r.code -eq 0) 'e6: install succeeds with only an unusable CUDA build in the package'
Assert-True ($r.out -match '=> runtime: CPU') 'e6: still falls back to CPU'
Assert-True ($r.out -notmatch 'Vulkan') 'e6: it does not claim a Vulkan build that is not there'

Log ''
Log ('=== E RESULT pass=' + $script:pass + ' fail=' + $script:fail + ' ===')
Write-Host ''
Write-Host ('E RESULT pass=' + $script:pass + ' fail=' + $script:fail)
if ($script:fail -gt 0) { $script:fails | ForEach-Object { Write-Host ('  ' + $_) } }
