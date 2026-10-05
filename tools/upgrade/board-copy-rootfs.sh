#!/bin/sh
# 把官方 fnOS 镜像里的新 rootfs 增量复制到 eMMC 上的 root-new 子卷。
# 在板子上以 root 运行：
#   bash /vol1/fnos-upgrade/board-copy-rootfs.sh     # 后台启动后立即返回
#
# 前置条件：
#   /mnt/newroot    = 官方镜像 loop 挂载（只读）
#   /mnt/emmc-top   = /dev/mmcblk0p2 subvolid=5，且以 compress=zstd 挂载
#                     （eMMC 分区只有 7G，不压缩装不下两份 rootfs）
#   /mnt/emmc-top/root-new 必须已是 btrfs 子卷（否则 rsync 会建普通目录）
#
# 设计要点：
#   * --delete-after：目标最终与源一致，脚本可反复重跑（幂等 / 断点续传）
#   * --checksum（-c）：**必须**。默认的大小+时间比较骗过我们一次——
#     上一轮复制中途板子被复位，留下了"大小和时间戳都对、内容是坏的"文件
#     （systemd 起不来：libaudit.so.1: invalid ELF header），
#     后续 rsync 全部跳过它们，最终比对还显示"0 差异"。
#     加 -c 后会逐个比内容，坏文件被重新传输。代价是每次都要读全量数据。
#   * --bwlimit=12M + nice 19：降低瞬时 I/O/CPU 压力
#   * 排除镜像自带的 fnOS 内核模块与源码头：本机跑的是自编译 6.6.54 全内置内核
set -eu

SRC=/mnt/newroot
DST=/mnt/emmc-top/root-new
LOG=/vol1/fnos-upgrade/board-copy-rootfs.log

if [ "${1:-}" != "--daemon" ]; then
	setsid /bin/sh "$0" --daemon >"$LOG" 2>&1 </dev/null &
	echo "已在后台启动复制，日志：$LOG"
	exit 0
fi

btrfs subvolume show "$DST" >/dev/null 2>&1 || {
	echo "错误：$DST 不是 btrfs 子卷，先创建：btrfs subvolume create $DST" >&2
	exit 1
}
mountpoint -q "$SRC" || { echo "错误：$SRC 未挂载" >&2; exit 1; }

exec nice -n 19 rsync -aHAXc --numeric-ids --delete-after --bwlimit=12M \
	--exclude='/usr/lib/modules/6.18.18.c944-trim' \
	--exclude='/usr/src/linux-headers-*' \
	-v --stats "$SRC/" "$DST/"
