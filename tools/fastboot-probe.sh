#!/bin/bash
# fastboot-probe.sh —— 探测本板 u-boot 的 USB fastboot 能力（线刷前置调查）
#
# 背景
# ----
# 板上 u-boot 的 help 里有：`fastboot- use USB Fastboot protocol`，
# 而且它的字符串里带一整套 Realtek OEM 命令：
#   fastboot oem set_flash_bootcode / set_load_kernel / set_load_dtb / set_load_rootfs
#   fastboot flash linuxKernel|kernelDT|kernelRootFS|system|data|cache|vendor ...
#   fastboot oem get_emmc_layout / get_part_info / get_fw_info / go_all / go_k / go_a
# 如果这条链路能用，7GiB 的 rootfs 走 USB 大约 3-6 分钟（TFTP 要 30 分钟），
# 而且不依赖网络稳定性。
#
# 用法
# ----
#   1) 用数据线把板子的 **OTG / Type-C / micro-USB** 口接到本机
#   2) 串口进 u-boot 提示符（开机 3 秒内按键），执行 `fastboot` 让它进入 fastboot 模式
#   3) 本机运行： ./tools/fastboot-probe.sh
#
# 脚本只做**只读探测**：列出设备、查询布局/分区/固件信息，不做任何写入。
set -u

FASTBOOT="$(command -v fastboot || echo "")"
[ -n "$FASTBOOT" ] || { echo "!! 本机没有 fastboot（apt install android-tools-fastboot）" >&2; exit 1; }
say() { echo "$@" ; }

say "=============================================="
say "探测板子 USB fastboot 能力（只读，不写入）"
say "=============================================="
say "fastboot: $FASTBOOT"

say ""
say "== 1) 设备是否可见 =="
if ! "$FASTBOOT" devices 2>&1 | tee /tmp/fb-dev.txt | grep -q .; then
	say "   ✗ 没看到 fastboot 设备。请确认："
	say "     · 板子的 OTG/Type-C 口已用数据线接到本机（不是只接电源）"
	say "     · 串口里已执行 fastboot 命令（u-boot 会打印一遍协议帮助）"
	say "     · lsusb 里能看到新增设备："
	lsusb 2>/dev/null | tail -5 | sed 's/^/       /'
	exit 1
fi
"$FASTBOOT" devices | sed 's/^/   ✔ /'

say ""
say "== 2) 查询 eMMC 布局与固件信息（决定后面用哪套刷写命令）=="
for c in "oem get_emmc_layout" "oem get_part_info" "oem get_fw_info"; do
	say "  $ fastboot $c"
	timeout 20 "$FASTBOOT" $c 2>&1 | head -20 | sed 's/^/     /'
done

say ""
say "== 3) 本机识别到的 USB 设备（留档）=="
lsusb 2>/dev/null | grep -iE "18d1|google|fastboot|0bda|realtek" | sed 's/^/   /' || true

say ""
say "== 结论怎么用 =="
cat <<'TXT'
   · 如果 get_emmc_layout 里出现了 linuxKernel / kernelDT / kernelRootFS 之类的分区名，
     那么可以用 `fastboot flash <名字> <文件>` 直接写 p1/p2（最快路径）。
   · 本机 eMMC 实测是 DOS/MBR 分区表、分区名是通用的 Boot，
     若上面查询显示没有这些名字，则改用 OEM 组合：
        fastboot oem set_load_kernel && fastboot boot <uImage>
        fastboot oem set_load_dtb    && fastboot boot <dtb>
        fastboot oem set_load_rootfs && fastboot boot <rootfs>
        fastboot oem go_all
   · 若 bootcode 需要重写（危险，先备份低区）：
        fastboot oem set_flash_bootcode && fastboot boot <bootcode 镜像>
TXT
