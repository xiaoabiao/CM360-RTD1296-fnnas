#!/bin/bash
# slim-p2.sh —— 把"完整 p2 镜像"重建成 < 2 GiB 的精简 p2（线刷工具硬限制，见 docs/10 §16.3 ⑤）
#
# 为什么必须精简：
#   厂商工具 rtumdfsample.exe 是 32 位程序，读分区载荷大小时用 32 位有符号变量
#   （ReadUnTarTempFile → getDataLen → Real_Partition_Data_Size_Point）。
#   载荷 ≥ 2^31 = 2,147,483,648 B 时大小变负数 → 数组/循环越界 → 进程崩溃
#   （WER: 0xC0000409，偏移落在 abort()）。实测：2.0 GB 载荷可载入，2.2 GB 崩溃。
#
#   线刷包的 part 语义允许"文件内容 < 分区大小"（厂商原包同样如此），
#   所以 p2 只写约 2 GiB，分区仍按 7.5 GB 建立；板上首启由 cm360-firstboot.sh
#   执行 `btrfs filesystem resize max /` 扩回满分区。
#
# 用法（Linux / WSL root）：
#   ./firmware/slim-p2.sh --src /path/to/p2.img --out /path/to/p2-slim.img [--size-mib 2000]
#
# 需要：btrfs-progs、rsync、losetup、root。临时挂载点用 $WORK（默认 /var/tmp/cm360-slim）。
set -euo pipefail

SRC=""
OUT=""
SIZE_MIB=2000          # 必须 < 2048；2000 MiB ≈ 2.09 GB，留 ~50 MiB 余量
WORK="${WORK:-/var/tmp/cm360-slim}"

while [ $# -gt 0 ]; do
	case "$1" in
	--src) SRC="$2"; shift 2 ;;
	--out) OUT="$2"; shift 2 ;;
	--size-mib) SIZE_MIB="$2"; shift 2 ;;
	-h|--help) sed -n '2,25p' "$0"; exit 0 ;;
	*) echo "未知参数 $1" >&2; exit 1 ;;
	esac
done
[ -n "$SRC" ] && [ -n "$OUT" ] || { echo "用法: $0 --src p2.img --out p2-slim.img [--size-mib 2000]" >&2; exit 1; }
[ "$SIZE_MIB" -lt 2048 ] || { echo "--size-mib 必须 < 2048（2 GiB 是工具上限）" >&2; exit 1; }
[ "$(id -u)" = 0 ] || { echo "需要 root（loop 挂载）" >&2; exit 1; }

MNT_SRC="$WORK/src"
MNT_DST="$WORK/dst"
rm -rf "$WORK"; mkdir -p "$MNT_SRC" "$MNT_DST"
rm -f "$OUT"
truncate -s $((SIZE_MIB * 1024 * 1024)) "$OUT"
mkfs.btrfs -q -f -L rootfs -m single -d single "$OUT"

L1=$(losetup -f --show "$SRC"); mount -o ro "$L1" "$MNT_SRC"
L2=$(losetup -f --show "$OUT"); mount -o compress=zstd:15 "$L2" "$MNT_DST"
trap 'umount "$MNT_DST" 2>/dev/null; umount "$MNT_SRC" 2>/dev/null; losetup -d "$L2" 2>/dev/null; losetup -d "$L1" 2>/dev/null' EXIT

# fnOS 要的子卷布局（与 build-images.sh 一致）
btrfs subvolume create "$MNT_DST/root" >/dev/null
SUBID=$(btrfs subvolume list "$MNT_DST" | awk '$NF=="root"{print $2}')
btrfs subvolume set-default "$SUBID" "$MNT_DST"

# 精简清单：删掉对 CM360 NAS 运行无影响的内容（换空间，保证 < 2 GiB）
#   - 编译器/头文件：/usr/lib/gcc /usr/include /usr/src
#   - 全量内核固件：/usr/lib/firmware（本板驱动全部内建，不需要外挂固件）
#   - 文档/man/多余 locale（保留 en*/zh_CN*/zh_TW*）
#   - apt 缓存、GUI/语音/VM 相关的静态资源（AAVMF UEFI、Qt、pocketsphinx、vim、proj、i18n）
#   - 软件渲染 LLVM（NAS 无 GUI）
echo "== rsync 精简 rootfs -> $OUT（$SIZE_MIB MiB）=="
rsync -aHAX --numeric-ids --info=progress2 --stats \
	--exclude='/usr/lib/gcc' --exclude='/usr/include' --exclude='/usr/src' \
	--exclude='/usr/lib/firmware' \
	--exclude='/usr/share/doc' --exclude='/usr/share/man' \
	--exclude='/usr/share/pocketsphinx' --exclude='/usr/share/vim' \
	--exclude='/usr/share/qt5' --exclude='/usr/share/proj' \
	--exclude='/usr/share/i18n' --exclude='/usr/share/AAVMF' \
	--exclude='/usr/lib/aarch64-linux-gnu/libLLVM-*' \
	--exclude='/usr/lib/aarch64-linux-gnu/libgallium-*' \
	--exclude='/var/lib/apt/lists/*' --exclude='/var/cache/apt/*' \
	--filter='+ /usr/share/locale/en*/***' \
	--filter='+ /usr/share/locale/zh_CN*/***' \
	--filter='+ /usr/share/locale/zh_TW*/***' \
	--filter='- /usr/share/locale/*' \
	"$MNT_SRC/" "$MNT_DST/root/" 2>&1 | tail -6

sync
echo "== 用量 =="
btrfs filesystem usage -b "$MNT_DST" | egrep 'Device size|Device allocated|Used|Free \(estimated\)' | sed 's/^/  /'
umount "$MNT_DST"; losetup -d "$L2"
umount "$MNT_SRC"; losetup -d "$L1"
trap - EXIT

SIZE=$(stat -c %s "$OUT")
echo "== 结果 =="
ls -l "$OUT"
echo "size=$SIZE  (< 2147483648 ? )"
[ "$SIZE" -lt 2147483648 ] || { echo "!! 仍然 ≥ 2 GiB，请减小 --size-mib 或增加排除项" >&2; exit 1; }
btrfs check --readonly "$OUT" 2>&1 | tail -3 || true
md5sum "$OUT"
