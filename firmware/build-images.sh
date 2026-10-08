#!/bin/bash
# build-images.sh —— 在**任意 Linux 主机**上生成 CM360 可刷镜像（p1 / p2）
#
# 为什么需要它
# ------------
# 别人的板子和我们这块不一样：他们的 eMMC 里是原厂固件，没有 fnOS。
# 而 fnOS 的 ARM 镜像是官方发布的**整盘镜像**（含 eMMC 分区表和它自己的内核），
# 直接刷上去会因为"内核不是我们编译的"而起不来（本板靠自编译 6.6.54 内核 + 板级 DTS）。
# 所以正确做法是：
#   L0 低区 → 用仓库里的 low-region 镜像（bootloader + u-boot，刷一次就好）
#   L1 p1   → 本脚本从 artifacts/ 生成（我们的内核 uImage + 板级 DTB）
#   L2 p2   → 本脚本从**官方 fnOS 镜像**生成，并施加本仓库的适配
#              （官方镜像不随仓库转发，请自行从官网下载 —— 见 README）
#
# 用法
# ----
#   ./build-images.sh p1                  # 生成 p1-256MiB.img（几秒）
#   ./build-images.sh p2 <官方镜像.gz>     # 生成 p2-7GiB.img（需 sudo，约 10~20 分钟）
#   ./build-images.sh all <官方镜像.gz>    # 两个都生成
#
# 需要：sudo（loop 挂载）、rsync、btrfs-progs、e2fsprogs、约 15 GB 临时空间
set -e

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
OUT="${OUT:-$HERE/images}"
KREL="${KREL:-6.6.54-gbe79582cba58-dirty}"
WORK="${WORK:-/var/tmp/cm360-build}"

P1_SIZE_MB=256
P2_SIZE_GIB=7
# eMMC 扇区边界（实测）：低区 0x0~0x12FFF / p1 0x13000~0x92FFF / p2 0x93000~末尾
P1_LBA=0x13000
P2_LBA=0x93000

die() { echo "!! $*" >&2; exit 1; }

# sudo 运行时，把产物交给调用者，免得后续非 root 步骤（如 flash-from-pc.py）写不进去
fix_owner() {
	[ -n "${SUDO_UID:-}" ] && [ -f "$1" ] && chown "$SUDO_UID:$SUDO_GID" "$1" 2>/dev/null || true
	[ -n "${SUDO_UID:-}" ] && [ -d "$OUT" ] && chown "$SUDO_UID:$SUDO_GID" "$OUT" 2>/dev/null || true
}
need_root() { [ "$(id -u)" = 0 ] || die "这一步需要 root：请用 sudo 运行"; }

# ── p1：256 MiB ext4，放内核 uImage + 板级 DTB（+ 一份 .bak 兜底）────────────
build_p1() {
	local img="$OUT/p1-${P1_SIZE_MB}MiB.img"
	mkdir -p "$OUT" "$WORK"
	local kern="$REPO/artifacts/kernel-6.6.54/Image-6.6.uimage"
	local dtb="$REPO/artifacts/kernel-6.6.54/rtd1296-cm360.dtb"
	[ -f "$kern" ] || die "缺 $kern"
	[ -f "$dtb" ] || die "缺 $dtb"

	echo "== 生成 p1（${P1_SIZE_MB} MiB ext4：内核 + DTB）=="
	rm -f "$img"
	truncate -s "${P1_SIZE_MB}M" "$img"
	mkfs.ext4 -q -F -L BOOT "$img"
	local mnt="$WORK/p1mnt"
	mkdir -p "$mnt"
	need_root
	mount -o loop "$img" "$mnt"
	cp "$kern" "$mnt/Image-6.6.uimage"
	cp "$dtb"  "$mnt/rtd1296-cm360.dtb"
	# 兜底副本：u-boot 里可用 ext4load ... .bak + bootm 退回
	cp "$kern" "$mnt/Image-6.6.uimage.bak"
	cp "$dtb"  "$mnt/rtd1296-cm360.dtb.bak"
	sync
	umount "$mnt"
	fix_owner "$img"
	echo "   ✔ $img"
	echo "     写入：mmc write <addr> $P1_LBA 0x80000     （256 MiB = 524288 扇区）"
	md5sum "$img"
}

# ── p2：7 GiB btrfs，从官方镜像搬 rootfs 并施加本仓库适配 ───────────────────
build_p2() {
	local official="$1"
	[ -n "$official" ] || die "用法: $0 p2 <官方 fnOS ARM 镜像(.gz|.img)>"
	[ -f "$official" ] || die "找不到 $official"
	local img="$OUT/p2-${P2_SIZE_GIB}GiB.img"
	mkdir -p "$OUT" "$WORK"
	need_root

	echo "== 1/6 解压官方镜像到 $WORK =="
	local raw="$WORK/official.img"
	if [ ! -f "$raw" ]; then
		case "$official" in
		*.gz) gzip -dc "$official" >"$raw" ;;
		*)    cp "$official" "$raw" ;;
		esac
	fi
	echo "   $(stat -c %s "$raw") 字节"

	echo "== 2/6 只读挂载官方镜像的 p2（rootfs）=="
	local loop
	loop=$(losetup -f --show -P "$raw")
	trap 'umount "$SRC" 2>/dev/null; umount "$DST" 2>/dev/null; losetup -d "$loop" 2>/dev/null' EXIT
	local SRC="$WORK/src"
	mkdir -p "$SRC"
	mount -o ro "${loop}p2" "$SRC"
	ls "$SRC" | head -5 | sed 's/^/   /'

	echo "== 3/6 建 ${P2_SIZE_GIB} GiB btrfs 目标镜像（label=rootfs，zstd 压缩）=="
	rm -f "$img"
	truncate -s "${P2_SIZE_GIB}G" "$img"
	mkfs.btrfs -q -f -L rootfs "$img"
	local DST="$WORK/dst"
	mkdir -p "$DST"
	mount -o compress=zstd "$img" "$DST"

	echo "== 3.5/6 建 root 子卷并把默认子卷指向它 =="
	# ★ 我们的内核 cmdline 是 rootflags=subvol=root（低区 u-boot env 里写着），
	#   而官方镜像的 p2 **没有子卷**（rootfs 就在顶层）—— 直接搬过去是起不来的。
	btrfs subvolume create "$DST/root"
	local subid
	subid=$(btrfs subvolume list "$DST" | awk '$NF=="root"{print $2}')
	[ -n "$subid" ] && btrfs subvolume set-default "$subid" "$DST"
	local ROOTFS="$DST/root"

	echo "== 4/7 复制 rootfs（-c 内容校验，排除 fnOS 自带内核与源码头）=="
	# ★ 必须带 -c：只比大小+时间的话，"复制中断"留下的坏文件会被判为一致
	rsync -aHAXc --numeric-ids \
		--exclude='/usr/lib/modules/6.18.18.c944-trim' \
		--exclude='/usr/src/linux-headers-*' \
		-q --stats "$SRC/" "$ROOTFS/" | tail -5

	echo "== 5/7 施加本仓库适配 =="
	adapt "$ROOTFS"
	sync
	umount "$DST" "$SRC"
	losetup -d "$loop"
	trap - EXIT

	echo "== 6/7 自检：重新挂载生成结果，核对子卷与关键文件 =="
	local CHK="$WORK/chk"
	mkdir -p "$CHK"
	local L2
	L2=$(losetup -f --show -P "$img")
	mount -o ro "$L2" "$CHK"
	# 注意：默认子卷已设为 root，所以挂载镜像看到的就是 rootfs 本身
	echo "  顶层: $(ls "$CHK" | tr '\n' ' ' | head -c 120)"
	echo "  子卷: $(btrfs subvolume list "$CHK" | tr '\n' ' ')"
	echo "  默认: $(btrfs subvolume get-default "$CHK" | tr '\n' ' ')"
	for f in etc/fstab usr/trim/etc/version \
		"usr/lib/modules/$KREL/modules.builtin" \
		usr/local/sbin/cm360-firstboot.sh \
		etc/systemd/system/cm360-firstboot.service \
		etc/systemd/system/multi-user.target.wants/cm360-firstboot.service; do
		[ -e "$CHK/$f" ] && echo "   ✔ $f" || { echo "   ✗ 缺 $f"; umount "$CHK"; losetup -d "$L2"; die "自检失败"; }
	done
	umount "$CHK"; losetup -d "$L2"

	fix_owner "$img"
	echo "== 7/7 完成 =="
	echo "   ✔ $img"
	echo "     写入：mmc write <addr> $P2_LBA <扇区数>   （镜像 $(stat -c %s "$img") 字节 = $(($(stat -c %s "$img")/512)) 扇区）"
	md5sum "$img"
}

# 适配：让官方 rootfs 能在**本板自编译 6.6.54 内核**上跑起来
adapt() {
	local NEW="$1"
	echo "   - fstab：去掉镜像自带的 UUID，改用固定设备名（本板 p2 恒为 mmcblk0p2）"
	cat >"$NEW/etc/fstab" <<'EOF'
# /etc/fstab —— 内核 cmdline 已提供根文件系统：
#   root=/dev/mmcblk0p2 rootfstype=btrfs rootflags=subvol=root
# 这里再写一行 / 是为了拿到 compress=zstd（eMMC 只有 7G，不压缩会写满；
# btrfs 的 compress= 只在"首次挂载/remount"生效，所以必须写在 / 这一行）。
# 内核与 DTB 在 mmcblk0p1，由 u-boot 直接读取（rootfs 里的 /boot 是空的）。
#
# <file system> <mount point>   <type>  <options>			<dump> <pass>
/dev/mmcblk0p2		/	btrfs	defaults,noatime,compress=zstd	0	1
tmpfs			/tmp	tmpfs	defaults,nosuid			0	0
EOF

	echo "   - 清掉镜像自带内核模块与源码头"
	rm -rf "$NEW/usr/lib/modules/6.18.18.c944-trim" "$NEW/usr/src/linux-headers-6.18.18.c944-trim"

	echo "   - 装入本机内核($KREL)的模块元数据（文本；board 首次开机会跑 depmod 生成索引）"
	mkdir -p "$NEW/usr/lib/modules/$KREL"
	for f in modules.builtin modules.builtin.modinfo modules.order; do
		[ -f "$REPO/artifacts/kernel-6.6.54/$f" ] || die "缺 artifacts/kernel-6.6.54/$f（仓库应自带，请检查 clone 是否完整）"
		cp "$REPO/artifacts/kernel-6.6.54/$f" "$NEW/usr/lib/modules/$KREL/"
	done
	: >"$NEW/usr/lib/modules/$KREL/modules.dep"
	: >"$NEW/usr/lib/modules/$KREL/modules.dep.bin"

	echo "   - 清掉 modules-load.d 里本机内核没有的模块（zfs / nft_fullcone / msr）"
	rm -f "$NEW/etc/modules-load.d/trim-zfs.conf" "$NEW/etc/modules-load.d/trim-fullconenat-nft.conf"
	[ -f "$NEW/etc/modules-load.d/modules.conf" ] && sed -i '/^msr$/d' "$NEW/etc/modules-load.d/modules.conf"

	echo "   - 写 kernel_version_output"
	mkdir -p "$NEW/var/tmp"
	printf "kernel_version='%s'\nplatform_name='rockchip'\n" "$KREL" >"$NEW/var/tmp/kernel_version_output"

	echo "   - ★ 安装 fnOS 1.2.x 在 6.6 内核上的两个兼容层（否则创建存储空间必失败）"
	install -m 755 "$REPO/boards/rtd1296-cm360/board-scripts/mdadm-lockless-compat.sh" \
		"$NEW/usr/local/sbin/mdadm-lockless-compat.sh" 2>/dev/null || true
	cat >"$NEW/usr/local/sbin/cm360-firstboot.sh" <<'EOF'
#!/bin/sh
# CM360 首次开机：补上两件在主机上做不了的事
#   1) depmod —— 全内置内核的模块索引必须在**板上**生成（kmod 只认 .bin 索引）
#   2) fnOS 1.2.x 兼容层：mdadm 的 lockless bitmap 降级 + fast_resync 跳过全量同步
set -u
R="$(uname -r)"
mkdir -p "/lib/modules/$R"
depmod -a "$R" 2>/dev/null && echo "cm360-firstboot: depmod ok"
if [ -x /usr/local/sbin/mdadm-lockless-compat.sh ]; then
	sh /usr/local/sbin/mdadm-lockless-compat.sh >/var/log/cm360-firstboot.log 2>&1
	echo "cm360-firstboot: mdadm 兼容层已安装"
fi
rm -f /etc/systemd/system/cm360-firstboot.service
systemctl disable cm360-firstboot.service 2>/dev/null
EOF
	chmod 755 "$NEW/usr/local/sbin/cm360-firstboot.sh"
	cat >"$NEW/etc/systemd/system/cm360-firstboot.service" <<'EOF'
[Unit]
Description=CM360 first boot fixes (depmod + fnOS 1.2 kernel compat)
After=local-fs.target
Before=trim_init.service trim_main.service
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/cm360-firstboot.sh
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
EOF
	mkdir -p "$NEW/etc/systemd/system/multi-user.target.wants"
	ln -sf ../cm360-firstboot.service "$NEW/etc/systemd/system/multi-user.target.wants/cm360-firstboot.service"
	echo "   - 适配完成"
}

case "${1:-}" in
p1)  build_p1 ;;
p2)  build_p2 "${2:-}" ;;
all) build_p1; build_p2 "${2:-}" ;;
*)   sed -n '1,30p' "$0"; exit 1 ;;
esac
