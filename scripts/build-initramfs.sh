#!/bin/bash
# 02 —— 制作 initramfs.cpio.gz
#
# 为什么要用内核自带的 usr/gen_init_cpio，而不是 cpio 命令：
#   initramfs 里必须有 /dev/console 这个字符设备节点，否则内核在
#   console_on_rootfs() 里打不开它，进而 init 进程的 fd 0/1/2 是空的，
#   表现就是"内核日志出一半，然后 shell 完全没反应"——非常难查。
#   而 mknod 需要 root。
#   gen_init_cpio 支持 spec 文件里的 nod 指令，在打包阶段就能写出设备节点，
#   不需要 root，也不需要宿主上的设备节点存在。
#
# busybox 用 Alpine 的 busybox-static（aarch64 static-pie，1.37.0）。
# 注意：busybox.net 官方 binaries 目录里的 busybox-armv8l 是 32 位 ARM，
# arm64 内核跑不了（除非开 CONFIG_COMPAT），别用错。

HERE="$(cd "$(dirname "$0")" && pwd)"
set -e
cd "$HERE"
source "$HERE/lib/env.sh"
env_check

BB="$BUILD_DIR/bb/bin/busybox.static"
INIT="$BUILD_DIR/initramfs-root/init"
[ -f "$BB" ]   || die "缺少 busybox: $BB"
[ -f "$INIT" ] || die "缺少 init: $INIT"

echo "== 1/4 编译 gen_init_cpio（宿主机工具）=="
cc -O2 -o "$OUT/gen_init_cpio" "$KTREE/usr/gen_init_cpio.c"
echo "ok: $OUT/gen_init_cpio"

echo
echo "== 2/4 生成 cpio spec =="
SPEC="$OUT/cpio_list"
LIST="$OUT/applets.txt"

# busybox 把 applet 名放在 rodata 的字符串表里；静态二进制没法直接跑
# (aarch64)，所以用 strings 做交集，只给真实存在的 applet 建软链。
#
# 坑：strings 默认最小长度是 4，会把 "sh"/"ls"/"cat" 这类短名字全滤掉，
# 结果就是 initramfs 里连 /bin/sh 都没有。必须显式 -n 2。
strings -a -n 2 "$BB" | sort -u > "$OUT/bb.strings"

CANDIDATES="sh ash cat ls ll cp mv rm mkdir rmdir ln chmod chown chgrp echo printf mount umount \
dmesg ps top free df du id whoami uname uptime date sleep sync reboot poweroff halt kill killall \
clear vi less more head tail wc sort uniq tr cut sed grep egrep fgrep find xargs tar gzip gunzip zcat \
wget ping ifconfig ip route netstat nc telnet udhcpc mdev switch_root insmod lsmod rmmod modprobe depmod \
mknod stat readlink realpath dirname basename seq expr test true false yes hexdump xxd od strings \
tty stty blkid lsblk blockdev devmem nproc lscpu md5sum sha256sum base64 awk touch timeout taskset \
pwd env printenv cmp diff file which busybox init poweroff"

: > "$LIST"
for a in $CANDIDATES; do
	if grep -qx -- "$a" "$OUT/bb.strings"; then
		echo "$a" >> "$LIST"
	fi
done
echo "可用 applet 数：$(wc -l < "$LIST")  (候选 $(echo $CANDIDATES | wc -w))"
echo "抽样: $(head -20 "$LIST" | tr '\n' ' ')"

{
	echo "# ---- 目录 ----"
	for d in /bin /sbin /usr /usr/bin /usr/sbin /etc /proc /sys /dev /tmp /root /mnt /lib; do
		case "$d" in
			/tmp) echo "dir  $d 1777 0 0" ;;
			/proc|/sys) echo "dir  $d 0555 0 0" ;;
			/root) echo "dir  $d 0700 0 0" ;;
			*)     echo "dir  $d 0755 0 0" ;;
		esac
	done

	echo "# ---- init 与 busybox ----"
	# -t 固定时间戳，保证同样的输入得到字节级一致的 cpio（便于比对/复现）
	echo "file /init        $INIT 0755 0 0"
	echo "file /bin/busybox $BB  0755 0 0"

	# gpio-rtk —— nolibc 静态编译的 GPIO chardev 最小工具（盘位供电排查）
	#   用法: gpio-rtk info | set <off> <0|1> | pulse <off> <ms_low>
	if [ -f "$BOARD_DIR/tools/gpio-rtk" ]; then
		echo "file /bin/gpio-rtk $BOARD_DIR/tools/gpio-rtk 0755 0 0"
	fi

	echo "# ---- applet 软链 ----"
	while read -r a; do
		[ -n "$a" ] || continue
		[ "$a" = "busybox" ] && continue
		echo "slink /bin/$a busybox 0777 0 0"
	done < "$LIST"

	echo "# ---- 字符设备（无 root 也能建，这是用 gen_init_cpio 的主因）----"
	echo "nod /dev/console 0600 0 0 c 5 1"
	echo "nod /dev/tty     0666 0 0 c 5 0"
	echo "nod /dev/ttyS0   0660 0 0 c 4 64"
	echo "nod /dev/null    0666 0 0 c 1 3"
	echo "nod /dev/zero    0666 0 0 c 1 5"
	echo "nod /dev/random  0666 0 0 c 1 8"
	echo "nod /dev/urandom 0666 0 0 c 1 9"
	echo "nod /dev/mem     0640 0 0 c 1 1"
	echo "nod /dev/kmem    0640 0 0 c 1 2"
	echo "nod /dev/loop0   0660 0 0 b 7 0"
	echo "nod /dev/ram0    0600 0 0 b 1 0"
} > "$SPEC"

echo
echo "== 3/4 打包 cpio =="
"$OUT/gen_init_cpio" -t 0 "$SPEC" > "$OUT/initramfs.cpio"
ls -la "$OUT/initramfs.cpio"

echo
echo "== 4/4 gzip 压缩 =="
gzip -9 -n -c "$OUT/initramfs.cpio" > "$OUT/initramfs.cpio.gz"
ls -la "$OUT/initramfs.cpio.gz"

echo
echo "---- 包内容抽查 ----"
"$OUT/gen_init_cpio" "$SPEC" | cpio -tv 2>/dev/null | head -20
echo "..."
"$OUT/gen_init_cpio" "$SPEC" | cpio -tv 2>/dev/null | grep -E "dev/console|/init$|bin/sh|bin/busybox"
