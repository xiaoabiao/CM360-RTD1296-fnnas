#!/bin/bash
# emmc-root.sh —— 板上执行（root）。把当前运行中的根文件系统整体搬到 eMMC 的 p2（btrfs）
#
# 路线：btrfs send/receive
#   /  →  只读快照 /root/__rootmig  →  send | receive 到 eMMC p2
#
# 为什么不用 dd：
#   * dd 活体 btrfs 会读到撕裂事务，可能挂不上；
#   * send/receive 是"读文件内容"，天然一致。
#
# ★ 关键：接收时 p2 挂 compress=zstd
#   原镜像的 extent 是构建期压缩的（du 表观 5.2G / 实际占用 2.19GiB），
#   send 流出的是**解压后** ~5.0 GiB。不带压缩接收会把这 5.0 GiB 原样落盘；
#   带 compress=zstd 则重新压回 ~2.2 GiB。两个都要能装下，所以 p2 给到 ~7 GiB。
#
# ★ 关键：收到的是子卷，必须 (a) 置回可写 (b) set-default
#   否则 root=/dev/mmcblk0p2 挂上去是"只读空目录"或者根本没内容。
set -euo pipefail

EMMC=${EMMC:-/dev/mmcblk0}
L=/tmp/emmc-layout.txt
M=/mnt/emmc
SNAP=/root/__rootmig
DEV=${EMMC}p2
say() { echo "[root] $*"; }

val() { awk -v k="$1" -v f="$2" '$1==k{for(i=1;i<=NF;i++) if($i==f) print $(i+1)}' "$L"; }
P2=$(val p2 LBA); P2S=$(val p2 sectors)
say "eMMC p2 = $DEV  (layout LBA $P2, $P2S 扇区)"

# ---------------------------------------------------------------- 0) 前置
say "[0] 前置检查"
[ -b "$DEV" ] || { echo "!! $DEV 不存在 —— 先跑 emmc-part.sh"; exit 1; }
umount "$DEV" 2>/dev/null || true
echo "    当前 / 的可用空间："
btrfs filesystem usage / | grep -E 'Device size|Free \(estimated\)|Used:' | sed 's/^/      /'

# 打整棵树的快照需要 COW 元数据；可用空间太少就先扩（sda 后面有 10.9 TiB slack）
FREE_MB=$(btrfs filesystem usage -b / | awk '/Free \(estimated\)/{print int($3/1048576)}')
if [ "${FREE_MB:-0}" -lt 2048 ]; then
	say "    可用 ${FREE_MB}MiB < 2GiB，先把 / 扩到设备上限（sda 有 10.9TiB slack）"
	btrfs filesystem resize max / || say "    !! resize 失败，继续试试"
	btrfs filesystem usage / | grep -E 'Device size|Free \(estimated\)' | sed 's/^/      /'
fi

# ---------------------------------------------------------------- 1) mkfs
say "[1] mkfs.btrfs $DEV"
mkfs.btrfs -f -L rootfs "$DEV"
btrfs inspect-internal dump-super "$DEV" | grep -Ei '^(fsid|label)' | sed 's/^/      /'

# ---------------------------------------------------------------- 2) 挂载
say "[2] 挂载 $DEV → $M（compress=zstd）"
mkdir -p "$M"
mountpoint -q "$M" && umount "$M" || true
mount -o compress=zstd:3,noatime,space_cache=v2 "$DEV" "$M"
findmnt -rno TARGET,SOURCE,OPTIONS "$M" | sed 's/^/      /'

# ---------------------------------------------------------------- 3) 快照
say "[3] 打只读快照 / → $SNAP"
btrfs subvolume delete "$SNAP" 2>/dev/null || true
rm -rf "$SNAP" 2>/dev/null || true
btrfs subvolume snapshot -r / "$SNAP"
btrfs subvolume show "$SNAP" | grep -E 'Name|UUID|Subvolume ID|Flags' | sed 's/^/      /'
echo "    快照后 / 可用空间："
btrfs filesystem usage / | grep -E 'Free \(estimated\)' | sed 's/^/      /'

# ---------------------------------------------------------------- 4) send/receive
say "[4] btrfs send | receive（解压后约 5.0 GiB，会跑几分钟）"
date '+      start %F %T'
btrfs send "$SNAP" | btrfs receive "$M"
date '+      end   %F %T'
echo "    目标内容："
ls "$M" | sed 's/^/      /'

# ---------------------------------------------------------------- 5) 置可写 + 设默认子卷
say "[5] 置可写 + set-default"
btrfs property set "$M/__rootmig" ro false
SVID=$(btrfs subvolume list "$M" | awk '/__rootmig/{print $2}')
say "    收到子卷 id=$SVID"
[ -n "$SVID" ] && btrfs subvolume set-default "$SVID" "$M"
echo "    默认子卷 id："; btrfs subvolume get-default "$M" | sed 's/^/      /'
btrfs subvolume show "$M/__rootmig" | grep -E 'Name|Subvolume ID|Flags|UUID' | sed 's/^/      /'

# ---------------------------------------------------------------- 6) 清源侧快照
say "[6] 删除源侧快照 $SNAP"
btrfs subvolume delete "$SNAP"

# ---------------------------------------------------------------- 7) 验证
say "[7] 验证"
echo "    --- 关键目录条目数 ---"
for d in etc usr bin lib sbin var home root boot; do
	printf '      %-6s %s\n' "$d" "$(ls "$M/__rootmig/$d" 2>/dev/null | wc -l)"
done
echo "    --- 账号 ---"
grep -H 'Xiaoabiao' "$M/__rootmig/etc/passwd" "$M/__rootmig/etc/group" 2>/dev/null | sed 's/^/      /' || echo "      !! 没找到 Xiaoabiao（严重）"
echo "    --- sshd 配置 ---"
ls -l "$M/__rootmig/etc/ssh/sshd_config" 2>/dev/null | sed 's/^/      /' || echo "      !! 没有 sshd_config"
echo "    --- fstab（应为空 root 条目，根交给 cmdline）---"
cat "$M/__rootmig/etc/fstab" | sed 's/^/      /'
echo "    --- 目标 fs 占用 ---"
btrfs filesystem usage "$M" | head -10 | sed 's/^/      /'
echo "    --- p2 UUID / LABEL（bootargs 可直接用 UUID）---"
btrfs filesystem show "$DEV" | sed 's/^/      /'

say "[8] 卸载"
umount "$M"
btrfs filesystem show "$DEV" | sed 's/^/      /'
say "完成。"
