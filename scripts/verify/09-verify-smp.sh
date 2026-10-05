#!/bin/bash
# 09 —— SMP 验证（cpu1~cpu3 是否上线）
#
# ★ 2026-10-05 新增：板级 DTS 给四个核补了
#     enable-method = "spin-table"
#     cpu-release-addr = <0x0 0x9801aa44>
#   （原厂写 "rtk-spin-table"，主线不认；见 DTS 里那段长注释）
#
# ★ 2026-10-05 04:31 实测结论：**全部通过，四核上线**。
#   配套的内核侧改动（补丁 patches/0003-smp-rtk-spin-table.patch）：
#     arch/arm64/kernel/smp_spin_table.c 的 cpu_prepare()
#       ioremap_cache() -> ioremap()            （0x9801aa44 是 pinctrl 寄存器，不是内存）
#       writeq_relaxed() -> writel_relaxed()    （32 位，不是 8 字节）
#       去掉 dcache_clean_inval_poc
#   实测：online=0-3 / present=0-3 / nproc=4 / cpuinfo 四段 /
#         interrupts 表头 CPU0..CPU3，arch_timer 分布 654/306/410/816。
#
# 要证的【五件事】：
#   ① 启动日志里不再有 "missing enable-method property"
#   ② 不再有 "Unsupported enable-method"
#   ③ /proc/cpuinfo 里出现 processor 1/2/3（4 个 processor 段）
#   ④ /sys/devices/system/cpu/ 下 cpu0..cpu3 都在，且 online=1
#   ⑤ /proc/interrupts 表头出现 CPU0 CPU1 CPU2 CPU3（GIC 已把中断分发到从核）
#   另外看 dmesg 里 "CPU1: Booted secondary processor" 之类的 bring-up 痕迹。
#
# ★ 只读。
set -uo pipefail

S0="$EVIDENCE_DIR/stage0"
CTL="$EVIDENCE_DIR/stage0/session02.ctl"
LOG="$EVIDENCE_DIR/stage0/session02.log"
MARKFILE=/tmp/.verify_smp_mark
OUTFILE="$LOG_DIR/verify-smp.out"

. "$TOOLS_DIR/serial/serial-guard.sh"
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

echo "== ① 从核 bring-up 痕迹（dmesg）=="
run __S01__ 'dmesg | grep -i "secondary\|CPU1\|CPU2\|CPU3\|enable-method\|Brought up\|smp"' 30
echo "== ② /proc/cpuinfo 的 processor 段数 =="
run __S02__ 'grep -c processor /proc/cpuinfo'
echo "== ③ cpuinfo 全文（看 4 段）=="
run __S03__ 'cat /proc/cpuinfo' 25
echo "== ④ sysfs 在线核 =="
run __S04__ 'ls /sys/devices/system/cpu/'
run __S05__ 'cat /sys/devices/system/cpu/online'
run __S06__ 'cat /sys/devices/system/cpu/present'
run __S07__ 'cat /sys/devices/system/cpu/possible'
echo "== ⑤ 中断分发到多核 =="
run __S08__ 'head -3 /proc/interrupts'
run __S09__ 'nproc'
run __S10__ 'echo __S_DONE__'

echo
echo "======== 本次新增串口输出 ========"
NEW="$(tail -c +$((MARK + 1)) "$LOG" | tr -d '\000')"
printf '%s\n' "$NEW" | tee "$OUTFILE"

echo
echo "======== 自动体检 ========"
c_online=$(printf '%s\n' "$NEW" | grep -ac '^0-3$\|^0-1$' || true)
c_cpuinfo=$(printf '%s\n' "$NEW" | grep -ac 'processor' || true)
c_cpu3=$(printf '%s\n' "$NEW" | grep -ac 'cpu3' || true)
c_missing=$(printf '%s\n' "$NEW" | grep -ac 'missing enable-method' || true)
c_unsup=$(printf '%s\n' "$NEW" | grep -ac 'Unsupported enable-method' || true)
c_booted=$(printf '%s\n' "$NEW" | grep -aciE 'Booted secondary processor|CPU1: booted|smp: Brought up' || true)
c_table=$(printf '%s\n' "$NEW" | grep -ac 'CPU1' || true)

printf '  cpuinfo processor 行数 : %s   （★ 期望 4）\n' "$c_cpuinfo"
printf '  cpu3 出现              : %s   （★ 期望 ≥1）\n' "$c_cpu3"
printf '  从核 booted 痕迹       : %s   （★ 期望 ≥1）\n' "$c_booted"
printf '  missing enable-method  : %s   （★ 期望 0）\n' "$c_missing"
printf '  Unsupported enable-... : %s   （★ 期望 0）\n' "$c_unsup"

echo
echo "  手工确认三处："
echo "   1) /proc/cpuinfo 有 4 个 processor 段（0..3）"
echo "   2) cat /sys/devices/system/cpu/online → 0-3"
echo "   3) /proc/interrupts 表头是 CPU0 CPU1 CPU2 CPU3"
echo "   4) dmesg 里应出现 'smp: Brought up 1 node, 4 CPUs' 或"
echo "      'CPU1: Booted secondary processor 0x0000000001 [0x410fd034]'"
echo
echo "  若从核没起来（仍只有 CPU0）："
echo "   - 看有没有 'CPU1: failed to come online' / 'CPU1: died due to' "
echo "   - 说明 0x9801aa44 只写进去不够 —— 需要 sev 或 boot ROM 侧的配合，"
echo "     再查 u-boot 是否真的执行了 bootup_slave_cpu()（串口里应有"
echo "     'Bring UP slave CPUs' 那行）。"
echo
echo "  详细日志已存: $OUTFILE"
