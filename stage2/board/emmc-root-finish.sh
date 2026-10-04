#!/bin/bash
# emmc-root-finish.sh —— 收尾/补做：置可写 + set-default + 清理 + 验证 + 卸载
#
# 为什么要单独有一个：emmc-root.sh 是通过 ssh 通道跑的，若主机侧通道先断
# （paramiko 默认 120s PipeTimeout 就干过这事），远端脚本会在 send/receive
# 之后撞 EPIPE 提前死掉，留下"子卷已收到但 ro=true 且不是默认子卷"的半成品。
# 本脚本幂等，可反复跑。
set -uo pipefail

M=/mnt/emmc
DEV=/dev/mmcblk0p2
say() { echo "[finish] $*"; }

# 0) 确认挂着
if ! mountpoint -q "$M"; then
	say "挂载 $DEV → $M"
	mount -o compress=zstd:3,noatime,space_cache=v2 "$DEV" "$M" || { echo "!! 挂载失败"; exit 1; }
fi
findmnt -rno TARGET,SOURCE,OPTIONS "$M" | sed 's/^/    /'

# 1) 找到收到的子卷（名字可能不是 __rootmig，兜底扫一遍）
SUB=""
for c in "$M/__rootmig" "$M/rootmig" "$M/root"; do
	[ -d "$c" ] && { SUB="$c"; break; }
done
if [ -z "$SUB" ]; then
	say "顶层没有已知名字的子卷，列出 /mnt/emmc 下的目录："
	ls -la "$M" | sed 's/^/    /'
	echo "!! 请人工确认子卷名后重跑（或直接 btrfs property set <路径> ro false）"
	exit 1
fi
say "收到子卷：$SUB"

# 2) 置可写
RO=$(btrfs property get "$SUB" ro | sed 's/.*=//')
say "当前 ro=$RO"
if [ "$RO" != "false" ]; then
	btrfs property set "$SUB" ro false && say "已置 ro=false"
else
	say "已经是 ro=false"
fi

# 3) set-default
SVID=$(btrfs subvolume list "$M" | awk -v s="$(basename "$SUB")" '$NF==s{print $2; exit}')
say "子卷 id=$SVID"
if [ -n "$SVID" ]; then
	btrfs subvolume set-default "$SVID" "$M"
	btrfs subvolume get-default "$M" | sed 's/^/    /'
	say "默认子卷已设为 $SVID"
fi

# 4) 清源侧快照
if [ -d /root/__rootmig ]; then
	say "删源侧快照 /root/__rootmig"
	btrfs subvolume delete /root/__rootmig || rm -rf /root/__rootmig
fi

# 5) 验证
say "==== 验证 ===="
echo "    --- 内容 ---"
ls "$SUB" | head -30 | sed 's/^/      /'
echo "    --- 关键目录条目数 ---"
for d in etc usr bin lib sbin var home root; do
	printf '      %-6s %s\n' "$d" "$(ls "$SUB/$d" 2>/dev/null | wc -l)"
done
echo "    --- 账号 Xiaoabiao ---"
grep -h 'Xiaoabiao' "$SUB/etc/passwd" "$SUB/etc/group" 2>/dev/null | sed 's/^/      /' || echo "      !! 没找到"
echo "    --- sshd 配置 ---"
ls -l "$SUB/etc/ssh/sshd_config" 2>/dev/null | sed 's/^/      /' || echo "      !! 无"
echo "    --- fstab ---"
cat "$SUB/etc/fstab" | sed 's/^/      /'
echo "    --- 目标 fs 占用 ---"
btrfs filesystem usage "$M" | head -10 | sed 's/^/      /'
echo "    --- p2 UUID / LABEL ---"
btrfs filesystem show "$DEV" | sed 's/^/      /'

# 6) p1 挂载验证
say "==== p1（引导分区）验证 ===="
mkdir -p /mnt/emmcp1
if mount /dev/mmcblk0p1 /mnt/emmcp1 2>/dev/null; then
	ls -l /mnt/emmcp1 | sed 's/^/      /'
	md5sum /mnt/emmcp1/Image-6.6.uimage 2>/dev/null | sed 's/^/      /'
	umount /mnt/emmcp1
else
	echo "      !! p1 挂不上（ext4 驱动或分区问题）"
fi

# 7) 卸载
say "卸载 $M"
umount "$M" && say "已卸载"
say "完成。"
