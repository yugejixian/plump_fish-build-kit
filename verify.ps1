<#
.SYNOPSIS
  拿到包之后、安装之前先跑这个：审查包里到底是什么、有没有被改过、上游对不对得上。

.DESCRIPTION
  分四层，越往下越需要网络，也越有说服力：

    1. 完整性   —— 重算全部文件的 SHA256，和 manifest.json 比。证明「你手上这份」
                   和「打包时那份」字节一致。防的是传输损坏和掉包，防不了打包者本身有恶意。
    2. 清单     —— 按类别列出体积、文件数、来源。
    3. 上游     —— 打印打包时从 GitHub API 记下的官方资产名与官方 SHA256。
                   加 -CheckUpstream 会真的下载官方 zip、核对其哈希、解压后逐文件比对；
                   加 -ReferenceDir 则用你自己准备好的官方解压目录做离线比对。
    4. 行为     —— 静态列出 installer 会写哪些路径、动哪些文件、启动什么进程。

  默认不联网。任何一项不过都返回非 0 退出码。

.PARAMETER CheckUpstream
  下载官方 llama.cpp release 资产并与包内文件逐字节比对（需要能访问 github.com）。

.PARAMETER ReferenceDir
  用本地已有的官方解压目录做比对（离线，与 -CheckUpstream 二选一）。

.PARAMETER SkipHash
  跳过 5.6 GB 的哈希重算（快，但第 1 层就没有结论了）。

.EXAMPLE
  .\verify.ps1
  .\verify.ps1 -CheckUpstream
  .\verify.ps1 -ReferenceDir D:\llama.cpp.official
#>
[CmdletBinding()]
param(
  [string]$PackageRoot = '',
  [switch]$CheckUpstream,
  [switch]$SkipHash,
  [string]$ReferenceDir = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if ([string]::IsNullOrWhiteSpace($PackageRoot)) { $PackageRoot = $PSScriptRoot }
if ([string]::IsNullOrWhiteSpace($PackageRoot)) { $PackageRoot = (Get-Location).Path }

$manifestPath = Join-Path $PackageRoot 'manifest.json'
if (-not (Test-Path $manifestPath)) { Write-Host "找不到 manifest.json：$manifestPath" -ForegroundColor Red; exit 2 }

# Two layouts are supported:
#   package   : <root>\payload\<kind>\...        (the delivered folder)
#   installed : <root>\gateway\, <root>\llama_cpp\, ...  (what install.ps1 writes)
# An installed folder only holds part of the manifest, so an absent entry there
# means "not part of this install", not "corrupt".
$script:installedLayout = $false
$payload = Join-Path $PackageRoot 'payload'
if (-not (Test-Path $payload)) {
  if (Test-Path (Join-Path $PackageRoot 'gateway\config.json')) {
    $payload = $PackageRoot
    $script:installedLayout = $true
  } else {
    Write-Host "找不到 payload 目录：$payload（这个目录也不像安装结果）" -ForegroundColor Red
    exit 2
  }
}

$manifest = Get-Content $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
$fail = 0

function Head($t) { Write-Host "`n=== $t ===" -ForegroundColor Cyan }
function Ok($t) { Write-Host "  [OK]   $t" -ForegroundColor Green }
function Bad($t) { Write-Host "  [FAIL] $t" -ForegroundColor Red; $script:fail++ }
function Info($t) { Write-Host "  $t" -ForegroundColor Gray }
function Warn($t) { Write-Host "  [WARN] $t" -ForegroundColor Yellow }

if ($script:installedLayout) { Write-Host "`nDSH 本地模型 · 已安装副本校验" -ForegroundColor White }
else { Write-Host "`nDSH 本地模型傻瓜包 · 安装前审查" -ForegroundColor White }
Write-Host "  包路径 : $PackageRoot"
if ($script:installedLayout) { Write-Host "  模式   : 已安装副本（只校验安装目录里真实存在的文件）" -ForegroundColor Gray }
Write-Host "  打包时间: $($manifest.packedAt)"
Write-Host "  打包机器: $($manifest.packedOn)"
Write-Host "  文件数 : $($manifest.fileCount)"
Write-Host ("  总大小 : {0:N2} GB" -f ($manifest.totalBytes / 1GB))

# ---------------------------------------------------------------- 1. 完整性
Head '1. 完整性（SHA256 逐文件重算）'
if ($SkipHash) {
  Warn '已跳过（-SkipHash），这一层没有结论'
} else {
  $sw = [Diagnostics.Stopwatch]::StartNew()
  $missing = 0; $mismatch = 0; $checked = 0; $notInstalled = 0; $generated = 0
  # Files the installer writes itself: their hash can never match the packaged
  # one in an install, so in installed mode they are checked differently.
  $generatedPaths = @('gateway\config.json', 'gateway\launch-gateway.vbs')
  foreach ($e in $manifest.files) {
    $full = Join-Path $payload $e.path
    if (-not (Test-Path $full)) {
      if ($script:installedLayout) { $notInstalled++; continue }
      Bad "缺失 $($e.path)"; $missing++; continue
    }
    if ($script:installedLayout -and ($generatedPaths -contains $e.path)) {
      $generated++
      if ($e.path -like '*.json') {
        try { $null = Get-Content -LiteralPath $full -Raw -Encoding UTF8 | ConvertFrom-Json } catch { Bad "生成的 $($e.path) 不是合法 JSON" }
      }
      continue
    }
    $h = (Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash
    if ($h -ne $e.sha256) { Bad "哈希不符 $($e.path)"; $mismatch++; continue }
    $checked++
    if ($checked % 250 -eq 0) { Write-Host "    ...已校验 $checked / $($manifest.files.Count)" -ForegroundColor DarkGray }
  }
  if ($missing -eq 0 -and $mismatch -eq 0) {
    Ok ("{0} 个文件全部与清单一致（耗时 {1:N0}s）" -f $checked, $sw.Elapsed.TotalSeconds)
    if ($notInstalled -gt 0) { Info ("另外 {0} 个清单项不属于本安装目录（plugins/、profile-snapshot/、tools/、未选中的模型），已跳过" -f $notInstalled) }
    if ($generated -gt 0) { Info ("{0} 个文件由安装器按本机情况重写（gateway\config.json、gateway\launch-gateway.vbs），只校验存在与可解析" -f $generated) }
    Info '注意：这证明的是「与打包时一致」，不是「内容本身安全」。'
  } else {
    Bad "缺失 $missing 个，哈希不符 $mismatch 个"
  }
}

# 额外文件（清单里没有的）
$onDisk = Get-ChildItem $payload -Recurse -File -Force
$known = @{}
foreach ($e in $manifest.files) { $known[$e.path] = $true }
$extra = @($onDisk | Where-Object { $rel = $_.FullName.Substring($payload.Length).TrimStart('\','/'); -not $known.ContainsKey($rel) })
if ($extra.Count) {
  if ($script:installedLayout) { Info ("安装目录里有 {0} 个文件不在清单里（脚本、文档、日志、另一个运行时），正常" -f $extra.Count) }
  else { Warn ("payload 里有 {0} 个清单外的文件（可能是 PROVENANCE.txt）" -f $extra.Count) }
}

# ---------------------------------------------------------------- 2. 清单
Head '2. 内容清单'
foreach ($group in ($manifest.files | Group-Object kind)) {
  $bytes = ($group.Group | Measure-Object -Property bytes -Sum).Sum
  Info ("{0,-10} {1,4} 个文件  {2,9:N1} MB" -f $group.Name, $group.Count, ($bytes / 1MB))
}

# ---------------------------------------------------------------- 3. 上游
Head '3. 上游来源'
$upProp = $manifest.PSObject.Properties['upstream']
$up = $null
if ($null -ne $upProp) { $up = $upProp.Value }
if ($null -eq $up) {
  Warn '打包时没有记录上游信息（当时网络不可用，或用了 -SkipUpstream）'
  Info '这种情况下只能依赖第 1 层，而第 1 层不覆盖「打包者本身是否有恶意」。'
} else {
  Info "工具   : $($up.tool)"
  Info "版本   : $($up.version)"
  Info "commit : $($up.commit)"
  Info "release: $($up.release)"
  foreach ($a in $up.assets) {
    Info ("资产   : {0}" -f $a.name)
    Info ("  官方 SHA256 : {0}" -f $a.digest)
    Info ("  大小        : {0:N1} MB" -f ($a.size / 1MB))
  }
  if ($up.verifiedAtPack) {
    Ok '打包时已下载官方资产并逐文件比对通过'
  } else {
    Warn '打包时【没有】做逐字节比对（本机无法下载 github.com 资产）'
    Info '下面两种方式可以补上这一环：'
    Info '  .\verify.ps1 -CheckUpstream     （你这台机器能下 github.com 的话）'
    Info '  .\verify.ps1 -ReferenceDir <官方解压目录>   （你自己下好后离线比对）'
  }
}

# 三类产物各自核到了什么程度
if ($null -ne $manifest.PSObject.Properties['verification']) {
  $vProp = $manifest.PSObject.Properties['verification']
$v = $null
if ($null -ne $vProp) { $v = $vProp.Value }
  Info ''
  if ($v.binaryVerified) { Ok '二进制：已验证（与官方 release 资产逐字节一致）' }
  else { Warn '二进制：未验证' }
  if ($v.modelVerified) { Ok '模型权重：已验证（与 ModelScope 仓库公布哈希一致）' }
  else { Warn '模型权重：未验证' }
  if ($v.pluginVerified) { Ok '插件：已验证（npm integrity + 逐文件一致）' }
  else { Warn ("插件：未验证 —— {0}" -f $v.pluginNote) }
}
if ($null -ne $manifest.PSObject.Properties['modelUpstream']) {
  Info ''
  Info '模型文件对照：'
  foreach ($m in $manifest.modelUpstream) {
    Info ("  {0,-46} {1}  {2}" -f $m.file, $(if ($m.match) { 'MATCH' } else { 'DIFF ' }), $m.repo)
  }
}

# 插件详情：包内若带 plugins-verified.json 就逐条展示
$pvPath = Join-Path $PackageRoot 'plugins-verified.json'
if (Test-Path $pvPath) {
  $pv = Get-Content $pvPath -Raw -Encoding UTF8 | ConvertFrom-Json
  Info ''
  Info ("插件对照（npm registry，校验于 {0}）：" -f $pv.checkedAt)
  $pvOk = $true
  foreach ($p in $pv.plugins) {
    if ($p.ok) {
      Info ("  {0,-22} v{1,-9} integrity OK，{2} 个文件全一致" -f $p.name, $p.version, $p.filesMatched)
    } else {
      $pvOk = $false
      Bad ("插件 {0} 未通过：{1}" -f $p.name, $(if ($p.error) { $p.error } else { "差分 $($p.filesDiff) 个" }))
    }
  }
  if (-not $pvOk) { $script:fail++ }
} else {
  Info ''
  Info '包内没有 plugins-verified.json —— 插件未校验，有网时可运行：.\plugins-verify.ps1'
}

# 其它运行时（CPU / Vulkan）：打包时已逐字节核对官方 sha256，这里只回放记录
foreach ($rtk in @(@{ key = 'upstreamCpu'; label = 'CPU' }, @{ key = 'upstreamVulkan'; label = 'Vulkan' })) {
  $prop = $manifest.PSObject.Properties[$rtk.key]
  if ($null -eq $prop -or $null -eq $prop.Value) { continue }
  $rec = $prop.Value
  Info ''
  Info ("运行时 : {0}  ->  payload/{1}" -f $rtk.label, $rec.payloadDir)
  foreach ($a in $rec.assets) {
    Info ("  资产  : {0}  ({1:N1} MB)" -f $a.name, ($a.size / 1MB))
    Info ("  官方 SHA256 : {0}" -f $a.digest)
  }
  if ($rec.verifiedAtPack) { Ok ("{0} 运行时：打包时已与官方哈希逐字节核对" -f $rtk.label) }
  else { Warn ("{0} 运行时：未与官方哈希核对" -f $rtk.label) }
  if ($rec.note) { Info ("  说明  : {0}" -f $rec.note) }
}

# 上游比对
function Compare-UpstreamTree {
  param([string]$TreeRoot, [string]$PayloadSubdir = 'llama_cpp')
  $ours = Get-ChildItem (Join-Path $payload $PayloadSubdir) -Recurse -File
  $theirs = @{}
  foreach ($f in (Get-ChildItem $TreeRoot -Recurse -File)) {
    if (-not $theirs.ContainsKey($f.Name)) { $theirs[$f.Name] = $f }
  }
  $match = 0; $diff = 0; $absent = 0
  foreach ($f in $ours) {
    if (-not $theirs.ContainsKey($f.Name)) { $absent++; continue }
    $a = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash
    $b = (Get-FileHash -LiteralPath $theirs[$f.Name].FullName -Algorithm SHA256).Hash
    if ($a -eq $b) { $match++ } else { Bad "与官方不一致：$($f.Name)"; $diff++ }
  }
  Ok "与官方一致 $match 个"
  if ($diff -gt 0) { } elseif ($absent -gt 0) { Warn "官方包里没找到对应文件 $absent 个（可能被裁剪或改名）" }
  if ($match -eq 0) { Bad '没有一个文件能和官方对上' }
}

if ($ReferenceDir) {
  Head '3a. 与本地官方目录比对'
  if (-not (Test-Path $ReferenceDir)) { Bad "参照目录不存在：$ReferenceDir" }
  else { Compare-UpstreamTree -TreeRoot $ReferenceDir }
}

if ($CheckUpstream -and $null -ne $up) {
  Head '3b. 下载官方资产并比对'
  $tmp = Join-Path $env:TEMP ("dsh-verify-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
  New-Item -ItemType Directory -Path $tmp -Force | Out-Null
  try {
    # 预检：下载域通常和 api 域不同，连不上就别干等超时
    $reachable = $false
    try {
      $head = [System.Net.HttpWebRequest]::Create($up.assets[0].url)
      $head.Method = 'HEAD'
      $head.Timeout = 10000
      $head.AllowAutoRedirect = $true
      $head.UserAgent = 'dsh-turnkey'
      $r = $head.GetResponse()
      $reachable = $true
      $r.Close()
    } catch {
      $reachable = $false
    }
    if (-not $reachable) {
      Warn '连不上 github.com 的下载域，跳过联网比对'
      Info '可以改用离线方式：自己在有网的机器上下载上面那两个 zip，解压后执行'
      Info ('  .\verify.ps1 -ReferenceDir <解压目录>')
      throw 'abort'
    }
    foreach ($a in $up.assets) {
      $zip = Join-Path $tmp $a.name
      Info "下载 $($a.name)（$([math]::Round($a.size/1MB)) MB）..."
      try {
        $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest -Uri $a.url -OutFile $zip -UseBasicParsing -TimeoutSec 900
      } catch {
        Bad "下载失败：$($_.Exception.Message)"
        throw 'abort'
      }
      $got = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLower()
      $want = ($a.digest -replace '^sha256:', '').ToLower()
      if ($got -eq $want) { Ok "官方哈希匹配 $($a.name)" }
      else { Bad "官方哈希不符 $($a.name)：得到 $got，应为 $want"; throw 'abort' }
      $ex = Join-Path $tmp ($a.name -replace '\.zip$', '')
      Expand-Archive -LiteralPath $zip -DestinationPath $ex -Force
      Compare-UpstreamTree -TreeRoot $ex
    }
  } catch {
    if ($_.Exception.Message -ne 'abort') { Warn "联网比对未完成：$($_.Exception.Message)" }
  } finally {
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
  }
}

# ---------------------------------------------------------------- 4. 行为
Head '4. 安装时的行为（静态清单）'
$installer = Join-Path $PackageRoot 'install.ps1'
if (Test-Path $installer) {
  Info 'install.ps1 只会做下面这些事：'
  Info '  · 复制 payload 到 %LOCALAPPDATA%\dsh-local-llm（可用 -TargetDir 改）'
  Info '  · 在 ~\.dsh\profiles\desktop\cordis.patch.yml 追加一个标记块（改前备份 .dsh-llm.bak）'
  Info '  · 在 ~\.dsh\AGENTS.md 追加一个标记块（改前备份）'
  Info '  · 在「启动」文件夹建一个快捷方式（可用 -NoStartup 跳过）'
  Info '  · 从 DSH 的 app.asar 补齐 profile 的宿主依赖（node_modules，只增不删）'
  Info '  · 按显卡自动选择运行时：CUDA / Vulkan / CPU（三个构建都随包分发）'
  Info '  · 运行它自己的 selftest.mjs 做一次自检'
  Info '不写注册表、不装服务、不提权、不联网。'
  $suspicious = Select-String -Path $installer -Pattern 'Invoke-WebRequest|Invoke-RestMethod|curl|wget|Start-BitsTransfer|New-ItemProperty|reg\.exe|schtasks' -AllMatches
  if ($suspicious) {
    Warn 'install.ps1 里出现了可能联网或改系统的关键字，请人工过一眼：'
    $suspicious | ForEach-Object { Info ("  第 {0} 行: {1}" -f $_.LineNumber, $_.Line.Trim()) }
  } else {
    Ok 'install.ps1 内没有发现联网或改系统的调用'
  }
} else { Warn '包里没有 install.ps1' }

# ---------------------------------------------------------------- 结论
Write-Host ''
$vProp = $manifest.PSObject.Properties['verification']
$v = $null
if ($null -ne $vProp) { $v = $vProp.Value }
$binaryOk = ($null -ne $up -and $up.verifiedAtPack) -or ($v -and $v.binaryVerified)
$modelOk = ($v -and $v.modelVerified)
$pluginOk = ($v -and $v.pluginVerified)
if ($fail -eq 0) {
  if ($script:installedLayout) { Write-Host '结论：已安装副本与清单一致（安装器生成的 2 个文件按存在性校验）。' -ForegroundColor Green }
  else { Write-Host '结论：包完整，第 1、2、4 层通过。' -ForegroundColor Green }
  if ($binaryOk -and $modelOk -and $pluginOk) {
    Write-Host '      第 3 层：二进制、模型权重、插件全部与上游公布哈希核对一致，无盲区。' -ForegroundColor Green
    Write-Host '      剩余风险：上游自己若被投毒则此层无法发现；作者脚本是纯文本，可自行逐行阅读。' -ForegroundColor Yellow
  } elseif ($binaryOk -or $modelOk -or $pluginOk) {
    Write-Host ('      第 3 层：部分完成（二进制 {0}，模型 {1}，插件 {2}）。' -f `
        $(if ($binaryOk) { '已验证' } else { '未验证' }), `
        $(if ($modelOk) { '已验证' } else { '未验证' }), `
        $(if ($pluginOk) { '已验证' } else { '未验证' })) -ForegroundColor Yellow
  } else {
    Write-Host '      第 3 层（上游比对）尚未完成 —— 二进制、模型、插件的来源仍需要你自己判断。' -ForegroundColor Yellow
  }
  exit 0
} else {
  Write-Host "结论：有 $fail 项没通过，不建议安装。" -ForegroundColor Red
  exit 1
}
