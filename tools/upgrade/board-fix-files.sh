#!/bin/sh
# 把暂存目录里的文件**就地**写回目标 rootfs。在板端以 root 运行：
#   bash board-fix-files.sh [目标rootfs] [暂存目录]
#   默认：/mnt/emmc-top/root-new  和  /mnt/emmc-top/stage
#
# 为什么要"就地"覆盖而不是直接 rsync 覆盖：
#   rsync/cp/tar 都会**新建 inode**（先 unlink 再创建），属主、权限、xattr、ACL
#   就都丢了；而这边的正确元数据是好的（只有内容坏）。
#   用 `cat stage/<path> > <dest>/<path>` 只改数据，inode 不动 → 元数据全保留。
#
# 暂存目录需要普通用户可写（rsync/scp 以普通用户推文件过来），
# 所以是：普通用户传到 stage → root 就地写回目标。
set -eu

DEST=${1:-/mnt/emmc-top/root-new}
STAGE=${2:-/mnt/emmc-top/stage}

[ -d "$STAGE" ] || { echo "错误：暂存目录 $STAGE 不存在" >&2; exit 1; }
[ -d "$DEST" ] || { echo "错误：目标 $DEST 不存在" >&2; exit 1; }

n=0
cd "$STAGE"
find . -type f | while read -r f; do
	t="$DEST/${f#./}"
	if [ -e "$t" ]; then
		cat "$f" >"$t"      # inode 不变 → 属主/权限/xattr 保留
		echo "就地修复  ${f#./}  ($(stat -c %s "$f") 字节)"
	else
		install -D -m 644 "$f" "$t"   # 目标缺文件才新建
		echo "新建文件  ${f#./}"
	fi
done
echo "完成，共 $(find . -type f | wc -l) 个文件"
