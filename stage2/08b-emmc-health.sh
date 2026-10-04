#!/bin/bash
# 08b —— eMMC 补验（在 08 主验证之后跑，清 shell 还活着时用）
#
# 为什么单独一份：
#   08-verify-emmc.sh 的第一版 ⑦ 期望 `/sys/devices/platform/98012000.emmc/emmc_info`，
#   实测【不存在】—— rtkemmc.c 不像 16xxb 的 dw_mmc_cqe-rtk 那样建这个私有属性。
#   换用 mmc 核心的标准 sysfs（/sys/class/mmc_host/mmc0/mmc0:0001/）。这层属性
#   才是后续 fnOS / 用户态（smartctl on emmc、udev、systemd）真正会读的东西。
#
# 要补证的【三件事】：
#   ① eMMC 寿命/健康度：life_time（SLC/MLC 磨损档 0x01..0x0b）、pre_eol_info
#      —— 决定这块 8GB 出厂盘能不能当 fnOS 系统盘长期跑
#   ② eMMC 身份细节：oemid / serial / hwrev / fwrev / date —— 追料、对原厂
#      BSP 日志时用得着
#   ③ 块设备拓扑：mmcblk0 + boot0/boot1 + rpmb 三件套是否齐全
#
# ★ 只读。
set -uo pipefail

S0=/home/xiaoabiao/WorkBuddy/2026-10-03-23-33-10/rtd1296-fnnas/stage0
CTL="$S0/session02.ctl"
LOG="$S0/session02.log"
MARKFILE=/tmp/.verify_emmc_health_mark
OUT="$S0/../stage2/logs/verify-emmc-health.out"

. "$S0/serial-guard.sh"
serial_guard || { echo "!! 串口被别的进程占用在读（见上）。" >&2; exit 4; }

run() {
	local tag="$1" cmd="$2" wait="${3:-20}" i n
	echo "$(stat -c %s "$LOG")" > "$MARKFILE"
	printf 'echo %s\n' "$tag" >> "$CTL"
	sleep 3
	printf '%s\n' "$cmd" >> "$CTL"
	for i in $(seq 1 "$wait"); do
		sleep 1
		n=$(tail -c +$(( $(cat "$MARKFILE") + 1 )) "$LOG" | tr -d '\000' | grep -ac "$tag")
		[ "$n" -ge 2 ] && break
	done
	sleep 1
}

MARK=$(stat -c %s "$LOG")
D=/sys/class/mmc_host/mmc0/mmc0:0001

echo "== ① eMMC 健康度（fnOS 系统盘够不够格）=="
run __H01__ "cat $D/life_time"
run __H02__ "cat $D/pre_eol_info"
echo "== ② eMMC 身份细节 =="
run __H03__ "cat $D/oemid"
run __H04__ "cat $D/serial"
run __H05__ "cat $D/hwrev"
run __H06__ "cat $D/fwrev"
run __H07__ "cat $D/date"
run __H08__ "cat $D/manfid"
echo "== ③ mmc 核心 sysfs 全貌 =="
run __H09__ "ls $D"
echo "== ④ 块设备拓扑（boot0/boot1/rpmb）=="
run __H10__ "ls /sys/block/mmcblk0"
run __H11__ "ls /dev/mmcblk0boot0 /dev/mmcblk0boot1 /dev/mmcblk0rpmb"
echo "== ⑤ 当前速率档（HS200 时钟）=="
run __H12__ "dmesg | grep -i 'hs200\|new .* MMC card\|mmcblk0:'"
run __H13__ "echo __H_DONE__"

echo
echo "======== 本次新增串口输出 ========"
NEW="$(tail -c +$((MARK + 1)) "$LOG" | tr -d '\000')"
printf '%s\n' "$NEW" | tee "$OUT"

echo
echo "  关键行："
printf '%s\n' "$NEW" | grep -aiE 'life_time|pre_eol|8GTF4R|HS200|mmcblk0' | head -30
echo
echo "  详细日志已存: $OUT"
