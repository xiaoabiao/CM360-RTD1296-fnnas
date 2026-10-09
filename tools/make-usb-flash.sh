#!/bin/bash
# make-usb-flash.sh —— 在电脑上把刷机镜像写进 U 盘（供 u-boot 用 fatload 读取）
#
# 为什么用 U 盘
# -------------
# u-boot 里 `fatload usb` 读 U 盘约 20~30 MB/s，比 TFTP（实测 1.5 MB/s）快十几倍，
# 而且**不依赖网络**。只要板子能进 u-boot 提示符就能用 —— 哪怕系统整个坏了。
#
# FAT32 限制：单文件 ≤ 4 GiB，而 p2 镜像有 7.5 GB —— 脚本会自动切成 2 GiB 分片。
# u-boot 2015.07 的 fatload 不支持文件内偏移，所以分片是必须的（每片写到连续的 LBA）。
#
# 用法
# ----
#   sudo ./make-usb-flash.sh /dev/sdX              # 写入（假定已是 FAT32）
#   sudo ./make-usb-flash.sh /dev/sdX --format     # 先格式化成 FAT32（会清空该盘！）
#   sudo ./make-usb-flash.sh /dev/sdX --check      # 只检查设备与镜像
#
# ⚠️ 会清空目标 U 盘上的内容。脚本会拒绝块设备（硬盘/SSD）与系统盘。
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
IMAGES="${IMAGES:-$REPO/firmware/images}"
FW="$REPO/firmware"
PART_BYTES=$((2 * 1024 * 1024 * 1024))     # 每片 2 GiB
DO_FORMAT=0
CHECK_ONLY=0

say() { echo "$@"; }
die() { echo "!! $*" >&2; exit 1; }

DEV=""
for a in "$@"; do
	case "$a" in
	--format) DO_FORMAT=1 ;;
	--check)  CHECK_ONLY=1 ;;
	/dev/*)   DEV="$a" ;;
	*) die "未知参数: $a" ;;
	esac
done
[ -n "$DEV" ] || die "用法: sudo $0 /dev/sdX [--format|--check]"
[ -b "$DEV" ] || die "$DEV 不是块设备"

say "=============================================="
say "制作 U 盘刷机盘"
say "=============================================="

# ── 1) 安全校验：拒绝系统盘/硬盘 ─────────────────────────────────────────
say "== 1) 目标设备安全检查 =="
SYS_DISKS=""
for m in $(lsblk -no PKNAME "$DEV" 2>/dev/null | sort -u); do SYS_DISKS="$SYS_DISKS /dev/$m"; done
ROOT_SRC=$(findmnt -no SOURCE / 2>/dev/null || true)
ROOT_DISK=$(lsblk -no PKNAME "$ROOT_SRC" 2>/dev/null | head -1 || true)
say "  目标     : $DEV"
say "  所属磁盘 : ${SYS_DISKS:-（未知）}"
say "  大小     : $(blockdev --getsize64 "$DEV" 2>/dev/null | numfmt --to=iec 2>/dev/null || echo '?')"
say "  可移动   : $(lsblk -no RM "$DEV" 2>/dev/null | head -1 || echo '?')  (1=可移动)"
if [ -n "$ROOT_DISK" ] && [ "$(basename "$DEV")" = "$ROOT_DISK" ]; then
	die "拒绝操作：$DEV 是系统盘（/ 所在磁盘）"
fi
SIZE=$(blockdev --getsize64 "$DEV" 2>/dev/null || echo 0)
[ "$SIZE" -ge $((9 * 1024 * 1024 * 1024)) ] || die "U 盘至少需要 9 GB（镜像合计约 7.8 GB），当前 $((SIZE/1048576)) MB"
say "   ✔ 安全检查通过"

# ── 2) 检查镜像 ──────────────────────────────────────────────────────────
say ""
say "== 2) 待写入的镜像 =="
declare -A SRC
for pair in "low-region.img:$FW/low-region.img" "p1.img:$IMAGES/p1-256MiB.img" "p2.img:$IMAGES/p2.img"; do
	name="${pair%%:*}"; path="${pair#*:}"
	if [ ! -f "$path" ]; then
		# 低区镜像随仓库以 .gz 提供，自动解压
		if [ -f "$FW/$name.gz" ]; then
			say "   解压 $name.gz …"
			gunzip -c "$FW/$name.gz" >"$IMAGES/$name"
			path="$IMAGES/$name"
		else
			die "缺少 $name（期望 $path）"
		fi
	fi
	SRC[$name]="$path"
	sz=$(stat -c %s "$path")
	parts=$(( (sz + PART_BYTES - 1) / PART_BYTES ))
	say "   $(printf '%-14s' "$name") %12d 字节  → %d 片" "$sz" "$parts"
done

TOTAL_SRC=0
for name in low-region.img p1.img p2.img; do TOTAL_SRC=$((TOTAL_SRC + $(stat -c %s "${SRC[$name]}"))); done
say "   合计 $((TOTAL_SRC/1048576)) MB（U 盘需 >= $(( (TOTAL_SRC/1048576) + 200 )) MB 可用）"
[ "$CHECK_ONLY" = 1 ] && { say ""; say "== --check：未写入任何东西 =="; exit 0; }

# ── 3) 确认 ──────────────────────────────────────────────────────────────
say ""
say "== 3) 确认 =="
say "   将${DO_FORMAT:+ 格式化并}写入 $DEV（**该盘原有内容会被清空**）"
read -r -p "   确认继续？输入 yes 回车：" a
[ "$a" = "yes" ] || die "已取消"

# ── 4) 卸载 + 可选格式化 ─────────────────────────────────────────────────
say ""
say "== 4) 准备文件系统 =="
umount "${DEV}"* 2>/dev/null || true
sleep 1
if [ "$DO_FORMAT" = 1 ]; then
	command -v mkfs.vfat >/dev/null || die "缺少 mkfs.vfat（apt install dosfstools）"
	wipefs -a "$DEV" >/dev/null 2>&1 || true
	mkfs.vfat -F 32 -n CM360FLASH "$DEV"
	say "   ✔ 已格式化为 FAT32（卷标 CM360FLASH）"
else
	FSTYPE=$(blkid -o value -s TYPE "${DEV}1" 2>/dev/null || blkid -o value -s TYPE "$DEV" 2>/dev/null || echo "")
	case "$FSTYPE" in
	vfat|fat|fat32) say "   ✔ 现有文件系统: $FSTYPE" ;;
	"")  say "   ! 读不到文件系统类型，若失败请加 --format" ;;
	*)   die "现有文件系统是 $FSTYPE，u-boot 只认 FAT —— 请加 --format" ;;
	esac
fi

# ── 5) 挂载 + 拷贝 ───────────────────────────────────────────────────────
MNT=$(mktemp -d)
trap 'umount "$MNT" 2>/dev/null || true; rmdir "$MNT" 2>/dev/null || true' EXIT
mount "$DEV" "$MNT" 2>/dev/null || mount "${DEV}1" "$MNT"
say ""
say "== 5) 拷贝镜像 =="
declare -a FLAT=()
for name in low-region.img p1.img p2.img; do
	path="${SRC[$name]}"
	sz=$(stat -c %s "$path")
	if [ "$sz" -le $PART_BYTES ]; then
		say "   → $name"
		cp "$path" "$MNT/$name"
		FLAT+=("$name")
	else
		parts=$(( (sz + PART_BYTES - 1) / PART_BYTES ))
		say "   → $name 切分 %d 片（FAT32 单文件 ≤4GiB）" "$parts"
		split -b "$PART_BYTES" -d -a 2 "$path" "$MNT/$name.part"
		for f in "$MNT/$name.part"*; do FLAT+=("$(basename "$f")"); done
	fi
done
sync
say "   ✔ 拷贝完成"

# ── 6) md5 清单 + 使用说明 ───────────────────────────────────────────────
say ""
say "== 6) 生成校验清单与说明 =="
( cd "$MNT" && md5sum "${FLAT[@]}" >MD5SUMS.txt ) 2>/dev/null || true
{
	echo "CM360 U 盘刷机盘"
	echo "================"
	echo
	echo "文件清单（按写入顺序）："
	printf '  %-24s %s\n' "low-region.img" "低区 38MiB：hwsetting+bootcode+FSBL+BL31+u-boot+env（含 MBR 分区表）"
	printf '  %-24s %s\n' "p1.img" "p1 256MiB：内核 uImage + 板级 DTB"
	for f in "${FLAT[@]}"; do
		case "$f" in p2.img.part*) printf '  %-24s %s\n' "$f" "rootfs 分片（按文件名顺序依次写到连续 LBA）" ;; esac
	done
	echo
	echo "板子侧（u-boot 提示符下，用串口驱动；也可以让电脑脚本自动跑）："
	echo "  usb start"
	echo "  fatload usb 0:1 0x20000000 low-region.img"
	echo "  mmc dev 0"
	echo "  mmc write 0x20000000 0x0 0x13000"
	echo "  fatload usb 0:1 0x20000000 p1.img"
	echo "  mmc write 0x20000000 0x13000 0x80000"
	LBA=$((0x93000))
	for f in "${FLAT[@]}"; do
		case "$f" in
		p2.img.part*)
			cnt=$(( $(stat -c %s "$MNT/$f") / 512 ))
			echo "  fatload usb 0:1 0x20000000 $f"
			echo "  mmc write 0x20000000 $(printf '0x%x' "$LBA") $(printf '0x%x' "$cnt")"
			LBA=$((LBA + cnt))
			;;
		esac
	done
	echo "  run bootcmd"
	echo
	echo "电脑侧一键：python3 firmware/flash-from-pc.py --usb --layers all"
	echo
	echo "注意："
	echo "  * 刷低区会直接改写 u-boot/分区表（砖区）——刷之前先备份低区"
	echo "  * 刷 p2 会清空 fnOS 配置；硬盘上的存储空间不受影响"
} >"$MNT/USB-FLASH-README.txt"
sync
say "   ✔ MD5SUMS.txt / USB-FLASH-README.txt 已写入"

umount "$MNT"
say ""
say "=============================================="
say "完成。U 盘已就绪，插到板子上即可刷机。"
say "  文件：$(printf '%s ' "${FLAT[@]}")"
say "=============================================="
