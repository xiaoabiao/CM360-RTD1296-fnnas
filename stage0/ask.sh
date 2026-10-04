#!/bin/bash
# ask.sh —— 向板子串口送一条命令并抓回显（复用 set_ios 那套哨兵纪律）
# 用法: ./ask.sh <TAG> '<command>' [等待秒数]
# 说明: 先发 `echo TAG`，再发命令，等日志里 TAG 出现 >=2 次即认为输出齐了。
set -uo pipefail

S0=/home/xiaoabiao/WorkBuddy/2026-10-03-23-33-10/rtd1296-fnnas/stage0
CTL="$S0/session02.ctl"
LOG="$S0/session02.log"

TAG="${1:?用法: ask.sh TAG 'cmd' [wait]}"
CMD="${2:?}"
WAIT="${3:-10}"

. "$S0/serial-guard.sh"
serial_guard || { echo "!! 串口被占用（见上）。" >&2; exit 4; }

MARK=$(stat -c %s "$LOG")
printf 'echo %s\n' "$TAG" >> "$CTL"
sleep 1
printf '%s\n' "$CMD" >> "$CTL"
for i in $(seq 1 "$WAIT"); do
	sleep 1
	n=$(tail -c +$((MARK + 1)) "$LOG" | tr -d '\000' | grep -ac "$TAG")
	[ "$n" -ge 2 ] && break
done
sleep 1
tail -c +$((MARK + 1)) "$LOG" | tr -d '\000'
