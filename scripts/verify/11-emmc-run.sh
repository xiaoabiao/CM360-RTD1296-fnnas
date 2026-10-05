#!/bin/bash
# 11-emmc-run.sh —— 一条命令跑完 eMMC 上板验证全链
#
# 链路：满线 ESC 洪流抓 console  →  引导 6.6 内核（boot66）  →  eMMC 体检
#
# 用户只需要做一件事：**断电，等 5 秒，上电**。
# 其余（抢 console / tftp / bootm / 等 initramfs / 发体检命令）全自动。
#
# 前置条件（都在 05-deploy-66.sh 与 08-verify-emmc.sh 里自检）：
#   * serial_agent.py 常驻在跑，且只有它一个读者
#   * TFTP 服务在 192.168.1.254:69 上、根目录是 stage1/tftproot
#   * tftproot 里有 Image-6.6.uimage / rtd1296-cm360.dtb / initramfs.cpio.gz
#
# 用法：./11-emmc-run.sh [守候窗口秒数]   默认 1800
# 日志：stage2/logs/emmc-run-<日期时间>.log（同时回显）
set -uo pipefail

S2="$BOARD_DIR"
S0="$EVIDENCE_DIR/stage0"
cd "$BOARD_DIR" || exit 1
WINDOW=${1:-1800}
RUNLOG="$LOG_DIR/emmc-run-$(date +%m%d-%H%M%S).log"

{
	echo "###### eMMC 上板验证全链  开始 $(date '+%F %T') ######"
	echo
	echo "==== [1/3] 抓 u-boot console（满线 ESC 洪流） ===="
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
	echo "==== [2/3] 引导 6.6 内核（legacy uImage + bootm） ===="
	./board.sh boot66
	echo
	echo "==== [2.5/3] 等 initramfs shell 就绪（提示符 '/ #'） ===="
	# boot66 只等到 'Run /init as init process'；/init 落成 shell 还要几秒。
	# 这里主动发 CR 把提示符逼出来（对正在启动的内核无害），最多等 60s。
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
	echo "==== [3/4] eMMC 体检（只读） ===="
	./08-verify-emmc.sh
	echo
	echo "==== [4/4] eMMC 健康度补验（life_time / pre_eol_info，只读） ===="
	./08b-emmc-health.sh
	echo
	echo "###### 全部完成 $(date '+%F %T') ######"
} 2>&1 | tee "$RUNLOG"

echo
echo "完整日志: $RUNLOG"
