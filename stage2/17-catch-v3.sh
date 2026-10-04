#!/bin/bash
# 17-catch-v3.sh —— 抓 u-boot v3：**洪流只在上电后短窗口内开**
#
# 为什么要改（06:32 这次踩的坑）：
#   v2（00-catch-uboot2.sh）是"从开头就一直灌 ESC"，直到抓到 'Enter console mode' 才停。
#   06:32 这次上电后，FSBL/bootcode 打印到 `switch bus width ... success` 读完 hwsetting
#   就**重启循环并卡死**（串口此后彻底静默、无 IP）。
#   对比 05:48（擦 eMMC 之前、同一套 v2 洪流）那次：FSBL 一路走完 → u-boot → 进 console。
#   所以要么是洪流长时间占线把 bootcode 带歪，要么是 eMMC 低区被我们改动了。
#   本脚本把洪流限制在"上电后 ~4 秒"（ESC 检测窗口在 FSBL 开始后约 0.9 秒），
#   命中就进 console；没命中也能留下干净启动日志用于诊断。
#
# 用法：./17-catch-v3.sh [窗口秒] [洪流持续秒]
# 退出码：0 抓到 console；2 上电了但没进 console（洪流窗口已过，归因看日志）；3 窗口内没上电
set -uo pipefail
S0=/home/xiaoabiao/WorkBuddy/2026-10-03-23-33-10/rtd1296-fnnas/stage0
S2=/home/xiaoabiao/WorkBuddy/2026-10-03-23-33-10/rtd1296-fnnas/stage2
CTL="$S0/session02.ctl"
LOG="$S0/session02.log"
OUT="$S2/out/catch-v3.txt"
WINDOW=${1:-900}
FLOODAFTER=${2:-4}       # 从"看到第一个启动字节"起，洪流再持续几秒

. "$S0/serial-guard.sh"
serial_guard || { echo "!! 串口被占用（见上）。" >&2; exit 4; }
mkdir -p "$S2/out"

start=$(stat -c %s "$LOG")
say() { echo "[$(date +%H:%M:%S)] $*"; }
newbytes() { tail -c +$((start + 1)) "$LOG" 2>/dev/null; }

say "窗口 ${WINDOW}s；洪流将开在上电后 ${FLOODAFTER}s 内"
amark=$(stat -c %s "$S0/agent3.out" 2>/dev/null || echo 0)
printf '@flood:30/8 esc\n' >> "$CTL"
sleep 1.2
if ! tail -c +$((amark + 1)) "$S0/agent3.out" 2>/dev/null | grep -qa '开始洪流'; then
	echo "!! 代理没响应 @flood（跑的是旧代码？）" >&2; exit 4
fi
say "★ 洪流已就绪。>>> 请给板子断电，等 5 秒再上电 <<<"

trap 'printf "@flood:0\n" >> "$CTL"; echo "[$(date +%H:%M:%S)] !! 被中断，已停洪流" ; exit 5' INT TERM

deadline=$(( SECONDS + WINDOW ))
bootseen=""          # 首次看到启动输出的 SECONDS
floodoff=0           # 洪流是否已停
found=0; missed=0
while [ $SECONDS -lt $deadline ]; do
	chunk=$(newbytes)
	if [ -n "$chunk" ]; then
		if [ -z "$bootseen" ] && printf '%s' "$chunk" | grep -qa 'FSBL\|U-Boot 2015\|Goto FSBL'; then
			bootseen=$SECONDS
			say "看到启动输出（第 $SECONDS s），洪流再续 ${FLOODAFTER}s"
		fi
		if printf '%s' "$chunk" | grep -qa 'Enter console mode'; then
			found=1; break
		fi
		if [ -n "$bootseen" ] && printf '%s' "$chunk" | grep -qa 'login:'; then
			missed=1; break
		fi
	fi
	# 洪流窗口到点就停（不管有没有抓到），让后续日志干净
	if [ "$floodoff" = 0 ] && [ -n "$bootseen" ] && [ $(( SECONDS - bootseen )) -ge "$FLOODAFTER" ]; then
		printf '@flood:0\n' >> "$CTL"
		floodoff=1
		say "洪流窗口已到，停洪流（继续观察启动日志）"
	fi
	[ "$floodoff" = 1 ] && sleep 1 || sleep 0.3
done
trap - INT TERM
printf '@flood:0\n' >> "$CTL"
sleep 2
tail -c +$((start + 1)) "$LOG" > "$OUT" 2>/dev/null || true

if [ "$found" = 1 ]; then
	say "★ 进 console 了 —— 已停洪流"
else
	if [ -n "$bootseen" ]; then
		say "这次上电没进 console（洪流窗口已过）；完整启动日志在 $OUT"
		exit 2
	fi
	say "窗口内没有上电动作"
	exit 3
fi

# 逼提示符
mark=$(stat -c %s "$LOG")
ok=0
for i in 1 2 3 4 5 6 7 8; do
	printf '@raw:03\n'   >> "$CTL"; sleep 1.2
	printf '@raw:0d0a\n' >> "$CTL"; sleep 1.5
	if tail -c +$((mark + 1)) "$LOG" 2>/dev/null | grep -aq 'CM360_DS218>'; then ok=1; break; fi
done
[ "$ok" = 1 ] && say "提示符已确认（第 $i 轮）" || say "!! 没逼出提示符，自己看日志"
tail -c +$((start + 1)) "$LOG" > "$OUT" 2>/dev/null || true
say "日志已存 $OUT"
exit 0
