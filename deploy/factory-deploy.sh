#!/bin/bash
# factory-deploy.sh — Linux 出厂部署（只支持 factory 流程，不支持增量/调试部署）
#
# 用法:
#   sudo ./deploy/factory-deploy.sh --product loader
#   sudo ./deploy/factory-deploy.sh --product reachstacker --skip-flash
#   ./deploy/factory-deploy.sh --product grabber --dry-run
#   ./deploy/factory-deploy.sh --list
#
# 七步（与交付流程图一致）:
#   1 校验制品 (sync.sh --verify)
#   2 选产品 + 板型
#   3 校验 md5 + 烧录固件
#   4 出厂擦除 (purge-data)
#   5 推产品文件 (运行时 + 出厂配置 + 最小 USB 包)
#   6 覆盖 custom (公司 / APN / MQTT)
#   7 装自启 + 冷启动验收
#
# 退出码: 0 成功 / 1 参数或前置失败 / 2 烧录失败 / 3 部署失败 / 4 验收失败

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ARTIFACTS="$REPO_ROOT/artifacts"

DEVICE_DIR="/data/local/tmp/qt-rust-demo"
DATA_DIR_arm32="/var/lib/qt-rust-demo"
DATA_DIR_arm64="/userdata/qt-rust-demo"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
step() { echo; echo -e "${YELLOW}══ $* ══${NC}"; }
ok()   { echo -e "${GREEN}  ✓ $*${NC}"; }
warn() { echo -e "${YELLOW}  ⚠ $*${NC}"; }
die()  { echo -e "${RED}错误: $*${NC}" >&2; exit "${2:-1}"; }

# ---- 产品表 ----
declare -A ARCH BOARD CRATE
ARCH[folding]=arm32;       BOARD[folding]=rk3506;        CRATE[folding]=qt-app-folding
ARCH[loader]=arm32;        BOARD[loader]=rk3506;         CRATE[loader]=qt-app-loader
ARCH[truckcrane]=arm32;    BOARD[truckcrane]=rk3506;     CRATE[truckcrane]=qt-app-truckcrane
ARCH[grabber]=arm64;       BOARD[grabber]=rk3568-s962;   CRATE[grabber]=qt-app-grabber
ARCH[reachstacker]=arm64;  BOARD[reachstacker]=rk3568-s962; CRATE[reachstacker]=qt-app-reachstacker
ALL_PRODUCTS="folding loader truckcrane grabber reachstacker"

PRODUCT=""; SKIP_FLASH=0; SKIP_VERIFY=0; DRY_RUN=0; CUSTOM=""; YES=0
while [ $# -gt 0 ]; do
	case "$1" in
		--product|-p)   PRODUCT="${2:?--product 需要参数}"; shift 2 ;;
		--custom|-c)    CUSTOM="${2:?--custom 需要参数}"; shift 2 ;;
		--skip-flash)   SKIP_FLASH=1; shift ;;
		--skip-verify)  SKIP_VERIFY=1; shift ;;
		--dry-run|-n)   DRY_RUN=1; shift ;;
		--yes|-y)       YES=1; shift ;;
		--list)         printf '%s\n' $ALL_PRODUCTS; exit 0 ;;
		-h|--help)      sed -n '2,20p' "$0"; exit 0 ;;
		*)              die "未知参数: $1" 1 ;;
	esac
done

[ -n "$PRODUCT" ] || die "必须指定 --product <$(echo $ALL_PRODUCTS | tr ' ' '|')>"
[ -n "${ARCH[$PRODUCT]:-}" ] || die "非法产品 '$PRODUCT';可用: $ALL_PRODUCTS"

arch="${ARCH[$PRODUCT]}"; board="${BOARD[$PRODUCT]}"; crate="${CRATE[$PRODUCT]}"
dest="$REPO_ROOT/products/$PRODUCT-$arch"
art="$ARTIFACTS/products/$PRODUCT-$arch"

run() {
	if [ "$DRY_RUN" = "1" ]; then echo "  [dry-run] $*"; else "$@"; fi
}
run_sh() {
	if [ "$DRY_RUN" = "1" ]; then echo "  [dry-run] adb shell $*"; else adb shell "$@" </dev/null; fi
}

echo "=================================================================="
echo " 出厂部署: $PRODUCT ($arch / $board)"
echo " 设备目录: $DEVICE_DIR"
[ "$DRY_RUN" = "1" ] && echo " *** DRY-RUN 模式，不改动任何东西 ***"
echo "=================================================================="

# ---- 1 校验制品 ----
step "[1/7] 校验制品 (sha256)"
if [ "$SKIP_VERIFY" = "1" ]; then
	warn "跳过校验 (--skip-verify)"
else
	[ -d "$art" ] || die "缺少制品目录 $art — 先跑 ./deploy/lib/sync.sh" 1
	[ -f "$ARTIFACTS/MANIFEST.sha256" ] || die "缺少制品清单 $ARTIFACTS/MANIFEST.sha256 — 先跑 ./deploy/lib/sync.sh" 1
	if [ "$DRY_RUN" = "1" ]; then
		echo "  [dry-run] ./deploy/lib/sync.sh --verify"
	else
		bash "$SCRIPT_DIR/lib/sync.sh" --verify >/dev/null || die "制品校验失败 — 重新跑 ./deploy/lib/sync.sh" 1
	fi
	ok "制品校验通过"
fi

# ---- 2 选产品 + 板型 ----
step "[2/7] 产品 $PRODUCT / 板型 $board / 架构 $arch"
[ -f "$REPO_ROOT/flash/$board/manifest.toml" ] || die "缺少固件清单 flash/$board/manifest.toml" 1
ok "固件清单: flash/$board/manifest.toml"

# ---- 3 烧录 ----
step "[3/7] 校验 md5 + 烧录固件"
if [ "$SKIP_FLASH" = "1" ]; then
	warn "跳过烧录 (--skip-flash)"
else
	command -v adb >/dev/null || die "需要 adb (Android platform-tools)" 2
	if [ "$arch" = "arm64" ]; then
		tool="$REPO_ROOT/tools/linux/upgrade_tool"
		[ -x "$tool" ] || die "缺少 $tool" 2
		img="$ARTIFACTS/flash/$board/update.img"
		[ -f "$img" ] || die "缺少固件 $img — 先跑 ./deploy/lib/sync.sh --only flash" 2
		md5_want="$(sed -n 's/^md5[[:space:]]*=[[:space:]]*"\(.*\)".*/\1/p' "$REPO_ROOT/flash/$board/manifest.toml")"
		if [ -n "$md5_want" ]; then
			md5_got="$(md5sum "$img" | awk '{print $1}')"
			[ "$md5_got" = "$md5_want" ] || die "md5 不匹配: 期望 $md5_want 实际 $md5_got" 2
			ok "md5 校验通过"
		fi
		echo "  → adb reboot loader; upgrade_tool uf update.img"
		run_sh "reboot loader" || true
		sleep 8
		run "$tool" uf "$img"
	else
		tool="$REPO_ROOT/tools/linux/upgrade_tool"
		[ -x "$tool" ] || die "缺少 $tool" 2
		loader_bin="$ARTIFACTS/flash/$board/MiniLoaderAll.bin"
		img="$ARTIFACTS/flash/$board/update.img"
		[ -f "$loader_bin" ] || die "缺少 $loader_bin — 先跑 ./deploy/lib/sync.sh --only flash" 2
		[ -f "$img" ] || die "缺少固件 $img — 先跑 ./deploy/lib/sync.sh --only flash" 2
		warn "ARM32 只有 maskrom 模式: 请断电重上电 (或按住 maskrom 键) 让板子进入 maskrom"
		if [ "$YES" != "1" ] && [ "$DRY_RUN" != "1" ]; then
			read -r -p "  板子已进入 maskrom? [y/N] " a
			[ "$a" = "y" ] || die "用户取消" 2
		fi
		run "$tool" db "$loader_bin"
		run "$tool" uf "$img"
	fi
	ok "烧录完成"
fi

# ---- 4 出厂擦除 ----
step "[4/7] 出厂擦除 (purge-data)"
if [ "$arch" = "arm32" ]; then data_dir="$DATA_DIR_arm32"; else data_dir="$DATA_DIR_arm64"; fi
run_sh "killall $crate 2>/dev/null || true"
run_sh "rm -rf $DEVICE_DIR/config $DEVICE_DIR/lib $DEVICE_DIR/plugins $DEVICE_DIR/qml_modules $DEVICE_DIR/fonts"
run_sh "rm -rf $data_dir"
run_sh "mkdir -p $DEVICE_DIR $data_dir"
ok "已清空设备部署目录与数据目录"

# ---- 5 推产品文件 ----
step "[5/7] 推产品文件 (运行时 + 出厂配置 + 最小 USB 包)"
[ -d "$art/runtime" ] || die "缺少运行时 $art/runtime — 先跑 ./deploy/lib/sync.sh" 3
run_sh "mkdir -p $DEVICE_DIR/lib $DEVICE_DIR/plugins $DEVICE_DIR/qml_modules $DEVICE_DIR/fonts $DEVICE_DIR/config"
for d in lib plugins qml_modules fonts; do
	[ -d "$art/runtime/$d" ] || continue
	run adb push "$art/runtime/$d/." "$DEVICE_DIR/$d/"
done
run adb push "$art/runtime/$crate" "$DEVICE_DIR/$crate"
run_sh "chmod +x $DEVICE_DIR/$crate"
# 出厂配置: 逐文件推送（禁止目录级 rm -rf，见 ADR-013）
if [ -d "$dest/config" ]; then
	while IFS= read -r f; do
		rel="${f#$dest/config/}"
		run_sh "mkdir -p $DEVICE_DIR/config/$(dirname "$rel")"
		run_sh "rm -f $DEVICE_DIR/config/$rel"
		run adb push "$f" "$DEVICE_DIR/config/$rel"
	done < <(find "$dest/config" -type f | sort)
fi
# 最小 USB 升级包 → 设备侧备份一份（现场可直接拷 U 盘）
if [ -f "$art/usb/upgrade.tar.gz" ]; then
	run adb push "$art/usb/upgrade.tar.gz" "$DEVICE_DIR/upgrade.tar.gz"
	ok "最小 USB 升级包已随包落地 (upgrade.tar.gz)"
fi
ok "产品文件推送完成"

# ---- 6 覆盖 custom ----
step "[6/7] 覆盖产品自定义 (公司 / APN / MQTT)"
if [ -n "$CUSTOM" ]; then
	custom_dir="$REPO_ROOT/custom/$CUSTOM"
	[ -d "$custom_dir" ] || die "缺少 custom 目录: $custom_dir" 3
	if [ -d "$custom_dir/config" ]; then
		while IFS= read -r f; do
			rel="${f#$custom_dir/config/}"
			run_sh "mkdir -p $DEVICE_DIR/config/$(dirname "$rel")"
			run_sh "rm -f $DEVICE_DIR/config/$rel"
			run adb push "$f" "$DEVICE_DIR/config/$rel"
		done < <(find "$custom_dir/config" -type f | sort)
	fi
	if [ -f "$custom_dir/apn" ]; then
		apn="$(tr -d '[:space:]' < "$custom_dir/apn")"
		run_sh "echo '$apn' > /etc/ec200a-apn"
		ok "APN: $apn"
	fi
	ok "custom/$CUSTOM 已覆盖"
else
	warn "未指定 --custom <客户代号>，保持出厂默认 (公司=见 config/shared/system/company.toml, APN=mobile)"
fi

# ---- 7 自启 + 验收 ----
step "[7/7] 装自启 + 冷启动验收"
if [ "$arch" = "arm32" ]; then
	init_src="$SCRIPT_DIR/device/pre_init-S10qt-app-$PRODUCT"
	[ -f "$init_src" ] || die "缺少 $init_src" 3
	run adb push "$init_src" "/etc/init.d/pre_init/S10qt-app-$PRODUCT"
	run_sh "chmod +x /etc/init.d/pre_init/S10qt-app-$PRODUCT"
	[ -f "$SCRIPT_DIR/device/S98ec200a" ] && {
		run adb push "$SCRIPT_DIR/device/S98ec200a" "/etc/init.d/S98ec200a"
		run_sh "chmod +x /etc/init.d/S98ec200a"
	}
else
	launch="$SCRIPT_DIR/device/kiosk-launch-$PRODUCT.sh"
	[ -f "$launch" ] || die "缺少 $launch" 3
	run adb push "$launch" "$DEVICE_DIR/kiosk-launch.sh"
	run_sh "chmod +x $DEVICE_DIR/kiosk-launch.sh"
	run adb push "$SCRIPT_DIR/device/S49weston" "/etc/init.d/S49weston"
	run_sh "chmod +x /etc/init.d/S49weston"
	run_sh "mv /etc/init.d/S50launcher /etc/init.d/K50launcher 2>/dev/null || true"
fi
run_sh "sync"

if [ "$DRY_RUN" = "1" ]; then
	echo; echo "  [dry-run] adb reboot && 等待首帧"
	exit 0
fi

echo "  重启设备并等待首帧…"
adb reboot </dev/null
sleep 45
for i in $(seq 1 12); do
	if adb shell "pidof $crate" </dev/null >/dev/null 2>&1; then
		ok "冷启动验收通过: $crate 已运行 (PID $(adb shell "pidof $crate" </dev/null | tr -d '\r'))"
		echo
		ok "=== 出厂部署完成: $PRODUCT ($arch) ==="
		exit 0
	fi
	sleep 10
done
die "冷启动验收失败: 60s 内未见 $crate 进程 (查 $DEVICE_DIR/startup.log)" 4
