#!/bin/bash
# 03 —— 把产物丢进 TFTP 根目录，并打印 u-boot 侧要敲的命令
#
# 走 TFTP 而不是 u 盘，原因很实际：
#   1. 数据通路已经双向验过了（tftp 下行 18.9 MiB/s，tftpput 回传 md5 对得上）
#   2. 迭代快 —— 改一行 DTS 重新加载只要几秒，不用拔插 U 盘
#   3. 不写 SPI / eMMC，板子刷坏了也能恢复
# U 盘可以作为兜底通道（u-boot 有 usb 命令），产物完全一样。

set -e
cd "$(dirname "$0")"
source ./env.sh
env_check

TFTPROOT="$SRC/stage1/tftproot"
[ -d "$TFTPROOT" ] || die "TFTP 根目录不存在: $TFTPROOT"

echo "== 检查产物 =="
for f in Image cm360.dtb initramfs.cpio.gz; do
	[ -f "$OUT/$f" ] || die "缺少 $OUT/$f（先跑 01-build.sh / 02-initramfs.sh）"
done
ls -la "$OUT/Image" "$OUT/cm360.dtb" "$OUT/initramfs.cpio.gz"

echo
echo "== 拷贝到 TFTP 根目录 =="
cp -v "$OUT/Image" "$OUT/cm360.dtb" "$OUT/initramfs.cpio.gz" "$TFTPROOT/"

echo
echo "== 校验和（板子上用 tftpput 回传比对）=="
( cd "$TFTPROOT" && md5sum Image cm360.dtb initramfs.cpio.gz | tee "$OUT/MD5SUMS" )

echo
echo "== TFTP 服务状态 =="
bash "$SRC/stage1/run-tftp.sh" --status 2>&1 | head -6

cat <<'EOF'

============================================================
接下来在串口那侧的 u-boot 提示符执行
（板子 IP 需要和 192.168.1.254/24 同网段）
============================================================

# --- 1. 网络（每次上电都要重来，u-boot 不保存）---
setenv ipaddr 192.168.1.100
setenv serverip 192.168.1.254
setenv netmask 255.255.255.0
ping 192.168.1.254

# --- 2. 加载三个文件 ---
# 内存布局（板子是 2 GiB，memory 节点从 0x1f000 起）：
#   0x03000000  Image            (48 MiB)
#   0x01f00000  cm360.dtb        (31 MiB)
#   0x08000000  initramfs.cpio.gz(128 MiB)
tftp 0x03000000 Image
tftp 0x01f00000 cm360.dtb
tftp 0x08000000 initramfs.cpio.gz

# --- 3. 设内核命令行 ---
# console/earlycon 都指向 0x98007800（vendor DTB 里就是它），115200
setenv bootargs 'console=ttyS0,115200 earlycon=uart8250,mmio32,0x98007800,115200 loglevel=8 keep_bootcon'
printenv bootargs

# --- 4. 启动 ---
# booti <kernel> <initrd> <fdt>
# initrd 不写大小，u-boot 用上一个 tftp 的 filesize，
# 所以 initramfs 必须是最后加载的那个文件。
booti 0x03000000 0x08000000 0x01f00000

============================================================
判读要点
============================================================
* earlycon 阶段就该出字。如果连 "Booting Linux on physical CPU 0x..." 都没有，
  说明卡在解压/重定位之前 —— 那就是 booti 的加载地址或 DTB 有问题，
  不是驱动问题。
* 出现 3 行 "missing enable-method property" 是【预期】的，
  cpu1..3 会被摘掉，只留单核。
* 走到 "Run /init as init process" 说明内核侧全通了。
* initramfs 里 /init 会打印 cpuinfo / meminfo / interrupts，
  然后给一个 busybox shell。

常见故障对照
------------------------------------------------------------
 现象                          | 最可能的原因
-------------------------------+----------------------------
 一个字符都不出                 | 加载地址不对 / DTB 没传对
 "Bad magic number"            | tftp 下来的不是 arm64 Image
 卡在 "Starting kernel ..."     | DTB 的 memory 节点覆盖了内核
                               | 自己的加载地址，或 GIC/uart 地址错
 出到一半停在 "Freeing unused"  | initramfs 不是 gzip cpio，
                               | 或 /init 不可执行
 无限重启                       | 看门狗（本 DTS 已 disabled）
EOF
