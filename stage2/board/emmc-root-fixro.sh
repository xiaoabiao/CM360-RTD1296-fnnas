#!/bin/bash
# emmc-root-fixro.sh —— 修 eMMC 根子卷的"只读"问题（v2）
#
# 两个坑：
#  1) `btrfs receive` 收到的子卷带 received_uuid，btrfs-progs 拒绝 ro->rw：
#       ERROR: cannot flip ro->rw with received_uuid set, use force if you really want that
#     只读子卷当根 → 整个 / 只读，systemd 起不来。
#     解法：对该只读子卷打一个可写快照（ro → rw 克隆是 btrfs 常规工作流），
#           新快照无 received_uuid，天然可写；extent 共享，不额外占空间。
#  2) ★ 一旦 set-default 到子卷，`mount $DEV $M` 就直接进到那个子卷里面了 ——
#     /mnt/emmc/__rootmig 这种"顶层相对路径"根本不存在。必须以 subvolid=5 挂顶层。
set -uo pipefail

M=/mnt/emmc
DEV=/dev/mmcblk0p2
say() { echo "[fixro] $*"; }

umount "$M" 2>/dev/null || true
say "以顶层 subvolid=5 挂载 $DEV → $M"
mount -o subvolid=5,compress=zstd:3,noatime,space_cache=v2 "$DEV" "$M" || exit 1
findmnt -rno TARGET,SOURCE,OPTIONS "$M" | sed 's/^/    /'

say "顶层下的子卷："
btrfs subvolume list "$M" | sed 's/^/    /'

# 找可写子卷；没有就从一个只读子卷克隆出可写的
# ★ btrfs subvolume list 的行是 "ID 256 gen 22 top level 5 path __rootmig"
#   —— "top level N path" 里有空格，用 read 切字段会切错；路径永远是最后一个字段。
RW=""
ROFIRST=""
for path in $(btrfs subvolume list "$M" | awk '{print $NF}'); do
	[ -d "$M/$path" ] || continue
	r=$(btrfs property get "$M/$path" ro 2>/dev/null | sed 's/.*=//')
	say "子卷 $path  ro=$r"
	if [ "$r" = "false" ]; then
		RW="$path"; break
	fi
	[ -z "$ROFIRST" ] && ROFIRST="$path"
done

if [ -z "$RW" ] && [ -n "$ROFIRST" ]; then
	say "全是只读；对 $ROFIRST 打可写快照 root"
	btrfs subvolume delete "$M/root" >/dev/null 2>&1 || true
	btrfs subvolume snapshot "$M/$ROFIRST" "$M/root" || { echo "!! 快照失败"; exit 1; }
	say "新子卷 ro=$(btrfs property get "$M/root" ro | sed 's/.*=//')（应为 false）"
	say "删除只读原件 $ROFIRST"
	btrfs subvolume delete "$M/$ROFIRST" || say "  （删不掉不影响）"
	RW="root"
fi

[ -n "$RW" ] || { echo "!! 找不到/造不出可写子卷"; btrfs subvolume list "$M"; exit 1; }

SVID=$(btrfs subvolume list "$M" | awk -v s="$RW" '$NF==s{print $2; exit}')
say "默认子卷 → $RW (id=$SVID)"
btrfs subvolume set-default "$SVID" "$M"
btrfs subvolume get-default "$M" | sed 's/^/    /'

say "==== 验证 ===="
for d in etc usr bin lib sbin var home; do
	printf '    %-6s %s\n' "$d" "$(ls "$M/$RW/$d" 2>/dev/null | wc -l)"
done
grep -h 'Xiaoabiao' "$M/$RW/etc/passwd" 2>/dev/null | sed 's/^/    /'
echo "    --- 子卷表 ---"; btrfs subvolume list "$M" | sed 's/^/      /'
echo "    --- 占用 ---";  btrfs filesystem usage "$M" | sed -n '1,6p' | sed 's/^/      /'

say "卸载"
umount "$M" && say "已卸载"
say "完成。"
