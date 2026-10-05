#!/bin/bash
# 09b —— eMMC 控制器 + CRT PLL 寄存器真值（devmem 只读）
#
# 目的：CCF 说 pll_emmc=189MHz、闸门已开，但驱动 wait_done 反复超时
#   （疑似 SDMMC_PLL_STATUS(0x55c) bit0=0）。要拿硬件真值判断：
#     * CRT 的 PLL_EMMC1(0x980001f0) bit1 是否 =1（PLL 复位释放/运行）
#     * PLL_EMMC4(0x980001fc) bit0 是否 =1（PLL 使能）
#     * 控制器 PLL_STATUS(0x9801255c) bit0 是否 =1（SDMMC 内部 PLL 锁定）
#     * CLKDIV/CLKSRC/CLKENA/CKGEN_CTL 是否被正确配置
#
# ★ 只读，绝不 devmem 写。串口纪律：单条 < 32 字符、无复合、等哨兵 ≥2 次。
set -uo pipefail

S0="$EVIDENCE_DIR/stage0"
CTL="$EVIDENCE_DIR/stage0/session02.ctl"
LOG="$EVIDENCE_DIR/stage0/session02.log"
MARKFILE=/tmp/.emmc_dm_mark
OUTFILE="$LOG_DIR/emmc-devmem.out"

. "$TOOLS_DIR/serial/serial-guard.sh"
serial_guard || { echo "!! 串口被占用（见上）。" >&2; exit 4; }

run() {
	local tag="$1" cmd="$2" wait="${3:-8}" i n
	echo "$(stat -c %s "$LOG")" > "$MARKFILE"
	printf 'echo %s\n' "$tag" >> "$CTL"
	sleep 1
	printf '%s\n' "$cmd" >> "$CTL"
	for i in $(seq 1 "$wait"); do
		sleep 1
		n=$(tail -c +$(( $(cat "$MARKFILE") + 1 )) "$LOG" | tr -d '\000' | grep -ac "$tag")
		[ "$n" -ge 2 ] && break
	done
	sleep 1
}

MARK=$(stat -c %s "$LOG")

echo "== devmem 是否存在 =="
run __D00__ 'which devmem'

echo "== CRT eMMC PLL（0x98000000 基）=="
run __D01__ 'devmem 0x980001f0'   # PLL_EMMC1: bit1=run, [7:3]=VP0, [12:8]=VP1
run __D02__ 'devmem 0x980001f4'   # PLL_EMMC2
run __D03__ 'devmem 0x980001f8'   # PLL_EMMC3: [25:16]=ssc_div_n / ldo
run __D04__ 'devmem 0x980001fc'   # PLL_EMMC4: bit0=enable

echo "== eMMC 控制器通用块（0x98012000 基）=="
run __D05__ 'devmem 0x98012000'   # CTRL
run __D06__ 'devmem 0x98012008'   # CLKDIV
run __D07__ 'devmem 0x9801200c'   # CLKSRC
run __D08__ 'devmem 0x98012010'   # CLKENA
run __D09__ 'devmem 0x98012018'   # CTYPE

echo "== Realtek wrapper =="
run __D10__ 'devmem 0x98012420'   # OTHER1
run __D11__ 'devmem 0x98012478'   # CKGEN_CTL
run __D12__ 'devmem 0x98012550'   # CMD_CTRL_SET
run __D13__ 'devmem 0x9801255c'   # PLL_STATUS

echo
echo "======== 本次新增串口输出 ========"
NEW="$(tail -c +$((MARK + 1 )) "$LOG" | tr -d '\000')"
printf '%s\n' "$NEW" | tee "$OUTFILE"
echo
echo "  完整: $OUTFILE"
