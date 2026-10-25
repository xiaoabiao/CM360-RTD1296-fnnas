#!/bin/bash
# 临时：WSL 内准备 6.6.54 内核构建环境（apt 工具链 + 拉锁定 commit 的内核树）
# 运行方式（Windows 侧）：
#   wsl.exe -d Ubuntu-26.04 -u root -e bash /mnt/c/Users/xiaoa/CM360-RTD1296-fnnas/tools/.wsl-kernel-setup.sh
set -x
export DEBIAN_FRONTEND=noninteractive

apt-get update -qq || exit 10
apt-get install -y -qq \
	gcc-aarch64-linux-gnu flex bison libssl-dev libelf-dev bc \
	rsync git u-boot-tools device-tree-compiler python3 kmod cpio patch \
	|| exit 11

cd /mnt/c/Users/xiaoa/CM360-RTD1296-fnnas || exit 12
export KTREE=/root/cm360-build/kernel
export OUT=/root/cm360-build/out-gpu
export LOG_DIR=/root/cm360-build/logs
mkdir -p "$OUT" "$LOG_DIR"

./scripts/setup-deps.sh || exit 13
echo "=== SETUP OK ==="
aarch64-linux-gnu-gcc --version | head -1
git -C "$KTREE" log --oneline -1
