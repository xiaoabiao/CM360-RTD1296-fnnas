#!/bin/bash
# 16-emmc-boot.sh —— eMMC 独立启动编排：抓 u-boot → 侦察 → 改 env → 启动
#
# 分步跑（省上电次数：catch 之后板子停在 u-boot 提示符，后续步骤共用同一会话，不用再上电）
#   ./16-emmc-boot.sh catch    [窗口秒]   # 抓 console（需要断电→上电配合）
#   ./16-emmc-boot.sh recon               # 跑 uboot/recon.cmd（只读侦察）
#   ./16-emmc-boot.sh install             # 跑 uboot/install.cmd（setenv + saveenv 写 SPI）
#   ./16-emmc-boot.sh boot                # run fnos_boot（直接从 eMMC 启动）
#   ./16-emmc-boot.sh tail                # 回显串口尾部
HERE="$(cd "$(dirname "$0")" && pwd)"
set -uo pipefail
cd "$HERE"
source "$HERE/../../scripts/lib/env.sh"
S2=$SCRIPTS_DIR
U="$TOOLS_DIR/uboot/uboot-console.sh"
MODE="${1:-recon}"
RUNLOG="$LOG_DIR/emmc-boot-$(date +%m%d-%H%M%S)-$MODE.log"

{
echo "###### eMMC 引导 / $MODE   开始 $(date '+%F %T') ######"
case "$MODE" in
	catch)
		echo "== 抓 u-boot console =="
		echo ">>> 请给板子断电，等 5 秒再上电 <<<"
		"$U" catch "${2:-1800}"
		;;
	recon)
		echo "== 只读侦察（recon.cmd）=="
		"$U" run "$BOARD_DIR/uboot-cmds/recon.cmd" UB-RECON-END 900
		echo
		echo "============ 侦察全文 ============"
		"$U" new
		;;
	install)
		echo "== 改 env + saveenv（install.cmd）=="
		"$U" run "$BOARD_DIR/uboot-cmds/install.cmd" UB-INSTALL-END 300
		echo
		echo "============ install 全文 ============"
		"$U" new
		;;
	boot)
		echo "== run fnos_boot（从 eMMC 启动）=="
		"$U" mark
		"$U" send 'run fnos_boot'
		"$U" wait 'Run /init as init process|fnnas login|Kernel panic|Wrong Image|Failed to mount|not found|Bad Data CRC' 240 || true
		echo
		echo "============ 启动输出 ============"
		"$U" new
		;;
	tail) "$U" tail ;;
	*)    sed -n '2,14p' "$0"; exit 1 ;;
esac
echo
echo "###### 完成 $(date '+%F %T') ######"
} 2>&1 | tee "$RUNLOG"
echo
echo "日志: $RUNLOG"
