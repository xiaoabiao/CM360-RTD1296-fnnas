#!/bin/bash
# 08 —— 点亮 eMMC（rtkemmc.c + 8 GiB 板载 eMMC）之后的验证
#
# ★ 2026-10-05 第二版：驱动从 dw_mmc_cqe-rtk.c 换成 rtkemmc.c。
#   第一版（16xxb 的 dw_mmc_cqe-rtk）失败证据：emmcprobe 寄存器转储显示
#   它写的 pad 控制寄存器（0x50c/0x550/0x554/0x558/0x55c）在 1296 上
#   全部读回 deadbeef —— 那些偏移在 1295 寄存器地图里不存在。
#   现用 jjm2473/rtd1295-next 的 rtkemmc.c（compatible realtek,rtd1295-emmc），
#   详见 rtd1296-cm360.dts 的 eMMC 段落大注释。
#
# ★ 2026-10-05 第三版（实测后修正两处判据漏洞）：
#   (a) panic 误报：旧 pattern 含 `BUG:` + `grep -i`，把内核自己打的
#       "printk: debug: ignoring loglevel" / "debug: skip boot console"
#       里的 "debug:" 当成 "BUG:" 命中，报出 2 条假 panic。
#       修：`BUG:` 限定前面必须是空白（内核真 BUG 打的是 "kernel BUG at ..."
#       或行首 "BUG:"），再补 "kernel BUG at" / "cut here"。
#   (b) ⑦ 期望的 /sys/devices/platform/98012000.emmc/emmc_info 【不存在】——
#       rtkemmc.c 不像 16xxb 驱动那样建这个私有属性。改用 mmc 核心标准
#       sysfs（/sys/class/mmc_host/mmc0/mmc0:0001/），这层才是用户态
#       （fnOS / udev / systemd / smart 类工具）真正会读的。
#       寿命健康度细节另见 08b-emmc-health.sh。
#
# 这一轮要证的【七件事】：
#   ① 驱动 probe 过了：console 里应有
#        "EMMC : emmc of_node found" / "[rtkemmc_probe] get speed-step : 2"
#      没有 panic / NULL deref。
#   ② mmc host 出现：/sys/class/mmc_host/mmc0
#   ③ 卡被认出：/sys/block/mmcblk0 出现，并读到 CID/CSD/型号
#   ④ 容量对：/sys/block/mmcblk0/size = 15,269,888 扇区（≈7.28 GiB，8GB eMMC）
#   ⑤ 中断进了 /proc/interrupts（GIC SPI 42 → hwirq 74；virq 动态，别写死）
#   ⑥ 速率档位：dmesg 里应有 "mmc0: new HS200 MMC card"
#   ⑦ eMMC 健康度（标准 sysfs）：life_time / pre_eol_info —— 见 08b
#
# ★ 只读！eMMC 上是出厂数据，本轮【绝不写】，只读容量/CID/CSD。
#
# ★ 串口纪律：单条命令、不用 ; | && 引号复合、等哨兵回显 ≥2 次。
set -uo pipefail

S0="$EVIDENCE_DIR/stage0"
CTL="$EVIDENCE_DIR/stage0/session02.ctl"
LOG="$EVIDENCE_DIR/stage0/session02.log"
MARKFILE=/tmp/.verify_emmc_mark
OUTFILE="$LOG_DIR/verify-emmc.out"

. "$TOOLS_DIR/serial/serial-guard.sh"
serial_guard || { echo "!! 串口被别的进程占用在读（见上），先关掉再跑体检。" >&2; exit 4; }

run() {
	local tag="$1" cmd="$2" wait="${3:-20}" i n
	echo "$(stat -c %s "$LOG")" > "$MARKFILE"
	printf 'echo %s\n' "$tag" >> "$CTL"
	sleep 3                       # ★ 静默，让板子把上一轮输出吐干净
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

echo "== ① 驱动 probe：从 dmesg 抓 EMMC/mmc/pll 段 =="
run __E01__ 'dmesg' 30

echo "== ② mmc host 是否注册 =="
run __E02__ 'ls /sys/class/mmc_host'

echo "== ③ 块设备与分区表 =="
run __E03__ 'cat /proc/partitions'

echo "== ④ /dev 下有没有 mmcblk 节点 =="
run __E04__ 'ls /dev/mmcblk0'

echo "== ⑤ 容量（★ 期望 15269888 扇区 / 7.28GiB）=="
run __E05__ 'cat /sys/block/mmcblk0/size'

echo "== ⑥ eMMC 身份（CID/CSD/型号/类型）=="
run __E06__ 'cat /sys/block/mmcblk0/device/type'
run __E07__ 'cat /sys/block/mmcblk0/device/name'
run __E08__ 'cat /sys/block/mmcblk0/device/cid'
run __E09__ 'cat /sys/block/mmcblk0/device/csd'

echo "== ⑦ mmc 核心标准 sysfs（★ 用户态真正会读的那层）=="
run __E10__ "ls $D"
run __E11__ "cat $D/life_time"
run __E12__ "cat $D/pre_eol_info"

echo "== ⑧ 速率档 + 中断（hwirq=74）=="
run __E13__ 'dmesg | grep -i "HS200\|new .* MMC card\|mmcblk0:"'
run __E14__ 'cat /proc/interrupts'
run __E15__ 'echo __E_DONE__'

echo
echo "======== 本次新增串口输出 ========"
NEW="$(tail -c +$((MARK + 1)) "$LOG" | tr -d '\000')"
printf '%s\n' "$NEW" | tee "$OUTFILE"

echo
echo "======== 自动体检 ========"
c_mmcblk=$(printf '%s\n' "$NEW" | grep -ac 'mmcblk0' || true)
c_mmchost=$(printf '%s\n' "$NEW" | grep -ac 'mmc0' || true)
c_size=$(printf '%s\n' "$NEW" | grep -ac '15269888' || true)
c_probe=$(printf '%s\n' "$NEW" | grep -aciE '\[EMMC\]|EMMC : emmc of_node found|rtkemmc' || true)
c_ss=$(printf '%s\n' "$NEW" | grep -ac 'get speed-step' || true)
c_hs200=$(printf '%s\n' "$NEW" | grep -aciE 'new HS200 MMC card' || true)
c_lt=$(printf '%s\n' "$NEW" | grep -ac 'life_time' || true)
c_eol=$(printf '%s\n' "$NEW" | grep -ac 'pre_eol_info' || true)
# ★ panic 判据：`BUG:` 前面必须是空白，避开 "printk: debug:" 这类假阳性
c_panic=$(printf '%s\n' "$NEW" | grep -aciE 'kernel panic|unable to handle kernel|internal error|attempted to kill init|[[:space:]]BUG:|kernel BUG at|cut here' || true)
c_done=$(printf '%s\n' "$NEW" | grep -ac '__E_DONE__' || true)

printf '  mmcblk0 出现          : %s   （★ 期望 ≥1）\n' "$c_mmcblk"
printf '  mmc0 出现             : %s   （★ 期望 ≥1）\n' "$c_mmchost"
printf '  15269888（8GB 容量）  : %s   （★ 期望 ≥1；出现即 8G eMMC 认全）\n' "$c_size"
printf '  rtkemmc probe 痕迹    : %s   （★ 期望 ≥1）\n' "$c_probe"
printf '  get speed-step        : %s   （★ 期望 ≥1）\n' "$c_ss"
printf '  "new HS200 MMC card"  : %s   （★ 期望 ≥1；HS200 调优过了才有）\n' "$c_hs200"
printf '  life_time 读数        : %s   （★ 期望 ≥1）\n' "$c_lt"
printf '  pre_eol_info 读数     : %s   （★ 期望 ≥1）\n' "$c_eol"
printf '  panic/oops 痕迹       : %s   （★ 期望 0）\n' "$c_panic"
printf '  __E_DONE__ 哨兵       : %s   （★ 期望 ≥1；0 说明脚本没跑完）\n' "$c_done"

echo
echo "  从【本次段】里抓 EMMC/mmc 关键行（内核自己打的，最可信）："
printf '%s\n' "$NEW" | grep -aiE 'EMMC : emmc of_node|rtkemmc|mmc[0-9]|mmcblk|pll_emmc|speed-step|HS200|HS400|DDR50|final phase|8GTF4R|life_time|pre_eol' | head -60 \
	|| echo "    （本次段里没有 —— 看整份 session02.log 的 boot 段）"

echo
echo "  手工确认六处："
echo "   1) dmesg 里应有 'EMMC : emmc of_node found' + 'get speed-step : 2'"
echo "   2) /sys/class/mmc_host/mmc0 存在"
echo "   3) /sys/block/mmcblk0/size = 15269888（8GB eMMC）"
echo "   4) /proc/interrupts 里应有一条 hwirq=74 的中断（virq 动态，别写死）"
echo "   5) dmesg 里 'mmc0: new HS200 MMC card' —— 调优成功；若只到"
echo "      DDR52/HS，把 DTS 的 speed-step 降到 1（ddr50）/ 0（sdr50）先拿设备"
echo "   6) life_time / pre_eol_info 判健康度（详见 08b-emmc-health.sh）"
echo
echo "  详细日志已存: $OUTFILE"
echo "  完整启动日志: $LOG"
