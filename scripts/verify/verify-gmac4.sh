#!/bin/bash
# verify-gmac4.sh —— 补最后一步：静态 IP + ping 宿主机（证明真能收发）
#
# 上一步已经拿到：
#   ip link set eth0 up → r8169 ... eth0: link up        （PHY 通了）
#   ip addr show eth0   → state UP, LOWER_UP             （载波在，LOWER_UP 很关键）
# 但这段实验网里没有 DHCP 服务器（udhcpc 广播 4 次 no lease），
# eth0 一直没有 IP，所以 ping 报 Network unreachable。
# 这里手工配一个 192.168.1.100/24（和 TFTP 服务器 192.168.1.254 同网段），
# 再 ping 它 —— 通了就等于「TX+RX 双向数据通路」全部验证完毕。
set -uo pipefail

S0="$EVIDENCE_DIR/stage0"
CTL="$EVIDENCE_DIR/stage0/session02.ctl"
LOG="$EVIDENCE_DIR/stage0/session02.log"
MARKFILE=/tmp/.gmac_mark2

run() {
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
	sleep 0.8
}

MARK=$(stat -c %s "$LOG")
run __P1__ 'ip addr add 192.168.1.100/24 dev eth0'
run __P2__ 'ip addr show eth0'
run __P3__ 'ping -c 3 -W 2 192.168.1.254' 25
run __P4__ 'arp' 15
run __P5__ 'echo __PINGDONE__'

echo
echo "======== 本次新增串口输出 ========"
tail -c +$((MARK + 1)) "$LOG" | tr -d '\000'
