#!/bin/bash
# 09 —— eMMC 时钟/闸门状态探针（板子已在 initramfs shell 时用）
#
# 背景（2026-10-05 第 2 次上板）：
#   驱动 probe 成功、bus_hz=189MHz（pll_emmc 生效）、IRQ 注册，
#   但 CMD0/CMD1 的 IRQ 恒为 0x0 → "Card stuck being busy" → 卡不枚举。
#   同时串口里看到 CCF 把 clk_en_emmc / clk_en_emmc_ip 标成
#   clk_regmap_gate_disable_unused（当"未使用"关掉），且驱动只用裸
#   clk_enable()/clk_disable()、没有 clk_prepare_enable()。
#   → 需要板上直接查 CCF 的 enable/prepare 计数与父链。
#
# ★ 只读。串口纪律：单条命令 < 32 字符、不用 ; | && 引号复合、等哨兵回显 ≥2 次。
set -uo pipefail

S0="$EVIDENCE_DIR/stage0"
CTL="$EVIDENCE_DIR/stage0/session02.ctl"
LOG="$EVIDENCE_DIR/stage0/session02.log"
MARKFILE=/tmp/.probe_emmc_clk_mark
OUTFILE="$LOG_DIR/probe-emmc-clk.out"

. "$TOOLS_DIR/serial/serial-guard.sh"
serial_guard || { echo "!! 串口被占用（见上）。" >&2; exit 4; }

run() {
	local tag="$1" cmd="$2" wait="${3:-15}" i n
	echo "$(stat -c %s "$LOG")" > "$MARKFILE"
	printf 'echo %s\n' "$tag" >> "$CTL"
	sleep 2
	printf '%s\n' "$cmd" >> "$CTL"
	for i in $(seq 1 "$wait"); do
		sleep 1
		n=$(tail -c +$(( $(cat "$MARKFILE") + 1 )) "$LOG" | tr -d '\000' | grep -ac "$tag")
		[ "$n" -ge 2 ] && break
	done
	sleep 1
}

MARK=$(stat -c %s "$LOG")

echo "== [1] debugfs 有没有挂、clk 目录在不在 =="
run __K01__ 'ls /sys/kernel/debug'
run __K02__ 'ls /sys/kernel/debug/clk'

echo "== [2] 若没挂，挂到 /dbg =="
run __K03__ 'mkdir /dbg'
run __K04__ 'mount -t debugfs none /dbg'
run __K05__ 'ls /dbg/clk'

echo "== [3] eMMC 相关时钟的 enable/prepare 计数与父链 =="
run __K06__ 'cat /dbg/clk/clk_summary' 25

echo
echo "======== 本次新增串口输出 ========"
NEW="$(tail -c +$((MARK + 1)) "$LOG" | tr -d '\000')"
printf '%s\n' "$NEW" | tee "$OUTFILE"

echo
echo "======== 自动摘要 ========"
printf '%s\n' "$NEW" | grep -ai 'emmc' | head -20 || true
echo
echo "  完整: $OUTFILE"
