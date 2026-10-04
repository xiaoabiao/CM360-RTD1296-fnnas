#!/bin/bash
# emmc-part.sh —— 板上执行（root）。抹 eMMC 头尾 → 写 MBR → 写兜底裸内核/DTB → 写 p1
#
# 依赖 /tmp 下已就位（由主机侧 14-emmc-write.sh 推入）：
#   emmc-mbr.bin  emmc-rawk.bin  emmc-rawd.bin  emmc-p1.img  emmc-layout.txt
set -euo pipefail

EMMC=${EMMC:-/dev/mmcblk0}
T=/tmp
L=$T/emmc-layout.txt
say() { echo "[part] $*"; }

[ -b "$EMMC" ] || { echo "!! $EMMC 不是块设备"; exit 1; }
for f in emmc-mbr.bin emmc-rawk.bin emmc-rawd.bin emmc-p1.img emmc-layout.txt; do
	[ -f "$T/$f" ] || { echo "!! 缺少 $T/$f"; exit 1; }
done

val() { awk -v k="$1" -v f="$2" '$1==k{for(i=1;i<=NF;i++) if($i==f) print $(i+1)}' "$L"; }
RK=$(val raw_kernel LBA); RKS=$(val raw_kernel sectors)
RD=$(val raw_dtb LBA);    RDS=$(val raw_dtb sectors)
P1=$(val p1 LBA);         P1S=$(val p1 sectors)
P2=$(val p2 LBA);         P2S=$(val p2 sectors)

say "布局：rawk@$RK($RKS)  rawd@$RD($RDS)  p1@$P1($P1S)  p2@$P2($P2S)"

# 按 LBA 写：偏移是 1MiB 整数倍就用 bs=1M（快得多），否则退回 bs=512
ddat() { # $1=源文件  $2=LBA
	local src="$1" off=$(( $2 * 512 ))
	if [ $(( off % 1048576 )) -eq 0 ]; then
		dd if="$src" of="$EMMC" bs=1M seek=$(( off / 1048576 )) conv=notrunc status=none
	else
		dd if="$src" of="$EMMC" bs=512 seek="$2" conv=notrunc status=none
	fi
}

# ---------------------------------------------------------------- 1) 卸载
# ★ 坑：findmnt -S /dev/mmcblk0 只按"源设备名精确相等"匹配，而实际挂载源是
#   /dev/mmcblk0p2…p7 —— 匹配不到会让 findmnt 退出码非 0，配合 pipefail + set -e
#   整脚本静默退出（第一次就踩了）。所以这里改成"按前缀过滤 + 处处 || true"。
mounted_from_emmc() {
	findmnt -rno TARGET,SOURCE 2>/dev/null | awk '$2 ~ /^\/dev\/mmcblk0/ {print $1}'
}
say "[1] 卸载 mmcblk0 上的挂载"
for round in 1 2 3; do
	tgts=$(mounted_from_emmc || true)
	[ -z "$tgts" ] && break
	for m in $tgts; do
		say "    umount $m"
		umount -f "$m" 2>/dev/null || umount -l "$m" 2>/dev/null || true
	done
	systemctl stop 'vol00-RemovableDisk*.mount' 2>/dev/null || true
	sleep 1
done
if [ -n "$(mounted_from_emmc || true)" ]; then
	echo "!! 仍有 mmcblk0 挂载，拒绝继续："
	mounted_from_emmc
	exit 1
fi
say "    已清空"

SECTORS=$(cat "/sys/block/$(basename "$EMMC")/size")
say "    eMMC 扇区数 = $SECTORS"

# ---------------------------------------------------------------- 2) 抹头尾
say "[2] 抹头部 1MiB 与尾部 1MiB（清原厂 GPT 主/备表）"
dd if=/dev/zero of="$EMMC" bs=1M count=1 conv=notrunc status=none
dd if=/dev/zero of="$EMMC" bs=1M seek=$(( SECTORS / 2048 - 1 )) count=1 conv=notrunc status=none
sync

# ---------------------------------------------------------------- 3) MBR
say "[3] 写 MBR"
dd if=$T/emmc-mbr.bin of="$EMMC" bs=512 seek=0 conv=notrunc status=none
echo "    MBR 回读（offset 440，应见磁盘签名 + 两段 83 分区项 + 55aa）:"
dd if="$EMMC" bs=512 count=1 2>/dev/null | od -An -tx1 -j 440 -N 72 | sed 's/^/      /'

# ---------------------------------------------------------------- 4) 兜底裸镜像
say "[4] 写兜底裸内核 @LBA $RK 与裸 DTB @LBA $RD"
ddat $T/emmc-rawk.bin "$RK"
ddat $T/emmc-rawd.bin "$RD"
sync

# ---------------------------------------------------------------- 5) p1
say "[5] 写 p1.img @LBA $P1（256 MiB ext4，含内核与 DTB）"
ddat $T/emmc-p1.img "$P1"
sync

# ---------------------------------------------------------------- 6) 重读分区表
say "[6] 重新读分区表"
blockdev --rereadpt "$EMMC" 2>/dev/null && say "    rereadpt ok" || say "    rereadpt 返回非零（继续看节点）"
sleep 2
grep "$(basename "$EMMC")" /proc/partitions | sed 's/^/      /'

# ---------------------------------------------------------------- 7) 回读校验
say "[7] 回读校验（md5 逐段比对）"
md5cmp() { # $1=名字 $2=LBA $3=扇区数 $4=/tmp 下源文件（必须按扇区对齐）
	local a b
	a=$(dd if="$EMMC" bs=512 skip="$2" count="$3" 2>/dev/null | md5sum | cut -d' ' -f1)
	b=$(md5sum "$4" | cut -d' ' -f1)
	if [ "$a" = "$b" ]; then echo "      $1 OK  $a"; else echo "      !! $1 不一致  盘=$a 源=$b"; fi
}
md5cmp 裸内核 "$RK" "$RKS" "$T/emmc-rawk.bin"
md5cmp 裸DTB  "$RD" "$RDS" "$T/emmc-rawd.bin"
md5cmp p1.img "$P1" "$P1S" "$T/emmc-p1.img"

say "完成。下一步：emmc-root.sh"
