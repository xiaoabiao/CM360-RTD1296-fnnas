#!/bin/bash
# verify-gmac2.sh —— GMAC 终局验证（稳健版：发一条 → 等回显 → 再发下一条）
#
# 为什么不用 verify-gmac.sh 那种"定时灌命令"的做法：
#   实测板子的 UART 顶不住 —— 连续灌会出一堆
#     ttyS ttyS0: N input overrun(s)
#   命令行还会被截断黏在一起（`dmesg | grep -iE 'r8169|eth0|gmaecho ===GMAC-3-...`）。
#   所以改成：每条命令后跟一个唯一哨兵 `echo __Sn__`，
#   轮询日志直到**哨兵的回显**出现，才发下一条。彻底消除竞态。
set -uo pipefail

S0="$EVIDENCE_DIR/stage0"
CTL="$EVIDENCE_DIR/stage0/session02.ctl"
LOG="$EVIDENCE_DIR/stage0/session02.log"

step() {                       # step <唯一标签> <命令> [最长等秒]
	local tag="$1" cmd="$2" wait="${3:-20}" i
	echo "$(stat -c %s "$LOG")" > /tmp/.gmac_mark
	printf 'echo %s\n' "$tag" >> "$CTL"
	sleep 0.8
	printf '%s\n' "$cmd" >> "$CTL"
	for i in $(seq 1 "$wait"); do
		sleep 1
		# 哨兵回显出现（且日志里该标签出现 >=2 次：一次是命令本身回显，一次是执行结果）
		if tail -c +$(( $(cat /tmp/.gmac_mark) + 1 )) "$LOG" | tr -d '\000' \
			| grep -aq "$tag" && \
		   [ "$(tail -c +$(( $(cat /tmp/.gmac_mark) + 1 )) "$LOG" | tr -d '\000' | grep -ac "$tag")" -ge 2 ]; then
			break
		fi
	done
	sleep 0.6
}

MARK=$(stat -c %s "$LOG")
echo "log mark = $MARK"
echo "（每条命令都等哨兵回显，慢但不会串行）"

step __S1__ 'ip addr show eth0'
step __S2__ 'ip link set eth0 up'
step __S3__ 'ip link show eth0'
step __S4__ 'cat /sys/class/net/eth0/carrier; cat /sys/class/net/eth0/speed' 25
step __S5__ "dmesg | grep -iE 'r8169|eth0'" 25
step __S6__ 'udhcpc -i eth0 -n -t 4 -T 3' 40
step __S7__ 'ip addr show eth0'
step __S8__ 'ping -c 3 -W 2 192.168.1.254' 25
step __S9__ 'echo __ALLDONE__'

echo
echo "======== 本次新增串口输出 ========"
tail -c +$((MARK + 1)) "$LOG" | tr -d '\000'
