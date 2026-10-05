#!/bin/sh
# 切换 rootfs 之前的预检，分两个阶段用。在板端以 root 运行：
#   bash board-verify-newroot.sh pre     # 复制刚跑完、还没适配时用（比对必须 0 差异）
#   bash board-verify-newroot.sh ready   # 适配完成后、切换之前用
#
# 为什么不合并成一步：适配会**故意**让目标与镜像不一致（补内核模块目录、
# 改 fstab、删 modules-load.d 里的 zfs/nft/msr），"0 差异"这个判据只在 pre 阶段成立。
set -eu

mode=${1:-pre}
TOP=/mnt/emmc-top
NEW=$TOP/root-new
SRC=/mnt/newroot
KREL=$(uname -r)
fail=0

ok()  { echo "  ✔ $1"; }
bad() { echo "  ✗ $1"; fail=1; }

# 与 board-copy-rootfs.sh 保持一致（有意排除的内容）
EXCLUDES="--exclude=/usr/lib/modules/6.18.18.c944-trim --exclude=/usr/src/linux-headers-*"

echo "=== 通用前提 ==="
if pgrep -f "[r]sync -aHAX" >/dev/null; then
	bad "rsync 仍在运行，先等它结束"
else
	ok "没有 rsync 在跑"
fi
if mountpoint -q "$SRC"; then ok "$SRC 已挂载"; else bad "$SRC 未挂载"; fi
if grep -q "compress=zstd" /proc/mounts; then
	ok "eMMC 挂载带 compress=zstd"
else
	bad "eMMC 挂载没有 compress=zstd（新写入不压缩，可能写满）"
fi

case "$mode" in
pre)
	echo
	echo "=== 与镜像逐项比对（只应剩下 0 处差异）==="
	# 已知且是故意的一处差异：root-new 顶层被打了 btrfs.compression=zstd 属性，
	# 镜像那边没有这个 xattr，比对时会显示成 ".d........x ./"，此处滤掉。
	# 注意必须带 -c（内容比较）：只比大小+时间的话，"复制中途被复位"留下的
	# 坏文件会被判为一致（踩过：libaudit.so.1 大小时间都对、内容是垃圾，
	# 结果切过去 systemd 直接 panic）。
	# shellcheck disable=SC2086
	OUT=$(rsync -aHAXcn --delete --itemize-changes $EXCLUDES "$SRC/" "$NEW/" 2>&1 \
		| grep -v '^$' | grep -v '^\.d.*x \.$' || true)
	N=$(printf '%s\n' "$OUT" | grep -c . || true)
	if [ "$N" -eq 0 ]; then
		ok "与镜像完全一致"
	else
		bad "还有 $N 处差异（前 20 行如下）"
		printf '%s\n' "$OUT" | head -20
	fi
	echo
	echo "=== 提示：此时应该还没做适配 ==="
	if grep -q "mmcblk0p2" "$NEW/etc/fstab" 2>/dev/null; then
		echo "  （注意：fstab 看起来已经适配过了 → 说明现在应该用 ready 模式）"
	fi
	;;

ready)
	echo
	echo "=== 本机适配是否到位 ==="
	if grep -q "mmcblk0p2" "$NEW/etc/fstab"; then
		ok "fstab 是适配后的版本"
	else
		bad "fstab 还是镜像的（UUID 对不上本机）"
	fi
	if [ -d "$NEW/usr/lib/modules/$KREL" ]; then
		ok "内核 $KREL 的模块目录存在"
	else
		bad "缺 usr/lib/modules/$KREL"
	fi
	if [ -f "$NEW/usr/lib/modules/$KREL/modules.builtin" ]; then
		ok "modules.builtin 已就位"
	else
		bad "缺 modules.builtin（modprobe 探测会失败）"
	fi
	if [ -f "$NEW/usr/lib/modules/$KREL/modules.dep.bin" ]; then
		ok "depmod 索引已生成"
	else
		bad "缺 modules.dep.bin（depmod 没成功）"
	fi
	if [ -e "$NEW/etc/modules-load.d/trim-zfs.conf" ]; then
		bad "trim-zfs.conf 还在（本机内核没有 zfs）"
	else
		ok "已移除 trim-zfs.conf"
	fi
	if [ -e "$NEW/etc/modules-load.d/trim-fullconenat-nft.conf" ]; then
		bad "trim-fullconenat-nft.conf 还在"
	else
		ok "已移除 trim-fullconenat-nft.conf"
	fi
	if grep -q '^msr$' "$NEW/etc/modules-load.d/modules.conf"; then
		bad "modules.conf 里还有 msr"
	else
		ok "modules.conf 已清理"
	fi
	if [ -f "$NEW/var/tmp/kernel_version_output" ]; then
		ok "kernel_version_output 已写"
	else
		bad "缺 kernel_version_output"
	fi
	if [ -e "$NEW/usr/lib/modules/6.18.18.c944-trim" ]; then
		bad "镜像自带的 6.18.18.c944-trim 模块还在（占空间且没人用）"
	else
		ok "镜像自带内核模块已清掉"
	fi
	;;
*)
	echo "用法: $0 pre|ready" >&2
	exit 2
	;;
esac

echo
echo "=== 目标 rootfs 自身是否能跑 ==="
if chroot "$NEW" /bin/bash -c 'exit 0' 2>/dev/null; then
	ok "chroot 进去能执行 /bin/bash"
else
	bad "chroot 执行 /bin/bash 失败（动态库缺失？复制不完整？）"
fi
# 关键烟雾测试：systemd 会链接 libaudit 等库，能跑起来才说明 PID 1 不会 panic。
# （只测 bash 是不够的——bash 不链接 libaudit，我们就这么漏过一次。）
if chroot "$NEW" /usr/lib/systemd/systemd --version 2>&1 | grep -q "systemd"; then
	ok "chroot 里能执行 systemd（PID 1 依赖的库都正常）"
else
	bad "chroot 里跑 systemd 失败 → 切过去大概率 panic，先看："
	chroot "$NEW" /usr/lib/systemd/systemd --version 2>&1 | head -3 | sed 's/^/      /'
fi
V=$(chroot "$NEW" cat /usr/trim/etc/version 2>/dev/null || echo "?")
echo "  rootfs 里的版本号: $V"

echo
echo "=== 关键文件抽查 ==="
for f in usr/trim/bin/triminit usr/lib/systemd/systemd usr/bin/bash sbin/init; do
	if [ -e "$NEW/$f" ]; then ok "$f"; else bad "缺 $f"; fi
done

echo
echo "=== 空间与子卷 ==="
btrfs subvolume list "$TOP"
btrfs filesystem usage "$TOP" | head -4
df -h "$TOP" | tail -1

echo
if [ "$fail" -eq 0 ]; then
	echo "全部通过 → 可以执行 board-switch-rootfs.sh switch"
else
	echo "有项目失败 → 先修好再切换"
	exit 1
fi
