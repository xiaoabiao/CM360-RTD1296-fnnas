#!/bin/bash
# 06 —— 收掉 clk_ignore_unused + 给 uart0 上中断之后的验证
#
# 这一轮要证的【三件事】：
#   ① uart0 的时钟真被驱动认领了
#        → /sys/kernel/debug/clk/clk_summary 里 clk_en_ur0 那行
#          应该 rate = 27000000、enable_cnt ≥ 1
#        → 这是撤掉 clk_ignore_unused 之后控制台还能活的【唯一依据】。
#          enable_cnt = 0 就说明没人认领，迟早被 clk_disable_unused() gate 掉。
#
#   ② uart0 拿到了真中断（不再 irq = 0 纯轮询）
#        → /proc/interrupts 里应出现一条 chip 叫 **realtek-irq-mux** 的
#          ttyS0 中断（挂在我们新加的 iso_irq_mux 上）
#        → 判据不是"看它有没有中断"，而是看【还有没有 input overrun】：
#          轮询模式下 RX FIFO 排不空，一灌命令就丢字节；有真中断就不该再丢。
#          脚本最后会自动统计本轮出现了几条 "input overrun"。
#
#   ③ 撤总闸没伤到 GMAC，顺便把"IRQ 14"这个疑点钉死
#        → 上板日志里 r8169 probe 打的是 "IRQ 14"，而 DTS 写的是
#          GIC SPI 22（按常规应映射成 hwirq 54 = 22+32）。
#          /proc/interrupts 能一次性看清：应该是一条
#          `NN:  ...  GICv2  54  Level  eth0`
#          —— 即 virq NN ↔ hwirq 54。**NN 是动态分配的 virq，不是固定值**：
#          2026-10-04 两次上电分别拿到 14 和 17（见 §14），所以脚本里不要写死 14。
#          唯一的不变量是 hwirq 必须 = 54。若 hwirq 不是 54，那才是真问题。
#
# ★ 串口纪律（前几轮血的教训，别再犯）：
#   - 单条命令，绝不用 ; | && 引号复合 —— 一旦被截断会把 shell 丢进
#     续行态（> 提示符），后面所有命令全被吞掉，只能 Ctrl-C 抢救。
#   - 要筛选内容时用 `grep 关键字 文件`（grep 直接吃文件名），不用管道。
#   - 每条命令前留静默、等哨兵回显 ≥ 2 次再发下一条。
set -uo pipefail

S0=/home/xiaoabiao/WorkBuddy/2026-10-03-23-33-10/rtd1296-fnnas/stage0
CTL="$S0/session02.ctl"
LOG="$S0/session02.log"
MARKFILE=/tmp/.verify_clkirq_mark
OUT="$S0/../stage2/logs/verify-clk-irq.out"

# 串口独占守卫：别的进程（如手动 screen）也 read() 同一个 tty 时，两个读者
# 会瓜分字节流 —— 症状是"命令有回显、却不执行、无输出"，极易误判成板子挂了。
# 详见 stage0/serial-guard.sh 顶部。本轮就是被这条坑了半天。
. "$S0/serial-guard.sh"
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

echo "== ① 时钟：clk_en_ur0 有没有被认领 =="
run __R01__ 'mkdir -p /sys/kernel/debug'
run __R02__ 'mount -t debugfs none /sys/kernel/debug'
run __R03__ 'ls /sys/kernel/debug/clk'
run __R04__ 'grep ur0 /sys/kernel/debug/clk/clk_summary'
run __R05__ 'grep -i etn /sys/kernel/debug/clk/clk_summary'

echo "== ② 中断：uart0 有没有真中断（看 chip 是不是 realtek-irq-mux）=="
run __R06__ 'cat /proc/interrupts'

echo "== ③ GMAC：撤总闸之后还通不通 + IRQ 14 到底是哪个 hwirq =="
run __R07__ 'ifconfig eth0 192.168.1.100'
run __R08__ 'ifconfig eth0'
run __R09__ 'ping -c 3 -W 2 192.168.1.254' 30
run __R10__ 'cat /proc/interrupts'
run __R11__ 'arp'
# /proc/net/arp 是更硬的证据：不依赖 applet 有没有被 symlink 出来
# （02-initramfs.sh 的 applet 白名单里就没有 arp；板上能用是因为 init 里那句
#   `busybox --install -s /bin` 会在运行时把【编译进去的】applet 全链一遍，
#   Alpine 的 busybox.static 确实带 arp。两条都打，互为备份。）
run __R12__ 'cat /proc/net/arp'
run __R13__ 'echo __R_DONE__'

echo
echo "======== 本次新增串口输出 ========"
NEW="$(tail -c +$((MARK + 1)) "$LOG" | tr -d '\000')"
printf '%s\n' "$NEW" | tee "$OUT"

echo
echo "======== 自动体检 ========"
n_overrun=$(printf '%s\n' "$NEW" | grep -ac 'input overrun' || true)
n_mux=$(printf '%s\n' "$NEW" | grep -ac 'realtek-irq-mux' || true)
n_ur0=$(printf '%s\n' "$NEW" | grep -ac 'clk_en_ur0' || true)
n_ping_ok=$(printf '%s\n' "$NEW" | grep -ac '0% packet loss' || true)
n_done=$(printf '%s\n' "$NEW" | grep -ac '__R_DONE__' || true)

printf '  input overrun 出现次数 : %s   （★ 期望 0；>0 说明串口还在丢字节）\n' "$n_overrun"
printf '  realtek-irq-mux 出现   : %s   （★ 期望 ≥1；0 说明 uart0 还是轮询）\n' "$n_mux"
printf '  clk_en_ur0 出现        : %s   （★ 期望 ≥1）\n' "$n_ur0"
printf '  ping 0%% packet loss    : %s   （★ 期望 ≥1）\n' "$n_ping_ok"
printf '  __R_DONE__ 哨兵收到     : %s   （★ 期望 ≥1；0 说明脚本没跑完）\n' "$n_done"

echo
echo "  手工确认三处："
echo "   1) clk_summary 里 clk_en_ur0 行：rate 应 = 27000000，enable_cnt 应 ≥ 1"
echo "   2) /proc/interrupts 里应有一条 ttyS0，chip 列 = realtek-irq-mux"
echo "   3) /proc/interrupts 里 eth0 行应是 GICv2 54 Level（virq 号动态变化，14/17 都见过，只看 hwirq=54）"
echo
echo "  详细日志已存: $OUT"
echo "  完整启动日志: $S0/session02.log（含 u-boot 到 shell 的全过程）"
