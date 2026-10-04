#!/bin/bash
# 14-emmc-write.sh —— 把引导分区 + 根文件系统写进 CM360 的 eMMC（主机侧编排）
#
# 前提：板子已在跑 fnOS（根在 SATA /dev/sda 的 btrfs 上），且 ssh 可用（见 brd.py）。
#
# 分工：
#   本脚本只做"推流 + 调用"；真正的写盘逻辑在 board/emmc-part.sh 与 board/emmc-root.sh，
#   在板上以 root 跑（避免把大量引号/转义塞进 ssh 命令行）。
#
# 用法：
#   ./14-emmc-write.sh check   # 只读体检
#   ./14-emmc-write.sh part    # [1-5] 卸载 + 抹表 + MBR + 兜底裸内核 + p1（快，可反复）
#   ./14-emmc-write.sh root    # [6-8] mkfs.btrfs + send/receive 迁根（慢，3~10 分钟）
#   ./14-emmc-write.sh all     # 全做（默认）
set -uo pipefail
cd "$(dirname "$0")"
source ./env.sh

MODE="${1:-all}"
OUTE="$OUT/emmc"
BOARD="$S2/board"
LOGD="$S2/logs"; mkdir -p "$LOGD"
RUNLOG="$LOGD/emmc-write-$(date +%m%d-%H%M%S).log"
BRD="$S2/brd.py"
T=/tmp

step() { echo; echo "########## $* ##########"; }

{
echo "###### eMMC 写入  模式=$MODE  开始 $(date '+%F %T') ######"

# ================================================================ check
if [ "$MODE" = check ]; then
	step "只读体检"
	"$BRD" sudo '
		echo "--- mmcblk0 / sda ---"; grep -E "mmcblk|sda" /proc/partitions
		echo "--- 从 mmcblk0 挂上来的 ---"; findmnt -rno TARGET,SOURCE | grep mmcblk0 || echo "(无)"
		echo "--- LBA0 尾 2 字节（55aa=MBR / 其他）---"; dd if=/dev/mmcblk0 bs=512 count=1 2>/dev/null | tail -c 2 | od -An -tx1
		echo "--- LBA1 首 8 字节（EFI PART=旧 GPT 还在）---"; dd if=/dev/mmcblk0 bs=512 skip=1 count=1 2>/dev/null | head -c 8 | od -c | head -1
		echo "--- 空间 ---"; df -h / /tmp | head -5
		echo "--- 工具 ---"; command -v mkfs.btrfs mkfs.ext4 blockdev btrfs dd
	'
	echo
	echo "###### 完成 $(date '+%F %T') ######"
	exit 0
fi

[ -f "$OUTE/mbr.bin" ] || die "缺少 $OUTE/mbr.bin（先跑 13-prep-emmc.sh）"
[ -f "$OUTE/p1.img" ]  || die "缺少 $OUTE/p1.img（先跑 13-prep-emmc.sh）"

# ================================================================ part
if [ "$MODE" = all ] || [ "$MODE" = part ]; then
	step "[推流 1/2] 把布局产物推到板子 /tmp"
	"$BRD" push "$OUTE/mbr.bin"        "$T/emmc-mbr.bin"
	"$BRD" push "$OUTE/raw-kernel.bin" "$T/emmc-rawk.bin"
	"$BRD" push "$OUTE/raw-dtb.bin"    "$T/emmc-rawd.bin"
	"$BRD" push "$OUTE/layout.txt"     "$T/emmc-layout.txt"
	"$BRD" push "$OUTE/p1.img"         "$T/emmc-p1.img"
	step "[推流 2/2] 推板上脚本并执行 emmc-part.sh"
	"$BRD" push "$BOARD/emmc-part.sh"  "$T/emmc-part.sh"
	"$BRD" sudo "bash $T/emmc-part.sh"
fi

# ================================================================ root
if [ "$MODE" = all ] || [ "$MODE" = root ]; then
	step "[推流] 推板上脚本并执行 emmc-root.sh"
	"$BRD" push "$BOARD/emmc-root.sh"  "$T/emmc-root.sh"
	"$BRD" sudo "bash $T/emmc-root.sh"
fi

echo
echo "###### 完成 $(date '+%F %T') ######"
} 2>&1 | tee "$RUNLOG"

echo
echo "日志: $RUNLOG"
