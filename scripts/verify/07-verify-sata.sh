#!/bin/bash
# 07 —— 点亮 SATA（ahci_rtk + 12T HGST 盘）之后的验证
#
# 背景（2026-10-04）：用户给 CM360 装了 1 块 12T SATA 盘。
# 该盘在 DSM（原厂内核 4.9）下已被证实可用：
#     ata1.00: ATA-9: HUH721212ALE600, T9C0, max UDMA/133
#     ata1.00: 23437770752 sectors
#     ata2: SATA link down            ← 端口 1 是空的
#     ata2: SATA max UDMA/133 mmio [mem 0x9803f000-0x9803ffff]
#   ⇒ 盘在【端口 0】，AHCI 窗口 = 0x3f000 + 0x1000（与我们的 reg 完全一致）
#
# 这一轮要证的【四件事】：
#   ① ahci_rtk 的 probe 真的过了（不是 -ENODEV / -EPROBE_DEFER / 没绑定）
#        → 启动日志里应有 "ahci_rtk" 或 ata 层 "SATA max UDMA/133" 那行。
#        → 没有的话，看是 "failed to remap sata wrapper reg"（satawrap 错）
#          还是 reset/clk 相关报错。
#   ② 端口 0 上的 12T 盘被认出（ata1: SATA link up ...）
#   ③ 块设备 /dev/sda 出现，且容量 = 23437770752 扇区（≈12 TB）
#        → /sys/block/sda/size 是最硬的证据（不依赖 sda 有没有被 mdev 建节点）
#   ④ ahci 中断进了 /proc/interrupts（走 GIC SPI 28 → hwirq 60）
#        → 注意 virq 是动态分配的，**不要写死数字**，只看 hwirq = 28+32 = 60。
#
# ★ 只读！这块盘上有 DSM 的既有分区（sda1/sda2/sda3），
#   本轮只读容量/型号/分区表，**绝不 mount、绝不写入**。
#
# ★ 串口纪律（前几轮血的教训）：单条命令、不用 ; | && 引号复合、等哨兵回显 ≥2 次。
set -uo pipefail

S0="$EVIDENCE_DIR/stage0"
CTL="$EVIDENCE_DIR/stage0/session02.ctl"
LOG="$EVIDENCE_DIR/stage0/session02.log"
MARKFILE=/tmp/.verify_sata_mark
OUTFILE="$LOG_DIR/verify-sata.out"

# 串口独占守卫：别的进程（如手动 screen）也 read() 同一个 tty 时，两个读者会
# 瓜分字节流 —— 症状是"命令有回显、却不执行、无输出"，极易误判成板子挂了。
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

echo "== ① ATA/AHCI 层：控制器起没起、端口状态 =="
run __S01__ 'cat /proc/partitions'
run __S02__ 'ls /sys/class/ata_port'
run __S03__ 'ls /sys/bus/ata/devices'

echo "== ② 块设备：/dev/sda 及其容量（★ 期望 23437770752 扇区）=="
run __S04__ 'cat /sys/block/sda/size'
run __S05__ 'cat /sys/block/sda/device/model'
run __S06__ 'ls /dev/sd*' 10
run __S07__ 'ls /dev'

echo "== ③ 分区表（只读，看 sda1/sda2/sda3 是否读得到）=="
run __S08__ 'cat /proc/partitions'

echo "== ④ 中断：ahci 有没有拿到 GIC SPI 28（hwirq 60）=="
run __S09__ 'cat /proc/interrupts'
run __S10__ 'echo __S_DONE__'

echo
echo "======== 本次新增串口输出 ========"
NEW="$(tail -c +$((MARK + 1)) "$LOG" | tr -d '\000')"
printf '%s\n' "$NEW" | tee "$OUTFILE"

echo
echo "======== 自动体检 ========"
n_sda=$(printf '%s\n' "$NEW" | grep -ac 'sda' || true)
n_12t=$(printf '%s\n' "$NEW" | grep -ac '23437770752' || true)
n_ahci=$(printf '%s\n' "$NEW" | grep -aci 'ahci' || true)
n_done=$(printf '%s\n' "$NEW" | grep -ac '__S_DONE__' || true)

printf '  sda 出现次数           : %s   （★ 期望 ≥1）\n' "$n_sda"
printf '  23437770752 出现       : %s   （★ 期望 ≥1；出现即 12T 盘认全）\n' "$n_12t"
printf '  ahci 出现              : %s   （★ 期望 ≥1）\n' "$n_ahci"
printf '  __S_DONE__ 哨兵        : %s   （★ 期望 ≥1；0 说明脚本没跑完）\n' "$n_done"

echo
echo "  从【启动日志】里抓 ahci/ata 段（这一段是内核自己在 console 上打的，最可信）："
tail -c +$((MARK + 1)) "$LOG" | grep -iE 'ahci|ata[0-9]|scsi|sd [0-9]|libata|sata' | head -40 \
	|| echo "    （本次段里没有 —— 再看整份 session02.log 的 boot 段）"

echo
echo "  手工确认三处："
echo "   1) 启动日志应出现 ahci_rtk 绑定 + 「ata1: SATA link up 6.0 Gbps」"
echo "   2) /sys/block/sda/size 应 = 23437770752（≈12TB）"
echo "   3) /proc/interrupts 里应有一条 hwirq=60 的中断（virq 号动态，别写死）"
echo
echo "  详细日志已存: $OUTFILE"
echo "  完整启动日志: $LOG（含 u-boot 到 shell 的全过程）"
