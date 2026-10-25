#!/bin/bash
# apply-kernel-patches.sh —— 把 stage2/patches/*.patch 打到 6.6 内核树上（幂等）
#
# 背景：之前几轮（SATA / irq-mux / eth0）是直接改 ~/.cache/rtd1296/
#   xpressreal-linux 里的源码，改动只存在于那棵树里。eMMC 这一轮开始把
#   内核侧改动固化成补丁存进项目，免得树被重置/重拉后丢失。
#
# 幂等策略：
#   - 先 --dry-run 正向试；能打就真打；
#   - 正向打不上、但反向能打 → 说明已打过，跳过；
#   - 两者都不行 → 报错退出（树被别的改动污染了，需人工看）。
HERE="$(cd "$(dirname "$0")" && pwd)"
set -e
cd "$HERE"
source "$HERE/lib/env.sh"
PDIR="$PATCH_DIR"
PATCH="$(command -v patch || true)"

[ -d "$KTREE" ] || { echo "  ERROR: 6.6 树不存在: $KTREE" >&2; exit 1; }
[ -n "$PATCH" ]   || { echo "  ERROR: 找不到 patch 命令" >&2; exit 1; }
[ -d "$PDIR" ]    || { echo "  （无 patches 目录，跳过）"; exit 0; }

shopt -s nullglob
files=( "$PDIR"/*.patch )
if [ ${#files[@]} -eq 0 ]; then
	echo "  （patches 目录为空，跳过）"
	exit 0
fi

for p in "${files[@]}"; do
	name="$(basename "$p")"
	if patch -d "$KTREE" -p1 --dry-run --forward --silent \
			--no-backup-if-mismatch < "$p" >/dev/null 2>&1; then
		patch -d "$KTREE" -p1 --forward --silent \
			--no-backup-if-mismatch < "$p"
		echo "  [apply ] $name"
	elif patch -d "$KTREE" -p1 --dry-run --reverse --silent \
			--no-backup-if-mismatch < "$p" >/dev/null 2>&1; then
		echo "  [skip  ] $name（已应用过）"
	else
		echo "  [FAIL  ] $name —— 既不能正向应用也不能反向应用。" >&2
		echo "           请人工检查 $KTREE（可能有冲突改动）。" >&2
		# 0005 与 0006 都改了 rtk_fan.c 的同一段（仓库历史遗留重叠），
		# 0005 应用后 0006 必然冲突；GPU/内核实验时可显式忽略，
		# 官方构建仍应在默认（未设置该变量）下失败退出。
		if [ "${PATCH_IGNORE_FAIL:-0}" = "1" ]; then
			echo "  [IGNORE] 已设置 PATCH_IGNORE_FAIL=1，跳过该补丁继续" >&2
		else
			exit 1
		fi
	fi
done
