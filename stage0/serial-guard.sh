#!/bin/bash
# serial-guard.sh —— 串口独占守卫（被 source，不单独执行）
#
# 2026-10-04 血泪教训：
#   手动开的 `screen /dev/ttyUSB0 115200` 会和 serial_agent 同时 read() 同一个
#   串口 tty。两个读者**不是各拿一份拷贝，而是瓜分字节流** —— 板子明明在大量
#   输出，采集代理侧却只收到零星碎片。症状极具迷惑性：
#     * u-boot 阶段：整段 "Filename / Loading / done / Bytes transferred" 消失，
#       只零星蹦出 "hex)" 之类残片；
#     * Linux 阶段：shell 提示符出来了、命令也被回显，但**就是不执行、无输出**
#       （因为回显凑巧被代理抢到，而真正执行后的输出被 screen 抢走了）。
#   看起来像"串口时钟又被 gate 了"或"板子挂了"，**实则跟板子毫无关系**。
#   本轮就是被这条坑掉了一个多小时：一度怀疑是撤 clk_ignore_unused 撤坏了。
#
# 排查手法（一句顶用）：遍历 /proc/<pid>/fd，看谁还开着那个 tty。
#   例：
#     for p in $(ls /proc|grep -E '^[0-9]+$'); do \
#       ls -l /proc/$p/fd 2>/dev/null | grep -q ttyUSB0 && \
#       echo "$p $(cat /proc/$p/comm)"; done
#
# 用法：
#   source serial-guard.sh   # 或 . "$S0/serial-guard.sh"
#   serial_guard || die "..."
#   会话名默认 session02，可用环境变量 SERIAL_SESSION 覆盖。
#   返回 0 = 独占正常；1 = 有别的进程在抢（已打印进程清单）。

serial_guard() {
	local sess="${SERIAL_SESSION:-session02}"
	local agent_pid dev p holders
	# ★ 只看 comm 是 python* 的候选：`pgrep -f` 会把**调用者自己的命令行**也匹配上
	#   （比如一条 Bash 工具包装行里含 "serial_agent.py .*session02" 这段文字），
	#   于是 head -1 可能挑到那个 shell，接着把真代理当成"抢占者"误报。
	agent_pid=""
	for p in $(pgrep -f "serial_agent.py .*$sess" 2>/dev/null); do
		case "$(cat "/proc/$p/comm" 2>/dev/null)" in
			python*) agent_pid="$p"; break ;;
		esac
	done
	if [ -z "$agent_pid" ]; then
		echo "!! 没找到 serial_agent（会话=$sess）在跑" >&2
		return 1
	fi
	dev=$(tr '\0' ' ' < "/proc/$agent_pid/cmdline" 2>/dev/null \
		| grep -oE '/dev/tty[A-Za-z0-9]+' | head -1)
	[ -n "$dev" ] || return 0

	holders=""
	for p in $(ls /proc 2>/dev/null | grep -E '^[0-9]+$'); do
		[ "$p" = "$agent_pid" ] && continue
		if ls -l "/proc/$p/fd" 2>/dev/null | grep -q -- "$dev"; then
			holders="$holders $p/$(cat "/proc/$p/comm" 2>/dev/null)"
		fi
	done

	if [ -n "$holders" ]; then
		echo "!! 串口 $dev 除了采集代理，还有别的进程在读:$holders" >&2
		echo "   两个读者会【瓜分】字节流 -> 回显大面积丢失。" >&2
		echo "   这看着像板子挂了/串口时钟被 gate，其实与板子无关。" >&2
		echo "   先关掉它们（典型是手动开的 screen:  screen -S <pid> -X quit）再继续。" >&2
		return 1
	fi
	return 0
}
