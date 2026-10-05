#!/bin/bash
# build-zfs.sh —— 为板上的 6.6.54 内核交叉编译 OpenZFS 2.4.1 模块
#
# 背景
# ----
# fnOS 支持"ZFS 型存储空间"，但它的内核模块是给自带内核（6.18.x）编的，
# 本板跑的是自编译 6.6.54，所以 zfs.ko/spl.ko 必须自己编。
# 板端用户态本来就是 2.4.1（zfs-2.4.1-1），内核模块版本必须一致。
#
# 用法
# ----
#   sudo apt install gcc-aarch64-linux-gnu      # 一次性：configure 需要带 libc 的交叉 gcc
#   ./scripts/build-zfs.sh                      # 编译并安装到板上
#   ./scripts/build-zfs.sh --build-only         # 只编，不装
#
# 三个非显然的坑（都实测踩过）
# ---------------------------
# 1) **configure 必须知道自己在交叉编译**：不传 --host 时它按本机 x86_64 编译测试程序，
#    而我们的内核工具链是 nolibc 的，直接 "C compiler cannot create executables"。
#    传了 --host=aarch64-linux-gnu 又需要**带 libc** 的交叉 gcc 来编 configure 的探针程序
#    （内核模块本身仍由内核的 Kbuild 用 CROSS_COMPILE 工具链编）。
# 2) **必须导出 ARCH/CROSS_COMPILE**：ZFS 的检查要编译内核测试模块，
#    缺这两个变量时它会报 "This kernel does not include the required loadable module support"
#    —— 其实 CONFIG_MODULES 是 y，纯粹是测试模块没编起来导致的误报。
# 3) **要打 NEON 补丁**：OpenZFS 2.4.1 的 aarch64 NEON RAIDZ 内联汇编在新版 GCC 上
#    报 "invalid hard register usage between earlyclobber operand and input operand"。
#    见 patches/zfs/0001-disable-aarch64-neon-raidz.patch（只是不注册 NEON 实现，
#    功能不受影响，RAIDZ 走通用实现）。
# 4) 内核树要有 **Module.symvers**（外部模块编译需要符号表）。全内置构建可能没有，
#    本脚本会自动跑 `make modules_prepare` + `make modules` 生成。
set -e

HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/lib/env.sh"

ZFS_VER="${ZFS_VER:-zfs-2.4.1}"
WORK="${ZFS_WORK:-$HOME/zfs-build}"
REL="$(make -s -C "$KTREE" ARCH=arm64 CROSS_COMPILE="$CROSS_COMPILE" kernelrelease 2>/dev/null)"
[ -n "$REL" ] || die "拿不到内核版本（KTREE=$KTREE）"

echo "== 0/5 环境检查 =="
echo "  内核   : $KTREE  ($REL)"
echo "  ZFS    : $ZFS_VER"
[ -x "$KTREE/scripts/dtc/dtc" ] || die "内核树不像已配置过"
if ! command -v aarch64-linux-gnu-gcc >/dev/null; then
	die "缺 aarch64-linux-gnu-gcc（configure 需要带 libc 的交叉 gcc）：sudo apt install gcc-aarch64-linux-gnu"
fi

echo
echo "== 1/5 准备内核树（Module.symvers 是外部模块编译的前提）=="
if [ ! -f "$KTREE/Module.symvers" ]; then
	echo "  没有 Module.symvers，先 modules_prepare + modules"
	kmake modules_prepare >/dev/null
	kmake modules >/dev/null
fi
[ -f "$KTREE/Module.symvers" ] || die "Module.symvers 仍然没有生成"
echo "  导出符号数: $(wc -l <"$KTREE/Module.symvers")"

echo
echo "== 2/5 取源码 =="
mkdir -p "$WORK"
cd "$WORK"
if [ ! -d "$ZFS_VER" ]; then
	if [ ! -f "$ZFS_VER.tar.gz" ]; then
		curl -fL -o "$ZFS_VER.tar.gz" \
			"https://github.com/openzfs/zfs/releases/download/$ZFS_VER/$ZFS_VER.tar.gz"
	fi
	tar xzf "$ZFS_VER.tar.gz"
fi
cd "$ZFS_VER"

echo
echo "== 3/5 打补丁（幂等）=="
for p in "$HERE/../patches/zfs"/*.patch; do
	[ -e "$p" ] || continue
	if patch -p1 --dry-run -s -f <"$p" >/dev/null 2>&1; then
		patch -p1 -s <"$p" && echo "  已应用 $(basename "$p")"
	else
		echo "  跳过（已应用或已改）: $(basename "$p")"
	fi
done

echo
echo "== 4/5 configure + 编译 =="
export ARCH=arm64
export CROSS_COMPILE
export PATH="$BINUTILS:$PATH"
CC=aarch64-linux-gnu-gcc ./configure \
	--host=aarch64-linux-gnu --build=x86_64-pc-linux-gnu \
	CC=aarch64-linux-gnu-gcc --with-config=kernel \
	--with-linux="$KTREE" --with-linux-obj="$KTREE" \
	--disable-pyzfs >"$WORK/configure.log" 2>&1 || {
	die "configure 失败，看 $WORK/configure.log"
}
make -j"$(nproc)" >"$WORK/make.log" 2>&1 || die "编译失败，看 $WORK/make.log"
ls -la module/spl.ko module/zfs.ko
echo "  vermagic: $(modinfo -F vermagic module/zfs.ko 2>/dev/null || strings module/zfs.ko | grep -m1 '^vermagic=')"

[ "${1:-}" = "--build-only" ] && exit 0

echo
echo "== 5/5 安装到板子 =="
"$TOOLS_DIR/brd-ssh.sh" put module/zfs.ko /tmp/zfs.ko
"$TOOLS_DIR/brd-ssh.sh" put module/spl.ko /tmp/spl.ko
"$TOOLS_DIR/brd-ssh.sh" sudo "R=\$(uname -r); D=/usr/lib/modules/\$R/extra
	mkdir -p \"\$D\"
	cp /tmp/zfs.ko /tmp/spl.ko \"\$D\"/
	chown root:root \"\$D\"/*.ko; chmod 644 \"\$D\"/*.ko
	depmod -a \"\$R\"
	printf '#Load zfs.ko at boot (CM360: 由本仓库 scripts/build-zfs.sh 编出)\nzfs\n' > /etc/modules-load.d/trim-zfs.conf
	modprobe zfs && echo 'modprobe zfs ✔'
	echo \"内核模块: \$(cat /sys/module/zfs/version)\"
	zpool version | head -2"
echo
echo "完成。fnOS 面板里的\"ZFS 型存储空间\"现在应该可用了。"
