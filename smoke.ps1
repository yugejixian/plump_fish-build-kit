#requires -Version 5.1
<#
.SYNOPSIS
    Check that the local model is really reachable FROM DSH, not just from curl.

.DESCRIPTION
    Three things must hold for DSH itself to be able to hand a job to the local
    model. Curl proves none of them:

      1. the profile patch wires the provider AND enables child model selection
         (the tool instance needs modelSelectionSettings: true - without it the
         subagent tool never exposes provider/model, and the settings service is
         never sampled)
      2. the gateway advertises the expected model id over /v1/models
      3. a real request with a DSH-sized prompt actually arrived. DSH's agent
         system prompt is thousands of tokens; a hand-written curl is tens. If the
         biggest prompt ever seen is a few hundred tokens, DSH has not called it.

    Exit code 0 = all three hold, 1 = something is still missing.
#>
[CmdletBinding()]
param(
    [string]$TargetDir = 'D:\DSH-LocalLLM',
    [string]$DshHome = '',
    [string]$ProviderId = 'local-gguf',
    [string]$ModelId = 'local-vl',
    [int]$MinPromptTokens = 2000,
    [int]$RecentEntries = 8
)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($DshHome)) { $DshHome = Join-Path $env:USERPROFILE '.dsh' }
$patchPath = Join-Path $DshHome 'profiles\desktop\cordis.patch.yml'
$gwLog = Join-Path $TargetDir 'logs\gateway.log'
$lsLog = Join-Path $TargetDir 'logs\llama-server.log'

$script:fail = 0
function Ok($m) { Write-Host "  [OK]   $m" -ForegroundColor Green }
function Bad($m) { Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:fail++ }
function Info($m) { Write-Host "         $m" -ForegroundColor Gray }
function Warn($m) { Write-Host "  [WARN] $m" -ForegroundColor Yellow }
function Head($m) { Write-Host "`n=== $m ===" -ForegroundColor Cyan }

Write-Host "`n本地模型 · DSH 连通性体检" -ForegroundColor White
Write-Host "  patch : $patchPath"
Write-Host "  logs  : $TargetDir\logs"
Write-Host "  期望  : provider=$ProviderId  model=$ModelId  大 prompt>$MinPromptTokens token"

# ---------------------------------------------------------------- 1. profile patch
Head '1. DSH 配置(provider 路由 + 子代理模型选择开关)'
if (-not (Test-Path $patchPath)) {
    Bad "找不到 profile patch:$patchPath(DSH 还没启动过?先装 DSH 并启动一次)"
} else {
    $cfg = [System.IO.File]::ReadAllText($patchPath, [System.Text.Encoding]::UTF8)

    if ($cfg -match ('(?m)^\s*(?:providers:)?\s*' + [regex]::Escape($ProviderId) + '\s*:')) {
        Ok "provider '$ProviderId' 已注册"
    } else {
        Bad "provider '$ProviderId' 不在 patch 里(安装时第 6 段没跑或标记块被删)"
    }

    if ($cfg -match 'baseURL:\s*http://127\.0\.0\.1:8099/v1') {
        Ok 'baseURL 指向网关 127.0.0.1:8099/v1'
    } else {
        Bad 'baseURL 不是 http://127.0.0.1:8099/v1'
    }

    if ($cfg -match ('(?m)^\s*-\s*id:\s*' + [regex]::Escape($ModelId) + '\s*$')) {
        Ok "模型 id '$ModelId' 已声明"
    } else {
        Bad "模型 id '$ModelId' 没有声明"
    }

    # the tool instance must opt in, otherwise provider/model are never exposed
    $toolBlock = [regex]::Match($cfg, '(?ms)^\s*-\s*id:\s*tool-subagent\s*$(.*?)(?=^\s*-\s*id:|\z)')
    $toolOn = $false
    if ($toolBlock.Success) {
        $toolOn = ($toolBlock.Groups[1].Value -match 'modelSelectionSettings:\s*true')
        if ($toolOn) { Ok 'tool-subagent 已开 modelSelectionSettings: true' }
        else { Bad 'tool-subagent 缺 modelSelectionSettings: true —— subagent 工具不会暴露 provider/model' }
        if ($toolBlock.Groups[1].Value -match 'provider:\s*spawn') { Ok 'tool-subagent 仍指向 spawn provider' }
        elseif ($toolBlock.Groups[1].Value -match 'provider:\s*fork') { Bad 'tool-subagent 被改成了 fork provider(应该只给 spawn 那行开)' }
    } else {
        Bad 'patch 里没有 tool-subagent 行(需要 provider: spawn / toolName: subagent / modelSelectionSettings: true)'
    }

    # the host service must be present, or composition throws
    $svcBlock = [regex]::Match($cfg, '(?ms)^\s*-\s*id:\s*subagent-model-selection-settings\s*$(.*?)(?=^\s*-\s*id:|\z)')
    if ($svcBlock.Success) {
        if ($svcBlock.Groups[1].Value -match 'enabled:\s*true') { Ok '子代理模型选择开关 enabled: true' }
        else { Warn '子代理模型选择开关 enabled 不是 true(开了工具开关但没开这个,等于不让选)' }
        if ($svcBlock.Groups[1].Value -match [regex]::Escape($ProviderId)) { Ok "allowedModels 含 $ProviderId" }
        else { Bad "allowedModels 里没有 $ProviderId(显式选模型会被拒)" }
    } else {
        if ($toolOn) { Bad '工具开了 modelSelectionSettings 但缺少 subagent-model-selection-settings 服务行 —— 这会让人工智能组合直接报错' }
        else { Warn '没有 subagent-model-selection-settings 行(子代理不能用本地模型)' }
    }

    Info '提示:这些值是 volatile 的,改完必须重启 DSH,并且在新会话里才生效(老会话不重采样)'
}

# ---------------------------------------------------------------- 2. gateway
Head '2. 网关公布的模型'
try {
    $models = Invoke-RestMethod 'http://127.0.0.1:8099/v1/models' -TimeoutSec 10
    $hit = @($models.data | Where-Object { $_.id -eq $ModelId })
    if ($hit.Count -ge 1) {
        Ok "/v1/models 里有 '$ModelId'"
        $m0 = $hit[0]
        if ($m0.name) { Info ("name: " + $m0.name) }
        $mods = @()
        if ($m0.architecture -and $m0.architecture.input_modalities) { $mods = @($m0.architecture.input_modalities) }
        if ($mods -contains 'image') { Ok 'input modalities 含 image(能看图)' }
        else { Warn ('input modalities = ' + ($mods -join ',') + ' —— 视觉可能没生效') }
    } else {
        Bad "/v1/models 里没有 '$ModelId'(网关活着但模型没注册)"
    }
} catch {
    Bad ('网关不可达: ' + $_.Exception.Message)
    Info '先启动网关:双击开始菜单启动项里的 DSH Local LLM Gateway,或跑 gateway-control.cmd start'
}

# ---------------------------------------------------------------- 3. real traffic
Head '3. 真实流量(DSH 到底有没有调用过)'
if (-not (Test-Path $lsLog)) {
    Bad "找不到 llama-server 日志:$lsLog"
} else {
    $lines = Get-Content $lsLog -Encoding UTF8 -ErrorAction SilentlyContinue
    $tokens = @()
    foreach ($ln in $lines) {
        $mm = [regex]::Match($ln, 'prompt eval time\s*=\s*[\d.]+\s*ms\s*/\s*(\d+)\s*tokens')
        if ($mm.Success) { $tokens += [int]$mm.Groups[1].Value }
    }
    if ($tokens.Count -eq 0) {
        Bad 'llama-server 日志里没有任何 prompt eval 记录(模型还没被调用过)'
    } else {
        $maxPrompt = ($tokens | Measure-Object -Maximum).Maximum
        $recent = @($tokens | Select-Object -Last $RecentEntries)
        Info ("累计请求 " + $tokens.Count + " 次,历史上最大的 prompt = " + $maxPrompt + " token")
        Info ("最近 " + $recent.Count + " 次:" + ($recent -join ', ') + ' token')
        $bigRecent = @($recent | Where-Object { $_ -gt $MinPromptTokens })
        if ($bigRecent.Count -ge 1) {
            Ok ("最近 " + $RecentEntries + " 次里有 " + $bigRecent.Count + " 次 prompt > " + $MinPromptTokens + " token(DSH 级请求)")
        } elseif ($maxPrompt -gt $MinPromptTokens) {
            Warn ("历史上有过大 prompt(" + $maxPrompt + " token),但最近 " + $RecentEntries + " 次都不是 —— 可能上次验证之后重启过")
        } else {
            Bad ("最大的 prompt 只有 " + $maxPrompt + " token,达不到 " + $MinPromptTokens + " —— 这只是 curl 级别的调用,DSH 从未调过本地模型")
            Info ("DSH 的 agent 系统提示是几千 token;若被调用,这里必然出现 > " + $MinPromptTokens + " 的记录")
            Info ("修法:重启 DSH -> 开一个新会话 -> 让子代理用 provider=" + $ProviderId + " model=" + $ModelId)
        }
    }
}

if (Test-Path $gwLog) {
    $gwTail = @(Get-Content $gwLog -Encoding UTF8 -ErrorAction SilentlyContinue | Where-Object { $_ -match 'POST /v1/chat' } | Select-Object -Last 3)
    if ($gwTail.Count) {
        Info '最近 3 条网关请求:'
        foreach ($g in $gwTail) { Info ('  ' + $g.Trim()) }
    }
}

# ---------------------------------------------------------------- summary
Head '结论'
if ($script:fail -eq 0) {
    Write-Host '  三项全部通过:DSH 有路由、网关有模型、并且真的发生过大 prompt 调用。' -ForegroundColor Green
    exit 0
} else {
    Write-Host ("  有 " + $script:fail + " 项没通过,见上面的 [FAIL]。") -ForegroundColor Red
    exit 1
}
