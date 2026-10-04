#!/bin/bash
# 05 —— 部署 6.6 树（xpressreal-linux）的产物到 TFTP 根目录
#
# 与 03-deploy.sh（管 6.17 主线那套）的区别：
#   1. 内核文件叫 Image-6.6 / Image-6.6.uimage，**不覆盖** 6.17 的 Image/Image.uimage，
#      这样两套产物在 TFTP 根目录里共存，随时可以切回去对照。
#   2. 板级 DTB 叫 rtd1296-cm360.dtb（我们给 XpressReal 树写的那份）。
#   3. initramfs 直接复用 stage2 那份 —— cpio 是内核无关的，busybox 里带
#      ip / ifconfig / udhcpc / ping，正好够验 GMAC。
#
# 跑完在串口侧执行：./board.sh boot66
set -e
cd "$(dirname "$0")"
source ./env.sh

TFTPROOT="$SRC/stage1/tftproot"
[ -d "$TFTPROOT" ] || die "TFTP 根目录不存在: $TFTPROOT"

echo "== 检查产物 =="
for f in Image-6.6 rtd1296-cm360.dtb initramfs.cpio.gz; do
	[ -f "$OUT/$f" ] || die "缺少 $OUT/$f（先跑 04-build-66.sh）"
done
ls -la "$OUT/Image-6.6" "$OUT/rtd1296-cm360.dtb" "$OUT/initramfs.cpio.gz"

echo
echo "== 套 legacy uImage（load/entry = 0x03000000）=="
# 壳本体仍是裸 arm64 Image，u-boot 走原生 bootm legacy 路径
./mk-uimage.py "$OUT/Image-6.6" "$OUT/Image-6.6.uimage" 0x03000000

echo
echo "== 拷贝到 TFTP 根目录 =="
cp -v "$OUT/Image-6.6.uimage"  "$TFTPROOT/Image-6.6.uimage"
cp -v "$OUT/rtd1296-cm360.dtb" "$TFTPROOT/rtd1296-cm360.dtb"
cp -v "$OUT/initramfs.cpio.gz" "$TFTPROOT/initramfs.cpio.gz"

echo
echo "== 校验和 =="
( cd "$TFTPROOT" && md5sum Image-6.6.uimage rtd1296-cm360.dtb initramfs.cpio.gz \
	| tee "$OUT/MD5SUMS-6.6" )

cat <<'EOF'

============================================================
下一步：串口侧一条命令起板（脚本会自己 tftp + bootm）
============================================================

  cd /home/xiaoabiao/WorkBuddy/2026-10-03-23-33-10/rtd1296-fnnas/stage2
  ./board.sh boot66

它做的事（等价于手敲）：
  1) setenv ipaddr 192.168.1.100 ; setenv serverip 192.168.1.254
  2) tftp 0x02ffffc0 Image-6.6.uimage      # 04 字节头 -> 载荷落在 0x03000000
     tftp 0x01f00000 rtd1296-cm360.dtb
     tftp 0x02200000 initramfs.cpio.gz
  3) setenv bootargs 'console=ttyS0,115200 earlycon=uart8250,mmio32,0x98007800,115200,27000000
                      loglevel=8 ignore_loglevel keep_bootcon initrd=0x02200000,<size>'
  4) bootm 0x02ffffc0 - 0x01f00000          # ★ bootm，不是 booti

进到 initramfs shell 后验 GMAC：
  dmesg | grep -iE 'r8169|rtl8168|eth0|gmac'
  ip link
  ip link set eth0 up
  udhcpc -i eth0 -q -n        # 拿不到就用 ip addr add 192.168.1.100/24 dev eth0
EOF
