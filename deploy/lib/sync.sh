#!/bin/bash
# 制品通道同步 — 从内网 NAS 拉取大文件 (update.img / 产品运行时 / USB 升级包)
#
# 用法:
#   ./deploy/lib/sync.sh                      # 全部同步 (按 ARTIFACTS_MANIFEST 清单)
#   ./deploy/lib/sync.sh --only flash         # 只同步固件
#   ./deploy/lib/sync.sh --only products      # 只同步产品运行时
#   ./deploy/lib/sync.sh --list               # 只列清单, 不下载
#   ./deploy/lib/sync.sh --verify             # 只校验本地已有文件的 sha256
#
# 制品来源 (优先级从高到低):
#   1. $ARTIFACTS_URL         —— http(s)://host:8080/product-release / //host/share / file:///mnt/nas
#   2. $ARTIFACTS_MOUNT       —— 已挂载的本地路径, 如 /mnt/nas/product-release
#   3. 仓库内 artifacts/nas.conf 的 ARTIFACTS_URL (交付端可改成本地地址)
#   4. (全无) 内置默认        —— http://192.168.110.96:8080/product-release (内网, 匿名只读)
#
# 为什么默认走 HTTP 而不是 SMB: Windows 10 1709+/11 默认 AllowInsecureGuestAuth=0,
# 客户端直接拒绝匿名 SMB 来宾访问 ("组织的安全策略阻止未经身份验证的来宾访问"), 服务端无法绕过。
# HTTP 与 SMB 两条通道都可用, 数据是同一份目录。
#
# 校验: artifacts/MANIFEST.sha256 逐行 "<sha256>  <相对路径>", 与 rsync/scp 后实测比对。
# 退出码: 0 成功 / 1 参数或清单错误 / 2 下载失败 / 3 校验失败

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ARTIFACTS_DIR="$REPO_ROOT/artifacts"
MANIFEST="$ARTIFACTS_DIR/MANIFEST.sha256"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info() { echo -e "${YELLOW}$*${NC}"; }
ok()   { echo -e "${GREEN}$*${NC}"; }
die()  { echo -e "${RED}错误: $*${NC}" >&2; exit "${2:-1}"; }

ONLY=""
LIST_ONLY=0
VERIFY_ONLY=0
while [ $# -gt 0 ]; do
	case "$1" in
		--only)   ONLY="${2:?--only 需要参数 flash|products}"; shift 2 ;;
		--list)   LIST_ONLY=1; shift ;;
		--verify) VERIFY_ONLY=1; shift ;;
		-h|--help) sed -n '2,20p' "$0"; exit 0 ;;
		*) die "未知参数: $1" 1 ;;
	esac
done

# ---- 来源解析 ----
NAS_CONF="$REPO_ROOT/artifacts/nas.conf"
if [ -z "${ARTIFACTS_URL:-}" ] && [ -z "${ARTIFACTS_MOUNT:-}" ] && [ -f "$NAS_CONF" ]; then
	# shellcheck disable=SC1090
	. "$NAS_CONF"
fi

# 内网默认制品通道 —— 全新 clone 未做任何配置时也能直接 sync。
# 覆盖优先级: ARTIFACTS_MOUNT > ARTIFACTS_URL > artifacts/nas.conf > 本默认值
DEFAULT_ARTIFACTS_URL="http://192.168.110.96:8080/product-release"
if [ -z "${ARTIFACTS_URL:-}" ] && [ -z "${ARTIFACTS_MOUNT:-}" ]; then
	ARTIFACTS_URL="$DEFAULT_ARTIFACTS_URL"
	info "未指定制品来源, 使用默认制品通道: $ARTIFACTS_URL"
fi

SRC=""
if [ -n "${ARTIFACTS_MOUNT:-}" ]; then
	SRC="$ARTIFACTS_MOUNT"
elif [ -n "${ARTIFACTS_URL:-}" ]; then
	case "$ARTIFACTS_URL" in
		file://*) SRC="${ARTIFACTS_URL#file://}" ;;
		http://*|https://*) SRC="$ARTIFACTS_URL" ;;  # 走 curl 分支
		/*)       SRC="$ARTIFACTS_URL" ;;
		smb://*|//*) SRC="$ARTIFACTS_URL" ;;  # 走 smbclient 分支
		*) die "ARTIFACTS_URL 协议不支持: $ARTIFACTS_URL (支持 http(s):// / file:// 本地路径 / smb:// / //host/share)" 1 ;;
	esac
fi

[ -n "$SRC" ] || die "未配置制品来源。设置 ARTIFACTS_URL 或 ARTIFACTS_MOUNT, 或写 artifacts/nas.conf" 1

[ -f "$MANIFEST" ] || die "缺少清单 $MANIFEST (由构建机 make release-stage 生成)" 1

# ---- 清单筛选 ----
mapfile -t LINES < <(grep -v '^\s*#' "$MANIFEST" | grep -v '^\s*$')
[ "${#LINES[@]}" -gt 0 ] || die "清单为空: $MANIFEST" 1

selected=()
for line in "${LINES[@]}"; do
	path="${line#*  }"
	case "$ONLY" in
		flash)    [[ "$path" == flash/* ]] && selected+=("$line") ;;
		products) [[ "$path" == products/* ]] && selected+=("$line") ;;
		*)        selected+=("$line") ;;
	esac
done

if [ "$LIST_ONLY" -eq 1 ]; then
	printf '%s\n' "${selected[@]}"
	exit 0
fi

[ "${#selected[@]}" -gt 0 ] || die "清单中没有匹配 --only=$ONLY 的条目" 1

# ---- 校验 ----
verify_one() {
	local want="$1" rel="$2" local_path="$ARTIFACTS_DIR/$rel"
	[ -f "$local_path" ] || { echo "缺失: $rel"; return 1; }
	local got
	got=$(sha256sum "$local_path" | awk '{print $1}')
	[ "$got" = "$want" ] || { echo "不匹配: $rel (期望 $want, 实际 $got)"; return 1; }
	return 0
}

if [ "$VERIFY_ONLY" -eq 1 ]; then
	fail=0
	for line in "${selected[@]}"; do
		want="${line%%  *}"; rel="${line#*  }"
		verify_one "$want" "$rel" || fail=1
	done
	if [ "$fail" -eq 0 ]; then ok "✓ 全部 ${#selected[@]} 个文件校验通过"; exit 0; fi
	die "校验失败" 3
fi

# ---- 下载 ----
info "制品来源: $SRC"
info "待同步: ${#selected[@]} 个文件"
mkdir -p "$ARTIFACTS_DIR"

fail=0
if [[ "$SRC" == http://* || "$SRC" == https://* ]]; then
	command -v curl >/dev/null || die "需要 curl" 1
	base="${SRC%/}"
	for line in "${selected[@]}"; do
		want="${line%%  *}"; rel="${line#*  }"
		if verify_one "$want" "$rel" >/dev/null 2>&1; then
			echo "  · $rel 已是最新"; continue
		fi
		mkdir -p "$ARTIFACTS_DIR/$(dirname "$rel")"
		# 先试断点续传 (服务端支持 Range); 失败则删掉重下一次。
		# 本地文件比远端大时 curl -C - 会拿到 416, 正是靠这条重下兜底。
		if curl -fS --retry 3 --retry-delay 2 -C - -o "$ARTIFACTS_DIR/$rel" "$base/$rel" 2>/dev/null; then
			echo "  ✓ $rel"
		else
			rm -f "$ARTIFACTS_DIR/$rel"
			if curl -fS --retry 3 --retry-delay 2 -o "$ARTIFACTS_DIR/$rel" "$base/$rel" 2>/dev/null; then
				echo "  ✓ $rel"
			else
				echo "  ✗ $rel"; fail=1
			fi
		fi
	done
elif [[ "$SRC" == smb://* || "$SRC" == //* ]]; then
	command -v smbclient >/dev/null || die "需要 smbclient (apt install smbclient)" 1
	share="$SRC"; [ "${share#//}" = "$share" ] && share="//${SRC#smb://}"
	for line in "${selected[@]}"; do
		want="${line%%  *}"; rel="${line#*  }"
		if verify_one "$want" "$rel" >/dev/null 2>&1; then
			echo "  · $rel 已是最新"; continue
		fi
		mkdir -p "$ARTIFACTS_DIR/$(dirname "$rel")"
		if smbclient "$share" -N -c "get \"$rel\" \"$ARTIFACTS_DIR/$rel\"" >/dev/null 2>&1; then
			echo "  ✓ $rel"
		else
			echo "  ✗ $rel"; fail=1
		fi
	done
else
	[ -d "$SRC" ] || die "来源路径不存在: $SRC" 1
	for line in "${selected[@]}"; do
		want="${line%%  *}"; rel="${line#*  }"
		if verify_one "$want" "$rel" >/dev/null 2>&1; then
			echo "  · $rel 已是最新"; continue
		fi
		mkdir -p "$ARTIFACTS_DIR/$(dirname "$rel")"
		if rsync -a --partial "$SRC/$rel" "$ARTIFACTS_DIR/$rel"; then
			echo "  ✓ $rel"
		else
			echo "  ✗ $rel"; fail=1
		fi
	done
fi

[ "$fail" -eq 0 ] || die "部分文件下载失败" 2

# ---- 同步后校验 ----
fail=0
for line in "${selected[@]}"; do
	want="${line%%  *}"; rel="${line#*  }"
	verify_one "$want" "$rel" || fail=1
done
[ "$fail" -eq 0 ] || die "下载后 sha256 校验失败" 3

ok "✓ 制品已同步并校验 (${#selected[@]} 个文件)"
