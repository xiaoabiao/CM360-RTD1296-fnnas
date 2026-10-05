#!/bin/bash
# 13-prep-emmc.sh —— 生成 eMMC 布局产物（主机侧，不需要板子）
#
# 产物（都在 out/emmc/）：
#   mbr.bin    ← 512 字节 MBR 分区表（写 eMMC LBA 0）
#   p1.img     ← 256 MiB ext4 引导分区（内含 Image-6.6.uimage + rtd1296-cm360.dtb）
#   layout.txt ← 布局说明 + u-boot 侧可用的引导命令（供侦察/改 env 时直接抄）
#
# ---------------------------------------------------------------------------
# 布局（MBR / DOS）
#
#   LBA 0            MBR
#   LBA 2048         兜底裸内核 Image-6.6.uimage（ext4load 读不了 p1 时用 mmc read）
#   LBA 74880        兜底裸 DTB
#   LBA 77824        p1  ext4  256 MiB (524288 扇区)      → 结束 602112
#   LBA 602112       p2  btrfs 14665728 扇区 (≈6.99 GiB)  → 到盘尾留 1MiB
#
# ★ 为什么 p1 的 ext4 要"关掉 metadata_csum / 64bit"：
#   u-boot 是 2015.07，它的 ext4 驱动不认识 metadata_csum（2016+）和 64bit（2016+）。
#   一旦带上，`ext4load` 会直接报 "** Unrecognized filesystem type **" 之类的错。
#   实测（dumpe2fs）本脚本产出的特性集为：
#     has_journal ext_attr resize_inode dir_index filetype extent flex_bg
#     sparse_super large_file huge_file dir_nlink extra_isize
#   —— 全在 2015.07 的能力范围内。
#
# ★ 为什么 p2 要 ~7 GiB（而 fs 只占 2.19 GiB）：
#   原镜像的 extent 是**构建期压缩**的（du 表观 5.2G vs 实际 2.19GiB）。
#   `btrfs send` 流出的是**解压后**数据 —— 实测 5,374,418,972 B ≈ 5.0 GiB。
#   所以目标分区必须 ≥ 5.4 GiB 才装得下；给到 ~7 GiB 留余量。
#   （接收时挂 compress=zstd，落盘会重新压回 ~2.2 GiB，届时另有 ~4.5 GiB 可用。）
# ---------------------------------------------------------------------------
HERE="$(cd "$(dirname "$0")" && pwd)"
set -euo pipefail
cd "$HERE"
source "$HERE/lib/env.sh"
OUTE="$OUT/emmc"
mkdir -p "$OUTE"

EMMC_SECTORS=${EMMC_SECTORS:-15269888}     # /proc/partitions: 7634944 KiB → 15269888×512B
RAW_K_START=2048          # 兜底裸内核
RAW_K_SECS=0              # 运行时按实际字节数算
RAW_D_START=74880         # 兜底裸 DTB
RAW_D_SECS=0
P1_START=77824            # = 2048×38，1 MiB 对齐
P1_SECS=524288            # 256 MiB
P2_START=$((P1_START + P1_SECS))
P2_SECS=$((EMMC_SECTORS - P2_START - 2048))   # 到盘尾留 1 MiB
P2_END=$((P2_START + P2_SECS))

[ "$P2_END" -le "$EMMC_SECTORS" ] || die "布局越界：p2 结束 $P2_END > eMMC 总扇区 $EMMC_SECTORS"

UIMG="$OUT/Image-6.6.uimage"
DTB="$OUT/rtd1296-cm360.dtb"
[ -f "$UIMG" ] || die "缺少 $UIMG（先跑 04-build-66.sh / 05-deploy-66.sh）"
[ -f "$DTB"  ] || die "缺少 $DTB"

UIMG_BYTES=$(stat -c %s "$UIMG"); DTB_BYTES=$(stat -c %s "$DTB")
RAW_K_SECS=$(( (UIMG_BYTES + 511) / 512 ))
RAW_D_SECS=$(( (DTB_BYTES + 511) / 512 ))
[ $((RAW_K_START + RAW_K_SECS)) -lt "$RAW_D_START" ] || die "兜底裸内核会撞到裸 DTB"
[ $((RAW_D_START + RAW_D_SECS)) -lt "$P1_START" ]    || die "兜底裸 DTB 会撞到 p1"

echo "==== eMMC 布局 ===="
printf '  eMMC 总扇区 : %s (%s GiB)\n' "$EMMC_SECTORS" "$((EMMC_SECTORS*512/1073741824))"
printf '  裸内核  : LBA %-9s %-7s 扇区 = %s MiB (兜底 mmc read)\n' "$RAW_K_START" "$RAW_K_SECS" "$((RAW_K_SECS/2048))"
printf '  裸 DTB  : LBA %-9s %-7s 扇区\n' "$RAW_D_START" "$RAW_D_SECS"
printf '  p1 : LBA %-9s %-7s 扇区 = %s MiB   ext4 BOOT\n' "$P1_START" "$P1_SECS" "$((P1_SECS/2048))"
printf '  p2 : LBA %-9s %-7s 扇区 = %s MiB   btrfs rootfs\n' "$P2_START" "$P2_SECS" "$((P2_SECS/2048))"
echo

# ---------------------------------------------------------------- MBR
echo "==== [1/3] 生成 MBR ===="
/usr/bin/env python3 - "$OUTE/mbr.bin" "$P1_START" "$P1_SECS" "$P2_START" "$P2_SECS" <<'PY'
import struct, sys
path, p1s, p1n, p2s, p2n = sys.argv[1], *map(int, sys.argv[2:6])

def entry(boot, ptype, lba, nsec):
    e = bytearray(16)
    e[0] = boot
    e[1:4] = bytes([0xFE, 0xFF, 0xFF])   # start CHS：LBA-only 标记
    e[4] = ptype
    e[5:8] = bytes([0xFE, 0xFF, 0xFF])   # end CHS：同上
    e[8:12] = struct.pack('<I', lba)
    e[12:16] = struct.pack('<I', nsec)
    return bytes(e)

mbr = bytearray(512)
mbr[440:444] = b'\x12\x34\x56\x78'                  # 磁盘签名（非零，便于 PARTUUID）
mbr[446:462] = entry(0x80, 0x83, p1s, p1n)          # ★ p1 置可引导位
mbr[462:478] = entry(0x00, 0x83, p2s, p2n)
mbr[510:512] = b'\x55\xAA'
open(path, 'wb').write(bytes(mbr))
print(f"  mbr.bin 写好：p1 LBA{p1s}+{p1n}  p2 LBA{p2s}+{p2n}")
PY
ls -l "$OUTE/mbr.bin"

# ---------------------------------------------------------------- p1.img
echo
echo "==== [2/3] 生成 p1.img（256 MiB ext4，保守特性）===="
P1IMG="$OUTE/p1.img"
rm -f "$P1IMG"
truncate -s $((P1_SECS * 512)) "$P1IMG"
mke2fs -q -t ext4 -F -L BOOT -I 256 \
	-O ^metadata_csum,^64bit,^metadata_csum_seed,^large_dir,^ea_inode,^orphan_file \
	"$P1IMG"
echo "  特性集："
dumpe2fs -h "$P1IMG" 2>/dev/null | grep -i 'Filesystem features' | sed 's/^/    /'

echo "  写入内核与 DTB（debugfs，无需 root/挂载）..."
debugfs -w -R "write $UIMG /Image-6.6.uimage" "$P1IMG" >/dev/null 2>&1
debugfs -w -R "write $DTB  /rtd1296-cm360.dtb" "$P1IMG" >/dev/null 2>&1
e2fsck -fy "$P1IMG" >/dev/null 2>&1 || true
echo "  p1 根目录："
debugfs -R 'ls -l /' "$P1IMG" 2>/dev/null | sed 's/^/    /'
echo "  用量："
debugfs -R 'stats' "$P1IMG" 2>/dev/null | grep -iE 'Block count|Free blocks|Block size' | sed 's/^/    /'

# ---------------------------------------------------------------- 裸兜底 + layout.txt
echo
echo "==== [3/3] 兜底裸镜像 + 布局说明 layout.txt ===="
cp -f "$UIMG" "$OUTE/raw-kernel.bin"
cp -f "$DTB"  "$OUTE/raw-dtb.bin"
# ★ 补齐到扇区整数倍：板上回读校验要按扇区整段 md5，源文件不够长会比不上
truncate -s $((RAW_K_SECS * 512)) "$OUTE/raw-kernel.bin"
truncate -s $((RAW_D_SECS * 512)) "$OUTE/raw-dtb.bin"
cat > "$OUTE/layout.txt" <<EOF
# eMMC 布局（$(date '+%F %T') 生成）  eMMC 总扇区 $EMMC_SECTORS
# 键名保持无空格 ASCII，便于 awk '\$1=="key"{print \$3}'
raw_kernel LBA $RAW_K_START sectors $RAW_K_SECS bytes $UIMG_BYTES
raw_dtb    LBA $RAW_D_START sectors $RAW_D_SECS bytes $DTB_BYTES
p1         LBA $P1_START sectors $P1_SECS bytes $((P1_SECS*512)) label BOOT fstype ext4
p2         LBA $P2_START sectors $P2_SECS bytes $((P2_SECS*512)) label rootfs fstype btrfs
emmc_sectors $EMMC_SECTORS

# ---- u-boot 侧候选引导命令（侦察时逐条试，只读）----
# A) 走分区 + ext4load（首选）
mmc dev 0
mmc part
ext4ls  mmc 0:1 /
ext4load mmc 0:1 0x02ffffc0 Image-6.6.uimage
ext4load mmc 0:1 0x01f00000 rtd1296-cm360.dtb
# B) 走裸块 mmc read（ext4load 不行时用）
mmc read 0x02ffffc0 $RAW_K_START $RAW_K_SECS
mmc read 0x01f00000 $RAW_D_START $RAW_D_SECS
# 之后（bootm 前）设 bootargs：
#   setenv bootargs 'console=ttyS0,115200 earlycon=uart8250,mmio32,0x98007800,115200 loglevel=8 ignore_loglevel keep_bootcon root=/dev/mmcblk0p2 rw rootwait'
#   bootm 0x02ffffc0 - 0x01f00000
EOF
cat "$OUTE/layout.txt"

echo
echo "==== 产物 ===="
ls -l "$OUTE"
