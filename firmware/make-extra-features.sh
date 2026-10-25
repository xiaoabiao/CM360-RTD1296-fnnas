#!/bin/bash
# make-extra-features.sh —— 从"完整 p2 镜像"生成功能注入包 cm360-extra-features.tar.gz
#
# 用途：线刷只刷得进 2 GiB 的精简 p2（工具 32 位内存限制，见 firmware/install-extra-features.sh
# 头部说明），刷完用这个包把被裁掉的功能文件补回去。
#
# 用法（Linux/WSL root）：
#   ./firmware/make-extra-features.sh /path/to/p2-full.img [输出目录]
set -e
FULL="${1:-}"
OUT="${2:-$(pwd)}"
[ -n "$FULL" ] || { echo "用法: $0 <p2-full.img> [outdir]" >&2; exit 1; }
[ "$(id -u)" = 0 ] || { echo "需要 root（loop 挂载）" >&2; exit 1; }
M="$(mktemp -d /var/tmp/extraf-XXXXXX)"

L=$(losetup -f --show "$FULL")
trap 'umount "$M" 2>/dev/null; losetup -d "$L" 2>/dev/null; rmdir "$M" 2>/dev/null' EXIT
mount -o ro "$L" "$M"

# 与 slim-p2.sh 的排除清单一致的“被裁掉的内容”
PATHS=(
	usr/lib/firmware usr/lib/gcc usr/include usr/src
	usr/share/doc usr/share/man usr/share/locale
	usr/share/pocketsphinx usr/share/vim usr/share/qt5
	usr/share/proj usr/share/i18n usr/share/AAVMF
	var/lib/apt/lists var/cache/apt
)
EXIST=()
for p in "${PATHS[@]}"; do [ -e "$M/$p" ] && EXIST+=("$p"); done

rm -f "$OUT/cm360-extra-features.tar.gz"
# ⚠️ 必须 cd 进镜像根再让 shell 展开通配符：GNU tar 创建时**不做** glob 展开，
#    原写法 `tar -C "$M" ... libLLVM-*` 里的通配符会在宿主当前目录展开（展开不到），
#    导致 libLLVM-14/15、libgallium 这三个 ~250 MB 的库被漏掉（2026-10-22 修）。
cd "$M"
tar -czf "$OUT/cm360-extra-features.tar.gz" --numeric-owner \
	"${EXIST[@]}" \
	usr/lib/aarch64-linux-gnu/libLLVM-* \
	usr/lib/aarch64-linux-gnu/libgallium-*
cd - >/dev/null

echo "✔ $OUT/cm360-extra-features.tar.gz"
ls -lh "$OUT/cm360-extra-features.tar.gz"
md5sum "$OUT/cm360-extra-features.tar.gz"
echo "  文件数：$(tar -tzf "$OUT/cm360-extra-features.tar.gz" | wc -l)"
