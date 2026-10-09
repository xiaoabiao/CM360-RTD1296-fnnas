#!/bin/bash
# shrink-p2.sh —— 把 p2（btrfs rootfs）镜像**收缩**成"精简镜像"，用于线刷包瘦身
#
# 为什么需要
# ----------
# dd 出来的 p2.img 是**整分区裸镜像**（7,508,852,736 B ≈ 6.99 GiB），但里面 67.5%
# 是空洞 —— btrfs 自己报的真实用量只有约 2.26 GiB。tar **不保留稀疏性**，于是线刷包
# 被撑到 7.32 GiB。厂商包之所以小，就是因为它**不装整分区镜像**（例如 etc 分区
# 6.875 GiB 只带 512 B 的 etc.bin；rootfs 128 MiB 只带 97.9 MB 的 squashfs 镜像）
# —— 参见 docs/10-vendor-usb-mp-tool-package.md §12、§13。
#
# ★ 关键坑（实测踩到）：btrfs 的收缩下限**不是 "Used"（文件系统已用）**，
#   而是 "Device allocated"（设备已分配块）。本机实测：
#       Used            2.26 GiB
#       Device allocated 4.04 GiB   ← 真正的下限
#   直接按 Used 算目标会报 "No space left on device"。
#   所以本脚本先跑一次轻量 balance 把稀疏块压实，再用 allocated 当下限。
#
# 本脚本做的事（全部在**副本**上操作，原 p2.img 绝不被改动）：
#   1) 稀疏复制 → 2) loop 挂载 → 3) 读用量 → 4) balance 压实已分配块
#   → 5) btrfs resize → 6) 卸载截断 → 7) btrfs check 只读复核 + 关键文件检查
#
# 收缩后：
#   · layout.txt 里**分区大小仍声明为真实分区大小**（7,508,852,736），只有"随包文件"
#     变小 —— 与厂商 system/data/rootfs 的做法同构；
#   · 板子首启由 /usr/local/sbin/cm360-firstboot.sh 执行
#     `btrfs filesystem resize max /` 自动扩回满分区。
#
# 用法
# ----
#   ./shrink-p2.sh --dry-run              # 只看用量与建议目标（**不需要 root**，偏低）
#   sudo ./shrink-p2.sh                   # p2.img → p2-compact.img（含 balance）
#   sudo ./shrink-p2.sh --no-balance      # 跳过 balance（下限会高很多）
#   sudo ./shrink-p2.sh --size 4G         # 指定目标大小（不得低于设备已分配）
#   sudo ./shrink-p2.sh --src A --dst B   # 自定义输入输出
#
# 需要：sudo（loop 挂载 + btrfs resize/balance）、btrfs-progs。
# 空间：副本是稀疏的，占 ≈ btrfs 用量（约 2.2 GiB），不是 7.5 GiB。
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/images/p2.img"
DST="$HERE/images/p2-compact.img"
SIZE=""
DRYRUN=0
BALANCE=50               # balance 阈值（-dusage/-musage）；0 = 不跑
MARGIN_PCT=25            # 在"已用"之上留的余量百分比
MIN_FREE=$((256 * 1024 * 1024))
ALIGN=$((256 * 1024 * 1024))
SLACK=$((64 * 1024 * 1024))
WORK="${WORK:-/var/tmp/cm360-shrink}"
LOOP=""
MNT=""

die() { echo "!! $*" >&2; exit 1; }
say() { echo "   $*"; }
need_root() { [ "$(id -u)" = 0 ] || die "需要 root（loop 挂载 / btrfs resize）：请用 sudo 运行"; }
gi() { awk "BEGIN{printf \"%.3f\", $1/1073741824}"; }

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
align() { echo $(( ($1 + ALIGN - 1) / ALIGN * ALIGN )); }
# 由"已用量 used"与"设备已分配 allocated"共同推荐目标（allocated 是硬下限）
suggest() {
	local used="$1" alloc="$2"
	local byuse=$(( used + used * MARGIN_PCT / 100 + MIN_FREE ))
	local byalloc=$(( alloc + SLACK ))
	[ "$byuse" -lt "$byalloc" ] && byuse=$byalloc
	align "$byuse"
}
# 从 `btrfs filesystem usage -b` 输出里取字段（输出行**带前导空白**，要先剥掉再比前缀）
usage_field() { # $1=mount $2=标签前缀（"Device allocated:" / "Used:"）
	btrfs filesystem usage -b "$1" 2>/dev/null | awk -v k="$2" '
		{ line=$0; sub(/^[ \t]+/, "", line); if (index(line, k) == 1) { print $NF; exit } }'
}

while [ $# -gt 0 ]; do
	case "$1" in
	--src) SRC="$2"; shift 2 ;;
	--dst) DST="$2"; shift 2 ;;
	--size) SIZE="$(to_bytes "$2")"; shift 2 ;;
	--balance) BALANCE="${2:-50}"; shift 2 ;;
	--no-balance) BALANCE=0; shift ;;
	--dry-run) DRYRUN=1; shift ;;
	-h|--help) sed -n '1,46p' "$0"; exit 0 ;;
	*) die "未知参数：$1" ;;
	esac
done

[ -f "$SRC" ] || die "找不到源镜像：$SRC"
SRC_BYTES=$(stat -c %s "$SRC")
SRC_ALLOC=$(( $(stat -c %b "$SRC") * 512 ))

echo "== 源 =="
say "$SRC"
say "表观 $(gi "$SRC_BYTES") GiB   实占 $(gi "$SRC_ALLOC") GiB   稀疏空洞 $(awk "BEGIN{printf \"%.1f%%\", 100*($SRC_BYTES-$SRC_ALLOC)/$SRC_BYTES}")"

# ── 预检：读 btrfs 超级块（**不需要 root**）──────────────────────────────
DUMP=$(btrfs inspect-internal dump-super -f "$SRC" 2>/dev/null) \
	|| die "$SRC 不是 btrfs 镜像（读不到超级块）"
SB_LABEL=$(echo "$DUMP" | awk '/^label/{print $2; exit}')
SB_TOTAL=$(echo "$DUMP" | awk '/^total_bytes/{print $2; exit}')
SB_USED=$(echo "$DUMP" | awk '/^bytes_used/{print $2; exit}')
[ -n "$SB_USED" ] || die "超级块里读不到 bytes_used"
say "超级块:  ✅ btrfs  label=${SB_LABEL:-?}  total=$(gi "$SB_TOTAL") GiB  used=$(gi "$SB_USED") GiB"
[ "$SB_TOTAL" = "$SRC_BYTES" ] || say "⚠️ 超级块 total_bytes 与文件大小不一致（截断？）"
if [ "$SRC_BYTES" -le $((1024 * 1024 * 1024)) ]; then
	die "源镜像只有 $(gi "$SRC_BYTES") GiB —— 不像真的 7 GiB p2，疑似路径给错"
fi

AUTO=0
if [ -z "$SIZE" ]; then AUTO=1; fi

# ── 空间预检 ────────────────────────────────────────────────────────────
# 副本是稀疏的（实测 cp --sparse=always 一份 7.5GB 文件只占 2.24 GiB），
# 所以真实需求 = 稀疏副本（≈SRC_ALLOC）+ 余量，而不是整份表观大小。
DST_DIR=$(dirname "$DST")
mkdir -p "$DST_DIR"
AVAIL=$(( $(df -Pk "$DST_DIR" | awk 'NR==2{print $4}') * 1024 ))
NEED=$(( SRC_ALLOC + 256 * 1024 * 1024 ))
[ "$AVAIL" -ge "$NEED" ] || die "空间不足：$DST_DIR 可用 $((AVAIL/1048576)) MiB，需要 $((NEED/1048576)) MiB
       副本是稀疏的（≈$((SRC_ALLOC/1048576)) MiB，不是 $((SRC_BYTES/1048576)) MiB）；可用 --dst 指到别的盘"
say "空间:    ✅ $DST_DIR 可用 $((AVAIL/1048576)) MiB ≥ 需要 $((NEED/1048576)) MiB（稀疏副本 + 256MiB 余量）"
if [ "$AVAIL" -lt "$SRC_BYTES" ]; then
	say "提示:    该盘放不下**非稀疏**的整份镜像（$(gi "$SRC_BYTES") GiB）—— 依赖 cp --sparse 保持稀疏（已实测可行）"
fi

if [ "$DRYRUN" = 1 ]; then
	echo
	say "dry-run（只看不动，无需 root；注意下限算不准 —— 见说明）："
	say "  文件系统已用(Used)      $(gi "$SB_USED") GiB"
	say "  按 Used 估算的目标      $(gi "$(suggest "$SB_USED" "$SB_USED")") GiB"
	say "  ⚠️ 真正下限是『设备已分配(Device allocated)』，只有挂载后才能读到；"
	say "     它可能高达 Used 的 2 倍（本机实测 Used 2.26 / allocated 4.04 GiB）。"
	say "     真跑时脚本会先 balance 压实，再把 allocated 作为硬下限。"
	say "  预计全量线刷包 ≈ 精简 p2 + 0.32 GiB（p1 0.25 + 低区 0.037 + 内核 0.035）"
	exit 0
fi

need_root
mkdir -p "$WORK"

echo "== 1/7 稀疏复制（原镜像不动）=="
rm -f "$DST"
cp --sparse=always --reflink=auto "$SRC" "$DST"
say "副本表观 $(gi "$(stat -c %s "$DST")") GiB，实占 $(gi $(( $(stat -c %b "$DST") * 512 )) ) GiB"

echo "== 2/7 loop 挂载 =="
LOOP=$(losetup -f --show "$DST") || die "losetup 失败"
MNT="$WORK/mnt"; mkdir -p "$MNT"
mount "$LOOP" "$MNT" || die "挂载失败（$DST 不是 btrfs？）"
say "已挂载 $LOOP → $MNT"

echo "== 3/7 读用量（Used 与 Device allocated 是两回事）=="
USED=$(usage_field "$MNT" "Used:")
ALLOC0=$(usage_field "$MNT" "Device allocated:")
[ -n "$USED" ] && [ -n "$ALLOC0" ] || die "读不到 btrfs 用量字段"
say "Used              $(gi "$USED") GiB"
say "Device allocated  $(gi "$ALLOC0") GiB   ← 收缩硬下限"

echo "== 4/7 balance 压实稀疏块（-dusage=$BALANCE -musage=$BALANCE）=="
ALLOC=$ALLOC0
if [ "$BALANCE" -gt 0 ]; then
	if btrfs balance start -dusage="$BALANCE" -musage="$BALANCE" "$MNT"; then
		ALLOC=$(usage_field "$MNT" "Device allocated:")
		USED=$(usage_field "$MNT" "Used:")
		say "allocated $(gi "$ALLOC0") GiB → $(gi "$ALLOC") GiB（省下 $(gi $((ALLOC0-ALLOC))) GiB）"
	else
		say "⚠️ balance 失败，继续用原 allocated 当限"
	fi
else
	say "已按要求跳过 balance"
fi

echo "== 5/7 逐级下探收缩（自动找 btrfs 真实下限）=="
# 关键经验（实测）：单次 resize 到"按 Used 算的目标"会报 ENOSPC；
# 但每次**成功的** resize 都会让 btrfs 顺手搬迁/压实，于是还能继续往下压。
# 所以这里：先跳到建议值（失败就按 256MiB 步长往上退到能成功），
# 成功后再以 256MiB 为步长**一直往下探**，直到失败 —— 用最小的成功值。
STEP=$((256 * 1024 * 1024))
SLACK_FREE=$((128 * 1024 * 1024))
try_resize() { btrfs filesystem resize "$1" "$MNT" >/dev/null 2>&1; }
unalloc() { usage_field "$MNT" "Device unallocated:"; }

if [ "$AUTO" = 1 ]; then
	CUR=$(suggest "$USED" "$ALLOC")
	[ "$CUR" -ge "$SRC_BYTES" ] && CUR=$(( SRC_BYTES - STEP ))
	ok=0
	# 往上退：找一个能成功的起点（上限 = 当前镜像大小；正常第一跳就成功）
	while [ "$CUR" -lt "$(( SRC_BYTES - STEP ))" ]; do
		if try_resize "$CUR"; then ok=1; break; fi
		say "  $(gi "$CUR") GiB 收缩失败，退一档重试…"
		CUR=$(( CUR + STEP ))
	done
	[ "$ok" = 1 ] || die "连 $(gi "$CUR") GiB 都缩不动 —— 异常（设备已分配 $(gi "$ALLOC") GiB）"
	say "起点 $(gi "$CUR") GiB 收缩成功，开始下探"
	BEST=$CUR
	while [ $(( BEST - STEP )) -gt $(( USED + 64 * 1024 * 1024 )) ]; do
		if try_resize $(( BEST - STEP )); then
			BEST=$(( BEST - STEP ))
			say "  ↓ $(gi "$BEST") GiB 成功（剩余未分配 $(gi "$(unalloc)") GiB）"
		else
			say "  ⛔ $(gi $((BEST-STEP))) GiB 失败 → 下限 ≈ $(gi "$BEST") GiB"
			break
		fi
	done
	SIZE=$BEST
	# 保证收缩后仍有 ≥128MiB 未分配空间（给首启留呼吸余量）
	while [ "$(unalloc)" -lt "$SLACK_FREE" ] && [ $(( SIZE + STEP )) -lt "$SRC_BYTES" ]; do
		SIZE=$(( SIZE + STEP ))
		try_resize "$SIZE" || break
		say "  ↑ 余量不足，退到 $(gi "$SIZE") GiB（未分配 $(gi "$(unalloc)") GiB）"
	done
else
	MINOK=$(( ALLOC + SLACK ))
	[ "$SIZE" -ge "$MINOK" ] || die "指定目标 $(gi "$SIZE") GiB 低于硬下限 $(gi "$MINOK") GiB（设备已分配 + 64MiB）"
	[ "$SIZE" -lt "$SRC_BYTES" ] || die "指定目标不小于当前 $(gi "$SRC_BYTES") GiB —— 无需收缩"
	try_resize "$SIZE" || die "resize 失败：当前已分配 $(gi "$(usage_field "$MNT" "Device allocated:")") GiB"
	say "按指定大小收缩到 $(gi "$SIZE") GiB"
fi
sync
btrfs filesystem show "$MNT" | sed 's/^/   /'
btrfs filesystem usage -b "$MNT" | grep -E 'Device size|Device allocated|Device unallocated|Used:|Free \(estimated\)' | sed 's/^/   /'

echo "== 6/7 收缩后关键文件复核 =="
missing=0
for f in etc/fstab usr/local/sbin/cm360-firstboot.sh \
	etc/systemd/system/cm360-firstboot.service; do
	if [ -e "$MNT/$f" ]; then say "✔ $f"; else say "✗ 缺 $f"; missing=1; fi
done
# 文件清单指纹：收缩前后应完全一致（只搬不删）
MANIFEST=$(find "$MNT" -xdev -printf '%P %s\n' | LC_ALL=C sort | md5sum | cut -d' ' -f1)
NFILES=$(find "$MNT" -xdev | wc -l)
say "文件数 $NFILES   清单指纹 $MANIFEST"
if [ -n "${MANIFEST_REF:-}" ] && [ "$MANIFEST_REF" != "$MANIFEST" ]; then
	die "清单指纹与参考值不一致：$MANIFEST != $MANIFEST_REF"
fi
[ "$missing" = 0 ] || die "关键文件缺失，收缩结果不可信（副本保留在 $DST 供排查）"

umount "$MNT"; MNT=""
losetup -d "$LOOP"; LOOP=""

echo "== 7/7 截断文件 + 只读复核 =="
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
echo "   文件数 $NFILES   清单指纹 $MANIFEST"
echo
echo "   打包（分区大小会自动仍按真实分区声明）："
echo "     python3 ../tools/make-lineflash-package.py --p2-compact --with-lowregion"
echo "   首启扩容由 /usr/local/sbin/cm360-firstboot.sh 里的 btrfs resize max 负责。"
