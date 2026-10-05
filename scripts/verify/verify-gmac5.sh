#!/bin/bash
# verify-gmac5.sh —— 静态 IP + ping（短命令版，规避 UART overrun）
#
# 上一版失败原因（很值得记住）：
#   `ip addr add 192.168.1.100/24 dev eth0` 只到第 32 个字符就被截断了：
#       ip addr add 192.168.1.100/24 devecho __P2__
#                          ^^^^^^^^^^^^^^ 正好 32 字符
#   同一时刻板子在打 `ttyS ttyS0: 1 input overrun(s)` —— 8250 RX FIFO 溢出丢字节。
#   板子的串口没有流控（dw-apb-uart 且 console 禁用 DMA），灌太快就丢。
#
# 两个对策：
#   1) 命令尽量短 —— 改用 busybox `ifconfig eth0 192.168.1.100`（27 字符，
#      192.x 是 C 类地址，busybox 会自动给 /24 掩码），不用长长的 `ip addr add`。
#   2) 发命令前多留静默（3 秒），让板子把上一轮的输出吐干净。
set -uo pipefail

S0="$EVIDENCE_DIR/stage0"
CTL="$EVIDENCE_DIR/stage0/session02.ctl"
LOG="$EVIDENCE_DIR/stage0/session02.log"
MARKFILE=/tmp/.gmac_mark3

run() {
	local tag="$1" cmd="$2" wait="${3:-20}" i n
	echo "$(stat -c %s "$LOG")" > "$MARKFILE"
	printf 'echo %s\n' "$tag" >> "$CTL"
	sleep 3                       # ★ 比上一版更长的静默
	printf '%s\n' "$cmd" >> "$CTL"
	for i in $(seq 1 "$wait"); do
		sleep 1
		n=$(tail -c +$(( $(cat "$MARKFILE") + 1 )) "$LOG" | tr -d '\000' | grep -ac "$tag")
		[ "$n" -ge 2 ] && break
	done
	sleep 1
}

MARK=$(stat -c %s "$LOG")
run __Q1__ 'ifconfig eth0 192.168.1.100'
run __Q2__ 'ifconfig eth0'
run __Q3__ 'ping -c 3 -W 2 192.168.1.254' 30
run __Q4__ 'arp'
run __Q5__ 'echo __Q_DONE__'

echo
echo "======== 本次新增串口输出 ========"
tail -c +$((MARK + 1)) "$LOG" | tr -d '\000'
