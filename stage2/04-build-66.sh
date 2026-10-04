#!/bin/bash
# 04 —— 在 XpressReal 6.6 树上配置 + 编译 Image + rtd1296-cm360.dtb（A′ 路线）
#
# 与 01-build.sh 的区别：
#   01 用的是 ~/.cache/cm360-bringup/ktree（6.17 主线），基线是 arm64 defconfig。
#   04 用的是 ~/.cache/rtd1296/xpressreal-linux（厂商 6.6.54 全家桶树）。
#
# ★ 基线选择（重要）：**不抄 T3 的 rtd16xxb_defconfig**。
#   那份打开了一堆 T3 专属东西（DRM_RTK / SND_SOC_REALTEK / RTK_NPUPP /
#   PCIE_RTD / REGULATOR_APW8889 / CHARGER_RTD1XXX），对 RTD1296 都是雷。
#   改用 arm64 主线 defconfig —— 它已被 stage2 实证能在这块板上启动 ——
#   只在其上加 6 个 Realtek 符号。配置小、编译快、CPU/GIC/串口侧零变量。
#
# 加的 Realtek 符号及依赖理由：
#   ARCH_REALTEK        编 rtd1296-cm360.dtb 的前提（只 select RESET_CONTROLLER，无副作用）
#   ARCH_RTD129x        129x 平台符号，rtkemmc/lockapi 都以它为门（2026-10-05 加）
#   MMC_RTK_EMMC        eMMC —— ★ 2026-10-05 换驱动。
#                       旧：MMC_DW_CQE + MMC_DW_CQE_RTK（16xxb 的 dw_mmc_cqe-rtk.c）。
#                       板上 emmcprobe 转储证明它写的 pad 寄存器 0x50c/0x550/
#                       0x554/0x558/0x55c 在 1296 上全是 deadbeef（偏移不存在）
#                       → 卡永不回话。现改用 jjm2473/rtd1295-next 为 1295/1296
#                       专写的 drivers/mmc/host/rtkemmc.c
#                       （compatible "realtek,rtd1295-emmc"）。
#                       选型依据见 rtd1296-cm360.dts 的 emmc 节点注释与
#                       patches/0002-emmc-rtkemmc.patch。
#   REALTEK_EMMC_LOCKAPI  rtkemmc 依赖的 DBG_PORT 硬件锁
#                       （drivers/soc/realtek/rtd129x/rtd129x_lockapi.c）
#   MMC_RTK_SDMMC       SD 卡
#   AHCI_RTK            SATA（select PHY_RTK_SATA / SATA_HOST）
#   R8169SOC            GMAC（depends on ARCH_REALTEK，select CRC32 / MII）
#   COMMON_CLK_RTD1295  CRT/ISO 时钟复位（default y，这里显式钉住以便复核）
#
# 再叠加 stage2 已实证的 5 点调整（理由见 01-build.sh 头部注释）。

set -e
cd "$(dirname "$0")"
source ./env.sh

KTREE66=/home/xiaoabiao/.cache/rtd1296/xpressreal-linux
DTB_NAME=rtd1296-cm360.dtb
# ★ 用【绝对】路径，不要相对路径。
#   踩过的坑：DTB_ONLY=1 时会跳过下面的 `cd "$KTREE66"`，于是相对路径
#   arch/arm64/boot/dts/realtek/xxx.dtb 会被解析成 stage2/arch/... ——
#   rm 删不到、[ -f ] 断言也必然失败，报出"dtb 编译失败：...不存在"，
#   而其实 make 已经把 dtb 正常编出来了（白查一轮）。
DTB_REL="$KTREE66/arch/arm64/boot/dts/realtek/$DTB_NAME"

die() { echo "ERROR: $*" >&2; exit 1; }
[ -d "$KTREE66" ] || die "6.6 树不存在: $KTREE66"
mkdir -p "$OUT" "$S2/logs"

k66() { make -C "$KTREE66" ARCH=$ARCH CROSS_COMPILE=$CROSS_COMPILE "$@"; }

# ★ 只重编 dtb：DTB_ONLY=1 ./04-build-66.sh
#   理由：只改 DTS 时（像给 uart0 补 clocks / 加 iso_irq_mux 这种）
#   步骤 2~4 的 defconfig + scripts/config 叠加和步骤 7 的 Image 编译
#   都纯粹是浪费 —— DTS 不参与内核二进制的产出。
#   跳过它们，只跑 1（拷 DTS）/5（编 dtb）/6（回读校验），几秒钟出结果。
#   注意：改的是 rtd1296-cm360.dts 以外的东西（.config 相关）时**不要**用这个开关。
DTB_ONLY="${DTB_ONLY:-0}"

echo "== 0/7 环境自检 =="
echo "  6.6 树 : $KTREE66"
echo "  工具链 : $($TC/aarch64-linux-gcc -dumpversion 2>/dev/null)"
echo "  dtc    : $("$KTREE/scripts/dtc/dtc" --version 2>/dev/null | head -1)"
echo "  模式   : $( [ "$DTB_ONLY" = 1 ] && echo '仅编 dtb（DTB_ONLY=1）' || echo '全量（config + dtb + Image）' )"

echo
echo "== 1/7 确认板级 DTS 就位 =="
cp -v "$S2/rtd1296-cm360.dts" "$KTREE66/arch/arm64/boot/dts/realtek/rtd1296-cm360.dts"
MK="$KTREE66/arch/arm64/boot/dts/realtek/Makefile"
grep -q "rtd1296-cm360.dtb" "$MK" || echo "dtb-\$(CONFIG_ARCH_REALTEK) += rtd1296-cm360.dtb" >> "$MK"
grep -n "rtd1296-cm360" "$MK"

echo
echo "== 1.5/7 应用内核补丁（stage2/patches/*.patch，幂等）=="
"$S2/apply-kernel-patches.sh"

if [ "$DTB_ONLY" = 1 ]; then
	echo "== 2~4/7 跳过（DTB_ONLY=1：沿用现有 .config，不重跑 defconfig/config 叠加）=="
	echo "  现有 .config 关键项："
	for k in ARCH_REALTEK COMMON_CLK_RTD1295 R8169SOC REALTEK_DHC_INTC SERIAL_8250_DW; do
		v=$(grep -E "^CONFIG_$k=" "$KTREE66/.config" | head -1 || true)
		printf "    %-24s %s\n" "$k" "${v:-★未设置★（.config 可能还没生成过，先跑一次全量）}"
	done
else

echo
echo "== 2/7 生成 .config（arm64 主线 defconfig 为基线）=="
k66 defconfig >/dev/null

echo
echo "== 3/7 叠加 Realtek 符号 + stage2 已验证的 5 点调整 =="
cd "$KTREE66"
# scripts/config 用了 bash 数组与 [[ ]]，必须用 bash 跑
# ★ -k（--keep-case）只作用于"下一个符号"：ARCH_RTD129x 末尾是小写 x，
#   而 scripts/config 默认会把符号名全大写（→ ARCH_RTD129X，另一个符号），
#   不加 -k 就会静默设置错符号、ARCH_RTD129x 永远 n，MMC_RTK_EMMC 连带
#   因为 depends 不满足而彻底不在 .config 里出现（本轮踩过）。
bash ./scripts/config --file .config \
	-e ARCH_REALTEK \
	-k -e ARCH_RTD129x \
	-e COMMON_CLK_RTD1295 \
	-e REALTEK_EMMC_LOCKAPI \
	-e MMC_RTK_EMMC -e MMC_RTK_SDMMC \
	-e AHCI_RTK \
	-e R8169SOC \
	-d RANDOMIZE_BASE \
	-d DEBUG_INFO_DWARF_TOOLCHAIN_DEFAULT -e DEBUG_INFO_NONE \
	-d ARM64_VA_BITS_52 -e ARM64_VA_BITS_48 \
	-d ARM64_PA_BITS_52 -e ARM64_PA_BITS_48 \
	-e CMDLINE_BOOL -d CMDLINE_FORCE -e CMDLINE_EXTEND \
	--set-str CMDLINE "earlycon=uart8250,mmio32,0x98007800,115200 console=ttyS0,115200 keep_bootcon loglevel=8 ignore_loglevel"

# ★★ 2026-10-05：eMMC 驱动从 dw_mmc_cqe-rtk.c 换成 rtkemmc.c ★★
#   第 3 次上板用 emmcprobe 转储寄存器，发现 16xxb 驱动写的 pad 控制寄存器
#   （0x50c DQ_CTRL_SET / 0x550 CMD_CTRL_SET / 0x554 WCMD / 0x558 RCMD /
#    0x55c PLL_STATUS）在 RTD1296 上全部读回 deadbeef —— 那些偏移在 1295
#   寄存器地图里根本不存在（见 reg_mmc.h）。所以那条路是死的。
#   改用 jjm2473/rtd1295-next（Linux 5.9）为 rtd1295/1296 专写的
#   drivers/mmc/host/rtkemmc.c（compatible "realtek,rtd1295-emmc"）。
#   ⇒ MMC_DW_CQE / MMC_DW_CQE_RTK 不再需要，明确关掉（它们和主线的
#     dw_mmc.o/dw_mmc-pltfm.o 符号同名，关掉后连 MMC_DW 都不必再点名关了，
#     但保留下面 -d MMC_DW 一行做双保险）。
bash ./scripts/config --file .config \
	-d MMC_DW_CQE -d MMC_DW_CQE_RTK -d MMC_DW_CQE_RTK13XX

# ★ 关掉厂商树里跟 6.6 API 脱节的驱动
#   RTK_CPU_VOLT_SEL（drivers/soc/realtek/cpudvfs/rtk_cpu_volt_sel.c）
#     它的 Kconfig 是 `default y`（depends on PM_OPP），所以 olddefconfig 会
#     自动把它打开；但源码还按老 API 写：
#         opp_table = dev_pm_opp_set_prop_name(dev, prop_name);   // 期望 struct opp_table*
#         dev_pm_opp_put_prop_name(opp_table);
#     6.6 里这两个函数已改成返回/接收 `int token`：
#         include/linux/pm_opp.h: static inline void dev_pm_opp_put_prop_name(int token)
#     于是报 -Wint-conversion 两条 error，编不过。
#     这是厂商树自己的 API 漂移，跟我们移植的外设无关；bring-up 阶段用不到
#     CPU 调压（也不该在没摸清 regulator 之前就让它动 CPU 电压）。
bash ./scripts/config --file .config -d RTK_CPU_VOLT_SEL

# ★ 关掉厂商树里被"脏回移"打坏的驱动
#   RPMSG_QCOM_GLINK（drivers/rpmsg/qcom_glink_native.c）
#     厂商把 6.7 才引入的 rpmsg_endpoint_ops.rx_done 硬回移进 6.6，但没回移干净：
#       1557 行是 `+	.rx_done = qcom_glink_rx_done,`   —— 行首那个 '+' 是打补丁
#             没剥掉的行首符号，gcc 直接 "expected expression before '.' token"
#       618 行调用 qcom_glink_send_rx_done()，而这棵树里压根没有这个函数
#             定义 → implicit declaration
#     跟 RTD1296 毫无关系（高通 GLINK 是手机 SoC 的核间通信），关掉即可。
bash ./scripts/config --file .config -d RPMSG_QCOM_GLINK -d RPMSG_QCOM_GLINK_RPM

# ★ 关掉厂商那份 TEE fork（否则链接期符号撞车）
#   drivers/soc/realtek/common/rtk_tee/Kconfig 里的 menuconfig REALTEK_TEE 是
#   `default y`，而且**没有** depends on TEE —— 于是它和主线 drivers/tee/
#   同时被编进去，两边都定义了 tee_shm_get_va / tee_shm_put / tee_shm_get_fd …
#   ld 报一串 "multiple definition of ... first defined here"：
#       drivers/tee/tee_shm.o: multiple definition of `tee_shm_get_va';
#       drivers/soc/realtek/common/rtk_tee/tee_shm.o: first defined here
#   这是厂商把整个 TEE 子系统 vendored 一份又没做成二选一导致的打包 bug。
#   bring-up 不需要 TEE（原厂 DTB 里只有个 tee@10100000 保留内存区，
#   没有需要我们驱动的 tee 设备）。
bash ./scripts/config --file .config -d REALTEK_TEE -d COMMON_CLK_REALTEK_TEE

# ★ 关掉与厂商 fork "同名符号" 的主线驱动（否则 ld 报 multiple definition）
#   厂商在 realtek 目录下 fork 了几个主线驱动，符号名跟主线一模一样：
#     drivers/clk/realtek/clk-regmap-mux.o / clk-regmap-gate.o
#         ↔ drivers/clk/meson/clk-regmap.o      （clk_regmap_mux_ops / gate_ops …）
#     drivers/clk/realtek/clk-pll.o
#         ↔ drivers/clk/qcom/clk-pll.o          （clk_pll_ops）
#     drivers/mmc/host/dw_mmc_cqe.o / dw_mmc_cqe-pltfm.o
#         ↔ drivers/mmc/host/dw_mmc.o / dw_mmc-pltfm.o
#           （dw_mci_probe / dw_mci_remove / dw_mci_pltfm_register …）
#   厂商自己那份 defconfig（rtd13xxe_defconfig）里，这些主线驱动**本来就是关的**
#   （它只有 CONFIG_MMC_DW_CQE / MMC_DW_CQE_RTK，没有 CONFIG_MMC_DW）。
#   我们继承的是 arm64 通用 defconfig，所以得手动关掉。
#
#   为什么关 ARCH_MESON / ARCH_QCOM 而不是逐个关 clk 符号：
#     这两家的 clk 家族都 depends on ARCH_<平台> || COMPILE_TEST，
#     关掉平台就整族级联关掉了，省事且彻底。
#     MMC_DW 没有 ARCH 依赖，必须单独点名关（子驱动 depend on MMC_DW，会级联）。
bash ./scripts/config --file .config \
	-d ARCH_MESON -d ARCH_QCOM \
	-d MMC_DW

# ★ 关掉厂商那些 "default y 但依赖没跟着开" 的驱动
#   RTK_IMAGE_CODEC（drivers/soc/realtek/common/jdi/rtk-jpu.o）
#     drivers/soc/realtek/Kconfig 里它是 `default y` 且**没有任何 depends**，
#     于是 olddefconfig 自动打开；但 jpu.o 引用的 rheap_dma_ops /
#     rheap_setup_dma_pools 定义在媒体堆（rtk_media_heap）里，
#     那个符号默认不开 → 最后的 vmlinux 链接报：
#         drivers/soc/realtek/common/jdi/jpu.o: undefined reference to `rheap_dma_ops'
#     JPU（JPEG 编解码单元）是厂商媒体 SoC 的东西，NAS 场景用不到，关掉。
bash ./scripts/config --file .config -d RTK_IMAGE_CODEC

# gcc 16 编 6.6 内核大概率会撞上新增警告；bring-up 阶段不要被 WERROR 卡住
bash ./scripts/config --file .config -d WERROR 2>/dev/null || true

echo "== 4/7 olddefconfig =="
make -s ARCH=$ARCH CROSS_COMPILE=$CROSS_COMPILE olddefconfig

echo "---- 关键配置复核（全部应为 y）----"
for k in ARCH_REALTEK ARCH_RTD129x COMMON_CLK_RTD1295 RTK_CLK_COMMON \
	MMC_RTK_EMMC REALTEK_EMMC_LOCKAPI \
	MMC_RTK_SDMMC AHCI_RTK PHY_RTK_SATA R8169SOC MII CRC32 \
         SERIAL_8250 SERIAL_8250_CONSOLE SERIAL_8250_DW \
         ARM_GIC ARM_ARCH_TIMER RESET_CONTROLLER \
         REALTEK_DHC_INTC IRQ_DOMAIN \
         ARM64_VA_BITS_48; do
	# ★ set -e 下 grep 未命中会返回 1 直接打死脚本 —— || true 兜住
	#   （arm64 没有 CMDLINE_BOOL/CMDLINE_EXTEND，别再往这个列表里加了）
	v=$(grep -E "^CONFIG_$k=" .config | head -1 || true)
	printf "  %-24s %s\n" "$k" "${v:-★未设置★}"
done
echo "  --- 应当关闭的 ---"
for k in RANDOMIZE_BASE ARM64_VA_BITS_52 DEBUG_INFO DEBUG_INFO_DWARF_TOOLCHAIN_DEFAULT \
	 WERROR MMC_DW MMC_DW_CQE MMC_DW_CQE_RTK MMC_DW_CQE_RTK13XX; do
	v=$(grep -E "^CONFIG_$k(=| is not set)" .config | head -1 || true)
	printf "  %-24s %s\n" "$k" "${v:-★未提及★}"
done
echo "  CONFIG_CMDLINE = $(grep '^CONFIG_CMDLINE=' .config)"

fi   # ← DTB_ONLY

echo
echo "== 5/7 编译 dtb =="
# ★ 先串行把 kbuild 自带的 host 版 dtc 编出来。
#   `make <某个.dtb>` 会顺带 build scripts_dtc；在 -j 并行下 scripts/dtc 目录
#   内部（dtc-parser.tab.h / checks.o 等）有已知竞态，新树上第一次跑会随机炸：
#       make[2]: *** [scripts/Makefile.host:131：scripts/dtc/checks.o] 错误 1
#   串行编一次（幂等，编好就跳过）就绕过去了。
k66 -j1 scripts_dtc 2>&1 | tail -3 || true

# ★★ 单 dtb 目标必须写成 **相对 dtstree 的路径**，不能给全路径！
#   Makefile:1390 的规则是：
#       %.dtb: dtbs_prepare
#           $(Q)$(MAKE) $(build)=$(dtstree) $(dtstree)/$@
#   其中 dtstree = arch/arm64/boot/dts。你要是传
#       arch/arm64/boot/dts/realtek/rtd1296-cm360.dtb
#   它就会拼成 arch/arm64/boot/dts/arch/arm64/boot/dts/realtek/... → “没有规则”。
#   正确目标：realtek/rtd1296-cm360.dtb
DTB_TARGET="realtek/$DTB_NAME"
rm -f "$DTB_REL"
# ★ 全量落盘再 tail（和下面 Image 一样的教训）：
#   dtb 预处理会打一堆 rtd1295-reset.h / realtek,rtd1295.h 的宏重定义 warning，
#   直接 `| tail -15` 的话真报错会被这些 warning 顶出窗口，看不见。
DTBLOG="$S2/logs/dtb-66.log"
if ! k66 -j"$JOBS" "$DTB_TARGET" > "$DTBLOG" 2>&1; then
	echo "---- dtb 编译报错（末尾 20 行；完整日志 $DTBLOG）----"
	grep -nE 'Error|error:|错误 [0-9]' "$DTBLOG" | head -10 || true
	tail -20 "$DTBLOG"
	die "dtb 编译失败"
fi
[ -f "$DTB_REL" ] || die "dtb 编译失败：$DTB_REL 不存在（make 返回 0 但产物没生成）"
cp -v "$DTB_REL" "$OUT/$DTB_NAME"

echo
echo "== 6/7 反编译校验 dtb =="
"$KTREE/scripts/dtc/dtc" -I dtb -O dts -o "$OUT/$DTB_NAME.roundtrip.dts" "$OUT/$DTB_NAME"
echo "-- GMAC 节点 --"
grep -A16 'r8169soc@16000' "$OUT/$DTB_NAME.roundtrip.dts" || echo "★ 没找到 GMAC 节点"
echo "-- 时钟控制器 --"
grep -c 'crt-clk\|iso-clk' "$OUT/$DTB_NAME.roundtrip.dts"
echo "-- memory --"
grep -A3 'memory@1f000' "$OUT/$DTB_NAME.roundtrip.dts"

echo
echo "-- 串口控制台 uart0（应当有 clocks 与 interrupt-parent 两项）--"
grep -A12 'serial@800' "$OUT/$DTB_NAME.roundtrip.dts" | head -16
echo "-- ISO 中断复用器节点 --"
grep -A9 'iso_irq_mux {' "$OUT/$DTB_NAME.roundtrip.dts" || echo "★ 没找到 iso_irq_mux"
echo "-- 27MHz 固定时钟（应有两个：osc27M 大写 / osc27m 小写）--"
grep -n 'clock-output-names = "osc27' "$OUT/$DTB_NAME.roundtrip.dts"

echo
echo "-- ★ 硬断言：uart0 三项必须齐（clocks / 中断父 / 中断号）--"
#   注意第 2 项：我们用的是 interrupts-extended（每个中断自带父 phandle），
#   这种写法**不会有** interrupt-parent —— 所以两者取其一即可，别只查
#   interrupt-parent 而误报"缺失"（第一次就是这么错杀自己的）。
UART_BLOCK="$(grep -A14 'serial@800' "$OUT/$DTB_NAME.roundtrip.dts" | head -15)"
for f in clocks; do
	printf '%s\n' "$UART_BLOCK" | grep -q "$f" \
		&& printf '  %-20s ✔\n' "$f" \
		|| { printf '  %-20s ✘ 缺失\n' "$f"; die "uart0 缺 $f（时钟没认领 → clk_disable_unused 会把串口 gate 掉）"; }
done
if printf '%s\n' "$UART_BLOCK" | grep -qE 'interrupts-extended|interrupt-parent'; then
	printf '  %-20s ✔\n' '中断父(extended/parent)'
else
	printf '  %-20s ✘ 缺失\n' '中断父(extended/parent)'
	die "uart0 没有中断父 —— 8250 会退回纯轮询，input overrun 会回来"
fi
# 中断号：interrupts-extended = <&iso_irq_mux 2> 会被 dtc 展开成 <phandle hwirq>，
# 所以"两个及以上数字"才算真有中断号（只有一个 phandle 是残的）。
IRQLINE="$(printf '%s\n' "$UART_BLOCK" | grep -m1 -E 'interrupts-extended|interrupts' || true)"
IRQNUM=$(printf '%s\n' "$IRQLINE" | grep -oE '0x[0-9a-f]+|[0-9]+' | wc -l)
if [ "$IRQNUM" -ge 2 ]; then
	printf '  %-20s ✔ (%s 个数字)\n' '中断号' "$IRQNUM"
else
	printf '  %-20s ✘ (%s 个数字)\n' '中断号' "$IRQNUM"
	die "uart0 的中断描述不完整：$IRQLINE"
fi
printf '%s\n' "$UART_BLOCK" | grep -E 'clocks|interrupt' | sed 's/^/    /'

echo
echo "-- ★ 硬断言：SATA 节点必须齐（status / satawrap / clocks / resets / 双端口）--"
#   这些全部来自驱动源码的硬性要求（见 DTS §5 注释）：
#     - realtek,satawrap 指到带 reg 的 syscon，否则 "failed to remap sata wrapper reg"
#     - 每个 sata-port 子节点必须有 reg（缺→-EINVAL）和 resets（缺→-ENOENT）
#     - clocks/resets 的数量和值由官方 1296 DTSI 金坐标决定
SATA_BLOCK="$(grep -A40 'sata@3f000' "$OUT/$DTB_NAME.roundtrip.dts" | head -42)"

# 1) 节点存在且 status = "okay"
if printf '%s\n' "$SATA_BLOCK" | grep -q 'sata@3f000'; then
	printf '  %-24s ✔\n' 'sata@3f000'
else
	printf '  %-24s ✘ 缺失\n' 'sata@3f000'
	die "dtb 里没有 sata@3f000 节点（DTS §5 没生效？）"
fi
if printf '%s\n' "$SATA_BLOCK" | grep -q 'status = "okay"'; then
	printf '  %-24s ✔\n' 'status=okay'
else
	printf '  %-24s ✘ 不是 okay\n' 'status=okay'
	die "sata 节点 status 不是 okay —— 驱动不会 probe"
fi

# 2) realtek,satawrap 存在
if printf '%s\n' "$SATA_BLOCK" | grep -q 'realtek,satawrap'; then
	printf '  %-24s ✔\n' 'realtek,satawrap'
else
	printf '  %-24s ✘ 缺失\n' 'realtek,satawrap'
	die "sata 缺 realtek,satawrap → device_node_to_regmap 失败，probe 直接返回"
fi

# 3) wrap syscon 节点存在且在 rbus 0x3ff60（官方 1296 布局）
if grep -q 'sata-wrap@3ff60' "$OUT/$DTB_NAME.roundtrip.dts"; then
	printf '  %-24s ✔\n' 'sata-wrap@3ff60'
else
	printf '  %-24s ✘ 缺失\n' 'sata-wrap@3ff60'
	die "缺 wrap syscon（应为 rbus 0x3ff60 = 0x9803FF60，官方 1296 PHY 基址）"
fi

# 4) clocks 数量：官方 1296 是 4 个（sata_0/alive_0 + sata_1/alive_1）
SATA_CLKLINE="$(printf '%s\n' "$SATA_BLOCK" | grep -m1 'clocks = ' || true)"
SATA_CLKNUM=$(printf '%s\n' "$SATA_CLKLINE" | grep -oE '0x[0-9a-f]+|[0-9]+' | wc -l)
if [ "$SATA_CLKNUM" -ge 8 ]; then
	printf '  %-24s ✔ (%s 个数字 = 4 个时钟)\n' 'clocks' "$SATA_CLKNUM"
else
	printf '  %-24s ✘ (%s 个数字，期望 8)\n' 'clocks' "$SATA_CLKNUM"
	die "SATA clocks 不完整：$SATA_CLKLINE"
fi

# 5) 节点级 resets 数量：官方是 4 个（sata_0/phy_0 + sata_1/phy_1）
SATA_RSTLINE="$(printf '%s\n' "$SATA_BLOCK" | grep -m1 'resets = ' || true)"
SATA_RSTNUM=$(printf '%s\n' "$SATA_RSTLINE" | grep -oE '0x[0-9a-f]+|[0-9]+' | wc -l)
if [ "$SATA_RSTNUM" -ge 8 ]; then
	printf '  %-24s ✔ (%s 个数字 = 4 个复位)\n' 'resets(节点级)' "$SATA_RSTNUM"
else
	printf '  %-24s ✘ (%s 个数字，期望 8)\n' 'resets(节点级)' "$SATA_RSTNUM"
	die "SATA 节点级 resets 不完整：$SATA_RSTLINE"
fi

# 6) 两个 sata-port 子节点，各自带 reg 与 resets
for port in 0 1; do
	PB="$(printf '%s\n' "$SATA_BLOCK" | grep -A4 "sata-port@$port" | head -5)"
	if [ -z "$PB" ]; then
		printf '  %-24s ✘ 缺失\n' "sata-port@$port"
		die "缺 sata-port@$port —— 该端口不会被初始化"
	fi
	if printf '%s\n' "$PB" | grep -q 'reg = ' && printf '%s\n' "$PB" | grep -q 'resets = '; then
		printf '  %-24s ✔ (reg+resets 齐)\n' "sata-port@$port"
	else
		printf '  %-24s ✘ 缺 reg 或 resets\n' "sata-port@$port"
		die "sata-port@$port 缺 reg（-EINVAL）或 resets（-ENOENT）→ probe 失败"
	fi
done
printf '%s\n' "$SATA_BLOCK" | grep -E 'clocks|resets|realtek,satawrap|sata-port|status' | sed 's/^/    /'

if [ "$DTB_ONLY" = 1 ]; then
	echo "== 7/7 跳过编译 Image（DTB_ONLY=1：DTS 不参与内核二进制）=="
	echo "  沿用现有 $OUT/Image-6.6 ：$(ls -la "$OUT/Image-6.6" 2>/dev/null | awk '{print $5" 字节"}' || echo '不存在')"
else

echo
echo "== 7/7 编译 Image =="
# 全量落盘再 tail —— 上一次用 `| tail -25` 把真报错截掉了，白跑一轮
IMGLOG="$S2/logs/image-66.log"
if ! k66 -j"$JOBS" Image > "$IMGLOG" 2>&1; then
	echo "---- Image 编译报错（尾部 30 行；完整日志 $IMGLOG）----"
	grep -nE 'error:|错误 [0-9]' "$IMGLOG" | head -15
	echo "   ..."
	tail -20 "$IMGLOG"
	die "Image 编译失败"
fi
cp -v "$KTREE66/arch/arm64/boot/Image" "$OUT/Image-6.6"

fi   # ← DTB_ONLY

echo
echo "==== 产物 ===="
ls -la "$OUT/$DTB_NAME" "$OUT/Image-6.6"
echo "内核版本串: $(strings "$OUT/Image-6.6" | grep -m1 'Linux version' || true)"
