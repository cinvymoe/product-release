#Requires -Version 5.1
<#
.SYNOPSIS
    sync.ps1 — 从内网 NAS 拉取制品通道的大文件（Windows 交付端）

.DESCRIPTION
    按 artifacts\MANIFEST.sha256 逐项拉取 update.img / 产品运行时 / USB 升级包，并校验 sha256。

    NAS 来源（优先级从高到低）：
      1. -Url 参数或 $env:ARTIFACTS_URL  —— \\nas\share\product-release 或映射盘符
      2. -Mount 参数或 $env:ARTIFACTS_MOUNT —— 已映射的本地路径，如 Z:\product-release
      3. artifacts\nas.conf 中的 ARTIFACTS_URL

.PARAMETER Only
    flash | products | (省略=全部)

.PARAMETER Verify
    只校验本地已有文件，不下载

.PARAMETER List
    只列清单

.EXAMPLE
    .\deploy\lib\sync.ps1 -Url \\nas\release\product-release

.EXAMPLE
    .\deploy\lib\sync.ps1 -Only flash -Verify
#>
[CmdletBinding()]
param(
    [string]$Url = '',
    [string]$Mount = '',
    [ValidateSet('', 'flash', 'products')]
    [string]$Only = '',
    [switch]$Verify,
    [switch]$List
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot  = Split-Path -Parent (Split-Path -Parent $ScriptDir)
$Artifacts = Join-Path $RepoRoot 'artifacts'
$Manifest  = Join-Path $Artifacts 'MANIFEST.sha256'

function Write-Ok([string]$m)   { Write-Host "  OK $m" -ForegroundColor Green }
function Write-Warn2([string]$m){ Write-Host "  !! $m" -ForegroundColor Yellow }

# ---- 来源解析 ----
$nasConf = Join-Path $Artifacts 'nas.conf'
if (-not $Url -and -not $Mount -and (Test-Path $nasConf)) {
    Get-Content $nasConf | Where-Object { $_ -match '^\s*ARTIFACTS_URL\s*=' } | ForEach-Object {
        $Url = ($_ -split '=', 2)[1].Trim().Trim('"').Trim("'")
    }
}
if (-not $Url -and $env:ARTIFACTS_URL) { $Url = $env:ARTIFACTS_URL }
if (-not $Mount -and $env:ARTIFACTS_MOUNT) { $Mount = $env:ARTIFACTS_MOUNT }

$Src = if ($Mount) { $Mount } else { $Url }
if (-not $Src) { throw '未配置制品来源：用 -Url / -Mount，或设置 $env:ARTIFACTS_URL，或写 artifacts\nas.conf' }

if (-not (Test-Path $Manifest)) { throw "缺少清单 $Manifest（由构建机 release-stage 生成）" }

# ---- 清单筛选 ----
$entries = Get-Content $Manifest |
    Where-Object { $_ -match '\S' -and $_ -notmatch '^\s*#' } |
    ForEach-Object {
        $parts = $_ -split '  ', 2
        [pscustomobject]@{ Sha256 = $parts[0]; Rel = $parts[1] }
    }

if ($Only) { $entries = $entries | Where-Object { $_.Rel -like "$Only/*" } }
if (-not $entries) { throw "清单中没有匹配 -Only=$Only 的条目" }

if ($List) { $entries | ForEach-Object { $_.Rel }; exit 0 }

function Test-One {
    param($e)
    $local = Join-Path $Artifacts $e.Rel
    if (-not (Test-Path $local)) { Write-Host "  缺失: $($e.Rel)"; return $false }
    $got = (Get-FileHash -Path $local -Algorithm SHA256).Hash.ToLower()
    if ($got -ne $e.Sha256.ToLower()) { Write-Host "  不匹配: $($e.Rel)"; return $false }
    return $true
}

if ($Verify) {
    $fail = 0
    foreach ($e in $entries) { if (-not (Test-One $e)) { $fail = 1 } }
    if ($fail -eq 0) { Write-Ok "全部 $($entries.Count) 个文件校验通过"; exit 0 }
    throw '校验失败'
}

# ---- 下载 ----
Write-Host "制品来源: $Src"
Write-Host "待同步: $($entries.Count) 个文件"

$fail = 0
foreach ($e in $entries) {
    $local = Join-Path $Artifacts $e.Rel
    $dir = Split-Path -Parent $local
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

    $remote = Join-Path $Src $e.Rel
    if (-not (Test-Path $remote)) {
        Write-Host "  !! 来源缺失: $($e.Rel)"; $script:fail = 1; continue
    }
    Copy-Item -Path $remote -Destination $local -Force
    if (Test-One $e) { Write-Ok $e.Rel } else { $script:fail = 1 }
}

if ($fail -ne 0) { throw '部分文件同步或校验失败' }
Write-Ok "制品已同步并校验（$($entries.Count) 个文件）"
