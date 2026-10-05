#!/bin/bash
# 25-deploy-modmeta.sh —— 把内核的**模块元数据**装到板子上（很关键，容易被忽略）
#
# 为什么需要它
# ------------
# 我们的内核是"全内置"构建（.ko 产出为 0），板上因此**没有 /lib/modules/<版本>/**。
# 于是 `modprobe <内置模块>` 一律失败：
#     modprobe: FATAL: Module zram not found in directory /lib/modules/6.6.54-...
# 而 fnOS 的一堆脚本就是靠 modprobe 判断可用性的（zramswap、ovs 等），
# 明明模块已经编进内核，服务照样起不来。
#
# 解法：把构建树里的 modules.builtin / modules.builtin.modinfo 拷到板上，
# 并在**板上**跑一次 depmod 生成 .bin 索引（kmod 只认索引，光有文本文件没用——
# 这条是实测踩出来的：先只拷文本，modprobe 依旧失败）。
#
# 用法：./25-deploy-modmeta.sh
HERE="$(cd "$(dirname "$0")" && pwd)"
set -e
cd "$HERE"
source "$HERE/lib/env.sh"
M="$OUT/modmeta"

[ -f "$KTREE/modules.builtin" ] || die "没有 $KTREE/modules.builtin（先跑 04-build-66.sh）"
mkdir -p "$M"
cp "$KTREE/modules.builtin" "$KTREE/modules.builtin.modinfo" "$M/"
touch "$M/modules.order"; : > "$M/modules.dep"

for f in modules.builtin modules.builtin.modinfo modules.order modules.dep; do
	"$TOOLS_DIR/brd-ssh.sh" put "$M/$f" "/tmp/$f"
done
"$TOOLS_DIR/brd-ssh.sh" sudo 'R=$(uname -r); mkdir -p /lib/modules/$R
	cp /tmp/modules.builtin /tmp/modules.builtin.modinfo /tmp/modules.order /tmp/modules.dep /lib/modules/$R/
	depmod -a "$R"
	echo "--- 验证 ---"
	for m in zram openvswitch overlay; do
		modprobe "$m" && echo "  modprobe $m  ✔" || echo "  modprobe $m  ✗"
	done'
