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
set -e
cd "$(dirname "$0")"
source ./env.sh

KTREE66=/home/xiaoabiao/.cache/rtd1296/xpressreal-linux
PDIR="$S2/patches"
PATCH="$(command -v patch || true)"

[ -d "$KTREE66" ] || { echo "  ERROR: 6.6 树不存在: $KTREE66" >&2; exit 1; }
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
	if patch -d "$KTREE66" -p1 --dry-run --forward --silent \
			--no-backup-if-mismatch < "$p" >/dev/null 2>&1; then
		patch -d "$KTREE66" -p1 --forward --silent \
			--no-backup-if-mismatch < "$p"
		echo "  [apply ] $name"
	elif patch -d "$KTREE66" -p1 --dry-run --reverse --silent \
			--no-backup-if-mismatch < "$p" >/dev/null 2>&1; then
		echo "  [skip  ] $name（已应用过）"
	else
		echo "  [FAIL  ] $name —— 既不能正向应用也不能反向应用。" >&2
		echo "           请人工检查 $KTREE66（可能有冲突改动）。" >&2
		exit 1
	fi
done
