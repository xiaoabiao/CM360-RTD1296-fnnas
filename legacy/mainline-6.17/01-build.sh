#!/bin/bash
# 01 —— 配置内核 + 编译 cm360.dtb + 编译 Image
#
# 配置基线是 ktree 里已有的 arm64 defconfig（已用 aarch64-linux-gcc 16.2.0 生成）。
# 只改 5 个点，每条都有明确理由：
#
#   1. VA_BITS 52 -> 48
#      A53 是 ARMv8.0，没有 LVA。虽然 Kconfig 说 52 位是"运行时回落"，
#      bring-up 阶段没必要留这个变量，直接钉死 48。
#   2. PA_BITS 52 -> 48   同上。
#   3. RANDOMIZE_BASE off
#      KASLR 关掉后 oops 里的地址就是链接地址，配合内置 KALLSYMS 能直接对出函数名。
#   4. DEBUG_INFO off
#      defconfig 打开 DEBUG_INFO + REDUCED，会拖慢编译并让 vmlinux 涨到几百 MB。
#      Image 本身不带调试信息，内核 oops 靠 KALLSYMS 出函数名就够了。
#   5. CMDLINE_EXTEND + 内置 cmdline（保命项）
#      不管 u-boot 传了什么、或者什么都没传，earlycon + console 一定生效。
#      bring-up 时"串口一个字节都不出"是最难查的故障，这条直接干掉它。
#      keep_bootcon 保证真正的 8250 驱动接管失败时 boot console 仍然留着手。

set -e
cd "$(dirname "$0")"
source "$(dirname "$0")/lib/env.sh"
env_check

DTB_REL=arch/arm64/boot/dts/realtek/cm360.dtb

echo "== 1/6 把 cm360.dts 放进内核树 =="
cp -v "$BOARD_DIR/legacy/cm360.dts" "$KTREE/arch/arm64/boot/dts/realtek/cm360.dts"
MK="$KTREE/arch/arm64/boot/dts/realtek/Makefile"
if ! grep -q "cm360.dtb" "$MK"; then
	echo 'dtb-$(CONFIG_ARCH_REALTEK) += cm360.dtb' >> "$MK"
fi
grep -n "cm360" "$MK"

echo
echo "== 2/6 调整 .config =="
cd "$KTREE"
# 注意：scripts/config 用了 bash 数组与 [[ ]]，不能用 sh(dash) 跑
bash ./scripts/config --file .config \
	-d RANDOMIZE_BASE \
	-d DEBUG_INFO_DWARF_TOOLCHAIN_DEFAULT -e DEBUG_INFO_NONE \
	-d ARM64_VA_BITS_52   -e ARM64_VA_BITS_48 \
	-d ARM64_PA_BITS_52   -e ARM64_PA_BITS_48 \
	-e CMDLINE_BOOL       -d CMDLINE_FORCE -e CMDLINE_EXTEND \
	--set-str CMDLINE "earlycon=uart8250,mmio32,0x98007800,115200 console=ttyS0,115200 keep_bootcon loglevel=8"

echo "== 3/6 olddefconfig =="
make -s ARCH=$ARCH CROSS_COMPILE=$CROSS_COMPILE olddefconfig

echo "---- 关键配置复核 ----"
grep -E "^CONFIG_(ARM64_VA_BITS=|ARM64_PA_BITS=|RANDOMIZE_BASE=|DEBUG_INFO=|DEBUG_INFO_NONE=|CMDLINE_BOOL=|CMDLINE_EXTEND=|SERIAL_8250_CONSOLE=|ARM_ARCH_TIMER=|ARM_GIC=|ARCH_REALTEK=)" .config | sort
grep '^CONFIG_CMDLINE=' .config

echo
echo "== 4/6 编译 dtb =="
if [ ! -f "$DTB_REL" ]; then
	make -j"$JOBS" ARCH=$ARCH CROSS_COMPILE=$CROSS_COMPILE "$DTB_REL" 2>&1 | tail -8 || true
fi
if [ ! -f "$DTB_REL" ]; then
	echo "单目标编译没产出，退回 make dtbs"
	make -j"$JOBS" ARCH=$ARCH CROSS_COMPILE=$CROSS_COMPILE dtbs 2>&1 | tail -5
fi
[ -f "$DTB_REL" ] || die "dtb 编译失败，未生成 $DTB_REL"
cp -v "$DTB_REL" "$OUT/cm360.dtb"

echo
echo "== 5/6 反编译校验 dtb =="
./scripts/dtc/dtc -I dtb -O dts -o "$OUT/cm360.dts.roundtrip" "$OUT/cm360.dtb"
echo "-- memory / chosen --"
grep -B1 -A6 "memory@1f000" "$OUT/cm360.dts.roundtrip"
grep -A6 "chosen {" "$OUT/cm360.dts.roundtrip"
echo "-- enable-method 出现次数（预期 0）: $(grep -c 'enable-method' "$OUT/cm360.dts.roundtrip" || true)"
echo "-- watchdog --"
grep -A4 "watchdog@680" "$OUT/cm360.dts.roundtrip"
echo "-- uart0 --"
grep -A7 "serial@800" "$OUT/cm360.dts.roundtrip"

echo
echo "== 6/6 编译 Image =="
make -j"$JOBS" ARCH=$ARCH CROSS_COMPILE=$CROSS_COMPILE Image 2>&1 | tail -20
cp -v arch/arm64/boot/Image "$OUT/Image"

echo
echo "==== 产物 ===="
ls -la "$OUT/cm360.dtb" "$OUT/Image"
echo "内核版本串: $(strings "$OUT/Image" | grep -m1 'Linux version' || true)"
