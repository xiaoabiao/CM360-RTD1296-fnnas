#!/bin/bash
# shrink-p2.sh —— 把 p2（btrfs rootfs）镜像**收缩**成"精简镜像"，用于线刷包瘦身
#
# 为什么需要
# ----------
# dd 出来的 p2.img 是**整分区裸镜像**（7,508,852,736 B ≈ 6.99 GiB），但里面 67.5%
# 是空洞 —— btrfs 自己报的真实用量只有约 2.19 GiB。tar **不保留稀疏性**，于是线刷包
# 被撑到 7.32 GiB。厂商包之所以小，就是因为它**不装整分区镜像**（例如 etc 分区
# 6.875 GiB 只带 512 B 的 etc.bin；rootfs 128 MiB 只带 97.9 MB 的 squashfs 镜像）
# —— 参见 docs/10-vendor-usb-mp-tool-package.md §12、§13。
#
# 本脚本做的事（全部在**副本**上操作，原 p2.img 绝不被改动）：
#   1) 稀疏复制一份 → 2) loop 挂载 → 3) btrfs 收缩到"用量 + 余量"
#   → 4) 卸载并截断文件 → 5) btrfs check 只读复核 + 关键文件检查
#
# 收缩后：
#   · layout.txt 里**分区大小仍声明为真实分区大小**（7,508,852,736），只有"随包文件"
#     变小 —— 与厂商 system/data/rootfs 的做法同构；
#   · 板子首启由 /usr/local/sbin/cm360-firstboot.sh 执行
#     `btrfs filesystem resize max /` 自动扩回满分区。
#
# 用法
# ----
#   ./shrink-p2.sh --dry-run                  # 只看用量与建议目标（**不需要 root**）
#   sudo ./shrink-p2.sh                       # p2.img → p2-compact.img
#   sudo ./shrink-p2.sh --size 4G             # 指定目标大小
#   sudo ./shrink-p2.sh --src A --dst B       # 自定义输入输出
#
# 需要：sudo（loop 挂载 + btrfs resize）、btrfs-progs。
# 空间：副本是稀疏的，占 ≈ btrfs 用量（约 2.2 GiB），不是 7.5 GiB。
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/images/p2.img"
DST="$HERE/images/p2-compact.img"
SIZE=""
DRYRUN=0
MARGIN_PCT=25            # 在"已用"之上留的余量百分比
MIN_FREE=$((256 * 1024 * 1024))
ALIGN=$((256 * 1024 * 1024))
WORK="${WORK:-/var/tmp/cm360-shrink}"
LOOP=""
MNT=""

die() { echo "!! $*" >&2; exit 1; }
say() { echo "   $*"; }
need_root() { [ "$(id -u)" = 0 ] || die "需要 root（loop 挂载 / btrfs resize）：请用 sudo 运行"; }

cleanup() {
	[ -n "$MNT" ] && mountpoint -q "$MNT" 2>/dev/null && umount "$MNT" 2>/dev/null || true
	[ -n "$LOOP" ] && losetup -d "$LOOP" 2>/dev/null || true
	[ -n "$MNT" ] && rmdir "$MNT" 2>/dev/null || true
}
trap cleanup EXIT

# "4G" / "4000M" / "123456789" → 字节
to_bytes() {
	local v="$1"
	case "$v" in
	*[Gg]) echo $(( ${v%[Gg]} * 1024 * 1024 * 1024 )) ;;
	*[Mm]) echo $(( ${v%[Mm]} * 1024 * 1024 )) ;;
	*[Kk]) echo $(( ${v%[Kk]} * 1024 )) ;;
	''|*[!0-9]*) die "无法解析大小：$v（用 4G / 4000M / 字节数）" ;;
	*) echo "$v" ;;
	esac
}

# 由"已用量"推荐目标大小
suggest() {
	local used="$1"
	local t=$(( used + used * MARGIN_PCT / 100 + MIN_FREE ))
	echo $(( (t + ALIGN - 1) / ALIGN * ALIGN ))
}

while [ $# -gt 0 ]; do
	case "$1" in
	--src) SRC="$2"; shift 2 ;;
	--dst) DST="$2"; shift 2 ;;
	--size) SIZE="$(to_bytes "$2")"; shift 2 ;;
	--dry-run) DRYRUN=1; shift ;;
	-h|--help) sed -n '1,40p' "$0"; exit 0 ;;
	*) die "未知参数：$1" ;;
	esac
done

[ -f "$SRC" ] || die "找不到源镜像：$SRC"
SRC_BYTES=$(stat -c %s "$SRC")
SRC_ALLOC=$(( $(stat -c %b "$SRC") * 512 ))
gi() { awk "BEGIN{printf \"%.3f\", $1/1073741824}"; }

echo "== 源 =="
say "$SRC"
say "表观 $(gi "$SRC_BYTES") GiB（$SRC_BYTES 字节）"
say "实占 $(gi "$SRC_ALLOC") GiB（稀疏空洞 $(awk "BEGIN{printf \"%.1f%%\", 100*($SRC_BYTES-$SRC_ALLOC)/$SRC_BYTES}")）"

# ── 预检：读 btrfs 超级块（**不需要 root**）──────────────────────────────
DUMP=$(btrfs inspect-internal dump-super -f "$SRC" 2>/dev/null) \
	|| die "$SRC 不是 btrfs 镜像（读不到超级块）"
SB_LABEL=$(echo "$DUMP" | awk '/^label/{print $2; exit}')
SB_TOTAL=$(echo "$DUMP" | awk '/^total_bytes/{print $2; exit}')
SB_USED=$(echo "$DUMP" | awk '/^bytes_used/{print $2; exit}')
[ -n "$SB_USED" ] || die "超级块里读不到 bytes_used"
say "超级块:  ✅ btrfs  label=${SB_LABEL:-?}  total=$(gi "$SB_TOTAL") GiB  used=$(gi "$SB_USED") GiB"

# 未指定大小就按超级块用量先算一版（挂载后还会用真实用量复核）
AUTO=0
if [ -z "$SIZE" ]; then AUTO=1; SIZE=$(suggest "$SB_USED"); fi

# ── 预检：空间（副本稀疏，占 ≈ 实占；再加最终目标大小）────────────────────
DST_DIR=$(dirname "$DST")
mkdir -p "$DST_DIR"
AVAIL=$(( $(df -Pk "$DST_DIR" | awk 'NR==2{print $4}') * 1024 ))
NEED=$(( SRC_ALLOC + SIZE ))
if [ "$AVAIL" -lt "$NEED" ]; then
	die "空间不足：$DST_DIR 可用 $((AVAIL/1048576)) MiB，需要 $((NEED/1048576)) MiB
       副本是稀疏的（≈$((SRC_ALLOC/1048576)) MiB，不是 $((SRC_BYTES/1048576)) MiB）；可用 --dst 指到别的盘"
fi
say "空间   :  ✅ $DST_DIR 可用 $((AVAIL/1048576)) MiB ≥ 需要 $((NEED/1048576)) MiB"

if [ "$DRYRUN" = 1 ]; then
	echo
	say "dry-run（只看不动，无需 root）："
	say "  btrfs 真实用量   $(gi "$SB_USED") GiB"
	say "  建议目标大小     $(gi "$(suggest "$SB_USED")") GiB（用量 +${MARGIN_PCT}% + $((MIN_FREE/1048576))MiB，256MiB 对齐）"
	if [ "$AUTO" = 0 ]; then say "  指定目标大小     $(gi "$SIZE") GiB"; fi
	say "  预计精简 p2      $(gi "$SIZE") GiB"
	say "  预计全量线刷包   $(gi $((SIZE + 268435456 + 39845888 + 37919296 + 4096)) ) GiB（当前整分区镜像版 7.32 GiB）"
	if [ "$SIZE" -lt "$SB_USED" ]; then
		say "  ⚠️ 目标 $(gi "$SIZE") GiB 小于已用 $(gi "$SB_USED") GiB —— 真跑时会被拒绝，请调大 --size"
	fi
	exit 0
fi

need_root
mkdir -p "$WORK"

echo "== 1/5 稀疏复制（原镜像不动）=="
rm -f "$DST"
cp --sparse=always --reflink=auto "$SRC" "$DST"
say "副本表观 $(gi "$(stat -c %s "$DST")") GiB，实占 $(gi $(( $(stat -c %b "$DST") * 512 )) ) GiB"

echo "== 2/5 loop 挂载 =="
LOOP=$(losetup -f --show "$DST") || die "losetup 失败"
MNT="$WORK/mnt"; mkdir -p "$MNT"
mount "$LOOP" "$MNT" || die "挂载失败（$DST 不是 btrfs？）"
say "已挂载 $LOOP → $MNT"

echo "== 3/5 用真实用量复核目标大小 =="
USED=$(btrfs filesystem usage -b "$MNT" | awk '/Used:/{print $2; exit}')
[ -n "$USED" ] || die "读不到 btrfs 用量"
btrfs filesystem show "$MNT" | sed 's/^/   /'
if [ "$AUTO" = 1 ]; then
	SIZE=$(suggest "$USED")
	say "自动目标 → $(gi "$SIZE") GiB（真实用量 $(gi "$USED") GiB）"
else
	say "指定目标 = $(gi "$SIZE") GiB（真实用量 $(gi "$USED") GiB）"
fi
[ "$SIZE" -ge "$USED" ] || die "目标 $SIZE 小于真实用量 $USED —— 会丢数据，拒绝执行"
[ "$SIZE" -lt "$SRC_BYTES" ] || die "目标 $SIZE 不小于当前 $SRC_BYTES —— 无需收缩（btrfs 只能缩小）"
[ "$SIZE" -ge $((64 * 1024 * 1024)) ] || die "目标过小（<64 MiB），疑似参数错误"

echo "== 4/5 btrfs 收缩 =="
btrfs filesystem resize "$SIZE" "$MNT"
sync
btrfs filesystem show "$MNT" | sed 's/^/   /'

echo "== 收缩后关键文件复核 =="
missing=0
for f in etc/fstab usr/local/sbin/cm360-firstboot.sh \
	etc/systemd/system/cm360-firstboot.service; do
	if [ -e "$MNT/$f" ]; then say "✔ $f"; else say "✗ 缺 $f"; missing=1; fi
done
[ "$missing" = 0 ] || die "关键文件缺失，收缩结果不可信（副本保留在 $DST 供排查）"

umount "$MNT"; MNT=""
losetup -d "$LOOP"; LOOP=""

echo "== 5/5 截断文件 + 只读复核 =="
truncate -s "$SIZE" "$DST"
say "新表观 $(gi "$(stat -c %s "$DST")") GiB，实占 $(gi $(( $(stat -c %b "$DST") * 512 )) ) GiB"
out=$(btrfs check --readonly "$DST" 2>&1 | tail -3)
echo "$out" | sed 's/^/   /'
if echo "$out" | grep -qi 'error\|corrupt'; then
	die "btrfs check 报错 —— 请勿使用该镜像（副本在 $DST）"
fi
btrfs inspect-internal dump-super -f "$DST" 2>/dev/null \
	| grep -E '^total_bytes|^bytes_used|^dev_item.total_bytes' | sed 's/^/   /'

echo
echo "✅ 完成：$DST"
md5sum "$DST" | sed 's/^/   /'
echo
echo "   打包（分区大小会自动仍按真实分区声明）："
echo "     python3 ../tools/make-lineflash-package.py --p2-compact --with-lowregion"
echo "   首启扩容由 /usr/local/sbin/cm360-firstboot.sh 里的 btrfs resize max 负责。"
