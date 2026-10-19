# Stress / fuzz suite for the DSH local-model turnkey kit.
#
# Runs entirely inside D:\_test:
#   - a MINI fixture package (stub runtime, no weights) so an install costs ~1s
#   - a fake USERPROFILE per case, so ~/.dsh is never touched
#   - install targets at D:\_test\cases\<case>\inst, which is deeper than the
#     installer's 2-level drive scan, so it can never mistake a sandbox for a
#     real install (and cannot pollute a later real install)
#
# Nothing outside D:\_test is written. Never calls -PurgeOthers.
$ErrorActionPreference = 'Stop'
$PS51  = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
$ROOT  = 'D:\_test'
$MINI  = Join-Path $ROOT 'mini'
$REAL  = 'D:\新手向大肥鱼build整合'
$LOG   = Join-Path $ROOT 'results.txt'
$script:pass = 0; $script:fail = 0; $script:fails = @()
$script:caseName = ''

function Log([string]$m) { Write-Host $m; Add-Content -LiteralPath $LOG -Value $m -Encoding UTF8 }
function Section([string]$m) { Log ''; Log ('=== ' + $m + ' ===') }
function Assert-True($cond, [string]$msg) {
  if ($cond) { $script:pass++; Log ('  PASS  ' + $msg) }
  else { $script:fail++; $script:fails += ('[' + $script:caseName + '] ' + $msg); Log ('  FAIL  ' + $msg) }
}
function Assert-Equal($actual, $expected, [string]$msg) {
  if ("$actual" -eq "$expected") { $script:pass++; Log ('  PASS  ' + $msg) }
  else { $script:fail++; $script:fails += ('[' + $script:caseName + '] ' + $msg + ' (got ' + $actual + ', want ' + $expected + ')'); Log ('  FAIL  ' + $msg + '  got=[' + $actual + '] want=[' + $expected + ']') }
}

function Get-Markers([string]$text) {
  return @{
    yB = ([regex]::Matches($text, '(?m)^[ \t]*#[ \t]*>>>[ \t]*dsh-local-llm[ \t]+BEGIN')).Count
    yE = ([regex]::Matches($text, '(?m)^[ \t]*#[ \t]*<<<[ \t]*dsh-local-llm[ \t]+END')).Count
    mB = ([regex]::Matches($text, '(?m)^[ \t]*<!--[ \t]*>>>[ \t]*dsh-local-llm')).Count
    mE = ([regex]::Matches($text, '(?m)^[ \t]*<!--[ \t]*<<<[ \t]*dsh-local-llm')).Count
  }
}
function Get-RowIds([string]$text) {
  return @([regex]::Matches($text, '(?m)^- id:[ \t]*(\S+)') | ForEach-Object { $_.Groups[1].Value })
}
function Count-Of($arr, [string]$item) { return @($arr | Where-Object { $_ -eq $item }).Count }

function New-Case([string]$name) {
  $script:caseName = $name
  $base = Join-Path (Join-Path $ROOT 'cases') $name
  if (Test-Path $base) { Remove-Item $base -Recurse -Force }
  $fakeHome = Join-Path $base 'home'
  $prof = Join-Path $fakeHome '.dsh\profiles\desktop'
  New-Item -ItemType Directory $prof -Force | Out-Null
  Set-Content -LiteralPath (Join-Path $prof 'package.json') -Value '{"name":"dsh-profile-desktop","private":true,"dependencies":{}}' -Encoding UTF8
  return @{ base = $base; home = $fakeHome; prof = $prof; target = (Join-Path $base 'inst') }
}

# Run a .ps1 with a fake USERPROFILE and capture output.
function Run-Ps1([string]$script, [string[]]$argList, [string]$fakeHome, [string]$workDir) {
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $PS51
  $psi.WorkingDirectory = $workDir
  $psi.UseShellExecute = $false
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.CreateNoWindow = $true
  $psi.EnvironmentVariables['USERPROFILE'] = $fakeHome
  $psi.EnvironmentVariables['LOCALAPPDATA'] = (Join-Path $fakeHome 'AppData\Local')
  $psi.EnvironmentVariables['APPDATA'] = (Join-Path $fakeHome 'AppData\Roaming')
  $quoted = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $script) + $argList
  $psi.Arguments = ($quoted | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }) -join ' '
  $p = [System.Diagnostics.Process]::Start($psi)
  $out = $p.StandardOutput.ReadToEnd()
  $err = $p.StandardError.ReadToEnd()
  $p.WaitForExit(300000) | Out-Null
  return @{ code = $p.ExitCode; out = $out; err = $err }
}

function Run-MiniInstall($case, [string[]]$extra) {
  $a = @('-Apply', '-TargetDir', $case.target, '-NoStartup', '-AllowMultiple', '-NoSelfTest', '-Runtime', 'cpu', '-ForceProfile', 'none') + $extra
  $res = Run-Ps1 (Join-Path $MINI 'install.ps1') $a $case.home $MINI
  if ($res.out -match 'dry-run only') { throw 'HARNESS BUG: install ran as dry run, -Apply was not passed through' }
  return $res
}

function Build-Mini {
  if (Test-Path $MINI) { Remove-Item $MINI -Recurse -Force }
  New-Item -ItemType Directory $MINI -Force | Out-Null
  foreach ($f in 'install.ps1', 'uninstall.ps1', 'verify.ps1', 'restore-peers.ps1', 'pack.ps1', 'README.md') {
    Copy-Item -LiteralPath (Join-Path $REAL $f) -Destination $MINI -Force
  }
  $pg = Join-Path $MINI 'payload\gateway'
  Copy-Item -LiteralPath (Join-Path $REAL 'payload\gateway') -Destination $pg -Recurse -Force
  # stub runtime: enough for Test-Path and for the (failing) --list-devices probe
  $pr = Join-Path $MINI 'payload\llama_cpp_cpu'
  New-Item -ItemType Directory $pr -Force | Out-Null
  [System.IO.File]::WriteAllBytes((Join-Path $pr 'llama-server.exe'), [byte[]](0x4D, 0x5A, 0x00))
  $rules = Join-Path $pg 'rules'
  New-Item -ItemType Directory $rules -Force | Out-Null
  Set-Content -LiteralPath (Join-Path $rules 'AGENTS.block.md') -Value "<!-- >>> dsh-local-llm BEGIN (installer-generated, do not edit) >>> -->`r`nTEST-RULE-ONE`r`n- do the thing`r`n<!-- <<< dsh-local-llm END <<< -->" -Encoding UTF8 -NoNewline
  $r = Run-Ps1 (Join-Path $MINI 'pack.ps1') @('-Apply', '-PackageDir', $MINI) $env:USERPROFILE $MINI
  if ($r.code -ne 0) { throw ("mini pack failed: " + $r.err) }
  return $r
}

$LOG_DIR = Split-Path $LOG -Parent
New-Item -ItemType Directory $LOG_DIR -Force | Out-Null
Set-Content -LiteralPath $LOG -Value ('=== stress suite ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + ' ===') -Encoding UTF8

Section 'fixture'
$sw = [Diagnostics.Stopwatch]::StartNew()
$r = Build-Mini
Log ('  mini package built in ' + [int]$sw.Elapsed.TotalSeconds + 's')
Assert-Equal $r.code 0 'mini fixture packs cleanly'
$miniManifest = Get-Content (Join-Path $MINI 'manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
Assert-True ($miniManifest.fileCount -gt 40) ('mini manifest has files: ' + $miniManifest.fileCount)

# ---------------------------------------------------------------- A. cordis.patch.yml fuzz
Section 'A. cordis.patch.yml marker fuzz'

$userRow = @"
- id: ui-chat
  name: "@deepseek-ai/dsh-client-ui-chat"
  config:
    transcriptView: detailed
"@
$accountRow = @"
- id: ui-settings-account
  name: "@deepseek-ai/dsh-client-ui-settings-account"
  config:
    step: done
    purpose: both
    process: detailed
"@
$ourVariant = @"
# >>> dsh-local-llm BEGIN (安装器生成，请勿手改) >>>
- id: llm-pi-ai
  name: "@deepseek-ai/dsh-llm-pi-ai"
  config:
    providers:
      local-gguf:
        displayName: old
- id: subagent-model-selection-settings
  name: "@deepseek-ai/dsh-tool-subagent/model-selection-settings"
  config:
    enabled: true
# <<< dsh-local-llm END <<<
"@

$seeds = @(
  @{ n = 'a1-plain-user-rows';    t = ($userRow + "`r`n" + $accountRow) },
  @{ n = 'a2-five-begins';        t = ("# >>> dsh-local-llm BEGIN (安装器生成，请勿手改) >>>`r`n# >>> dsh-local-llm BEGIN (安装器生成，请勿手改) >>>`r`n# >>> dsh-local-llm BEGIN`r`n# >>> dsh-local-llm BEGIN`r`n# >>> dsh-local-llm BEGIN`r`n" + $ourVariant + "`r`n" + $userRow) },
  @{ n = 'a3-begin-without-end';  t = ("# >>> dsh-local-llm BEGIN`r`n- id: llm-pi-ai`r`n  name: x`r`n" + $userRow) },
  @{ n = 'a4-orphan-rows';        t = ("- id: llm-pi-ai`r`n  name: old`r`n`r`n" + $userRow + "`r`n- id: subagent-model-selection-settings`r`n  name: old2`r`n") },
  @{ n = 'a5-interleaved';        t = ("# >>> dsh-local-llm BEGIN`r`n- id: llm-pi-ai`r`n  name: a`r`n" + $userRow + "`r`n# <<< dsh-local-llm END <<<`r`n" + $accountRow) },
  @{ n = 'a6-empty';              t = '' },
  @{ n = 'a7-whitespace';         t = "   `r`n`r`n`t`r`n" },
  @{ n = 'a8-lf-only';            t = ($userRow -replace "`r`n", "`n") },
  @{ n = 'a9-old-variant';        t = $ourVariant },
  @{ n = 'a10-end-without-begin'; t = ("# <<< dsh-local-llm END <<<`r`n" + $userRow) }
)

foreach ($seed in $seeds) {
  $case = New-Case ('cfg-' + $seed.n)
  Set-Content -LiteralPath (Join-Path $case.prof 'cordis.patch.yml') -Value $seed.t -Encoding UTF8 -NoNewline
  $r1 = Run-MiniInstall $case @()
  Assert-Equal $r1.code 0 ($seed.n + ': install exit 0')
  $after1 = [System.IO.File]::ReadAllText((Join-Path $case.prof 'cordis.patch.yml'), [System.Text.Encoding]::UTF8)
  $m = Get-Markers $after1
  Assert-Equal $m.yB 1 ($seed.n + ': exactly 1 BEGIN')
  Assert-Equal $m.yE 1 ($seed.n + ': exactly 1 END')
  $ids = Get-RowIds $after1
  Assert-Equal (Count-Of $ids 'llm-pi-ai') 1 ($seed.n + ': one llm-pi-ai row')
  Assert-Equal (Count-Of $ids 'subagent-model-selection-settings') 1 ($seed.n + ': one subagent row')
  if ($seed.t -match 'ui-chat') { Assert-Equal (Count-Of $ids 'ui-chat') 1 ($seed.n + ': user ui-chat row preserved') }
  if ($seed.t -match 'ui-settings-account') { Assert-Equal (Count-Of $ids 'ui-settings-account') 1 ($seed.n + ': ui-settings-account preserved') }
  # idempotency: a second run must not change a single byte
  $r2 = Run-MiniInstall $case @()
  $after2 = [System.IO.File]::ReadAllText((Join-Path $case.prof 'cordis.patch.yml'), [System.Text.Encoding]::UTF8)
  Assert-Equal $after2 $after1 ($seed.n + ': second install is byte-identical')
  # a third run, for good measure
  $null = Run-MiniInstall $case @()
  $after3 = [System.IO.File]::ReadAllText((Join-Path $case.prof 'cordis.patch.yml'), [System.Text.Encoding]::UTF8)
  Assert-Equal $after3 $after1 ($seed.n + ': third install is byte-identical')
}

# ---------------------------------------------------------------- B. AGENTS.md fuzz
Section 'B. AGENTS.md marker fuzz'
$mdVariant = "<!-- >>> dsh-local-llm BEGIN (安装器生成，请勿手改) >>> -->`r`nRULES-BODY`r`n<!-- <<< dsh-local-llm END <<< -->`r`n"
$mdSeeds = @(
  @{ n = 'b1-empty';        t = '' },
  @{ n = 'b2-user-content'; t = "# my own rules`r`n- be nice`r`n" },
  @{ n = 'b3-nested';       t = ($mdVariant + $mdVariant) },
  @{ n = 'b4-begin-no-end'; t = "<!-- >>> dsh-local-llm BEGIN`r`nRULES-BODY`r`n" },
  @{ n = 'b5-end-no-begin'; t = ("# mine`r`n" + "<!-- <<< dsh-local-llm END <<< -->`r`n") },
  @{ n = 'b6-user-plus-block'; t = ("# my own rules`r`n" + $mdVariant + "- another line`r`n") }
)
foreach ($seed in $mdSeeds) {
  $case = New-Case ('md-' + $seed.n)
  Set-Content -LiteralPath (Join-Path $case.home '.dsh\AGENTS.md') -Value $seed.t -Encoding UTF8 -NoNewline
  # mini payload has no rules file, so give the mini a rules block to install

  $r1 = Run-MiniInstall $case @()
  $agents = Join-Path $case.home '.dsh\AGENTS.md'
  $after1 = [System.IO.File]::ReadAllText($agents, [System.Text.Encoding]::UTF8)
  $m = Get-Markers $after1
  Assert-Equal $m.mB 1 ($seed.n + ': exactly 1 md BEGIN')
  Assert-Equal $m.mE 1 ($seed.n + ': exactly 1 md END')
  Assert-True ($after1 -match 'TEST-RULE-ONE') ($seed.n + ': rules body present')
  if ($seed.t -match 'my own rules') { Assert-True ($after1 -match 'my own rules') ($seed.n + ': user text preserved') }
  Assert-True (-not ($after1 -match 'TEST-RULE-ONE.*TEST-RULE-ONE')) ($seed.n + ': stale RULES-BODY placeholder removed')
  $null = Run-MiniInstall $case @()
  $after2 = [System.IO.File]::ReadAllText($agents, [System.Text.Encoding]::UTF8)
  Assert-Equal $after2 $after1 ($seed.n + ': second install is byte-identical')
}

Log ''
Log ('--- subtotal after A/B: pass=' + $script:pass + ' fail=' + $script:fail)
Write-Host ''
Write-Host ('SUBTOTAL pass=' + $script:pass + ' fail=' + $script:fail)
if ($script:fail -gt 0) { Write-Host 'FAILURES:'; $script:fails | ForEach-Object { Write-Host ('  ' + $_) } }
