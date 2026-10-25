#!/bin/sh
# install-extra-features.sh —— 把精简线刷镜像里裁掉的功能文件注入回板子的根分区
#
# 背景：厂商 USB MP Tool 是 32 位程序，会把**所有** PART 载荷读进内存（约 3 GB 上限），
# 所以 7.5 GB 的完整 p2 既不能整文件、也不能分片放进同一个线刷包
# （实测分 4 片时加载到 PART2 报 GetLastError:8 / ERROR_NOT_ENOUGH_MEMORY）。
# 因此线刷包用 "2 GiB 精简 p2"（能启动），刷完再在板上跑本脚本把功能补齐。
#
# 用法（板子进系统后）：
#   sudo ./install-extra-features.sh
#
# 文件需与本脚本同目录：
#   cm360-extra-features.tar.gz   （485 MB，28,190 个成员）
#   md5 f91c6c9ef0f6ec4fd18a44df761ad018
set -e

[ "$(id -u)" = 0 ] || { echo "!! 请用 sudo 运行：sudo $0" >&2; exit 1; }
HERE="$(cd "$(dirname "$0")" && pwd)"
TAR="$HERE/cm360-extra-features.tar.gz"
[ -f "$TAR" ] || { echo "!! 找不到 $TAR" >&2; exit 1; }

echo "== 注入功能文件（firmware / AAVMF / gcc / doc / locale / LLVM ...）=="
du -sh "$TAR"
tar -xzpf "$TAR" -C /
sync

# 库缓存（LLVM/gallium 等 .so）
if command -v ldconfig >/dev/null 2>&1; then
	ldconfig || true
fi

echo "== 完成 =="
df -h / | tail -1
echo "已恢复：/usr/lib/firmware、/usr/share/AAVMF、gcc/头文件、文档/man、全部 locale、"
echo "        apt 列表缓存、LLVM/gallium 等（原精简清单见 firmware/slim-p2.sh）"
