# RTD1296 主线驱动现状盘点

> 目标设备：**小睿 CM360**（Realtek RTD1296，4×Cortex-A53@1.5GHz + Mali-T820，2GB DDR4，8GB eMMC，PCIe，千兆网口）
> 目标系统：飞牛 fnOS ARM（要求主线 6.12.y / 6.18.y 内核 + btrfs + FilesACL 补丁）
> 盘点日期：2026-10-03
> 文档性质：移植可行性评估的**事实基础**。所有结论均有源码级证据，未采用二手资料推断。

---

## ⚠️ 勘误（2026-10-04 实测更新）

本报告基于**源码分析 + 二手资料**写成。后续拿到 CM360 的真实启动日志
（`stage0/阶段0-日志分析-shot_log_01.md`）后，**有三条结论被实测推翻**：

| # | 本报告原文 | 实测 |
|---|---|---|
| 1 | 接硬盘需要"PCIe 转双 SATA 卡" | **错**。SoC 有**原生双 SATA**（`ata1`/`ata2` @ MMIO `0x9803f000`，IRQ 12） |
| 2 | 打通 PCIe 是必需环节（约 1,858 行） | **不需要**。DSM 内核里完全没有 PCIe host bridge，PCIe 总线根本没启用 |
| 3 | 打断 u-boot autoboot 用回车 | **错**。实测提示语是 `Hit Esc or Tab key to enter console mode` |

因此第 5 章的路线图和第 6 章的工作量需按实测修正：

- **PCIe + SATA 从"移植 1,858 行"降级为"点亮已有原生双 SATA"**，阶段 4 大幅提前、难度大幅下降
- 需移植总量从 40,895 行降至约 **39,037 行**；MVP 阶段实际必须先搬的约 **3,000 行**（时钟 2,146 + pinctrl 933）
- 另有一条**新约束**：SPI NOR 只有 8 MB 且已被当前四个镜像占满约 7.4 MB，
  **阶段 1 应改用 u-boot 从 USB/SD 加载内核，不往 SPI 写入**（顺带排除变砖风险）

其余结论（时钟是最大阻塞、网卡是 SoC 内置 GMAC、USB3 驱动已在主线、上游已放弃该平台）**均被实测证实**。
详见 `stage0/阶段0-日志分析-shot_log_01.md`。

### 勘误补充（2026-10-04 第二份日志 —— u-boot 环境变量）

拿到 `stage0/阶段0-日志分析-shot_uboot_01.md`（u-boot `printenv` 全量）后，再补三条：

| # | 原判断 | 实测 |
|---|---|---|
| 4 | 阶段 1 建议"从 SD 卡 / U 盘起 rootfs" | **可能更省事**：u-boot **自带可用的网卡驱动**（`Net: Realtek PCIe GBE Family Controller` / `r8168#0`），且 `bootcmd` 里已在用 `ping`。**若支持 `tftpboot`，走 TFTP 灌内核，零介质** |
| 5 | 假设打断后可用标准 `bootm` 流程 | **要打问号**：`bootcmd` 走的是 Realtek 私有 **`rtkspi` + `lzmadec` + `go all`**；u-boot 版本 **2015.07 早于 `booti`（2016.05 引入）**，裸 `Image` 无法用 `booti` 启动 |
| 6 | 原生 SATA 直接点灯即可 | **需带 PHY 参数**：u-boot 用 `fdt set /sata@9803F000 tx-driving <2> / rx-sensitivity <2>` 动态改写设备树，**自研 dts 必须照抄这两个属性** |

另外拿到三条**硬约束**（写启动脚本时必看）：

- `bootdelay=0`，但 `Hit Esc or Tab key …` 的窗口**连打 Esc/Tab 能稳定抢到**（已两次复现）
- 内存加载地址：`fdt 0x01f00000` / `kernel 0x03000000` / `rootfs 0x02200000` / `audio 0x01b00000`；
  u-boot 把 `0x20000000-0x40000000` 映射为 **non-cached**，`rootfs_loadaddr` 就在里面 —— **沿用原厂地址最省心，不要自己改**
- SPI 占用率精确值：四个已知镜像 **7.25 MiB（90.6%）**，加盲区后 **99.2%**，剩余 68 KB ~ 772 KB
  → **"不写 SPI"的结论从"建议"升级为"必须"**

→ **阶段 1 的唯一未知项变成：这个 u-boot 支持哪些命令（`help`）。** 已备好 `probe` 模式一键探查。

### 勘误补充二（2026-10-04 第三批 —— u-boot `help` + 原厂 DTB 反解）

**u-boot 实测能力（`help` 全表）推翻了本报告的一条关键推断**：

| # | 原判断 | 实测 | 影响 |
|---|---|---|---|
| 7 | u-boot 版本 2015.07 早于 `booti`（2016.05 引入）→ 裸 arm64 `Image` 只能包成 uImage 走 `bootm`，或自写引导桩 | **错。`booti` 存在**（Realtek 自己 backport 了）：`booti [addr [initrd[:size]] [fdt]]` | **阶段 1 大幅简化**：直接 `booti` 裸 Image |
| 8 | 主线 rtd1296 能起 4 核 | **可疑**：主线 `rtd129x.dtsi`/`rtd1296.dtsi` 里 **完全没有 `enable-method` / `psci` / `spin-table`** | 必须自己补 CPU 启动方式，否则跑单核 |
| 9 | 中断直连 GIC | **错**：存在 **`Realtek,rtk-irq-mux`**（`intc@9801B000`，只因 GIC SPI 40/41 两条），大量外设中断汇聚于此（含 UART0） | 移植网卡/SATA/eMMC 必须一并处理 |
| 10 | watchdog 需移植（地址对得上） | **几乎白送**：主线 `realtek,rtd1295-watchdog` 地址 `0x98007680` 与原厂 `Realtek,rtk-watchdog` **完全一致** | 改一行 of_match |
| 11 | 复位控制器需移植 | **大部分白送**：主线 4 个 `snps,dw-low-reset`（crt +0x0/0x4/0x8/0x50）+ `iso_reset`(+0x88) 与原厂 5 个 `soft_reset*` **一一对应** | 工作量下调 |
| 12 | pinctrl 933 行可搬 | **比预期重**：厂商用**字符串引脚名 + `rtk119x,function` 功能名**（如 `pins = "mmc_data_3"`），主线用**数字 pinmux** | 需重做引脚编号表与功能表 |
| 13 | 备份需要设备 shell | **不需要**：`mmc read` + `tftpput` 就能把 SPI/eMMC 整机导出到 PC | 备份门槛大降 |
| 14 | PCIe 完全没启用 | **部分修正**：原厂 DTB **有** `pcie@9804E000` + `pcie2@9803B000` 节点（只是 DSM 内核没打印枚举日志） | 仍非必需（原生双 SATA 够用） |

**同时拿到了移植 CCF 最缺的那张图纸**（详见 `stage0/阶段0-完整实测报告.md` §3）：

- 原厂 DTB 完整反解 **2,077 行** → `stage0/original-dtb.dts.txt`
- **时钟树 24 个节点**：`osc27M`(27 MHz) → `spll`/`pll_bus`/`pll_bus_h`/`pll_ddsa`/`pll_ddsb`/`pll_vodma`/`pll_ve1`/`pll_ve2`/`pll_gpu`/`pll_acpu` → `clk_sys`/`clk_sysh`/`clk_ve*`/`clk_gpu`/`clk_vodma` + 3 个 `clk_enable` 寄存器
- **电源/门控树 73 个节点**（`realtek,powerctrl-simple` ×53、`sram` ×9、`once` ×7、`gpu-core` ×3），覆盖 ve1/2/3、jpeg、gpu、sata、nand、emmc、sdio、usb p0-p3、pcie1/2、**etn_gphy**、cbus、md、rsa、se 等
- **PLL 实测频率**（`bdinfo`）：SCPU 1600→800 MHz、ACPU 549、VCPU1 594、VCPU2 675、DDSA/B 432、BUS 256、BUS_H 459、GPU 449、VODMA 405；DDR 1866 MT/s
- **eMMC 分区表**：`uboot` 8 MiB + 三个 8 MiB + **两个 512 MiB（raid1 对）** + 一个 2.2 GiB，起始 LBA 0x8000

**阶段 1 路线因此收敛为**：`tftp` 灌内核 → `booti 0x03000000 - 0x01f00000`（备选 `bootr uz` 从 U 盘启动；兜底 `loady` 走串口）。

---

## 0. 结论摘要

| 问题 | 答案 |
|---|---|
| 主线支持 RTD1296 吗？ | **只支持到"能起串口"的量级**。有 UART / GIC / timer / PMU / watchdog / reset / GPIO(驱动在但没接 DTS)。 |
| 网卡怎么走？ | SoC 内置 **RTL8168 兼容 MAC** + 外置 **RTL8211** PHY。主线**完全没有**，厂商对应 `r8169soc_rtd119x.c`（7,779 行）。**Realtek 在 2020 年提过主线 RFC，从未合入。** |
| 最大阻塞是什么？ | **没有时钟驱动（CCF）**。主线只有一颗 27MHz 固定晶振，没有 PLL / 门控 / 分频。所有外设（eMMC、USB3、网卡、PCIe、SATA）都缺时钟树父节点。这是"第一块必须搬的砖"。 |
| 要搬多少代码？ | 核心外设 **约 40,895 行 / 19 个文件**（厂商 4.9.119 BSP）。 |
| 现实吗？ | 现实但周期长。**建议先做 MVP**：串口 + watchdog + GPIO + RTC + SD 卡启动 + USB 网卡。这条路径主线已有 6 个组件中的 5 个，是唯一"短平快"的切入点。 |

---

## 1. 盘点基准（可复现）

### 1.1 主线基准
| 项 | 值 |
|---|---|
| 仓库 | `https://github.com/torvalds/linux.git` |
| 版本 | **v7.3-rc5**（`git log -1` = `8623551 Merge tag 'input-for-v7.3-rc5'`） |
| 抓取方式 | `git clone --depth 1 --filter=blob:none --no-checkout` |

### 1.2 厂商基准
| 项 | 值 |
|---|---|
| 仓库 | `https://github.com/BPI-SINOVOIP/BPI-W2-bsp.git` |
| 内核 | `linux-rtk/`，**Linux 4.9.119**（Realtek 官方 BSP，SinoVoIP 发布） |
| 板级 | `rtd129x_bpi_defconfig`（`CONFIG_R8169SOC=y`、`CONFIG_R8168=y`、`CONFIG_R8169` 关闭） |
| 另一参考 | 群晖 GPL 源码 `linux-4.4.x`（RTD129x 版），toolchain `aarch64-unknown-linux-gnueabi-gcc 4.9.4` |

### 1.3 关键情报：SoC 代号
厂商 DTS 目录里 RTD1296 的板级文件名为 **`rtd-1296-saola-*`** —— **`saola` 就是 RTD1296 的 SoC 代号**（RTD1295 是 `giraffe`，RTD1294 是 `giraffe` 1GB 变体）。
自研板级 DTS 应以 `rtd-1296-saola-common.dtsi` 为蓝本，而不是主线那个只配了串口的 `rtd1296-ds418.dts`。

---

## 2. 主线现状总表

图例：✅ 完整可用 ｜ 🟡 驱动在主线但 DTS 未接 / 半成品 ｜ ❌ 完全缺失

| 子系统 | 主线 | 证据 | 缺什么 |
|---|---|---|---|
| CPU 四核 A53 | ✅ | `rtd1296.dtsi`：`cpu@0..3` = `arm,cortex-a53` | — |
| GIC-400 中断控制器 | ✅ | `rtd129x.dtsi`：`arm,gic-400` @ `ff011000` | — |
| ARMv8 架构定时器 | ✅ | `rtd1296.dtsi`：`arm,armv8-timer` 4 路 PPI | — |
| PMU 性能计数器 | ✅ | `arm,cortex-a53-pmu` + `interrupt-affinity` | — |
| 串口 UART0/1/2 | ✅ | `snps,dw-apb-uart` @ iso:0x800 / misc:0x200/0x400 | — |
| 看门狗 | ✅ | `realtek,rtd1295-watchdog` + `drivers/watchdog/rtd119x_wdt.c` | — |
| 复位控制器 | ✅（部分） | `snps,dw-low-reset` ×5（crt reset1-4 + iso_reset） | 部分复位域 |
| **时钟 CCF** | ❌ | 全树只有 `osc27M` = `fixed-clock` 27MHz；`drivers/clk/` **无 realtek 目录** | **PLL / 门控 / 分频 / DVFS 全套** |
| GPIO | 🟡 | `drivers/gpio/gpio-rtd.c` **已支持** `realtek,rtd1295-misc-gpio` 和 `realtek,rtd1295-iso-gpio` | 主线 DTS 未实例化 |
| PINMUX | ❌ | `drivers/pinctrl/realtek/` 只有 rtd1315e / rtd1319d / rtd1619b / rtd1625 | pinmux 配置全靠 bootloader 预设 |
| RTC | 🟡 | `drivers/rtc/rtc-rtd119x.c` 在主线 | 主线 DTS 无 RTC 节点 |
| **以太网 MAC** | ❌ | `NET_VENDOR_REALTEK` 是 `depends on PCI`；`drivers/net/ethernet/realtek/` 只有 r8169/r8125/rtase，**无 r8169soc** | 整个 MAC 驱动 |
| 以太网 PHY (RTL8211) | ✅ | `CONFIG_REALTEK_PHY=y`，`drivers/net/phy/realtek.c` | — |
| eMMC / SD | ❌ | `drivers/mmc/host/` **无任何 rtk/rtd 文件**；`rtd129x.dtsi` 无 mmc 节点 | 控制器驱动 + 节点 |
| PCIe | ❌ | `drivers/pci/controller/` 无 realtek | 整个 host 控制器 |
| SATA | ❌ | `drivers/ata/` 无 `ahci_rtk` | 整个 AHCI 驱动 |
| USB3 | 🟡 | `drivers/usb/dwc3/dwc3-rtk.c`（`realtek,rtd-dwc3`）**在主线**；`drivers/phy/realtek/phy-rtk-usb3.c`（**`realtek,rtd1295-usb3phy`**）和 `phy-rtk-usb2.c` **也在主线** | 主线 DTS 无 USB 节点；缺时钟/PHY 上电时序 |
| I2C / SPI / PWM | ❌ | 无 realtek 驱动 | 全部 |
| 热传感器 | ❌ | `drivers/thermal/` 无 realtek | 全部 |
| VPU 硬件编解码 | ❌ | 无 | 全部（飞牛影视转码用不上） |
| **平台配置项** | ✅ | `arch/arm64/Kconfig.platforms:335` `config ARCH_REALTEK`；**arm64 defconfig 里 `CONFIG_ARCH_REALTEK=y`** | — |

> **一句话**：主线 v7.3-rc5 对 RTD1296 的支持 = **串口控制台 + 看门狗 + 复位**。上游唯一"能用"的板子是群晖 DS418，能起串口 shell，仅此而已。这与 2019 年社区在 Armbian 论坛的判断完全一致（"mainline support for the rtd1296 is more or less non-existent"）。

---

## 3. 网卡：三条路（用户重点）

### 3.0 硬件定性

CM360 的 RJ45 不是独立 PCIe 网卡，而是：

```
SoC 内置 RTL8168 兼容千兆 MAC  ←→  RTL8211 PHY  ←→  RJ45
        │
        └── 旁挂 HWNAT 硬件 NAT 加速块（独立 DT 节点 Realtek,rtd1295-hwnat）
```

厂商 DTS 里 MAC 节点的 compatible 就是 **`Realtek,r8168`**（注意大写 R，且不是标准 vendor 前缀写法）。
`Realtek rtl8275` 是 WiFi/BT 模组，与有线网口无关。

**PHY 侧没问题**：RTL8211 是主线 `drivers/net/phy/realtek.c` 原生支持，`CONFIG_REALTEK_PHY=y`。
**MAC 侧是全部工作量所在。**

---

### 路 A：移植 `r8169soc`（正路，但最重）

**厂商代码**

| 文件 | 行数 | 用途 |
|---|---|---|
| `drivers/net/ethernet/realtek/r8169soc_rtd119x.c` | **7,779** | **RTD119x/RTD129x 专用版（我们要的就是这个）** |
| `drivers/net/ethernet/realtek/r8169soc.c` | 10,281 | RTD139x/16xx/13xx 版 |

厂商 Makefile 的选择逻辑（源码原文）：

```make
ifeq ($(CONFIG_ARCH_RTD119X),y)
obj-$(CONFIG_R8169SOC) += r8169soc_rtd119x.o
else
obj-$(CONFIG_R8169SOC) += r8169soc.o
endif
```

→ **CM360（RTD1296，属 RTD119x 家族）走的是 `r8169soc_rtd119x.c`。**

**驱动本质**：把 PCI 版 r8169 改造成 `platform_driver`：

```c
static const struct of_device_id rtl8169_dt_ids[] = {
        { .compatible = "Realtek,r8168", },
        {},
};
static struct platform_driver rtl8169_soc_driver = { ... };
module_platform_driver(rtl8169_soc_driver);
```

**移植障碍（逐条可查）**

1. **依赖已注释掉的 `mach/cpu.h`** —— 调用 `get_rtd129x_cpu_revision()`（在 `r8169soc.c:3900`、`:10139` 用于芯片 B00 步进的差异化初始化）。主线没有 `mach/*` 头，芯片步进必须改走 **efuse / nvmem / soc-bus** 读取。
2. **procfs 接口** —— 驱动 include 了 `<linux/proc_fs.h>` 并注册 `/proc` 节点。内核 5.x 起已全面移除 netdev 的 procfs 入口，这段必须重写为 debugfs 或直接删。
3. **netdev API 十年债**（4.9 → 7.3）：
   - `netif_napi_add()` 的 weight 参数（6.1 起移除）
   - `alloc_etherdev` → `devm_alloc_etherdev_mqs`
   - 自带 PHY 处理 + `struct mii_if_info` 老式 mii API → 建议改用 **phylib / phylink**
   - ethtool ops 结构体布局大改（`get_link_ksettings` 等）
   - `dev->features` → `netdev->features`，大量 `NETIF_F_*` 语义变更
4. **用 kthread 轮询链路状态** —— 源码注释原文：`/* Yukuen: Use kthread to watch link status change. 20150206 */`。应改为 phylib 的 link 中断 / `phy_state_machine`。
5. **依赖时钟和 pinctrl** —— MAC 要跑起来必须有 MAC/PHY 的时钟和 PINMUX，这两块主线都是 ❌。**网卡不能脱离时钟单独解决。**

**★ 关键情报：Realtek 自己提过主线 RFC，且从未合入**

| 项 | 值 |
|---|---|
| 邮件 | `[RFC v1 0/3] Realtek DHC SoCs Ethernet driver` |
| 作者 | Eric Wang `<ericwang@realtek.com>` |
| 日期 | **2020-09-18** |
| 列表 | `linux-realtek-soc@lists.infradead.org` |
| 覆盖 | RTD119x / 129x / 139x / 16xx / 13xx **统一一份驱动** |
| 规模 | `r8169soc.c` **9,285 行**，3 个 patch |
| Kconfig | `config R8169SOC` + `depends on ARCH_REALTEK`；同时把 `NET_VENDOR_REALTEK` 改成 `depends on PCI \|\| (PARPORT && X86) \|\| ARCH_REALTEK` |
| 附带选项 | `config RTL_RX_NO_COPY`（零拷贝收包） |
| 状态 | **RFC v1 后无下文；v7.3-rc5 主线中确认不存在该驱动** |

**这条情报的价值**：RFC v1 的代码基线是 **~5.9 内核 API**，比 4.9 BSP 少了整整 8 年的 API 债（procfs 已清、NAPI 签名接近现代、phylib 迁移已做了一部分）。**如果要走路 A，起点应该选 RFC v1 而不是 4.9 BSP。**

RFC 原文下载：`https://lists.infradead.org/pipermail/linux-realtek-soc/2020-September/000109.html`

---

### 路 B：USB 网卡（最快的迂回，推荐作为 MVP 的网络方案）

**依据**：主线**已经合入**了 RTD 系列的 USB3 全套驱动：

| 组件 | 主线文件 | compatible |
|---|---|---|
| dwc3 胶水层 | `drivers/usb/dwc3/dwc3-rtk.c` | `realtek,rtd-dwc3` |
| USB3 PHY | `drivers/phy/realtek/phy-rtk-usb3.c` | **`realtek,rtd1295-usb3phy`** ✅ 正是我们的芯片 |
| USB2 PHY | `drivers/phy/realtek/phy-rtk-usb2.c` | RTD 系列 |

这三个文件来自同一批 Realtek 上游提交（2020-09，`stanley_chang` 的 `[PATCH 00/10] Realtek DHC SoCs USB module driver`），**PHY 和 dwc3 胶水都成功合入了主线**（DT 那 4 个 patch 没合）。

**做法**：补齐主线 DTS 里的 USB 节点 + 时钟 + PHY 上电时序 → USB3 口可用 → 插 **RTL8153（千兆）/ RTL8156（2.5G）** USB 网卡 → 走主线 `drivers/net/usb/r8152.c`，**零驱动开发**。

**风险**：USB3 依赖 pinctrl 和时钟，恰好是主线最弱的两块。但相比路 A 的 7,779 行驱动，这是"补 DTS"的量级。

**附加收益**：CM360 有 USB3.0 口，飞牛也支持 USB 外接存储。USB 通道打通等于同时解锁网络和外接盘。

---

### 路 C：PCIe 网卡（一旦 PCIe 通，网卡白送）

**依据**：CM360 板上有 PCIe（闲鱼那批库存板常配 PCIe 转双 SATA 卡）。
一旦 PCIe host 控制器通了，插 RTL8111/8168 或 Intel i225，**主线 `r8169` 驱动直接可用，完全不用碰 `r8169soc`**。

**代价**：主线 **没有** RTD129x 的 PCIe host 驱动，需从厂商搬：

| 厂商文件 | 行数 |
|---|---|
| `drivers/pci/host/pcie-rtd129x-slot1.c` | 929 |
| `drivers/pci/host/pcie-rtd129x-slot2.c` | 929 |
| `drivers/pci/host/pcie-rtd129x.h` | — |

**注意**：这是 4.9 时代的 `drivers/pci/host/` 布局，现代内核已迁移到 `drivers/pci/controller/dwc/`（DesignWare 框架）。从 Andreas Färber 的分支 commit 标题（`FIXUP: arm64: dts: realtek: rtd129x: Limit PCIe bar mapping to 4K`）看，RTD129x 的 PCIe 是 **DesignWare 系**，理论上能用 `pcie-designware-host.c` + 一层薄 glue，工作量可能比想象小。

**额外价值**：PCIe 通了，CM360 那块 **PCIe 转双 SATA 卡**也就能用了 → NAS 的核心诉求（多盘位）才有意义。

---

### 三条路对比

| | 路 A 移植 r8169soc | 路 B USB 网卡 | 路 C PCIe 网卡 |
|---|---|---|---|
| 代码量 | 7,779 行（或 RFC 版 9,285 行） | **0 行**（只补 DTS + 时钟） | 1,858 行（PCIe host） |
| 前置依赖 | 时钟 + pinctrl | 时钟 + pinctrl | 时钟 + pinctrl + DesignWare glue |
| 网速 | 千兆（原生） | 千兆 / 2.5G | 千兆 / 2.5G |
| 附赠能力 | HWNAT 硬件加速 | USB3 + 外接存储 | **双 SATA（NAS 核心）** |
| 主线接受度 | 曾有 RFC，未合 | **驱动已全部在主线** | 需新写 glue |
| 建议 | 阶段 4 做（长期） | **阶段 2 做（MVP 用）** | 阶段 3 做（NAS 必需） |

---

## 4. 需移植的厂商代码清单（按子系统）

厂商 4.9.119 BSP 中 RTD1296 相关、主线缺失的驱动：

### 4.1 时钟（最高优先级 —— 所有外设的前提）
| 文件 | 行数 |
|---|---|
| `drivers/clk/realtek/cc-rtd129x.c` | 480 |
| `drivers/clk/realtek/reset.c` | 436 |
| `drivers/clk/realtek/clk-pll.c` | 378 |
| `drivers/clk/realtek/common.c` | 290 |
| `drivers/clk/realtek/cgc.c` | 266 |
| `drivers/clk/realtek/cc-platform.c` | 131 |
| `drivers/clk/realtek/clk-mmio-gate.c` | 96 |
| `drivers/clk/realtek/clk-mmio-mux.c` | 69 |
| **小计** | **2,146** |

> 对应厂商 DTS compatible：`realtek,clock-gate-controller`、`realtek,rtk1295-pu_pll`、`realtek,reset-controller`、`realtek,reset-control-provider`
> **好消息**：这是标准 CCF 框架，改动主要是 API 适配，不是架构重写。`clk-mmio-gate` / `clk-mmio-mux` 在主线已有同名通用驱动（`clk-gate.c` / `clk-mux.c`）可直接替代。

### 4.2 GPIO 与 PINMUX
| 文件 | 行数 | 备注 |
|---|---|---|
| `drivers/gpio/gpio-rtd129x.c` | 926 | **可能可以整个丢掉** —— 主线 `gpio-rtd.c` 已支持 `realtek,rtd1295-misc-gpio` / `realtek,rtd1295-iso-gpio` |
| `drivers/pinctrl/realtek/pinctrl-rtd129x.c` | 933 | 主线无对应，需移植 |
| **小计** | **1,859**（去掉 GPIO 则 933） |

### 4.3 存储
| 文件 | 行数 | 备注 |
|---|---|---|
| `drivers/mmc/host/rtkemmc.c` | 5,455 | eMMC 主体 |
| `drivers/mmc/host/rtkemmc_rtd119x.c` | 5,373 | eMMC 平台胶水 |
| `drivers/mmc/host/rtk-sdmmc.c` | 3,931 | SD 卡 |
| `drivers/mmc/host/sdhci-rtk.c` | 1,243 | SDHCI 变体（SDIO） |
| **小计** | **16,002** | **最大的一块** |

> **策略提示**：eMMC 两个文件加起来 10,828 行，但飞牛只要求"能挂载存储"。**MVP 阶段可先用 SD 卡启动（`rtk-sdmmc.c` 3,931 行）或直接用 USB 存储，把 eMMC 推到后期。**
> 厂商 compatible：`Realtek,rtk1295-emmc`、`Realtek,rtk1295-sdmmc`、`Realtek,rtk1295-sdio`

### 4.4 网络 / 总线 / SATA / USB
| 文件 | 行数 |
|---|---|
| `drivers/net/ethernet/realtek/r8169soc_rtd119x.c` | 7,779 |
| `drivers/pci/host/pcie-rtd129x-slot1.c` | 929 |
| `drivers/pci/host/pcie-rtd129x-slot2.c` | 929 |
| `drivers/ata/ahci_rtk.c` | 508 |
| `drivers/usb/dwc3/dwc3-rtk.c`（厂商版，主线已有替代） | 462 |
| **小计** | **10,607** |

### 4.5 总量

| 子系统 | 行数 |
|---|---|
| 时钟 + 复位 | 2,146 |
| GPIO + pinctrl | 1,859（可优化到 933） |
| 存储 | 16,002 |
| 网络 + PCIe + SATA + USB | 10,607 |
| **合计（含 19 个文件）** | **40,895** |

> 若 MVP 阶段跳过 eMMC、GPIO 复用主线、USB dwc3 复用主线，**实际必须先搬的约 2,000 ~ 10,000 行**。这是可控的量级。
> 另有 DTS 工作量：厂商 `rtd-1296.dtsi` 1,158 行 + `rtd-129x-common.dtsi` 495 行 + 各外设 dtsi，需改写成现代 binding 语法（`syscon`/`nvmem`/`resets`/`clocks` 属性和 GIC/PMU 写法都变了）。

---

## 5. 建议的路线图

### 阶段 0：环境与信息 ✅ 已完成（2026-10-04）
- TTL 串口接好（`3.3V / TX / RX / GND`），115200 8N1 —— 已抓两份完整日志。
- ✅ 原厂启动日志全量 dump：`stage0/shot_log_01.log`（934 行/48,721 B）→ 分析见 `stage0/阶段0-日志分析-shot_log_01.md`
- ✅ u-boot 环境变量全量：`stage0/shot_uboot_01.log`（163 行/4,939 B）→ 分析见 `stage0/阶段0-日志分析-shot_uboot_01.md`
- ✅ 打断 autoboot 的方式已验证：`Hit Esc or Tab key` → 连打 Esc/Tab → `CM360_DS218>`，**两次稳定复现**
- ⬜ **还差一步：`help` 命令表** → 决定阶段 1 用 TFTP / U 盘 / 私有 `go all` 哪条路（工具已备好 `probe` 模式）
- ⬜ **备份 SPI / eMMC 分区**（需要设备 shell；DSM 登录凭据能大幅简化这一步）
  - 注：阶段 1 全程不写 SPI/eMMC，所以备份可以晚做，不是阻塞项

### 阶段 1：最小启动（MVP-0）★ 里程碑一
目标：**主线 6.12/6.18 内核能起来并进 shell**。

**路线已收敛（2026-10-04 实测）**：`tftp` + `booti` 为主，`bootr uz`（U 盘）为辅，`loady`（串口）兜底。
```bash
# 板子侧（只改内存，绝不 saveenv）
setenv ipaddr 192.168.1.100 ; setenv serverip <PC_IP>
ping <PC_IP>
tftp 0x03000000 Image
tftp 0x01f00000 cm360.dtb
booti 0x03000000 - 0x01f00000
```

**自研 CM360 DTS 必须补的五个点（全部来自实测）**：

| # | 事项 | 依据 |
|---|---|---|
| 1 | **`enable-method` + `cpu-release-addr = <0x0 0x9801aa44>`**（或改用 PSCI） | 原厂 CPU 节点有 `rtk-spin-table`；主线缺失 → 否则单核 |
| 2 | **memory 从 `0x1f000` 起**：`reg = <0x1f000 0x7ffe1000>` | 主线 `rtd1296-ds418.dts` 写法；低 124 KB 被 boot ROM 占用 |
| 3 | **`/memreserve/ 0x1b00000 0x4be000`**（音频固件区，不要动） | 主线 dtsi 与 u-boot `audio_loadaddr=0x01b00000` 双向印证 |
| 4 | **SATA 节点带 `tx-driving = <2>; rx-sensitivity = <2>;`** | u-boot `mod_fdt` 会覆盖成 2（原厂 DTB 里是 9） |
| 5 | **总线用 `ranges` 恒等映射覆盖 `0x98000000`** | 主线 `soc@0` 的 ranges 不覆盖 0x98000000，其 `rbus` 子节点地址翻译实际是坏的 —— 自己写干净版 |

**验收**：`uname -a` 出得来，`/proc/cpuinfo` 有 4 个 processor。
**全程不写 SPI / eMMC** → 随时拔电恢复，零变砖风险。

### 阶段 2：把时钟搬过来 ★ 里程碑二（最难也最关键）
- 移植 `cc-rtd129x.c` + `clk-pll.c` + `common.c` + `cgc.c` + `reset.c`（约 1,650 行）。
- `clk-mmio-gate` / `clk-mmio-mux` 大概率能换成主线的 `clk-gate.c` / `clk-mux.c`。
- **验收：`/sys/kernel/debug/clk/clk_summary` 里外设时钟有正确的 rate，能开关门控。**
- 顺带把 `gpio-rtd.c` 的节点接上（主线现成），把 `rtc-rtd119x.c` 的节点也接上。
- 移植 `pinctrl-rtd129x.c`（933 行），让关键引脚可配。

### 阶段 3：USB3 + 网络可用 ★ 里程碑三（第一个"能用"的状态）
- 补 USB DTS 节点 + PHY 上电时序，启用主线的 `dwc3-rtk.c` + `phy-rtk-usb3.c`。
- 插 RTL8153/RTL8156 USB 网卡 → `r8152` → **有网了**。
- **此时可以试装飞牛 rootfs 了**：把这个主线的 6.12/6.18 内核 + 飞牛 rootfs（btrfs）+ 一个 CM360 的 dtb，按 ophub 的 `renas` 打包格式做一个自定义镜像。
- **验收：飞牛面板能打开，能挂 USB 硬盘存文件。**

### 阶段 4：PCIe + SATA（NAS 的真身）
- 移植 `pcie-rtd129x-slot1/2.c`，尽量改写成 `drivers/pci/controller/dwc/` 下的 DesignWare glue。
- PCIe 通了以后：
  - PCIe 转 SATA 卡可用 → **双盘位 NAS**
  - 插 PCIe 网卡可用 → 主线 r8169 直接上，不用碰 `r8169soc`

### 阶段 5：eMMC 启动 + 原生网卡
- 移植 `rtkemmc.c` + `rtkemmc_rtd119x.c`（10,828 行）→ 装进 eMMC，摆脱 SD 卡。
- 移植 / 重写 `r8169soc_rtd119x.c`（以 RFC v1 为起点向上移植到 7.x）→ 原生千兆网口。
- 可选：`ahci_rtk.c`（SoC 原生 SATA）。

---

## 6. 风险与未知项

| # | 风险 | 影响 | 应对 |
|---|---|---|---|
| 1 | **u-boot 8MB 内核镜像上限** | 群晖用户的实测：u-boot 限制了 `CONFIG_SYS_BOOTM_LEN`，4.4 内核配置编出 20MB+ 塞不进去，要裁剪到 8MB 以下 | 主线 arm64 `defconfig` 精简，或让 bootloader 加载压缩内核 + 用 `initrd` 引导 |
| 2 | **两阶段私有 bootloader** | dvrboot/LK + u-boot，需要 `boot_recovery.exe` + hwsetting `.config/.bin` 才能重写 u-boot；不能像晶晨那样 U 盘直接启动 | 先不动 u-boot，用现成 u-boot 的 `bootm`/`fatload` 加载自编内核（群晖用户已验证可行） |
| 3 | **飞牛要求 6.12+ 主线** | 这正是我们选主线的理由，但也意味着不能用厂商 4.9 内核偷懒 | 接受；主线 bring-up 是唯一路径 |
| 4 | **飞牛 FilesACL 是闭源补丁** | 即使内核跑起来，没有官方补丁，**文件回收站和多用户权限会失效** | 向飞牛官方申请对接；或接受降级功能 |
| 5 | **没有硬件文档** | Realtek 不公开 SoC 寄存器手册，所有寄存器地址只能从厂商 4.9 源码反推 | 以厂商源码为唯一权威；Linux 社区 2019 年就吐槽过"寄存器含义完全没文档" |
| 6 | **HWNAT 无法复刻** | RTL1296 的硬件 NAT 加速块只有 Realtek 有源码 | 放弃 HWNAT，走 CPU 软件转发（对 NAS 够用） |
| 7 | **PVR/VPU 缺失** | 飞牛的实时转码、AI 相册需要 VPU/GPU，主线全无 | 接受；或给内核加 Mali-T820 的 panfrost（主线有 panfrost，但 RTD1296 的 GPU 节点未描述） |
| 8 | **上游已放弃这条线** | `drivers/soc/realtek` 和 `drivers/clk/realtek` 在主线中**已不存在**；MAINTAINERS 里 `ARM/REALTEK ARCHITECTURE` 的覆盖范围只剩下 **DT + pinctrl**；Realtek 现在的精力在 rtd1315e/1319d/1619b/1625 | 意味着**没有上游支持渠道**，所有工作要自持。向上游提交的话，接受度未知（真实提交者 James Tai / Yu-Chun Lin 仍在维护该 entry） |

---

## 7. 源码路径索引（可直接查）

### 主线（v7.3-rc5）
```
arch/arm64/boot/dts/realtek/rtd129x.dtsi        # 共享 SoC 定义
arch/arm64/boot/dts/realtek/rtd1296.dtsi        # RTD1296 增量
arch/arm64/boot/dts/realtek/rtd1296-ds418.dts   # 唯一"可用"的板级 DTS（群晖 DS418）
arch/arm64/Kconfig.platforms                    # config ARCH_REALTEK (line 335)
arch/arm64/configs/defconfig                    # CONFIG_ARCH_REALTEK=y
drivers/gpio/gpio-rtd.c                         # ✅ 支持 realtek,rtd1295-{misc,iso}-gpio
drivers/rtc/rtc-rtd119x.c                       # 🟡 在主线，未接 DTS
drivers/watchdog/rtd119x_wdt.c                  # ✅
drivers/usb/dwc3/dwc3-rtk.c                     # 🟡 realtek,rtd-dwc3
drivers/phy/realtek/phy-rtk-usb3.c              # 🟡 realtek,rtd1295-usb3phy
drivers/phy/realtek/phy-rtk-usb2.c              # 🟡
drivers/pinctrl/realtek/pinctrl-rtd.c           # 通用 helper（无 rtd129x）
drivers/net/ethernet/realtek/Kconfig            # NET_VENDOR_REALTEK depends on PCI ← 卡点
drivers/net/phy/realtek.c                       # ✅ RTL8211 PHY
```

### 厂商 BSP（linux-4.9.119）
```
arch/arm64/boot/dts/realtek/rtd129x/rtd-1296.dtsi              # 1,158 行，SoC 外设全表
arch/arm64/boot/dts/realtek/rtd129x/rtd-129x-common.dtsi       # 495 行
arch/arm64/boot/dts/realtek/rtd129x/rtd-1296-saola-common.dtsi # ★ 板级蓝本
arch/arm64/boot/dts/realtek/rtd129x/rtd-1296-sata.dtsi
arch/arm64/boot/dts/realtek/rtd129x/rtd-1296-usb.dtsi
arch/arm64/configs/rtd129x_bpi_defconfig                       # 参考配置
drivers/clk/realtek/                                           # 全套 CCF
drivers/gpio/gpio-rtd129x.c
drivers/pinctrl/realtek/pinctrl-rtd129x.c
drivers/mmc/host/rtkemmc.c / rtkemmc_rtd119x.c / rtk-sdmmc.c
drivers/pci/host/pcie-rtd129x-slot1.c / slot2.c
drivers/ata/ahci_rtk.c
drivers/usb/dwc3/dwc3-rtk.c
drivers/net/ethernet/realtek/r8169soc_rtd119x.c                # ★ CM360 用的那个
drivers/soc/realtek/rtd129x/
```

### 厂商 DTS 中外设 compatible 速查（自研 DTS 的对照表）
```
CPU/中断/定时器   arm,cortex-a53 / arm,cortex-a15-gic / arm,armv8-timer / arm,armv8-pmuv3
时钟              realtek,clock-gate-controller / realtek,rtk1295-pu_pll / realtek,rtd129x-dvfs / realtek,rtd129x-busfreq
复位              realtek,reset-controller / realtek,reset-control-provider
GPIO / PINMUX     realtek,rtk-misc-gpio-irq-mux / realtek,rtk-iso-gpio-irq-mux / realtek,rtk129x-pinctrl
存储              Realtek,rtk1295-emmc / Realtek,rtk1295-sdmmc / Realtek,rtk1295-sdio
网络              Realtek,r8168 (MAC) / Realtek,rtd1295-hwnat (硬件加速)
PCIe              realtek,rtk-pcie-slot1 / realtek,rtk-pcie-slot2
SATA              —（见 rtd-1296-sata.dtsi）
USB               Realtek,dwc3 / Realtek,dwc3-type_c / Realtek,usb2phy / Realtek,usb3phy /
                  Realtek,usb-manager / Realtek,rtd129x-ehci / Realtek,rtd129x-ohci / rtk-rts5400
RTC / WDT         realtek,rtk-rtc / realtek,rtk-watchdog
I2C / SPI / PWM   realtek,rtk-i2c / Realtek,rtk129x-spi / Realtek,rtd1295-pwm
温度 / 红外       realtek,rtd129x-thermal-sensor / Realtek,rtk-irda
视频 / 显示       Realtek,rtk1295-ve1 / ve3 (VPU) / realtek,rtd129x-hdmitx / Realtek,rtk-fb
```
> 注意厂商 compatible 大小写混乱（`Realtek,` 和 `realtek,` 混用），现代内核 binding 要求全小写，移植时**必须统一改写**。

---

## 8. 参考链接

| 主题 | 链接 |
|---|---|
| Realtek 官方 r8169soc 主线 RFC v1（2020-09-18） | https://lists.infradead.org/pipermail/linux-realtek-soc/2020-September/000109.html |
| 该月邮件线索总览（含 USB dwc3/PHY 那批） | https://lists.infradead.org/pipermail/linux-realtek-soc/2020-September/thread.html |
| Andreas Färber 的 RTD129x 主线实验分支 | https://github.com/afaerber/linux/tree/rtd1295-next |
| BPI-W2 官方 BSP（4.9.119 内核 + u-boot 源码） | https://github.com/BPI-SINOVOIP/BPI-W2-bsp |
| Synology DS218play 跑 Debian 实战（含内核裁剪到 8MB 的完整过程） | https://forum.doozan.com/read.php?2,135588,135872 |
| Armbian 论坛 RTD1295/1296 讨论（主线支持现状的社区结论） | https://forum.armbian.com/topic/9285-proof-of-concept-realtek-1295/ |
| 小睿私人云 RTD1296 TTL 刷机流程 | http://171216.xyz/2020/01/07/小睿私人云RTD1296刷机步骤/ |
| iStoreOS for RTD1296（已有可用固件，可作对照） | https://www.i066.com/posts/d8b53bb4 |
| 飞牛 ophub 适配情况汇总（6.12/btrfs/FilesACL 关键信息） | https://github.com/ophub/fnnas/issues/21 |

---

## 附录：本地已下载的源码缓存

本次盘点下载的源码保存在（blobless 稀疏克隆，含完整元数据，可随时 `git show` 取任意文件）：

```
/home/xiaoabiao/.cache/rtd1296/lx              # torvalds/linux, v7.3-rc5
/home/xiaoabiao/.cache/rtd1296/BPI-W2-bsp      # 厂商 4.9.119 BSP
/home/xiaoabiao/.cache/rtd1296/build-raycloud  # 小睿私人云专用构建脚本
```

重新获取单个文件的命令：
```bash
cd /home/xiaoabiao/.cache/rtd1296/BPI-W2-bsp
git show HEAD:linux-rtk/drivers/net/ethernet/realtek/r8169soc_rtd119x.c | less
```

> ⚠️ 注意：本机 `/tmp` 是 10MB 的 tmpfs，**不要往 /tmp 里克隆内核**，会 `Out of diskspace`。
