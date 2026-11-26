#Requires -Version 5.1
<#
.SYNOPSIS
    factory-deploy.ps1 — Windows 出厂部署（只支持 factory 流程）

.DESCRIPTION
    七步流程（与交付流程图一致）：
      1 校验制品 (sha256)
      2 选产品 + 板型
      3 校验 md5 + 烧录固件（整包 uf，不做 di 逐分区）
      4 出厂擦除
      5 推产品文件（运行时 + 出厂配置 + 最小 USB 包）
      6 覆盖 custom（公司 / APN / MQTT）
      7 装自启 + 冷启动验收

    与 Linux 版的差异：Windows 侧没有 python3，也不做 GPT PARTUUID 修正，
    因此烧录只走整包 `upgrade_tool uf update.img`，不支持 `di` 逐分区。

.PARAMETER Product
    folding | loader | truckcrane | grabber | reachstacker

.PARAMETER Custom
    custom/ 下的客户代号目录名（可选）

.PARAMETER SkipFlash
    跳过烧录（设备已烧好固件时用）

.PARAMETER DryRun
    只打印计划，不改动任何东西

.EXAMPLE
    .\deploy\factory-deploy.ps1 -Product loader

.EXAMPLE
    .\deploy\factory-deploy.ps1 -Product reachstacker -Custom acme -DryRun

.NOTES
    需要：管理员 PowerShell、adb 在 PATH、tools\windows\upgrade_tool 已解压。
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
    [switch]$List
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
function Invoke-Cmd {
    param([string]$Exe, [string[]]$ArgList)
    Write-Host "  -> $Exe $($ArgList -join ' ')"
    if ($DryRun) { return '' }
    $out = & $Exe @ArgList 2>&1 | ForEach-Object { "$_" }
    $code = $LASTEXITCODE
    $out | ForEach-Object { Write-Host "     $_" }
    if ($code -ne 0) { throw "$Exe 失败 (exit $code)" }
    return ($out -join "`n")
}

function Invoke-Adb {
    param([string[]]$ArgList, [switch]$AllowFail)
    if ($DryRun) { Write-Host "  [dry-run] adb $($ArgList -join ' ')" ; return '' }
    $out = & adb @ArgList 2>&1 | ForEach-Object { "$_" }
    $code = $LASTEXITCODE
    if ($code -ne 0) {
        if ($AllowFail) { return ($out -join "`n") }
        throw "adb $($ArgList -join ' ') 失败 (exit $code): $($out -join ' | ')"
    }
    return ($out -join "`n")
}

Write-Host "=================================================================="
Write-Host " 出厂部署: $Product ($arch / $board)"
Write-Host " 设备目录: $DeviceDir"
if ($DryRun) { Write-Host " *** DRY-RUN 模式，不改动任何东西 ***" }
Write-Host "=================================================================="

# ---- 前置：管理员 ----
if (-not $DryRun) {
    $isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) { throw "需要管理员权限运行 (Rockchip 驱动与 upgrade_tool 都需要)" }
    if (-not (Get-Command adb -ErrorAction SilentlyContinue)) { throw "adb 不在 PATH（需 platform-tools）" }
}

# ---- 1 校验制品 ----
Write-Step '[1/7] 校验制品 (sha256)'
if ($SkipVerify) {
    Write-Warn2 '跳过校验 (-SkipVerify)'
} else {
    if (-not (Test-Path $Art)) { throw "缺少制品目录 $Art — 先跑 .\deploy\lib\sync.ps1" }
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

# ---- 3 烧录（只走整包 uf） ----
Write-Step '[3/7] 校验 md5 + 烧录固件 (整包 uf)'
if ($SkipFlash) {
    Write-Warn2 '跳过烧录 (-SkipFlash)'
} else {
    $toolDir = Join-Path $RepoRoot 'tools\windows'
    $tool = Join-Path $toolDir 'upgrade_tool.exe'
    if (-not (Test-Path $tool)) {
        # 允许已解压到子目录
        $found = Get-ChildItem -Path $toolDir -Recurse -Filter 'upgrade_tool.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $found) { throw "缺少 tools\windows\upgrade_tool.exe — 先解压 upgrade_tool_v2.46.zip" }
        $tool = $found.FullName
    }

    $img = Join-Path $Artifacts "flash\$board\update.img"
    if (-not (Test-Path $img)) { throw "缺少固件 $img — 先跑 sync --only flash" }

    $md5Want = (Select-String -Path $fwManifest -Pattern '^md5\s*=\s*"(.*)"').Matches.Groups[1].Value
    if ($md5Want) {
        $md5Got = (Get-FileHash -Path $img -Algorithm MD5).Hash.ToLower()
        if ($md5Got -ne $md5Want.ToLower()) { throw "md5 不匹配: 期望 $md5Want 实际 $md5Got" }
        Write-Ok 'md5 校验通过'
    }

    if ($arch -eq 'arm64') {
        Write-Host '  -> adb reboot loader; upgrade_tool uf update.img'
        Invoke-Adb @('reboot', 'loader')
        Start-Sleep -Seconds 8
    } else {
        Write-Warn2 'ARM32 只有 maskrom 模式: 请断电重上电 (或按住 maskrom 键) 让板子进入 maskrom'
        if (-not $Yes -and -not $DryRun) {
            $a = Read-Host '  板子已进入 maskrom? [y/N]'
            if ($a -ne 'y') { throw '用户取消' }
        }
    }
    # 显式传参 (不再经 Invoke-Cmd 的数组参数), 并把工具输出打出来 + 校验它真的说成功了
    Write-Host "  -> $tool uf $img"
    $flashOut = & $tool 'uf' $img 2>&1 | ForEach-Object { "$_" }
    $flashCode = $LASTEXITCODE
    $flashOut | ForEach-Object { Write-Host "     $_" }
    if ($flashCode -ne 0) { throw "upgrade_tool uf 失败 (exit $flashCode)" }
    if (($flashOut -join "`n") -notmatch '(?i)(ok|成功)') {
        throw "upgrade_tool 没有报告烧录成功 (输出里找不到 ok)。多半是板子没进入 maskrom —— 先手动跑 tools\windows\upgrade_tool.exe LD 看设备是否显示 Maskrom"
    }
    Write-Ok '烧录完成'
}

# ---- 4 出厂擦除 ----
Write-Step '[4/7] 出厂擦除 (purge-data)'
# 烧录后板子应已重启进系统; adb 里看不到设备 = 烧录没生效 (还停在 maskrom) 或 USB 掉了。
# 这一关必须在擦除/推送之前过, 否则后面几步会全部"假成功"。
if (-not $DryRun) {
    $state = (& adb get-state 2>&1 | Out-String).Trim()
    if ($state -ne 'device') {   # 成功时 adb get-state 恰好输出 device; 失败是 error: no devices/emulators found
        throw "adb 看不到设备 (adb get-state 返回 '$state') — 板子可能仍停在 maskrom 或未重启: 断电重上电, 等系统起来后再跑 -SkipFlash"
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
    $initSrc = Join-Path $ScriptDir "device\pre_init-S10qt-app-$Product"
    if (-not (Test-Path $initSrc)) { throw "缺少 $initSrc" }
    Invoke-Adb @('push', $initSrc, "/etc/init.d/pre_init/S10qt-app-$Product")
    Invoke-Adb @('shell', "chmod +x /etc/init.d/pre_init/S10qt-app-$Product")
    $ec = Join-Path $ScriptDir 'device\S98ec200a'
    if (Test-Path $ec) {
        Invoke-Adb @('push', $ec, '/etc/init.d/S98ec200a')
        Invoke-Adb @('shell', 'chmod +x /etc/init.d/S98ec200a')
    }
} else {
    $launch = Join-Path $ScriptDir "device\kiosk-launch-$Product.sh"
    if (-not (Test-Path $launch)) { throw "缺少 $launch" }
    Invoke-Adb @('push', $launch, "$DeviceDir/kiosk-launch.sh")
    Invoke-Adb @('shell', "chmod +x $DeviceDir/kiosk-launch.sh")
    Invoke-Adb @('push', (Join-Path $ScriptDir 'device\S49weston'), '/etc/init.d/S49weston')
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
        Write-Host ''
        Write-Ok "=== 出厂部署完成: $Product ($arch) ==="
        exit 0
    }
    Start-Sleep -Seconds 10
}
throw "冷启动验收失败: 60s 内未见 $crate 进程 (查 $DeviceDir/startup.log)"
