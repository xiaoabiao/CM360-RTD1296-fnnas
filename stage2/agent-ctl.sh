#!/bin/bash
# agent-ctl.sh —— 停/起串口采集代理（恢复脚本要独占 /dev/ttyUSB0）
#
# ★ 不用 pkill -f：那种写法会把"调用者自己的命令行"也匹配上，可能误杀当前 shell。
#   这里照抄 serial-guard 的做法：遍历 /proc，只认 comm 是 python* 且 cmdline 含
#   serial_agent.py + 会话名的进程。
set -uo pipefail
S0=/home/xiaoabiao/WorkBuddy/2026-10-03-23-33-10/rtd1296-fnnas/stage0
SESS="${SERIAL_SESSION:-session02}"
AGENTLOG="$S0/agent3.out"

find_agent() {
	local p
	for p in $(pgrep -f "serial_agent.py .*$SESS" 2>/dev/null); do
		case "$(cat "/proc/$p/comm" 2>/dev/null)" in
			python*) echo "$p"; return 0 ;;
		esac
	done
	return 1
}

case "${1:-}" in
	stop|status)
		pid=$(find_agent) || { echo "代理未在运行"; [ "$1" = status ] && exit 1 || exit 0; }
		if [ "$1" = status ]; then echo "代理 PID=$pid"; exit 0; fi
		echo "停代理 PID=$pid"
		kill -TERM "$pid" 2>/dev/null
		for i in 1 2 3 4 5 6 7 8 9 10; do
			kill -0 "$pid" 2>/dev/null || break
			sleep 0.5
		done
		kill -0 "$pid" 2>/dev/null && { echo "  还在，SIGKILL"; kill -KILL "$pid"; sleep 1; }
		echo "  已停"
		# 确认没人再占串口
		sleep 0.5
		if ls -l /proc/*/fd 2>/dev/null | grep -q ttyUSB0; then
			echo "  !! 还有进程占着 ttyUSB0："
			for p in $(ls /proc 2>/dev/null | grep -E '^[0-9]+$'); do
				ls -l "/proc/$p/fd" 2>/dev/null | grep -q ttyUSB0 && echo "    $p $(cat /proc/$p/comm 2>/dev/null)"
			done
		else
			echo "  串口已空闲"
		fi
		;;
	start)
		if find_agent >/dev/null; then echo "代理已在运行，不重复起"; exit 0; fi
		cd "$S0" || exit 1
		setsid nohup python3 serial_agent.py -d /dev/ttyUSB0 -b 115200 \
			-o "$SESS" --gap 0.6 --append >> "$AGENTLOG" 2>&1 &
		sleep 2
		pid=$(find_agent) && echo "已起代理 PID=$pid" || echo "!! 起失败，看 $AGENTLOG"
		;;
	*) sed -n '2,6p' "$0"; exit 1 ;;
esac
