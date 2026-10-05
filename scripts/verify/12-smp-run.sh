#!/bin/bash
# 12-smp-run.sh —— SMP（多核）上板验证全链
#
# 与 11-emmc-run.sh 同一套骨架，只把最后一步体检换成 09-verify-smp.sh：
#   抓 u-boot console → boot66 → 等 initramfs shell → SMP 体检
#
# ★ 本轮改动【DTS + 内核】两处，都要重编：
#   1) DTS：四个 cpu 节点补 enable-method = "spin-table" + cpu-release-addr。
#      原厂写的是 "rtk-spin-table"，主线 dt_supported_cpu_ops[] 只认
#      "spin-table" / "psci"，匹配不上会 pr_warn("missing enable-method")。
#   2) 内核 arch/arm64/kernel/smp_spin_table.c（补丁 0003）：
#      cpu-release-addr = 0x9801aa44 落在 pinctrl@9801A000 寄存器区，
#      **不是内存**。上游按内存假设用 ioremap_cache + writeq_relaxed(8 字节)
#      去写它 → 总线挂死在 smp_prepare_cpus()。改成原厂做法：
#      ioremap() + writel_relaxed()（32 位设备写）。
#      症状：第一次上板日志停在 "Mountpoint-cache hash table entries" 之后，
#      本该出现的 "RCU Tasks: Setting shift to 0 ..." 不再打印。
#
# 用法：./12-smp-run.sh [守候窗口秒数]   默认 1800
set -uo pipefail

S2="$BOARD_DIR"
S0="$EVIDENCE_DIR/stage0"
cd "$BOARD_DIR" || exit 1
WINDOW=${1:-1800}
RUNLOG="$LOG_DIR/smp-run-$(date +%m%d-%H%M%S).log"

{
	echo "###### SMP 上板验证全链  开始 $(date '+%F %T') ######"
	echo
	echo "==== [1/4] 抓 u-boot console（满线 ESC 洪流） ===="
	./00-catch-uboot2.sh "$WINDOW"
	rc=$?
	if [ "$rc" -ne 0 ]; then
		echo
		echo "!! 抓 console 失败（退出码 $rc）："
		echo "   2 = 上电了但没进 console（板子自己启了 DSM）"
		echo "   3 = 窗口内没有上电动作"
		echo "   4 = 代理没加载 @flood（需重启代理）"
		echo "   5 = 被中断"
		echo "!! 中止，没有引导内核。"
		exit 2
	fi
	echo
	echo "==== [2/4] 引导 6.6 内核（legacy uImage + bootm） ===="
	./board.sh boot66
	echo
	echo "==== [3/4] 等 initramfs shell 就绪（提示符 '/ #'） ===="
	AGENT_LOG="$EVIDENCE_DIR/stage0/session02.log"
	CTL="$EVIDENCE_DIR/stage0/session02.ctl"
	shell_ok=0
	for i in $(seq 1 20); do
		mark=$(stat -c %s "$AGENT_LOG")
		printf '@raw:0d0a\n' >> "$CTL"
		sleep 2
		if tail -c +$((mark + 1)) "$AGENT_LOG" 2>/dev/null | grep -aq '/ #'; then
			echo "OK: initramfs shell 已就绪（第 $((i * 2)) s）"
			shell_ok=1
			break
		fi
	done
	if [ "$shell_ok" = 0 ]; then
		echo "!! 60s 内没看到 '/ #' 提示符 —— 后面体检命令可能会丢，先看日志"
	fi
	echo
	echo "==== [4/4] SMP 体检（只读） ===="
	./09-verify-smp.sh
	echo
	echo "###### 全部完成 $(date '+%F %T') ######"
} 2>&1 | tee "$RUNLOG"

echo
echo "完整日志: $RUNLOG"
