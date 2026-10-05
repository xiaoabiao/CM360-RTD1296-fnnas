#!/bin/sh
# 复制完成后，对 /mnt/emmc-top/root-new 做"本机适配"——替换 rootfs 前的最后一步。
# 在板子上以 root 运行：
#   bash /vol1/fnos-upgrade/board-adapt-newroot.sh
#
# 为什么必须做适配（都是实测踩出来的）
# -----------------------------------
# 1) fstab：官方镜像的 /etc/fstab 写的是**镜像自己的 UUID**（root 与 /boot 各一条），
#    在本机上根本不存在。当前 1.1.31 的 fstab 只有 tmpfs 一行、靠内核 cmdline 的
#    root=/dev/mmcblk0p2 rootflags=subvol=root 起家，一直正常 —— 沿用这套最小配置。
# 2) 内核模块：镜像自带 fnOS 内核（6.18.18-trim），本机跑的是自编译 6.6.54 全内置内核。
#    全内置 = 板上没有 /lib/modules/<版本>/ 的 .ko，而 fnOS 大量脚本用 modprobe 探测模块，
#    所以必须补上 modules.builtin* 并在板上 depmod 生成索引，否则 zram/ovs 等服务起不来。
# 3) modules-load.d：镜像要加载 zfs / nft_fullcone / msr 三个本机内核里不存在的模块，
#    每次开机都会刷 modprobe 报错，直接去掉。
# 4) kernel_version_output：fnOS 运行时读的内核/平台标识文件（镜像里没有）。
set -eu

TOP=/mnt/emmc-top
NEW=$TOP/root-new
KREL=$(uname -r)

[ -d "$NEW" ] || { echo "错误：$NEW 不存在" >&2; exit 1; }

# rsync 还在跑的话，下面的改动会被下一次同步覆盖掉
if pgrep -f "[r]sync -aHAX" >/dev/null; then
	echo "错误：rsync 仍在运行，等它跑完再执行本脚本" >&2
	exit 1
fi

echo "=== 1) 改写 $NEW/etc/fstab（最小可用配置）==="
# 根文件系统由内核 cmdline 提供，但**压缩必须写在 / 这一行**：
# btrfs 的 compress= 只在"挂上去的那一次"生效，对已挂载过的 fs 再 mount 会被忽略，
# 而 eMMC 只有 7G，不压缩早晚写满（实测 40MB 文本压缩后只占 1.4MB）。
P2UUID=$(blkid -s UUID -o value /dev/mmcblk0p2)
cat >"$NEW/etc/fstab" <<EOF
# /etc/fstab: static file system information.
#
# 本板由内核 cmdline 提供根文件系统：
#   root=/dev/mmcblk0p2 rootfstype=btrfs rootflags=subvol=root
# 内核与 DTB 放在 mmcblk0p1，由 u-boot 直接读取（rootfs 里的 /boot 是空的），
# 所以不需要单独的 /boot 条目。
#
# <file system> <mount point>   <type>  <options>       <dump>  <pass>
UUID=$P2UUID				/	btrfs	defaults,noatime,compress=zstd	0	1
tmpfs					/tmp	tmpfs	defaults,nosuid			0	0

# ↓ 升级期间临时挂载：eMMC 顶层子卷，便于回滚/维护。升级收尾后可以删掉这一行。
#   （这里写 compress 没用 —— 同一个 fs 已被 / 挂上了，btrfs 会忽略这个选项）
/dev/mmcblk0p2  /mnt/emmc-top  btrfs  subvolid=5,noatime,nofail  0 0
EOF
cat "$NEW/etc/fstab"

echo
echo "=== 2) 清掉镜像自带的 fnOS 内核模块与源码头 ==="
rm -rf "$NEW/usr/lib/modules/6.18.18.c944-trim" \
       "$NEW/usr/src/linux-headers-6.18.18.c944-trim"
ls "$NEW/usr/lib/modules/" "$NEW/usr/src/" 2>/dev/null

echo
echo "=== 3) 装入本机内核($KREL)的模块元数据 ==="
mkdir -p "$NEW/usr/lib/modules/$KREL"
cp -a "/usr/lib/modules/$KREL/." "$NEW/usr/lib/modules/$KREL/"
rm -rf "$NEW/usr/lib/modules/$KREL/build" "$NEW/usr/lib/modules/$KREL/source"
depmod -b "$NEW" "$KREL" && echo "depmod 完成"
ls "$NEW/usr/lib/modules/$KREL/"

echo
echo "=== 4) 清掉 modules-load.d 里本机不存在的模块 ==="
rm -f "$NEW/etc/modules-load.d/trim-zfs.conf" \
      "$NEW/etc/modules-load.d/trim-fullconenat-nft.conf"
sed -i '/^msr$/d' "$NEW/etc/modules-load.d/modules.conf"
for f in "$NEW"/etc/modules-load.d/*; do echo ">>> $f"; cat "$f"; done

echo
echo "=== 5) 写 kernel_version_output ==="
mkdir -p "$NEW/var/tmp"
printf "kernel_version='%s'\nplatform_name='rockchip'\n" "$KREL" >"$NEW/var/tmp/kernel_version_output"
cat "$NEW/var/tmp/kernel_version_output"

echo
echo "=== 适配完成，检查一下体积 ==="
du -sh --one-file-system "$NEW"
btrfs filesystem usage "$TOP" | head -4
df -h "$TOP" | tail -1
