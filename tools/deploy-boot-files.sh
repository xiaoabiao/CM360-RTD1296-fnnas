#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════
# 把新的内核 uImage + 板级 DTB 部署到 eMMC p1（u-boot 的 bootcmd 从 mmc 0:1 读）
#
# 用法（在板子上以 root 运行）：
#   deploy-boot-files.sh /tmp/Image-6.6.uimage /tmp/rtd1296-cm360.dtb
#
# 行为：
#   1. 挂载 /dev/mmcblk0p1（没挂载时）；
#   2. 把现有 Image-6.6.uimage / rtd1296-cm360.dtb 备份为 *.bak（只备份一次，
#      避免连续部署把好的 .bak 覆盖掉）；
#   3. 安装新文件、sync、校验 md5、打印目录清单、卸载。
#
# 回滚（若新内核起不来、用串口/救援系统进去后）：
#   mount /dev/mmcblk0p1 /mnt && cp /mnt/Image-6.6.uimage.bak /mnt/Image-6.6.uimage \
#     && cp /mnt/rtd1296-cm360.dtb.bak /mnt/rtd1296-cm360.dtb && sync && umount /mnt
#
# ⚠ 本脚本不会重启；部署完由调用方决定何时 reboot。
# ═══════════════════════════════════════════════════════════════════════════
set -euo pipefail

IMG="${1:?用法: $0 <Image-6.6.uimage> <rtd1296-cm360.dtb>}"
DTB="${2:?用法: $0 <Image-6.6.uimage> <rtd1296-cm360.dtb>}"
BOOTDEV="${BOOTDEV:-/dev/mmcblk0p1}"
MNT="${MNT:-/mnt/bootp1}"

[ -f "$IMG" ] || { echo "找不到 $IMG" >&2; exit 1; }
[ -f "$DTB" ] || { echo "找不到 $DTB" >&2; exit 1; }
[ -b "$BOOTDEV" ] || { echo "$BOOTDEV 不是块设备" >&2; exit 1; }

grep -q "$MNT" /proc/mounts && { echo "$MNT 已被占用，先 umount" >&2; exit 1; }
mkdir -p "$MNT"
mount "$BOOTDEV" "$MNT"
trap 'umount "$MNT" 2>/dev/null || true' EXIT

for f in Image-6.6.uimage rtd1296-cm360.dtb; do
	if [ -f "$MNT/$f" ] && [ ! -f "$MNT/$f.bak" ]; then
		cp -f "$MNT/$f" "$MNT/$f.bak"
		echo "已备份 $f → $f.bak"
	fi
done

install -m 0644 "$IMG" "$MNT/Image-6.6.uimage"
install -m 0644 "$DTB" "$MNT/rtd1296-cm360.dtb"
sync

echo "── 部署结果 ───────────────────────────────────────────"
ls -l "$MNT"
echo "── md5 ───────────────────────────────────────────────"
md5sum "$MNT/Image-6.6.uimage" "$MNT/rtd1296-cm360.dtb"
echo "── 参考 md5（本仓库 artifacts/kernel-6.6.54，= 2026-10-26 USB/LED 修复版） ──"
echo "  Image-6.6.uimage : b9e217c7717a4e0ad1151256c5e0ce2a   # CONFIG_PHY_RTK_RTD_USB2/3PHY=y"
echo "  rtd1296-cm360.dtb: 333649683feee81ff999dde986a1e77f   # USB 3 控制器 + gpio-leds（高有效）"
echo "部署完成；reboot 后生效。"
