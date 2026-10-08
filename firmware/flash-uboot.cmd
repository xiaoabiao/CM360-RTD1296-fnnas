# ============================================================================
# CM360 一键刷机脚本（u-boot 版）
#
# 为什么用"三个裸镜像 + mmc write"而不是"往分区里放文件"：
#   这块板的 u-boot 是 BPI-W2 2015.07，有 ext4load/fatload/fatwrite，
#   但**没有 ext4write** —— 也就是说它能把 p1 里的文件读出来，却没法往里写文件。
#   所以整块刷入（裸镜像 + mmc write）才是 u-boot 下唯一可靠的通路。
#
# 三层与扇区边界（实测）：
#   L0 低区  LBA 0x00000 ~ 0x12FFF   38 MiB   hwsetting+bootcode+FSBL+BL31+u-boot+env
#   L1 p1    LBA 0x13000 ~ 0x92FFF   256 MiB  ext4（内核 uImage + DTB）
#   L2 p2    LBA 0x93000 ~ 末尾       ~7 GiB   btrfs（fnOS rootfs，子卷 root）
#   校验：低区末 = 0x13000（p1 起点），p1 末 = 0x93000（p2 起点），互不重叠。
#
# 用法（串口进 u-boot 提示符，逐段粘贴；或存盘后 `env import -t $loadaddr $filesize`）：
#   1. 主机跑 TFTP 并放好镜像（或把镜像放 FAT32 U 盘，见路线 B）
#   2. 改下面 srvip/boardip 两行
#   3. 从头执行到底，最后 boot
#
# 镜像体积建议：
#   low-region-38MiB.img   ~15 MB（可入库）
#   p1-256MiB.img          ~40 MB（gz 后；裸 256 MiB）
#   p2-7GiB.img            建议切成 ≤2 GiB 的分片（TFTP 与 FAT32 都有单文件尺寸限制）
#
# ⚠️ 低区写入 = 变砖风险最高的一步。写入前先 dump 并核对 md5；
#    供电必须稳；并确认 docs/04-recovery.md 的串口 ROM Monitor 路线可用。
# ============================================================================

# ---- 0. 参数 ----
setenv srvip   192.168.1.10
setenv boardip 192.168.1.50
setenv pkgdir  cm360
setenv loadaddr 0x02000000
setenv serverip ${srvip}
setenv ipaddr   ${boardip}
setenv autoload no

# ---- 1. 低区 38 MiB（0x13000 扇区 = 77824）----
echo "=== [1/3] 刷低区（hwsetting/bootcode/FSBL/BL31/u-boot/env）==="
tftpboot ${loadaddr} ${pkgdir}/low-region-38MiB.img
mmc dev 0
mmc write ${loadaddr} 0x0 0x13000

# ---- 2. p1 256 MiB（内核 + DTB）----
echo "=== [2/3] 刷 p1（内核 uImage + 板级 DTB）==="
tftpboot ${loadaddr} ${pkgdir}/p1-256MiB.img
mmc write ${loadaddr} 0x13000 0x80000

# ---- 3. p2 rootfs（分片，逐片追写）----
echo "=== [3/3] 刷 p2（fnOS rootfs，逐片）==="
setenv p2start 0x93000
# 第 1 片：2 GiB = 0x400000 扇区
tftpboot ${loadaddr} ${pkgdir}/p2-7GiB.img.part1
mmc write ${loadaddr} ${p2start} 0x400000
# 第 2 片：从第 1 片末尾继续（0x93000 + 0x400000 = 0x493000）
tftpboot ${loadaddr} ${pkgdir}/p2-7GiB.img.part2
mmc write ${loadaddr} 0x493000 0x400000
# 第 3 片（若需要）：
# tftpboot ${loadaddr} ${pkgdir}/p2-7GiB.img.part3
# mmc write ${loadaddr} 0x893000 0x400000

# ---- 4. 收尾 ----
echo "=== 校验分区表并启动 ==="
mmc part
boot

# ============================================================================
# 路线 B：没有网络时用 U 盘（FAT32）
#   usb start
#   fatload usb 0 ${loadaddr} cm360/low-region-38MiB.img
#   mmc write ${loadaddr} 0x0 0x13000
#   ...（其余同上，只是把 tftpboot 换成 fatload usb 0）
#
# 路线 C：只想换内核/DTB（不动低区与 rootfs）——最常用、风险最低
#   tftpboot ${loadaddr} ${pkgdir}/p1-256MiB.img     # 或在系统里 dd 到 /dev/mmcblk0p1
#   mmc write ${loadaddr} 0x13000 0x80000
#   （板上已有 p1 的 .bak 兜底：改动前先把 Image-6.6.uimage 备份成 .bak）
#
# 路线 D：系统能起来时，直接在板上写（不需要 u-boot）
#   dd if=low-region-38MiB.img of=/dev/mmcblk0 bs=512 count=77824 conv=fsync
#   dd if=p1-256MiB.img        of=/dev/mmcblk0p1                       conv=fsync
#   dd if=p2-7GiB.img          of=/dev/mmcblk0p2                       conv=fsync
# ============================================================================
