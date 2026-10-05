#!/bin/sh
# 切换 eMMC 上的 rootfs 子卷，可一键回滚。在板端以 root 运行：
#   bash board-switch-rootfs.sh switch     # 启用 root-new（当前 root 改名留档，不删除）
#   bash board-switch-rootfs.sh rollback   # 退回 1.1.31
# 切换后执行 reboot 生效（本机看门狗重启处理已修好，reboot 正常）。
#
# 原理：内核 cmdline 是 root=/dev/mmcblk0p2 rootfstype=btrfs rootflags=subvol=root，
# 按**名字**找子卷，所以只要把子卷改名成 root 即可，不需要动 u-boot。
# 内核/DTB 在 mmcblk0p1，与 rootfs 无关，换子卷不会换错内核。
set -eu

TOP=/mnt/emmc-top
CUR=$TOP/root
NEW=$TOP/root-new
BAK=$TOP/root-1.1.31
FAILED=$TOP/root-1.2.0302

need() {
	if ! btrfs subvolume show "$1" >/dev/null 2>&1; then
		echo "错误：$1 不是 btrfs 子卷" >&2
		exit 1
	fi
}

setdefault() {
	id=$(btrfs subvolume list "$TOP" | awk -v p="$1" '$NF == p { print $2 }')
	if [ -n "$id" ]; then
		btrfs subvolume set-default "$id" "$TOP"
		echo "默认子卷已指向 $1 (id $id)"
	else
		echo "警告：没找到子卷 $1，跳过 set-default" >&2
	fi
}

case "${1:-}" in
switch)
	need "$NEW"
	need "$CUR"
	if [ -e "$BAK" ]; then
		echo "错误：$BAK 已存在（可能已经切换过），先确认再处理" >&2
		exit 1
	fi
	mv "$CUR" "$BAK"
	mv "$NEW" "$CUR"
	setdefault root
	sync
	echo "已切换：新系统(fnOS 1.2.0302)成为 root，旧系统保留在 $BAK"
	echo "回滚命令： bash $0 rollback && reboot"
	;;
rollback)
	need "$BAK"
	if [ -e "$FAILED" ]; then
		echo "错误：$FAILED 已存在，先处理它" >&2
		exit 1
	fi
	mv "$CUR" "$FAILED"
	mv "$BAK" "$CUR"
	setdefault root
	sync
	echo "已回滚到 1.1.31，被替换下来的新系统留在 $FAILED"
	;;
*)
	echo "用法: $0 switch|rollback" >&2
	exit 1
	;;
esac
