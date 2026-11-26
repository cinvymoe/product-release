#Requires -Version 5.1
<#
.SYNOPSIS
    factory-deploy.ps1 — Windows 出厂部署（只支持 factory 流程）

.DESCRIPTION
    七步流程（与交付流程图一致）：
      1 校验制品 (sha256)
      2 选产品 + 板型
      3 校验 md5 + 烧录固件（默认按 manifest.toml 的 [flash] strategy）
      4 出厂擦除
      5 推产品文件（运行时 + 出厂配置 + 最小 USB 包）
      6 覆盖 custom（公司 / APN / MQTT）
      7 装自启 + 冷启动验收
         - ARM32 会先禁用出厂固件的 pre_init/S10lv_demo（它抢 DRM master 和 CMA，
           导致 Qt app 起得来但屏幕停在 LVGL demo/开机 logo），再装 S10qt-app-*
         - shell 脚本推送时统一转 LF（CRLF 会导致 shebang 失效）
         - 冷启动后除 pidof 外，还校验 DRM master 确实归本程序

    烧录全自动：
      - 启动时检查 Rockchip USB 驱动，缺 rockusb/android_winusb 时用 pnputil 静默预装
      - adb 缺失时自动解压 tools\windows\platform-tools.zip（优先随包版本，最后才用 PATH）
      - upgrade_tool.exe 缺失时自动解压 tools\windows\upgrade_tool_v2.46.zip
      - ARM32 不再交互询问，自动轮询 upgrade_tool LD 等待 maskrom
      - 烧录后自动等待 adb 设备上线，无需手动干预
      - strategy=partition 时按 parameter.txt 的 CMDLINE 顺序逐分区写：
        di -p parameter.txt，di -uboot/-misc/-boot/-recovery/-rootfs/-oem/-userdata。
        未定义缩写的分区用 `-<分区名>`（Rockchip Linux/GPT 标准用法），
        boot 优先用 manifest [flash] boot（如 boot_emmc.img）。
      - strategy=update 时走整包 `uf update.img`。
      - ARM64 仍为 `adb reboot loader` + 整包 `uf`。

.PARAMETER Product
    folding | loader | truckcrane | grabber | reachstacker

.PARAMETER Custom
    custom/ 下的客户代号目录名（可选）

.PARAMETER SkipFlash
    跳过烧录（设备已烧好固件时用）

.PARAMETER FlashStrategy
    auto(默认) | partition | update
    auto 读取 flash\<board>\manifest.toml 的 [flash] strategy，缺省按架构推断
    (arm32 -> partition, arm64 -> update)。
    partition 按 parameter.txt 的分区名逐个 di（含 -rootfs/-oem/-userdata）。

.PARAMETER FlashWaitSec
    自动等待板子进入 maskrom/loader 的超时（秒，默认 180）

.PARAMETER BootWaitSec
    烧录后自动等待 adb 设备上线的超时（秒，默认 180）

.PARAMETER AutoSync
    制品缺失时自动执行 deploy\lib\sync.ps1 从制品通道拉取

.PARAMETER SkipDriver
    跳过 Rockchip USB 驱动检查（默认会检测 rockusb.inf / android_winusb.inf，
    缺失时解压 DriverAssitant_v5.13.zip 并用 pnputil 静默预装）

.PARAMETER DryRun
    只打印计划，不改动任何东西

.EXAMPLE
    .\deploy\factory-deploy.ps1 -Product loader

.EXAMPLE
    .\deploy\factory-deploy.ps1 -Product loader -AutoSync

.EXAMPLE
    .\deploy\factory-deploy.ps1 -Product reachstacker -Custom acme -DryRun

.NOTES
    需要：管理员 PowerShell。adb 与 upgrade_tool 都优先用 tools\windows 下的随包工具，
    缺失时自动解压 platform-tools.zip / upgrade_tool_v2.46.zip；adb 才回退系统 PATH。
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [ValidateSet('folding', 'loader', 'truckcrane', 'grabber', 'reachstacker')]
    [string]$Product,

    [string]$Custom = '',
    [switch]$SkipFlash,
    [switch]$SkipVerify,
    [switch]$DryRun,
    [switch]$Yes,
    [switch]$List,

    [ValidateSet('auto', 'partition', 'update')]
    [string]$FlashStrategy = 'auto',
    [int]$FlashWaitSec = 180,
    [int]$BootWaitSec = 180,
    [switch]$AutoSync,
    [switch]$SkipDriver
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$ScriptDir  = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot   = Split-Path -Parent $ScriptDir
$Artifacts  = Join-Path $RepoRoot 'artifacts'
$DeviceDir  = '/data/local/tmp/qt-rust-demo'

if ($List) {
    'folding', 'loader', 'truckcrane', 'grabber', 'reachstacker' | ForEach-Object { $_ }
    exit 0
}

if (-not $Product) { throw "必须指定 -Product <folding|loader|truckcrane|grabber|reachstacker>" }

# ---- 产品表 ----
$Products = @{
    folding      = @{ Arch = 'arm32'; Board = 'rk3506';       Crate = 'qt-app-folding' }
    loader       = @{ Arch = 'arm32'; Board = 'rk3506';       Crate = 'qt-app-loader' }
    truckcrane   = @{ Arch = 'arm32'; Board = 'rk3506';       Crate = 'qt-app-truckcrane' }
    grabber      = @{ Arch = 'arm64'; Board = 'rk3568-s962';  Crate = 'qt-app-grabber' }
    reachstacker = @{ Arch = 'arm64'; Board = 'rk3568-s962';  Crate = 'qt-app-reachstacker' }
}
$p = $Products[$Product]
$arch  = $p.Arch
$board = $p.Board
$crate = $p.Crate

$Dest = Join-Path $RepoRoot "products\$Product-$arch"
$Art  = Join-Path $Artifacts "products\$Product-$arch"
$DataDir = if ($arch -eq 'arm32') { '/var/lib/qt-rust-demo' } else { '/userdata/qt-rust-demo' }

function Write-Step([string]$msg) { Write-Host ""; Write-Host "== $msg ==" -ForegroundColor Yellow }
function Write-Ok([string]$msg)   { Write-Host "  OK $msg" -ForegroundColor Green }
function Write-Warn2([string]$msg){ Write-Host "  !! $msg" -ForegroundColor Yellow }

# 注意: 参数名不能用 $Args —— 那是 PowerShell 的自动变量, 同名会让外部命令收不到参数
# (upgrade_tool 只打印帮助并 exit 0, 脚本却当成"烧录完成"), 故一律叫 $ArgList。
# 原生命令的 stderr 在 $ErrorActionPreference=Stop 下会变成终止错误（adb 无设备时就是），
# 所以统一在这里临时切成 Continue，只按退出码判断成败。
function Invoke-Native {
    param([string]$Exe, [string[]]$ArgList)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = & $Exe @ArgList 2>&1 | ForEach-Object { "$_" }
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prev
    }
    return [pscustomobject]@{ Output = @($out); Code = $code }
}

function Invoke-Cmd {
    param([string]$Exe, [string[]]$ArgList)
    Write-Host "  -> $Exe $($ArgList -join ' ')"
    if ($DryRun) { return '' }
    $r = Invoke-Native -Exe $Exe -ArgList $ArgList
    $r.Output | ForEach-Object { Write-Host "     $_" }
    if ($r.Code -ne 0) { throw "$Exe 失败 (exit $($r.Code))" }
    return ($r.Output -join "`n")
}

function Invoke-Adb {
    param([string[]]$ArgList, [switch]$AllowFail)
    if ($DryRun) { Write-Host "  [dry-run] adb $($ArgList -join ' ')" ; return '' }
    $r = Invoke-Native -Exe $script:AdbExe -ArgList $ArgList
    if ($r.Code -ne 0) {
        if ($AllowFail) { return ($r.Output -join "`n") }
        throw "adb $($ArgList -join ' ') 失败 (exit $($r.Code)): $($r.Output -join ' | ')"
    }
    return ($r.Output -join "`n")
}

# Windows 仓库里的 shell 脚本是 CRLF，直接 push 会让设备上的 "#!.../sh\r" 找不到解释器，
# 报 "cannot execute: required file not found"。这里统一转成 LF(UTF-8 无 BOM) 再推。
function Push-TextFile {
    param([string]$LocalPath, [string]$RemotePath)
    if ($DryRun) { Write-Host "  [dry-run] push(LF) $LocalPath -> $RemotePath"; return }
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ("push_" + [IO.Path]::GetFileName($LocalPath))
    $text = [IO.File]::ReadAllText($LocalPath) -replace "`r`n", "`n" -replace "`r", "`n"
    [IO.File]::WriteAllText($tmp, $text, (New-Object System.Text.UTF8Encoding($false)))
    try {
        Invoke-Adb @('push', $tmp, $RemotePath) | Out-Null
    } finally {
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    }
}

# ---- manifest.toml 取值（只支持 [section] 下的 key = "value"）----
function Get-TomlValue {
    param([string]$Path, [string]$Section, [string]$Key)
    if (-not (Test-Path -Path $Path)) { return '' }
    $cur = ''
    foreach ($line in Get-Content -Path $Path) {
        if ($line -match '^\s*\[([^\]]+)\]\s*$') { $cur = $Matches[1].Trim(); continue }
        if ($cur -ne $Section) { continue }
        if ($line -match ('^\s*' + [regex]::Escape($Key) + '\s*=\s*"(.*)"\s*$')) { return $Matches[1] }
        if ($line -match ('^\s*' + [regex]::Escape($Key) + "\s*=\s*'(.*)'\s*$")) { return $Matches[1] }
    }
    return ''
}

# ---- 解析 upgrade_tool.exe：缺失时自动解压随包的 zip ----
function Resolve-UpgradeTool {
    param([string]$Root, [switch]$DryRun)
    $toolDir = Join-Path $Root 'tools\windows'
    $exe = Join-Path $toolDir 'upgrade_tool.exe'
    if (Test-Path -Path $exe) { return $exe }
    $found = Get-ChildItem -Path $toolDir -Recurse -Filter 'upgrade_tool.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($found) { return $found.FullName }
    $zip = Join-Path $toolDir 'upgrade_tool_v2.46.zip'
    if (-not (Test-Path -Path $zip)) {
        throw "缺少 tools\windows\upgrade_tool.exe（也没有 upgrade_tool_v2.46.zip 可自动解压）"
    }
    if ($DryRun) {
        Write-Host "  [dry-run] 解压 $zip -> $toolDir"
        return (Join-Path $toolDir 'upgrade_tool_v2.46_for_window\upgrade_tool.exe')
    }
    Write-Host "  -> 自动解压 $zip"
    Expand-Archive -Path $zip -DestinationPath $toolDir -Force
    $found = Get-ChildItem -Path $toolDir -Recurse -Filter 'upgrade_tool.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $found) { throw '解压后仍找不到 upgrade_tool.exe' }
    return $found.FullName
}

# ---- 解析 adb：优先用随包 tools\windows 里的 platform-tools，最后才回退 PATH ----
# 这样新机器没装 adb 也能直接跑：platform-tools.zip 缺失时才要求系统 PATH。
function Resolve-Adb {
    param([string]$Root, [switch]$DryRun)
    $toolDir = Join-Path $Root 'tools\windows'
    foreach ($rel in @('adb.exe', 'platform-tools\adb.exe')) {
        $p = Join-Path $toolDir $rel
        if (Test-Path -Path $p) { return $p }
    }
    $found = Get-ChildItem -Path $toolDir -Filter 'adb.exe' -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($found) { return $found.FullName }

    $zip = Join-Path $toolDir 'platform-tools.zip'
    if (Test-Path -Path $zip) {
        if ($DryRun) {
            Write-Host "  [dry-run] 解压 $zip -> $toolDir"
            return (Join-Path $toolDir 'platform-tools\adb.exe')
        }
        Write-Host "  -> 自动解压 $zip"
        Expand-Archive -Path $zip -DestinationPath $toolDir -Force
        $found = Get-ChildItem -Path $toolDir -Filter 'adb.exe' -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $found) { throw '解压 platform-tools.zip 后仍找不到 adb.exe' }
        return $found.FullName
    }

    $cmd = Get-Command adb -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    throw "找不到 adb：把 platform-tools.zip 放到 tools\windows\ 下（会自动解压），或安装 platform-tools 并加入 PATH"
}

# ---- Rockchip USB 驱动：检测 rockusb.inf / android_winusb.inf，缺失时用 pnputil 静默预装 ----
# 驱动来自 tools\windows\DriverAssitant_v5.13.zip（Rockchip 官方签名包）。
# pnputil /add-driver 会把驱动放进 DriverStore；设备插入时会自动绑定，无需点 GUI。
function Ensure-RockchipDriver {
    param([string]$Root, [switch]$DryRun)

    $names = (Invoke-Native -Exe 'pnputil.exe' -ArgList @('/enum-drivers')).Output -join "`n"
    $needRock = $names -notmatch '(?i)rockusb\.inf'
    $needAdb  = $names -notmatch '(?i)android_winusb\.inf'
    if (-not $needRock -and -not $needAdb) { Write-Ok 'Rockchip USB 驱动已就绪'; return }

    $missing = @()
    if ($needRock) { $missing += 'rockusb.inf' }
    if ($needAdb)  { $missing += 'android_winusb.inf' }
    $msg = "缺少 Rockchip USB 驱动: $($missing -join ', ')"
    if ($DryRun) { Write-Host "  [dry-run] $msg -> 会解压 DriverAssitant_v5.13.zip 并用 pnputil 预装"; return }

    Write-Warn2 $msg
    $zip = Join-Path $Root 'tools\windows\DriverAssitant_v5.13.zip'
    if (-not (Test-Path -Path $zip)) {
        throw "缺少驱动包 $zip — 无法自动安装 $($missing -join ',')；请手动安装 Rockchip USB 驱动后重试"
    }

    $toolRoot = Join-Path $Root 'tools\windows'
    $dir = Join-Path $toolRoot 'DriverAssitant_v5.13'
    if (-not (Test-Path (Join-Path $dir 'DriverInstall.exe'))) {
        Write-Host "  -> 解压 $zip"
        Expand-Archive -Path $zip -DestinationPath $toolRoot -Force
    }

    $arch = if ([Environment]::Is64BitOperatingSystem) { 'x64' } else { 'x86' }
    $os = 'win10'
    $v = [Environment]::OSVersion.Version
    if ($v.Major -eq 6 -and $v.Minor -eq 1) { $os = 'win7' }
    elseif ($v.Major -eq 6 -and $v.Minor -eq 2) { $os = 'win8' }
    elseif ($v.Major -eq 6 -and $v.Minor -eq 3) { $os = 'win81' }

    $infs = @()
    if ($needRock) {
        $inf = Join-Path $dir "Driver\$arch\$os\rockusb.inf"
        if (-not (Test-Path -Path $inf)) { $inf = Join-Path $dir "Driver\$arch\win10\rockusb.inf" }
        $infs += $inf
    }
    if ($needAdb) { $infs += (Join-Path $dir 'ADBDriver\android_winusb.inf') }

    foreach ($inf in $infs) {
        if (-not (Test-Path -Path $inf)) { throw "驱动 INF 不存在: $inf" }
        Write-Host "  -> pnputil /add-driver `"$inf`" /install"
        $r = Invoke-Native -Exe 'pnputil.exe' -ArgList @('/add-driver', $inf, '/install')
        $r.Output | ForEach-Object { Write-Host "     $_" }
        if ($r.Code -ne 0) { Write-Warn2 "pnputil 返回 $($r.Code)（继续按结果校验）" }
    }

    $names = (Invoke-Native -Exe 'pnputil.exe' -ArgList @('/enum-drivers')).Output -join "`n"
    $still = @()
    if ($names -notmatch '(?i)rockusb\.inf')        { $still += 'rockusb.inf' }
    if ($names -notmatch '(?i)android_winusb\.inf') { $still += 'android_winusb.inf' }
    if ($still.Count -gt 0) {
        throw "驱动预装后仍缺失: $($still -join ', ') — 请手动运行 `"$dir\DriverInstall.exe`" 安装后重试"
    }
    # 让 Windows 重新匹配已连接的设备（maskrom/ADB），避免已插着却仍绑定旧驱动
    Invoke-Native -Exe 'pnputil.exe' -ArgList @('/scan-devices') | Out-Null
    Write-Ok 'Rockchip USB 驱动已就绪'
}

# ---- 自动等待 maskrom / loader 设备 ----
function Wait-Maskrom {
    param([string]$Tool, [int]$TimeoutSec = 180, [switch]$DryRun)
    if ($DryRun) { Write-Host '  [dry-run] 轮询 upgrade_tool LD 等待 maskrom/loader'; return $true }
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    $hinted = $false
    while ((Get-Date) -lt $deadline) {
        $r = Invoke-Native -Exe $Tool -ArgList @('LD')
        if (($r.Output -join "`n") -match '(?i)(maskrom|loader)') { return $true }
        if (-not $hinted) {
            Write-Host "  等待板子进入 maskrom/loader（自动检测，最多 $TimeoutSec s）…"
            Write-Host '  ARM32: 现在给板子断电重上电，或按住 maskrom 键再上电'
            $hinted = $true
        }
        Start-Sleep -Seconds 3
    }
    return $false
}

# ---- 自动等待 adb 设备上线 ----
function Wait-AdbDevice {
    param([int]$TimeoutSec = 180, [switch]$DryRun)
    if ($DryRun) { Write-Host '  [dry-run] 等待 adb device'; return $true }
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        $r = Invoke-Native -Exe $script:AdbExe -ArgList @('get-state')
        if (($r.Output -join "`n").Trim() -eq 'device') { return $true }
        Start-Sleep -Seconds 3
    }
    return $false
}

# ---- 调用 upgrade_tool 并校验它真的报成功 ----
function Invoke-Upgrade {
    param([string]$Tool, [string[]]$ArgList, [switch]$AllowFail)
    Write-Host "  -> $(Split-Path -Leaf $Tool) $($ArgList -join ' ')"
    if ($DryRun) { return }
    $r = Invoke-Native -Exe $Tool -ArgList $ArgList
    $out = $r.Output
    $code = $r.Code
    $out | ForEach-Object { Write-Host "     $_" }
    $tail = ($out -join ' ').Trim()
    if ($tail.Length -gt 400) { $tail = $tail.Substring($tail.Length - 400) }
    if ($code -ne 0) {
        if ($AllowFail) { Write-Warn2 "upgrade_tool $($ArgList[0]) 返回 $code（已忽略）"; return }
        throw "upgrade_tool $($ArgList[0]) 失败 (exit $code): $tail"
    }
    if (($out -join "`n") -notmatch '(?i)(ok|success|成功)') {
        if ($AllowFail) { Write-Warn2 "upgrade_tool $($ArgList[0]) 输出里没有 ok（已忽略）"; return }
        throw "upgrade_tool $($ArgList[0]) 没有报告成功: $tail"
    }
}

# ---- 按 image\md5sum.txt 校验分区镜像 ----
function Test-ImageMd5 {
    param([string]$Dir)
    $sums = Join-Path $Dir 'md5sum.txt'
    if (-not (Test-Path -Path $sums)) {
        Write-Warn2 "未找到 $sums，跳过分区镜像 md5 校验"
        return
    }
    foreach ($line in Get-Content -Path $sums) {
        if ($line -notmatch '\S' -or $line -match '^\s*#') { continue }
        $parts = $line -split '\s+', 2
        if ($parts.Count -lt 2) { continue }
        $want = $parts[0].ToLower()
        $name = $parts[1].Trim()
        $f = Join-Path $Dir $name
        if (-not (Test-Path -Path $f)) { throw "缺少分区镜像 $f" }
        $got = (Get-FileHash -Path $f -Algorithm MD5).Hash.ToLower()
        if ($got -ne $want) { throw "分区镜像 md5 不匹配: $name 期望 $want 实际 $got" }
    }
    Write-Ok '分区镜像 md5 校验通过'
}

Write-Host "=================================================================="
Write-Host " 出厂部署: $Product ($arch / $board)"
Write-Host " 设备目录: $DeviceDir"
if ($DryRun) { Write-Host " *** DRY-RUN 模式，不改动任何东西 ***" }
Write-Host "=================================================================="

# ---- 前置：管理员 + 工具 ----
if (-not $DryRun) {
    $isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) { throw "需要管理员权限运行 (Rockchip 驱动与 upgrade_tool 都需要)" }
}

# adb 不再依赖系统 PATH：优先 tools\windows\adb.exe / platform-tools\adb.exe，
# 其次自动解压 tools\windows\platform-tools.zip，最后才回退 PATH。
$script:AdbExe = Resolve-Adb -Root $RepoRoot -DryRun:$DryRun
Write-Host "  adb: $script:AdbExe"

# Rockchip USB 驱动：缺 rockusb.inf（maskrom）或 android_winusb.inf（ADB）时自动 pnputil 预装
if ($SkipDriver) {
    Write-Warn2 '跳过驱动检查 (-SkipDriver)'
} else {
    Ensure-RockchipDriver -Root $RepoRoot -DryRun:$DryRun
}

# ---- 1 校验制品 ----
Write-Step '[1/7] 校验制品 (sha256)'
if ($SkipVerify) {
    Write-Warn2 '跳过校验 (-SkipVerify)'
} else {
    if (-not (Test-Path $Art)) {
        if ($AutoSync) {
            Write-Warn2 "缺少制品目录 $Art — 自动执行 deploy\lib\sync.ps1"
            if ($DryRun) {
                Write-Host '  [dry-run] powershell -File deploy\lib\sync.ps1'
            } else {
                & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $ScriptDir 'lib\sync.ps1')
                if ($LASTEXITCODE -ne 0) { throw 'sync.ps1 失败' }
            }
        } else {
            throw "缺少制品目录 $Art — 先跑 .\deploy\lib\sync.ps1（或加 -AutoSync 自动拉取）"
        }
    }
    $manifest = Join-Path $Artifacts 'MANIFEST.sha256'
    if (-not (Test-Path $manifest)) { throw "缺少制品清单 $manifest — 先跑 .\deploy\lib\sync.ps1" }
    $fail = 0
    Get-Content $manifest | Where-Object { $_ -match '\S' -and $_ -notmatch '^\s*#' } | ForEach-Object {
        $parts = $_ -split '  ', 2
        $want = $parts[0]; $rel = $parts[1]
        $local = Join-Path $Artifacts $rel
        if (-not (Test-Path $local)) { Write-Host "  缺失: $rel"; $script:fail = 1; return }
        $got = (Get-FileHash -Path $local -Algorithm SHA256).Hash.ToLower()
        if ($got -ne $want.ToLower()) { Write-Host "  不匹配: $rel"; $script:fail = 1 }
    }
    if ($fail -ne 0) { throw "制品校验失败 — 重新跑 sync" }
    Write-Ok '制品校验通过'
}

# ---- 2 选产品 + 板型 ----
Write-Step "[2/7] 产品 $Product / 板型 $board / 架构 $arch"
$fwManifest = Join-Path $RepoRoot "flash\$board\manifest.toml"
if (-not (Test-Path $fwManifest)) { throw "缺少固件清单 $fwManifest" }
Write-Ok "固件清单: flash\$board\manifest.toml"

# ---- 3 烧录（按 manifest strategy，全自动） ----
Write-Step '[3/7] 校验 md5 + 烧录固件'
if ($SkipFlash) {
    Write-Warn2 '跳过烧录 (-SkipFlash)'
} else {
    $tool = Resolve-UpgradeTool -Root $RepoRoot -DryRun:$DryRun
    Write-Ok "烧录工具: $tool"

    # 策略: auto -> manifest.toml [flash] strategy -> 按架构推断
    $strategy = $FlashStrategy
    if ($strategy -eq 'auto') {
        $strategy = Get-TomlValue -Path $fwManifest -Section 'flash' -Key 'strategy'
        if (-not $strategy) { $strategy = if ($arch -eq 'arm64') { 'update' } else { 'partition' } }
    }
    Write-Host "  烧录策略: $strategy"

    $imgSub = Get-TomlValue -Path $fwManifest -Section 'image' -Key 'dir'
    if (-not $imgSub) { $imgSub = 'image' }
    $imgDir = Join-Path $Artifacts "flash\$board\$imgSub"
    $loaderName = Get-TomlValue -Path $fwManifest -Section 'flash' -Key 'loader'
    if (-not $loaderName) { $loaderName = 'MiniLoaderAll.bin' }
    $loaderBin = Join-Path $imgDir $loaderName

    # di 支持“-<分区名>”直接写未定义缩写的分区（-rootfs/-oem/-userdata…），
    # 见 Rockchip Linux(GPT) 标准用法；这里按 parameter.txt 的 CMDLINE 顺序生成计划。
    $paramFile = Join-Path $imgDir 'parameter.txt'
    $paramParts = @()
    if (Test-Path -Path $paramFile) {
        $cmdlineLine = Get-Content -Path $paramFile | Where-Object { $_ -match '^CMDLINE:' } | Select-Object -First 1
        if ($cmdlineLine) {
            $paramParts = @([regex]::Matches($cmdlineLine, '\(([A-Za-z0-9_]+)(?::[^)]*)?\)') | ForEach-Object { $_.Groups[1].Value })
        }
    }

    $useUpdate = $strategy -ne 'partition'
    $img = Join-Path $Artifacts "flash\$board\update.img"

    if ($strategy -eq 'partition') {
        if ($paramParts.Count -eq 0) { throw "无法从 $paramFile 解析分区表，不能走 partition 策略" }
        $bootName = Get-TomlValue -Path $fwManifest -Section 'flash' -Key 'boot'
        if (-not $bootName) { $bootName = 'boot.img' }
        $plan = @()
        foreach ($name in $paramParts) {
            $flag = if ($name -eq 'parameter') { '-p' } else { "-$name" }
            $file = if ($name -eq 'parameter') { 'parameter.txt' } elseif ($name -eq 'boot') { $bootName } else { "$name.img" }
            $f = Join-Path $imgDir $file
            if (-not (Test-Path $f)) { throw "缺少分区镜像 $f — 先跑 .\deploy\lib\sync.ps1 --only flash" }
            $plan += @{ Name = $name; Flag = $flag; File = $file }
        }
        if (-not (Test-Path $loaderBin)) { throw "缺少 $loaderBin — 先跑 .\deploy\lib\sync.ps1 --only flash" }
        if (-not $DryRun) { Test-ImageMd5 -Dir $imgDir }

        if (-not (Wait-Maskrom -Tool $tool -TimeoutSec $FlashWaitSec -DryRun:$DryRun)) {
            throw "等待 maskrom 超时（$FlashWaitSec s）— 给板子断电重上电/按住 maskrom 键后重试"
        }

        # maskrom 引导 + 逐分区
        Invoke-Upgrade -Tool $tool -ArgList @('db', $loaderBin)
        try {
            foreach ($item in $plan) {
                Invoke-Upgrade -Tool $tool -ArgList @('di', $item.Flag, (Join-Path $imgDir $item.File))
            }
            Invoke-Upgrade -Tool $tool -ArgList @('rd') -AllowFail
        } catch {
            if ($_.Exception.Message -match '(?i)(invalid|unknown|unrecognized|usage|命令|no found|not found|check download item)') {
                Write-Warn2 "di 长参数被当前 upgrade_tool 拒绝: $($_.Exception.Message)"
                Write-Warn2 '自动回退整包 uf update.img'
                $useUpdate = $true
            } else {
                throw
            }
        }
    }

    if ($useUpdate) {
        if (-not (Test-Path $img)) { throw "缺少固件 $img — 先跑 .\deploy\lib\sync.ps1 --only flash" }

        $md5Want = Get-TomlValue -Path $fwManifest -Section 'image' -Key 'md5'
        if ($md5Want) {
            $md5Got = (Get-FileHash -Path $img -Algorithm MD5).Hash.ToLower()
            if ($md5Got -ne $md5Want.ToLower()) { throw "md5 不匹配: 期望 $md5Want 实际 $md5Got" }
            Write-Ok 'md5 校验通过'
        }

        if ($arch -eq 'arm64') {
            Write-Host '  -> adb reboot loader'
            Invoke-Adb @('reboot', 'loader') -AllowFail | Out-Null
            Start-Sleep -Seconds 8
        }
        if (-not (Wait-Maskrom -Tool $tool -TimeoutSec $FlashWaitSec -DryRun:$DryRun)) {
            throw "等待 maskrom/loader 超时（$FlashWaitSec s）— 检查 USB/驱动，或手动让板子进入 maskrom"
        }
        if ($arch -eq 'arm32') {
            if (-not (Test-Path $loaderBin)) { throw "缺少 $loaderBin — 先跑 .\deploy\lib\sync.ps1 --only flash" }
            Invoke-Upgrade -Tool $tool -ArgList @('db', $loaderBin)
        }
        Invoke-Upgrade -Tool $tool -ArgList @('uf', $img)
    }
    Write-Ok '烧录完成'
}

# ---- 4 出厂擦除 ----
Write-Step '[4/7] 出厂擦除 (purge-data)'
# 烧录后板子应已重启进系统; adb 里看不到设备 = 烧录没生效 (还停在 maskrom) 或 USB 掉了。
# 这一关必须在擦除/推送之前过, 否则后面几步会全部"假成功"。
if (-not $DryRun) {
    Write-Host "  等待系统起来 (adb device, 最多 $BootWaitSec s)…"
    if (-not (Wait-AdbDevice -TimeoutSec $BootWaitSec)) {
        throw "adb 看不到设备（等待 $BootWaitSec s 超时）— 板子可能仍停在 maskrom 或未重启: 断电重上电后加 -SkipFlash 重跑"
    }
}
Invoke-Adb @('shell', "killall $crate 2>/dev/null || true")
Invoke-Adb @('shell', "rm -rf $DeviceDir/config $DeviceDir/lib $DeviceDir/plugins $DeviceDir/qml_modules $DeviceDir/fonts")
Invoke-Adb @('shell', "rm -rf $DataDir")
Invoke-Adb @('shell', "mkdir -p $DeviceDir $DataDir")
Write-Ok '已清空设备部署目录与数据目录'

# ---- 5 推产品文件 ----
Write-Step '[5/7] 推产品文件 (运行时 + 出厂配置 + 最小 USB 包)'
$runtime = Join-Path $Art 'runtime'
if (-not (Test-Path $runtime)) { throw "缺少运行时 $runtime — 先跑 sync" }

Invoke-Adb @('shell', "mkdir -p $DeviceDir/lib $DeviceDir/plugins $DeviceDir/qml_modules $DeviceDir/fonts $DeviceDir/config")
foreach ($d in 'lib', 'plugins', 'qml_modules', 'fonts') {
    $src = Join-Path $runtime $d
    if (Test-Path $src) { Invoke-Adb @('push', "$src\.", "$DeviceDir/$d/") }
}
Invoke-Adb @('push', (Join-Path $runtime $crate), "$DeviceDir/$crate")
Invoke-Adb @('shell', "chmod +x $DeviceDir/$crate")

$cfgRoot = Join-Path $Dest 'config'
if (Test-Path $cfgRoot) {
    Get-ChildItem -Path $cfgRoot -Recurse -File | ForEach-Object {
        $rel = $_.FullName.Substring($cfgRoot.Length + 1).Replace('\', '/')
        $dir = ($rel -split '/')[0..(($rel -split '/').Length - 2)] -join '/'
        if ($dir) { Invoke-Adb @('shell', "mkdir -p $DeviceDir/config/$dir") }
        Invoke-Adb @('shell', "rm -f $DeviceDir/config/$rel")
        Invoke-Adb @('push', $_.FullName, "$DeviceDir/config/$rel")
    }
}

$usbPkg = Join-Path $Art 'usb\upgrade.tar.gz'
if (Test-Path $usbPkg) {
    Invoke-Adb @('push', $usbPkg, "$DeviceDir/upgrade.tar.gz")
    Write-Ok '最小 USB 升级包已随包落地 (upgrade.tar.gz)'
}
Write-Ok '产品文件推送完成'

# ---- 6 覆盖 custom ----
Write-Step '[6/7] 覆盖产品自定义 (公司 / APN / MQTT)'
if ($Custom) {
    $customDir = Join-Path $RepoRoot "custom\$Custom"
    if (-not (Test-Path $customDir)) { throw "缺少 custom 目录: $customDir" }
    $ccfg = Join-Path $customDir 'config'
    if (Test-Path $ccfg) {
        Get-ChildItem -Path $ccfg -Recurse -File | ForEach-Object {
            $rel = $_.FullName.Substring($ccfg.Length + 1).Replace('\', '/')
            $dir = ($rel -split '/')[0..(($rel -split '/').Length - 2)] -join '/'
            if ($dir) { Invoke-Adb @('shell', "mkdir -p $DeviceDir/config/$dir") }
            Invoke-Adb @('shell', "rm -f $DeviceDir/config/$rel")
            Invoke-Adb @('push', $_.FullName, "$DeviceDir/config/$rel")
        }
    }
    $apnFile = Join-Path $customDir 'apn'
    if (Test-Path $apnFile) {
        $apn = (Get-Content $apnFile -Raw).Trim()
        Invoke-Adb @('shell', "echo '$apn' > /etc/ec200a-apn")
        Write-Ok "APN: $apn"
    }
    Write-Ok "custom\$Custom 已覆盖"
} else {
    Write-Warn2 '未指定 -Custom，保持出厂默认 (公司=见 config/shared/system/company.toml, APN=mobile)'
}

# ---- 7 自启 + 验收 ----
Write-Step '[7/7] 装自启 + 冷启动验收'
if ($arch -eq 'arm32') {
    # 出厂固件的 pre_init/S10lv_demo 会先启动厂商 LVGL demo，
    # 它抢占 DRM master 和 CMA，导致 qt app 起得来但屏幕是 demo/黑屏。
    # 改名成 K10 前缀使其不再被 rcS 执行（与 arm64 关掉 S50launcher 同理）。
    Invoke-Adb @('shell', 'if [ -f /etc/init.d/pre_init/S10lv_demo ]; then mv /etc/init.d/pre_init/S10lv_demo /etc/init.d/pre_init/K10lv_demo; fi')
    Invoke-Adb @('shell', 'p=$(pidof lv_demo); [ -n "$p" ] && kill -9 $p; true')
    $initSrc = Join-Path $ScriptDir "device\pre_init-S10qt-app-$Product"
    if (-not (Test-Path $initSrc)) { throw "缺少 $initSrc" }
    Push-TextFile -LocalPath $initSrc -RemotePath "/etc/init.d/pre_init/S10qt-app-$Product"
    Invoke-Adb @('shell', "chmod +x /etc/init.d/pre_init/S10qt-app-$Product")
    $ec = Join-Path $ScriptDir 'device\S98ec200a'
    if (Test-Path $ec) {
        Push-TextFile -LocalPath $ec -RemotePath '/etc/init.d/S98ec200a'
        Invoke-Adb @('shell', 'chmod +x /etc/init.d/S98ec200a')
    }
} else {
    $launch = Join-Path $ScriptDir "device\kiosk-launch-$Product.sh"
    if (-not (Test-Path $launch)) { throw "缺少 $launch" }
    Push-TextFile -LocalPath $launch -RemotePath "$DeviceDir/kiosk-launch.sh"
    Invoke-Adb @('shell', "chmod +x $DeviceDir/kiosk-launch.sh")
    Push-TextFile -LocalPath (Join-Path $ScriptDir 'device\S49weston') -RemotePath '/etc/init.d/S49weston'
    Invoke-Adb @('shell', 'chmod +x /etc/init.d/S49weston')
    Invoke-Adb @('shell', 'mv /etc/init.d/S50launcher /etc/init.d/K50launcher 2>/dev/null || true')
}
Invoke-Adb @('shell', 'sync')

if ($DryRun) {
    Write-Host ''
    Write-Host '  [dry-run] adb reboot && 等待首帧'
    exit 0
}

Write-Host '  重启设备并等待首帧…'
Invoke-Adb @('reboot') | Out-Null
Start-Sleep -Seconds 45
for ($i = 1; $i -le 12; $i++) {
    # $pid 是 PowerShell 的自动变量 (进程 ID, 只读), 不能拿来赋值
    $appPid = (Invoke-Adb @('shell', "pidof $crate") -AllowFail).Trim()
    if ($appPid) {
        Write-Ok "冷启动验收通过: $crate 已运行 (PID $appPid)"
        # 进程活着不代表画面归它：确认没有 lv_demo 抢屏，且 DRM master 是它
        $lv = (Invoke-Adb @('shell', 'pidof lv_demo') -AllowFail).Trim()
        if ($lv) { Write-Warn2 "lv_demo 仍在运行 (PID $lv)，屏幕可能被它占用" }
        $clients = Invoke-Adb @('shell', 'cat /sys/kernel/debug/dri/0/clients 2>/dev/null') -AllowFail
        if ($clients -match "(?m)^\s*$([regex]::Escape($crate))\s+\d+\s+\d+\s+y") {
            Write-Ok 'DRM master 已切到 app（画面由本程序接管）'
        } elseif ($clients) {
            Write-Warn2 "DRM master 不在 $crate 手上，屏幕可能仍是开机 logo：$($clients.Trim())"
        }
        Write-Host ''
        Write-Ok "=== 出厂部署完成: $Product ($arch) ==="
        exit 0
    }
    Start-Sleep -Seconds 10
}
throw "冷启动验收失败: 60s 内未见 $crate 进程 (查 $DeviceDir/startup.log)"
