<#
.SYNOPSIS
  对照 npm registry 校验插件包：下载官方 tarball、核对 integrity、解压后逐文件比对。

.DESCRIPTION
  这是 verify.ps1 第 3 层里「插件」那一段的完整版。需要能访问 registry.npmjs.org；
  跑完把结果写进 plugins-verified.json，verify.ps1 会自动读它。

  校验链：
    registry 的 dist.integrity (sha512)  →  tarball 哈希
    tarball 内的文件                      →  与 payload\plugins\<name> 逐字节比对

.PARAMETER PluginRoot
  待校验的插件目录（默认 <包>\payload\plugins）。

.PARAMETER ResultJson
  结果输出路径（默认 <包>\plugins-verified.json）。

.EXAMPLE
  .\plugins-verify.ps1
#>
[CmdletBinding()]
param(
  [string]$PluginRoot = '',
  [string]$ResultJson = ''
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($PluginRoot)) {
  $base = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
  $PluginRoot = Join-Path $base 'payload\plugins'
}
if ([string]::IsNullOrWhiteSpace($ResultJson)) {
  $ResultJson = Join-Path (Split-Path $PluginRoot -Parent | Split-Path -Parent) 'plugins-verified.json'
}
if (-not (Test-Path $PluginRoot)) { Write-Host "找不到插件目录：$PluginRoot" -ForegroundColor Red; exit 2 }

$tmp = Join-Path $env:TEMP ('dsh-plugins-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null

function HexToBase64([string]$hex) {
  $bytes = New-Object byte[] ($hex.Length / 2)
  for ($i = 0; $i -lt $hex.Length; $i += 2) { $bytes[$i / 2] = [Convert]::ToByte($hex.Substring($i, 2), 16) }
  return [Convert]::ToBase64String($bytes)
}

$results = @()
$allOk = $true
Write-Host "`n插件校验（对照 npm registry）`n" -ForegroundColor Cyan

foreach ($dir in (Get-ChildItem $PluginRoot -Directory)) {
  $name = $dir.Name
  $pkgPath = Join-Path $dir.FullName 'package.json'
  if (-not (Test-Path $pkgPath)) { Write-Host "  [SKIP] $name 没有 package.json" -ForegroundColor Yellow; continue }
  $pkg = Get-Content $pkgPath -Raw -Encoding UTF8 | ConvertFrom-Json

  Write-Host "  --- $name@$($pkg.version) ---"
  $entry = [pscustomobject]@{
    name = $name; version = $pkg.version; license = $pkg.license
    integrityOk = $false; filesMatched = 0; filesDiff = 0
    onlyOurs = @(); onlyTarball = @(); mismatch = @(); ok = $false; error = $null
  }

  try {
    $meta = Invoke-RestMethod -Uri ("https://registry.npmjs.org/{0}/{1}" -f $name, $pkg.version) -TimeoutSec 30
    $dist = $meta.dist
    Write-Host ("      registry tarball : {0}" -f (Split-Path $dist.tarball -Leaf))
    Write-Host ("      integrity        : {0}" -f $dist.integrity)

    $tgz = Join-Path $tmp "$name-$($pkg.version).tgz"
    $null = & curl.exe -L --fail --silent --show-error --max-time 600 -o $tgz $dist.tarball 2>&1
    if ($LASTEXITCODE -ne 0) { throw "下载失败 exit=$LASTEXITCODE" }

    # sha512 integrity
    $sha512hex = (Get-FileHash $tgz -Algorithm SHA512).Hash
    $sha512b64 = HexToBase64 $sha512hex
    $expected = $dist.integrity -replace '^sha512-', ''
    if ($sha512b64 -eq $expected) {
      Write-Host "      [OK]   integrity 匹配（sha512）" -ForegroundColor Green
      $entry.integrityOk = $true
    } else {
      Write-Host "      [FAIL] integrity 不符" -ForegroundColor Red
      Write-Host "             期望 $expected" -ForegroundColor Red
      Write-Host "             实际 $sha512b64" -ForegroundColor Red
      $allOk = $false
    }

    # 解压（npm tarball 顶层是 package/）
    $ex = Join-Path $tmp "$name-extract"
    New-Item -ItemType Directory -Path $ex -Force | Out-Null
    $null = & tar.exe -xzf $tgz -C $ex 2>&1
    if ($LASTEXITCODE -ne 0) { throw "解压失败 exit=$LASTEXITCODE" }
    $pkgRoot = Join-Path $ex 'package'
    if (-not (Test-Path $pkgRoot)) { $pkgRoot = $ex }

    # 逐文件比对（按相对路径）
    $theirs = @{}
    foreach ($f in (Get-ChildItem $pkgRoot -Recurse -File -Force)) {
      $rel = $f.FullName.Substring($pkgRoot.Length).TrimStart('\', '/').Replace('\', '/')
      $theirs[$rel] = $f.FullName
    }
    $ours = @{}
    foreach ($f in (Get-ChildItem $dir.FullName -Recurse -File -Force)) {
      $rel = $f.FullName.Substring($dir.FullName.Length).TrimStart('\', '/').Replace('\', '/')
      $ours[$rel] = $f.FullName
    }

    foreach ($rel in $ours.Keys) {
      if (-not $theirs.ContainsKey($rel)) { $entry.onlyOurs += $rel; continue }
      $a = (Get-FileHash -LiteralPath $ours[$rel] -Algorithm SHA256).Hash
      $b = (Get-FileHash -LiteralPath $theirs[$rel] -Algorithm SHA256).Hash
      if ($a -eq $b) { $entry.filesMatched++ } else { $entry.mismatch += $rel; $entry.filesDiff++ }
    }
    foreach ($rel in $theirs.Keys) { if (-not $ours.ContainsKey($rel)) { $entry.onlyTarball += $rel } }

    Write-Host ("      文件：一致 {0}，不一致 {1}，仅我方有 {2}，仅 tarball 有 {3}" -f `
        $entry.filesMatched, $entry.filesDiff, $entry.onlyOurs.Count, $entry.onlyTarball.Count)
    if ($entry.mismatch.Count) {
      Write-Host "      !! 内容不一致：$($entry.mismatch -join ', ')" -ForegroundColor Red
      $allOk = $false
    }
    if ($entry.onlyOurs.Count) {
      Write-Host ("      ?? 仅我方有的文件（可能是安装时生成）：{0}" -f (($entry.onlyOurs | Select-Object -First 6) -join ', ')) -ForegroundColor Yellow
    }
    $entry.ok = $entry.integrityOk -and ($entry.filesDiff -eq 0)
    if (-not $entry.ok) { $allOk = $false }
  } catch {
    $entry.error = $_.Exception.Message
    $allOk = $false
    Write-Host "      [FAIL] $($_.Exception.Message)" -ForegroundColor Red
  }
  $results += $entry
}

Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue

$doc = [pscustomobject]@{
  checkedAt = (Get-Date -Format o)
  registry  = 'https://registry.npmjs.org'
  allOk     = $allOk
  plugins   = $results
}
$jsonDir = Split-Path $ResultJson -Parent
if ($jsonDir -and -not (Test-Path $jsonDir)) { New-Item -ItemType Directory -Path $jsonDir -Force | Out-Null }
[System.IO.File]::WriteAllText($ResultJson, ($doc | ConvertTo-Json -Depth 5), (New-Object System.Text.UTF8Encoding($false)))

Write-Host ''
if ($allOk) {
  Write-Host "结论：所有插件都与 npm registry 公布的 integrity 一致，且内容逐文件匹配。" -ForegroundColor Green
  exit 0
} else {
  Write-Host "结论：有插件未通过校验，见上。" -ForegroundColor Red
  exit 1
}
