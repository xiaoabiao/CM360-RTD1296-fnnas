#!/bin/bash
# verify-gmac3.sh —— GMAC 终局验证（最终版）
#
# 两条铁律（都是实测踩出来的）：
#   1) 绝不用「定时灌命令」：板子 UART 顶不住，会 input overrun 并把命令行截断
#      → 换成「发一条 → 等哨兵回显 → 再发下一条」。
#   2) 绝不用带 `;`/`|`/引号的复合命令：一旦被截断就会留下未闭合的引号，
#      busybox shell 会停在 `>` 续行态，之后所有命令都被当续行吃掉
#      （上一版就是这么把自己玩死的，只能发 Ctrl-C 抢救）。
#      所以这里每条都是**单个简单命令**。
set -uo pipefail

S0="$EVIDENCE_DIR/stage0"
CTL="$EVIDENCE_DIR/stage0/session02.ctl"
LOG="$EVIDENCE_DIR/stage0/session02.log"
MARKFILE=/tmp/.gmac_mark

run() {                        # run <标签> <命令> [最长等秒]
	local tag="$1" cmd="$2" wait="${3:-20}" i n
	echo "$(stat -c %s "$LOG")" > "$MARKFILE"
	printf 'echo %s\n' "$tag" >> "$CTL"
	sleep 1
	printf '%s\n' "$cmd" >> "$CTL"
	for i in $(seq 1 "$wait"); do
		sleep 1
		n=$(tail -c +$(( $(cat "$MARKFILE") + 1 )) "$LOG" | tr -d '\000' | grep -ac "$tag")
		[ "$n" -ge 2 ] && break
	done
	echo "[$tag] 等了 ${i}s"
	sleep 0.8
}

MARK=$(stat -c %s "$LOG")
n=0
step() { n=$((n+1)); run "__G${n}__" "$1" "${2:-20}"; }

step 'ip addr show eth0'
step 'ip link set eth0 up'
step 'ip link show eth0'
step 'cat /sys/class/net/eth0/operstate'
step 'cat /sys/class/net/eth0/carrier'
step 'cat /sys/class/net/eth0/address'
step 'dmesg'
step 'udhcpc -i eth0 -n -t 4 -T 3' 45
step 'ip addr show eth0'
step 'ping -c 3 -W 2 192.168.1.254' 25
step 'echo __ALLDONE__'

echo
echo "======== 本次新增串口输出 ========"
tail -c +$((MARK + 1)) "$LOG" | tr -d '\000'
