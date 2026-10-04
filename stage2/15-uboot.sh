#!/bin/bash
# 15-uboot.sh —— 与"当前 u-boot console 会话"交互（复用 stage0 的串口代理）
#
# 背景：板上测试过 u-boot 2015.07 有 `source - run script from memory`。
#       串口"主机→板子"方向单条 >32 字符会被截断，所以：
#         复杂逻辑 → 打成 .scr 走 TFTP；串口只敲三条短命令。
#
# 子命令：
#   catch [窗口秒]            满线 ESC 洪流抓 console（成功后板子停在 u-boot 提示符）
#   send  '<cmd>'             发一条命令（自动确保洪水已停）
#   mark                      记下当前日志字节位置（后续 new/tail 以此为起点）
#   new                       回显 mark 之后的全部新日志
#   wait  '<正则>' [秒]        等日志新内容里出现正则
#   run   <本地.cmd> [标记]    包成 .scr 放 TFTP 根 → setenv l / tftpboot $l x.scr / source $l → 等标记
#   flood <秒> [间隔ms]        手动开洪水（一般不用）
#   floodoff                  停洪水
set -uo pipefail
cd "$(dirname "$0")"
source ./env.sh

S0=$SRC/stage0
CTL="$S0/session02.ctl"
LOG="$S0/session02.log"
TFTPROOT="$SRC/stage1/tftproot"
MARK=/tmp/uboot.mark
LADDR=${LADDR:-0xa000000}
S2=$SRC/stage2

ens_flood_off() { printf '@flood:0\n' >> "$CTL"; sleep 1; }

cmd_catch() { "$S2/00-catch-uboot2.sh" "${1:-1800}"; }

cmd_send() {
	ens_flood_off
	printf '%s\n' "$1" >> "$CTL"
	echo "-> $1"
}

cmd_mark() { stat -c %s "$LOG" > "$MARK"; echo "mark = $(cat "$MARK")"; }

cmd_new() {
	[ -f "$MARK" ] || { echo "先跑 mark"; exit 1; }
	tail -c +$(( $(cat "$MARK") + 1 )) "$LOG" 2>/dev/null | tr -d '\000'
}

cmd_wait() {
	local pat="$1" secs="${2:-120}" i
	[ -f "$MARK" ] || stat -c %s "$LOG" > "$MARK"
	local start; start=$(cat "$MARK")
	for i in $(seq 1 "$secs"); do
		sleep 1
		if tail -c +$(( start + 1 )) "$LOG" 2>/dev/null | tr -d '\000' | grep -aqE "$pat"; then
			echo "OK: 命中 /$pat/（第 ${i}s）"
			return 0
		fi
	done
	echo "!! ${secs}s 内未命中 /$pat/"
	return 1
}

cmd_run() {
	local src="$1" tag="${2:-UB-SCRIPT-END}"
	local base scr
	base=$(basename "$src" .cmd)
	scr="$TFTPROOT/$base.scr"
	"$S2/mk-uboot-script.py" "$src" "$scr" "$base" || exit 1
	cmd_mark
	cmd_send "setenv l $LADDR"
	sleep 1
	cmd_send "tftpboot \$l $base.scr"
	sleep 3
	cmd_send "source \$l"
	sleep 1
	cmd_wait "$tag" "${3:-300}"
}

cmd_flood() { printf '@flood:%s/%s esc\n' "${1:-90}" "${2:-8}" >> "$CTL"; echo "洪水已开 ${1:-90}s"; }
cmd_floodoff() { ens_flood_off; echo "洪水已停"; }

case "${1:-}" in
	catch)  shift; cmd_catch "$@" ;;
	send)   shift; cmd_send "$@" ;;
	mark)   cmd_mark ;;
	new)    cmd_new ;;
	wait)   shift; cmd_wait "$@" ;;
	run)    shift; cmd_run "$@" ;;
	flood)  shift; cmd_flood "$@" ;;
	floodoff) cmd_floodoff ;;
	tail)   tail -c 3000 "$LOG" | tr -d '\000' ;;
	*) sed -n '2,25p' "$0"; exit 1 ;;
esac
