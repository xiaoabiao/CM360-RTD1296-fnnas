# CM360（RTD1296）固件侧研究报告：能否用 UEFI 替代 U-Boot

**日期**：2026-10-22
**作者**：固件研究员（研究任务，未上板、未刷写）
**范围**：只回答"固件层"的问题——上游支持现状、EFI_LOADER 版本与配置、现代 U-Boot 迁移、纯 EDK2 可行性、可复用厂商源码、工作量与风险。
**本文不涉及**：内核/发行版适配、fnOS 本身。所有操作建议均**不包含**任何写 eMMC/串口/刷机命令。

**证据分级**（全文逐条标注）：

| 标记 | 含义 |
|---|---|
| 【本机已验证】 | 本仓库内的日志/二进制/文档实证，给出仓库内路径与行号 |
| 【外部已验证】 | 本次研究直接访问 URL 校验（HTTP 200 / 内容原文），给出 URL |
| 【推断】 | 由已验证事实推导，未直接验证 |
| 【未验证/TODO】 | 无证据或证据不足，明确列出待查项 |

---

## 0. 结论先行

用户问："能不能直接给这块板做一个 UEFI 替代 U-Boot，直接启动 UEFI ARM 安装镜像？"
分级回答：

| 方案 | 可行性 | 工作量（1 名熟练嵌入式工程师） | 主要风险 | 结论 |
|---|---|---|---|---|
| ① **纯 EDK2 替代 U-Boot**（EDK2 作为 BL33） | **工程上不现实** | **3～9 人月**（其中 Realtek 专属 DXE/ACPI 约 2～6 人月） | 无上游平台、无 JTAG、eMMC/USB/变量存储全要自写、ACPI/DT 路线冲突 | 不建议 |
| ② **现代 U-Boot（2024/2025）+ EFI_LOADER** 作为 BL33 | **可行，但不是"改个配置"** | **3～6 人周**（以 Armbian 的 17 个 `v2026.10-rtd129x` 外挂补丁为起点；见 §12；若不用这套补丁则回到 8～14 人周） | eMMC 已有 DW 驱动可抄、FSBL/BL31 handoff、低区容器槽位不够、**完全没有 USB 驱动**、无 JTAG 调试慢 | 若必须 UEFI，这是唯一现实路线 |
| ③ **保留现有 U-Boot 2015.07** | **不能启动 UEFI** | 0 | —— | 只能继续 legacy uImage/FIT/`booti` 引导；**装 fnOS 本身不需要 UEFI** |

**一句话**：这块板"UEFI 替代 U-Boot"不是买不到的东西，而是**要从头造一整套 SoC 固件支持**；纯 EDK2 是 3～9 人月的高风险项目，现代 U-Boot + EFI_LOADER 是 2～3.5 人月的"重移植"，且第一步就要动全板唯一的砖区（低区 38 MiB）。

---

## 1. 本板固件事实（先对齐基线）

### 1.1 启动链与加载地址【本机已验证】

来自本仓库实测启动日志 [`evidence/logs/uboot-rescue-2026-10-05.log`](../../../evidence/logs/uboot-rescue-2026-10-05.log)（UTF-8 文本，行号按该文件）：

```
[150.288] Goto FSBL: 0x10100000
[150.518] FW_TYPE_GOLD_TEE
[150.526]   FW Image to 0x10200000, size=0x0007BDA0 (0x1027BDA0)   fr 0x000B0600
[150.675] FW_TYPE_GOLD_BL31
[150.675]   FW Image to 0x10120000, size=0x000062A0 (0x101262A0)   fr 0x0012C400
[150.784] FW_TYPE_BOOTCODE
[150.784]   FW Image to 0x00020000, size=0x0007DC20 (0x0009DC20)   fr 0x00020E00
[150.870] NOTICE:  BL31: v1.2(debug):a6c9ab6   Built : Apr 27 2017
[150.903] TEE-CORE: TEE OS v2.1
[150.965] EXIT BL31
[150.975] U-Boot 2015.07 (Apr 27 2018 - 09:10:25 -0700)
[150.988] Board: Realtek QA Board
[150.988] DRAM:  2 GiB
[151.002] mapping memory 0x20000000-0x40000000 non-cached
```

要点：

- **BL31/TEE 在 RAM 低端固定占用**：BL31 `0x10120000`（257 MiB）～`0x101262A0`，TEE `0x10200000`（258 MiB）～`0x1027BDA0`。二者合计约 0x7F000 字节，位于 2 GiB DRAM 的前 260 MiB 内。
- **BL33（U-Boot）由 FSBL 加载到 `0x20000`**，大小由 hwsetting 中的字段决定（当前 `0x7DC20`＝515,104 B）。
- BL31 是 **ARM Trusted Firmware v1.2（2017-04-27，debug 构建）**，OP-TEE 是 **v2.1**（2017-12）。这两者都极老，是后面 EDK2/U-Boot 迁移的"不可改动前提"。
- BL31 日志明确 `bl31 jumps to EL2: LK entry`：**BL33 运行在 EL2**。
- U-Boot 自己把 `0x20000000-0x40000000`（512～1024 MiB）映射为 **non-cached**，原厂加载地址（kernel `0x03000000`、DTB `0x01F00000`、rootfs `0x02200000`、audio `0x01B00000`）都在低端（见 [`docs/reports/stage0-complete-report.md`](../stage0-complete-report.md) 与 [`docs/reports/driver-inventory.md`](../driver-inventory.md)）。

### 1.2 eMMC 低区布局与"bootcode 槽位"上限【本机已验证】

来自 [`firmware/RECOVERY.md`](../../../firmware/RECOVERY.md) 与 [`docs/10-vendor-usb-mp-tool-package.md`](../../10-vendor-usb-mp-tool-package.md)：

| eMMC 绝对偏移 | 内容 | 大小/说明 |
|---|---|---|
| `0x020000` | hwsetting（ROM 从 blk#0x100 读；docs/01 与 docs/10 均记 0x20000，RECOVERY 表里的 `0x200` 应为笔误） | 3,200 B；`+0x004..+0x010` 是各镜像长度字段 |
| `0x020E00` | **bootcode（= BL33 载荷，含 U-Boot）** | FSBL 按 hwsetting 字段加载，现 `0x7DC20` |
| `0x0B0600` | TEE / BL32 | `0x7BDA0` |
| `0x12C400` | BL31 | `0x62A0` |
| `0x07F300` | U-Boot 版本串所在（在 bootcode 镜像内） | 见 `docs/10` §5 |
| `0x220000` / `0x420000` | U-Boot env 双副本（生效/旧） | `0x20A00` |

**关键硬约束（本报告新算出的）**【推断，基于上表偏移】：
bootcode 槽位的物理上限 = TEE 偏移 − bootcode 偏移 = `0xB0600 − 0x20E00 = 0x8F800` = **587,776 B ≈ 574 KiB**。
当前 bootcode 已用 `0x7DC20`（515,104 B），**只剩约 71 KiB 余量**。
→ 现代 U-Boot（arm64 + EFI_LOADER + MMC + USB + FAT，几乎肯定 >600 KiB）**很可能放大不下**；要么裁剪功能，要么**改 hwsetting 里 TEE/BL31 的偏移与长度字段**把 TEE 往后挪——后者等于重写整条低区布局，风险等级最高。
（hwsetting 各字段的精确偏移目前只在 [`firmware/RECOVERY.md`](../../../firmware/RECOVERY.md) §二 有 `+0x004..+0x010` 的定性描述，**精确字段表仍属 TODO**，见 §11。）

### 1.3 本板 U-Boot 2015.07 的实际能力【本机已验证】

`help` 全表见 [`docs/reports/stage0-complete-report.md`](../stage0-complete-report.md) §u-boot help（原文列出 50+ 命令）：

- **有**：`booti`（Realtek backport）、`bootm`、`tftp`、`tftpput`、`usb`、`mmc`、`sata`、`fatload`、**`ext4load`**、`loady`、`fdt`、`fastboot`（含 Realtek OEM 命令）、**`setenv`/`saveenv`/`printenv`/`editenv`**。
- **没有**：`bootefi`、任何 EFI_LOADER 相关能力（2015.07 早于 UEFI 支持，见 §3）。
- **重要更正**：任务背景中"没有 `ext4load`、`setenv/saveenv`"的说法**与本仓库实测证据矛盾**——`bootcmd` 就是用 `ext4load` 写的（[`firmware/README.md`](../../../firmware/README.md) §2.5/§3），`saveenv` 还有实测输出（[`firmware/RECOVERY.md`](../../../firmware/RECOVERY.md) §"u-boot env 的真实布局"：
  `Saving Environment to FACTORY... [FAC] Save to eMMC (blk#:0x1100, buf:0x07000000, len:0x20a00)`），`help` 表里两者都在。
  本报告按**有日志/有 help 表的一方**为准；建议 Lead 复核该背景条目。

---

## 2. 上游 U-Boot 对 Realtek RTD1195/RTD1295/RTD1296 的支持现状

### 2.1 结论：**无上游支持**（没有 board 目录、没有 defconfig、没有补丁进 mainline）

逐条证据（本次研究直接请求）：

| # | 检查 | 结果 | 证据 URL |
|---|---|---|---|
| 1 | `board/realtek` 是否存在 | **404 Not Found** | https://api.github.com/repos/u-boot/u-boot/contents/board/realtek |
| 2 | 全体 board 文件里搜 `realtek`/`rtd1*`/`bpi-w2`/`ds218` | board 子树 4,139 个文件，**0 命中**（GitHub git-tree API，`recursive=1`，`truncated=false`） | https://github.com/u-boot/u-boot/tree/master/board |
| 3 | 全体 configs 里搜 `rtd129x`/`bpi-w2`/`ds218` | configs 子树 1,563 个文件，**0 命中** | https://github.com/u-boot/u-boot/tree/master/configs |
| 4 | 逐个探测候选 defconfig | `rtd1295_defconfig`、`rtd1296_defconfig`、`rtd1195_defconfig`、`bpi-w2_defconfig`、`ds218_defconfig` 全部 **404** | 例：https://github.com/u-boot/u-boot/blob/master/configs/rtd1296_defconfig |
| 5 | `MAINTAINERS` 中 Realtek/RTD 条目 | **0 命中**（grep `REALTEK|RTD1` 无输出） | https://github.com/u-boot/u-boot/blob/master/MAINTAINERS |
| 6 | u-boot 邮件列表 `rtd1295` 检索 | **仅 3 条**，全部是 2024 年 `dts/upstream` 同步补丁（DT 文件顺带更新），**没有任何板级支持/RFC** | https://lore.kernel.org/u-boot/?q=rtd1295 |

补充说明：

- U-Boot 2024+ 会把 Linux 的 `dts/upstream`（含 `arch/arm64/boot/dts/realtek/*`）同步进来，所以"**RTD1296 的 DT 文件**可能出现在 U-Boot 树里"【推断，本次未逐文件核实，TODO】；但这只是**数据**，没有 board 代码、defconfig、驱动 glue 把它变成可启动固件。
- U-Boot 里**可以复用的通用件**【外部已验证，200】：
  - 串口：https://github.com/u-boot/u-boot/blob/master/drivers/serial/ns16550.c （RTD1296 UART 是 `snps,dw-apb-uart`，兼容 ns16550 寄存器模型【推断】）
  - MMC：https://github.com/u-boot/u-boot/blob/master/drivers/mmc/dw_mmc.c （**通用 DW MSHC**；RTD1296 eMMC 是否与 DW MSHC 兼容**未验证**，厂商 Linux 驱动是自研 `rtkemmc.c`，见 §6）
  - USB3 host：https://github.com/u-boot/u-boot/blob/master/drivers/usb/host/xhci-dwc3.c （dwc3 host 模式的 xHCI 胶水；PHY 初始化要自己补）
  - 网络：https://github.com/u-boot/u-boot/blob/master/drivers/net/rtl8169.c （**注意：这是 PCI 版 r8169**；RTD1296 的 MAC 是 SoC 内置 platform device，不能直接 bind【推断，需读代码确认】）
- 结论：**"上游 U-Boot 已支持 RTD129x"不成立**。任何"下载 mainline U-Boot 编一下就能跑"的设想都不成立。

### 2.2 有没有历史 RFC/补丁？

本次只检索到 lore 的 3 条 `dts/upstream` 同步记录（上面 #6）。**没有找到** RTD129x 的 U-Boot RFC/board 补丁。
【未验证/TODO】补充检索 `rtd1195`、`rtd1296`、`bpi-w2`、`realtek` 在 lore u-boot 与 patchwork.ozlabs.org 的结果（本次 patchwork API 404、lore 对 curl 403，仅完成 `rtd1295` 一项）。

---

## 3. U-Boot 的 EFI_LOADER：从哪个版本开始可用？

### 3.1 版本事实【外部已验证】

| 版本 | 事实 | 证据 URL |
|---|---|---|
| **v2015.07** | **没有** EFI loader：`lib/efi_loader/`、`cmd/bootefi.c`、`lib/efi_loader/Kconfig` 全部 **404** | https://github.com/u-boot/u-boot/tree/v2015.07/lib （无 efi_loader 目录） |
| **v2016.05** | **首次出现**：`lib/efi_loader/Kconfig` 已存在，且 **Kconfig 明确写 `depends on (ARM64 || ARM) && OF_LIBFDT`、help 里点名 "run EFI applications (like grub2)"** | https://github.com/u-boot/u-boot/blob/v2016.05/lib/efi_loader/Kconfig |
| **v2016.11** | 新增 `EFI_LOADER_BOUNCE_BUFFER`（`depends on EFI_LOADER && ARM64`），解决 32 位 DMA 设备无法访问 64 位地址的问题 | https://github.com/u-boot/u-boot/blob/v2016.11/lib/efi_loader/Kconfig |
| **v2020.01+** | `efidebug`、`CMD_NVEDIT_EFI` 等 UEFI 变量管理命令成熟；qemu_arm64 defconfig 已带 `CMD_BOOTEFI_SELFTEST`、`CMD_NVEDIT_EFI` | https://github.com/u-boot/u-boot/blob/v2020.01/configs/qemu_arm64_defconfig |
| **master（2025）** | `EFI_LOADER` 依赖 `BLK`、`STACK_SIZE >= 0x20000`（EFI 规范要求 128 KiB 栈），select `EFI/LMB/OF_LIBFDT/REGEX`，imply `FAT/FAT_WRITE`；变量存储有 4 种：文件（FAT）/SPI Flash/OP-TEE MM/不持久化 | https://github.com/u-boot/u-boot/blob/master/lib/efi_loader/Kconfig |

**结论：想 boot `bootaa64.efi`（GRUB），最低要 U-Boot v2016.05，实用起见应选 v2019.07 之后（变量服务/块设备/ARM64 修复成熟），本报告建议直接以 2024/2025 版本为目标。**

### 3.2 UEFI 官方文档对"跑 GRUB"的说明【外部已验证】

https://github.com/u-boot/u-boot/blob/master/doc/develop/uefi/uefi.rst

- 目标：满足 **EBBR v2.1.0**（"UEFI on U-Boot" 文档开头）。
- 打开方式：`CONFIG_CMD_BOOTEFI=y` + `CONFIG_EFI_LOADER=y`；文档给出了**从 FAT 加载 `efi/debian/grubaa64.efi` 再 `bootefi ${kernel_addr_r} ${fdt_addr_r}` 的完整示例**（文档 §"Executing a UEFI binary"）。
- 变量服务限制（**这是最大的坑之一**）：文档原文 "**As of U-Boot v2020.10 UEFI variables cannot be set at runtime**"、"**Since U-Boot doesn't currently support SetVariable at runtime**"（同文件约 417、666 行）；另有 "Using OP-TEE for EFI variables" 一节（需 OP-TEE 侧有 StandAloneMM，**本板 OP-TEE 2.1 太老，几乎肯定没有**【推断】）。
- DT 传递：文档明确 "The environment variable `fdtcontroladdr` points to U-Boot's internal device tree"——即 **EFI 给 OS/GRUB 的 DT 默认是 U-Boot 自己的控制 DT**，不是你想给的那份。

### 3.3 要 boot UEFI arm64 安装镜像（GRUB bootaa64.efi）的最小 CONFIG 清单

基于 master `lib/efi_loader/Kconfig` 与文档【外部已验证 + 推断】：

```text
CONFIG_ARM=y
CONFIG_ARM64=y                 # RTD1296 是 AArch64，必须 64 位
CONFIG_SYS_CPU="armv8"         # EFI_LOADER 的 ARM 依赖项
CONFIG_STACK_SIZE=0x20000      # EFI 规范要求 ≥128 KiB
CONFIG_OF_LIBFDT=y             # EFI_LOADER select
CONFIG_LMB=y                   # EFI_LOADER select（内存映射/加载用）
CONFIG_BLK=y                   # EFI_LOADER 依赖
CONFIG_DM=y                    # 现代 U-Boot 驱动模型
CONFIG_CMD_BOOTEFI=y
CONFIG_EFI_LOADER=y
CONFIG_PARTITIONS=y / CONFIG_PARTITION_UUIDS=y
CONFIG_FAT=y / CONFIG_FAT_WRITE=y   # 读 ESP；写变量文件需要 FAT_WRITE
CONFIG_EFI_LOADER_BOUNCE_BUFFER=y   # 若有 <4 GiB DMA 限制（arm64 SoC 常见）
# 块设备二选一或都开：
CONFIG_MMC=y + CONFIG_DM_MMC=y + CONFIG_MMC_DW=y（若 eMMC 是 DW MSHC）
CONFIG_USB=y + CONFIG_DM_USB=y + CONFIG_USB_XHCI_HCD=y + PHY 驱动
# 变量存储（EFI 安装器/GRUB 会 SetVariable）：
CONFIG_EFI_VARIABLE_FILE_STORE=y    # 存 /ubootefi.var 到 FAT，需 FAT_WRITE
# 或 CONFIG_EFI_VARIABLE_NO_STORE=y（不持久化，对"一次性启动安装器"够用）
# 可选：
CONFIG_EFI_GET_TIME=y + CONFIG_DM_RTC=y   # GetTime()；GRUB/Linux 会调用
CONFIG_CMD_BOOTEFI_SELFTEST=y              # 自测
CONFIG_POSITION_INDEPENDENT=y              # 建议：BL33 被加载到 0x20000，PIE 更稳
```

### 3.4 已知坑（按本板情况逐条）

| # | 坑 | 说明与对本板的影响 |
|---|---|---|
| 1 | **SetVariable 需要非易失存储** | 没有 EFI 变量后端时 GRUB/安装器可能报错或无法保存启动项。本板 SPI NOR 只剩 ~68 KiB～772 KiB 且被明令禁止写入（[`docs/01-hardware-and-boot.md`](../../01-hardware-and-boot.md) §4），**不能**用 SPI varstore；只能用 FAT 文件存储（`/ubootefi.var`，放在 ESP 上）【推断：U-Boot 的 `EFI_VARIABLE_FILE_STORE` 正是为此设计，见 Kconfig】。 |
| 2 | **DT 传递** | U-Boot 把**自己的控制 DT** 通过 EFI config table 交给 GRUB；如果控制 DT 是 "Realtek QA Board" 的 BPI-W2 DT，GRUB 再把这份 DT 传给 Linux → 内核找不到 eMMC/GMAC/SATA。对策：`bootefi <img> <fdt>` 显式给 CM360 DTB（文档支持第二参数），或在 GRUB 里用 `devicetree` 命令覆盖【推断，需实测】。 |
| 3 | **EFI 内存映射** | `bootefi` 会把 U-Boot 占用内存释放给 OS（文档 §"bootefi" 说明），但 **BL31/TEE 占的 `0x10120000-0x1027BDA0` 必须作为 reserved 出现在 EFI memory map / DT 里**，否则 Linux 可能把它当空闲内存分配 → 立刻崩。本板 DT 里没有这个 reserved 区【推断：仓库 DTS 未见；TODO】。 |
| 4 | **GOP/framebuffer 不需要，serial console 要** | 本板无 HDMI 输出需求时，GRUB 走 EFI 串口控制台即可；U-Boot 的 EFI console 会通过 serial 提供 `EFI_SIMPLE_TEXT_OUTPUT`。但部分安装器默认图形菜单，需在 GRUB 里选 serial 终端或改 `console=`。 |
| 5 | **BL33 在 EL2** | BL31 v1.2 日志显示 `bl31 jumps to EL2`。U-Boot 支持 EL2 入口（会按需降级），但 EDK2 的 ARM BL33 对 EL2/EL1 假设不同，迁移 EDK2 时要单独验证【未验证】。 |
| 6 | **旧 ATF handoff** | BL31 v1.2（2017）传给 BL33 的参数（x0=DT？）没有文档；现代 U-Boot 期望 `x0` 是有效 FDT 指针，否则可能直接死。**这是现代 U-Boot 迁移的第一个致命不确定点**【未验证/TODO】。 |
| 7 | **U-Boot 镜像尺寸** | 见 §1.2：bootcode 槽位只剩 ~71 KiB。EFI_LOADER + USB + MMC + FAT 很容易超。对策：裁掉网络/SATA/视频/命令行冗余，或改 hwsetting 布局（高风险）。 |
| 8 | **EFI runtime 变量与 Linux efivarfs** | 文件后端的变量在 runtime 不可写（U-Boot 文档明说）；Linux 里 `efibootmgr` 写入会失败。对"只启动安装器"影响有限，对"装完系统后维护启动项"影响大。 |

---

## 4. 现代 U-Boot（2024/2025）+ EFI_LOADER 迁移：到底要做什么

### 4.1 需要新增/移植的板级内容

| 模块 | 主线可复用件 | 本板要做什么 | 预估代码量 | 风险 |
|---|---|---|---|---|
| **board/defconfig/DTS** | 无 Realtek 板；DT 可从 Linux `dts/upstream` 借【推断】 | 新建 `board/realtek/rtd1296-cm360/`、`configs/cm360_defconfig`、板级 DTS（含 memory/reserved-memory/BL31-TEE 区、串口、eMMC、USB、GMAC 节点） | 600～1,500 行 | 中：DTS 错误 → 早期死机 |
| **串口 8250** | `ns16550.c` | 确认 UART 时钟（父时钟来自 CRT/PLL，FSBL 已设好）；写 `ns16550_serial_plat` 的 clock/reg shift | 50～150 行 | 低 |
| **ARM arch timer / GIC** | 架构定时器通用；U-Boot 的 GIC 只用于中断，EFI 启动不强制 | 基本可复用；GIC 基址 `0xff011000`（Linux DT 有） | 0～100 行 | 低 |
| **DRAM** | 无（hwsetting+FSBL 已完成 DDR 初始化） | 只需在 board 代码/DT 里声明 2 GiB 与 reserved 区；**不要重跑 DDR 训练** | 50～150 行 | 中：内存描述错 →  relocate 崩 |
| **eMMC** | `drivers/mmc/dw_mmc.c`（通用 DW MSHC） | **先验证 RTD1296 eMMC 是否 DW MSHC 兼容**；不兼容则从厂商 `rtkemmc.c`（Linux 10,828 行）裁出 U-Boot 版 | 500～1,500 行（兼容）／3,000～6,000 行（不兼容） | **高** |
| **USB3 (dwc3 host)** | `xhci-dwc3.c` + `xhci` 栈 | 补 RTD1296 的 dwc3 胶水寄存器、PHY 上电/复位时序（厂商 Linux `dwc3-rtk.c` 可参考） | 400～900 行 | 中高 |
| **GMAC（原生千兆）** | `rtl8169.c` 是 **PCI** 驱动，不能直接用 | 从厂商 `r8169soc_rtd119x.c`（Linux 7,779 行）裁 U-Boot 平台版；或**第一期不做**（从 USB/eMMC 启动安装器不需要网络） | 800～2,500 行（可延后） | 中 |
| **pinctrl/clock** | 无 Realtek 驱动 | **依赖 hwsetting/FSBL 预配置**，尽量不写驱动；只为 UART/eMMC/USB 需要的少数门控/引脚做最小初始化 | 0～500 行 | 中 |
| **hwsetting / 低区刷写** | 无 | 改 bootcode 长度字段（若镜像变大）；必要时移动 TEE/BL31 偏移；生成新的低区镜像并用 ROM Monitor/TFTP 刷入 | 脚本 + 反复上板 | **最高（砖区）** |
| **EFI 配置与调试** | Kconfig 现成 | 打开 §3.3 的 CONFIG；接 GRUB/安装器；变量文件存储；DT 显式传递 | 配置 + 调试 | 中 |

### 4.2 FSBL/BL31 已初始化、可以直接复用的东西【本机已验证 + 推断】

- **DRAM 初始化/训练**：hwsetting（ROM 执行）+ FSBL 完成；U-Boot/EDK2 **不需要**再初始化 DDR。**这是最大的"白送"**。
- **eMMC 时钟/位宽/PHY 训练**：FSBL 日志显示已切 HS200、8-bit、PHY TX/RX 窗口训练完成（`TEMP TX_WINDOW=...`、`[LY] speed up emmc at HS-200`）→ U-Boot 只需**继续用**控制器，不要重做训练。
- **BL31/TEE**：原样保留（除非要换 ATF 版本，那会引入新风险）。
- **串口**：FSBL 已打印，说明 UART 时钟/引脚已配好。
- **USB3 PHY/时钟**：**未验证** FSBL 是否初始化（日志未见），大概率要自己配。

### 4.3 内存布局：现代 U-Boot 会不会撞 BL31/TEE？

- U-Boot 从 `0x20000` 开始执行，很快会 **relocate 到 DRAM 高端**（典型是 2 GiB 顶部附近），运行时占用 ~1-2 MiB；**不会**长期占用 `0x10120000` 区域。
- **真正会撞的是**：EFI_LOADER 需要把 BL31/TEE 标为 reserved，否则 EFI payload（GRUB/Linux）会把它们当空闲内存。且 U-Boot 的 `bootefi` 会把自身非 runtime 内存释放给 OS——必须有正确的内存节点/reserved 描述。
- 原厂加载地址（kernel `0x03000000`、DTB `0x01F00000`）与 BL31/TEE 不重叠，**可以继续沿用**【本机已验证：仓库文档中的 bootcmd/加载地址】。
- 【推断】若把 U-Boot 的 `CONFIG_TEXT_BASE` 设为 `0x20000` 且不 PIE，则必须保证它 relocate 前不越过 `0x10120000`（512 KiB 的 U-Boot 不可能越界，安全）。但 PIE 更稳（推荐 `CONFIG_POSITION_INDEPENDENT=y`，arm64 支持，见 https://github.com/u-boot/u-boot/blob/master/arch/arm/Kconfig ）。

### 4.4 要不要改 hwsetting 的长度字段？

- **如果新 U-Boot 镜像 ≤ 574 KiB（含 FSBL 需要的任何头/对齐）**：理论上可以只替换 bootcode 槽位内容，hwsetting 只需把 bootcode 长度字段从 `0x7DC20` 改成新长度（必须改，否则 FSBL 少拷/多拷）。
- **如果 > 574 KiB**（很可能）：必须把 TEE（`0xB0600`）及 BL31（`0x12C400`）**整体后移**，同时改 hwsetting 里所有受影响字段 + 低区镜像布局 → 这已经不是"刷 U-Boot"，而是"重做整条低区"。
- 并且 U-Boot 镜像大小是**编译产物**，会随 config 变化，**每次迭代都要重新核对槽位**——工程上应把"最大尺寸检查"写进构建脚本（`size` 检查 + `-Wl` 断言）。

### 4.5 工作量估算（8～14 人周，含上板调试）

| 阶段 | 内容 | 人周（乐观/现实） |
|---|---|---|
| P0 | 读厂商代码、确认 eMMC/DW 兼容性、确认 FSBL handoff、搭交叉编译 | 0.5 / 1.0 |
| P1 | 最小 U-Boot：串口 + DT + 内存 + 板级骨架，能打 banner | 0.5 / 1.0 |
| P2 | eMMC 读写（能 load 内核/能读 FAT） | 1.5 / 3.0 |
| P3 | 打开 EFI_LOADER，跑 GRUB `bootaa64.efi`，解决 DT/变量/内存映射 | 1.0 / 2.0 |
| P4 | USB3 host（安装器从 U 盘启动） | 0.5 / 1.5 |
| P5 | GMAC（可选，可延后） | 0.5 / 2.0 |
| P6 | hwsetting/低区镜像改造 + 刷写流程 + 回归（含救砖演练） | 1.5 / 3.0 |
| **合计** | | **6 / 13.5 人周** |

前提：能拿到并使用 `BPI-W2-bsp` 的 U-Boot 2015.07 源码做"寄存器级参考"（见 §6）；否则 eMMC/USB/GMAC 的无文档寄存器工作会让估算翻倍【推断】。

### 4.6 失败模式

1. **eMMC 控制器不是 DW MSHC**：只能从厂商 5,000～11,000 行驱动里裁，工作量 +2～4 人周，且寄存器无文档（Realtek 不公开 datasheet）。
2. **FSBL/BL31 handoff 不兼容**：现代 U-Boot 在 `0x20000` 起来但不认 x0/DT → 无串口输出（连 banner 都没有），而**没有 JTAG**，只能靠 FSBL 串口日志与"改镜像再刷"迭代，每轮 10～30 分钟。
3. **镜像超槽位**：见 §1.2/§4.4；改 hwsetting 布局时一次写错 = 变砖，只能走 ROM Monitor YMODEM 救砖（约 1.2 MB 最小集合，已验证可行，但要拆机接串口、独占串口、逐段校验）。
4. **EFI 变量/内存映射问题**：GRUB 能起来但 Linux 起不来（DT 错、reserved 区缺失），表现为"安装器菜单能进、选安装就崩"，排查成本高。
5. **旧 ATF v1.2 + 新 U-Boot**：ATF 的 PSCI/SMCCC 版本很老，U-Boot 某些特性（如 `PSCI_RESET`、runtime services 调 SMC）可能不工作 → 复位/关机异常。

---

## 5. 纯 EDK2 做"真 UEFI 固件"替代 U-Boot：为什么不现实

### 5.1 没有捷径：tianocore 没有 Realtek 平台

本次直接列出 `tianocore/edk2-platforms` 的 `Platform/` 子树（git-tree API，`truncated=false`，4,013 个文件）：

```
Platform/96Boards  Platform/ADLINK  Platform/AMD  Platform/ARM  Platform/ASRockRack
Platform/Ampere  Platform/Bosc  Platform/Intel  Platform/Loongson  Platform/Marvell
Platform/MinPlatformPkg  Platform/NXP  Platform/Phytium  Platform/Qemu
Platform/Qualcomm  Platform/RISC-V  Platform/RaspberryPi  Platform/SiFive
Platform/SolidRun  Platform/Sophgo  Platform/StandaloneMm
```

**没有 Realtek**。证据：https://github.com/tianocore/edk2-platforms/tree/master/Platform

EDK2 不是一个"编译一下就能当 BL33"的通用固件：**每个 SoC 都要一个 platform package**（`.dsc`/`.fdf`/`.dec` + ArmPlatformLib 内存映射 + 一堆 DXE 驱动 + ACPI 表）。Realtek 的这个 package **不存在**，只能从零写。

### 5.2 EDK2 在 ARM 上作为 BL33 需要什么

| 类别 | 需要的组件 | 主线是否有通用件（可复用） | Realtek 专属工作 |
|---|---|---|---|
| 启动/内存 | SEC/PrePi + `ArmPlatformLib`（DRAM 布局、BL31/TEE reserved、UART 基址） | `ArmPkg` 有框架 | 写 `ArmPlatformLibMem.c` 等（~300-600 行） |
| 串口控制台 | `SerialDxe`（8250 寄存器模型，`PcdSerialRegisterBase`） | ✅ https://github.com/tianocore/edk2/blob/master/MdeModulePkg/Universal/SerialDxe/SerialDxe.inf | 配置基址/时钟（~50 行） |
| 定时器 | `TimerDxe` + `ArmArchTimerLib` | ✅ https://github.com/tianocore/edk2/blob/master/ArmPkg/Drivers/TimerDxe/TimerDxe.inf | 0 |
| 中断 | `ArmGicDxe`（GIC-400 @ `0xff011000`） | ✅ https://github.com/tianocore/edk2/blob/master/ArmPkg/Drivers/ArmGicDxe/ArmGicDxe.inf | 配置基址（~50 行） |
| 块设备 eMMC | `EmbeddedPkg/Universal/MmcDxe` + 具体 host DXE | ✅ MmcDxe 框架；**DW MSHC 有现成 `DwEmmcDxe`** https://github.com/tianocore/edk2-platforms/blob/master/Silicon/Synopsys/DesignWare/Drivers/DwEmmcDxe/DwEmmcDxe.inf | 若 DW 兼容：改基址/时钟（~200 行）；不兼容：**自写 host DXE（1,500～3,000 行）** |
| 块设备 USB | `XhciDxe` + dwc3 胶水 + PHY | 有 XhciDxe；dwc3/PHY 无 RTD1296 版 | 1,000～2,000 行 |
| 文件系统 | `FatPkg` | ✅ https://github.com/tianocore/edk2/blob/master/FatPkg/EnhancedFatDxe/Fat.inf | 0 |
| 分区 | `PartitionDxe` | ✅ https://github.com/tianocore/edk2/blob/master/MdeModulePkg/Universal/Disk/PartitionDxe/PartitionDxe.inf | 0 |
| 变量存储 | `VariableRuntimeDxe` + 非易失后端 | ✅ 框架有；**没有 NVRAM 硬件** → 需文件/自定义 flash 后端 | 500～1,000 行 |
| RTC | RTC DXE（Linux 有 `rtc-rtd119x.c` 可参考） | 无 Realtek RTC DXE | 200～400 行 |
| 控制台输出 | `ConSplitter`/`GraphicsConsole`（GOP 可选，串口必需） | ✅ | 0～300 行 |
| 启动管理 | `BdsDxe`（BootOrder/Boot####） | ✅ | 0 |
| **ACPI 表** | SPCR/GTDT/MADT/DSDT（ARM Linux 走 ACPI 时必需） | 通用框架 | **RTD1296 的 ACPI 表要自己写（1,000～2,000 行 ASL/C）**；而本板 Linux 6.6 vendor 内核的 eMMC/GMAC/SATA 驱动全是 **DT based**，ACPI 下没有驱动 |
| **DT 传递** | 若继续走 DT：把 CM360 DTB 装进 EFI config table（`gFdtTableGuid`） | EDK2 有 FdtLib/FdtClientDxe | 200～500 行 + 验证 |

**关键矛盾**：EDK2 在 ARM 上的"标准路线"是 ACPI，而这块板的内核支持（eMMC/GMAC/SATA）**只在 vendor DT 世界里存在**（见 [`docs/reports/driver-inventory.md`](../driver-inventory.md)：主线 Linux 的 eMMC/GMAC 驱动都没有）。也就是说：**即使 EDK2 能把 Linux 拉起来，装好的系统大概率也找不到 eMMC/网卡**，除非再解决"EDK2 把 CM360 DT 传给 GRUB、GRUB 再传给 Linux"这条非标准链。这一条就把 EDK2 的"纯 UEFI"意义抵消大半。

### 5.3 公开先例：EDK2 作为 BL33 的 ARM 平台，各自靠什么

| 平台 | EDK2 平台包 | 依赖 | 说明 |
|---|---|---|---|
| ARM Juno | `Platform/ARM/JunoPkg/ArmJuno.dsc` | **TF-A**（BL1/BL2/BL31）+ EDK2 作 BL33 | ARM 官方参考，最接近"EDK2 当 BL33" |
| NXP LX2160A | `Platform/NXP/LX2160aRdbPkg/LX2160aRdbPkg.dsc` | **TF-A** + NXP 的 Silicon 包 + `edk2-non-osi` 二进制 | SoC 专属 DXE 一大堆（含 DesignWare eMMC） |
| Raspberry Pi 4 | `Platform/RaspberryPi/RPi4/RPi4.dsc` | 树莓派**闭源 bootloader** + TF-A BL31 | 仍然依赖厂商固件，不是"EDK2 从零启动" |
| Marvell Armada | `Platform/Marvell/...` + `Silicon/Marvell/Drivers/SdMmc/XenonDxe` | TF-A + Marvell 专属 eMMC DXE | 每个 SoC 都要自己的 host DXE |
| Sophgo SG2042 | `Platform/Sophgo/SG2042Pkg` + `Silicon/Sophgo/.../MmcDxe` | 厂商/社区 BSP | RISC-V 也有同样模式 |

共同点：**每个平台都有 (a) SoC/板级 package、(b) 专属块设备/串口/RTC DXE、(c) TF-A 或厂商 bootloader 提供 BL31**。Realtek 这三点**全部为零**。

### 5.4 量化结论

- 一个"最小可引导"的 EDK2 ARM 平台包（含 DSC/FDF/内存库/串口/定时器/GIC/FAT/分区/变量/启动管理）≈ **2,000～4,000 行胶水 + 复用大量通用包**；但要让它**驱动这块板的 eMMC/USB 并给 Linux 留下可用硬件描述**，Realtek 专属代码 ≈ **4,000～10,000 行**（eMMC host 1.5-3k、USB/PHY 1-2k、变量 0.5-1k、RTC 0.2-0.4k、ACPI/DT 1-2k、平台胶水 1-2k）。
- 按 1 名熟练工程师 + 每周 ~300 行有效调试代码估算：**3～9 人月**（不含救砖/上板等待时间），与 U-Boot 路线的 1.5～3.5 人月相比是 **2～4 倍**，且风险更高（没有 JTAG，EDK2 早期崩溃几乎没有调试手段）。
- 另外 EDK2 需要 BL33 由 BL31 以某种 ABI 交接；**本板 BL31 是 2017 年的 debug 版 v1.2**，其 handoff 是否满足 EDK2 的 `ArmPlatformLib` 假设【未验证】。
- 结论：**"纯 EDK2 替代 U-Boot" = 不现实/成本极高**，不是"因为 tianocore 没写所以难"，而是"要写的正是别人每个 SoC 都要写的那 4k～10k 行专属固件，而且这块板连 datasheet 都没有"。

---

## 6. 可复用的 Realtek 厂商/第三方源码（能让"现代 U-Boot 移植"少走弯路）

| 仓库 | 内容 | U-Boot 版本 | 许可 | 对本项目的价值 |
|---|---|---|---|---|
| https://github.com/BPI-SINOVOIP/BPI-W2-bsp | Banana Pi W2（RTD1296）BSP：**U-Boot 2015.7 + Linux 4.9.119**、build.sh | **2015.07**（无 EFI_LOADER，见 §3.1） | 仓库未标 license；**U-Boot 部分本身是 GPL-2.0+**（https://github.com/u-boot/u-boot/blob/master/Licenses/gpl-2.0.txt ），Linux 部分 GPL-2.0 | **最有价值**：U-Boot 里的 eMMC/USB/GMAC/串口寄存器操作可直接抄；内核里的 `rtkemmc.c`/`r8169soc_rtd119x.c`/`dwc3-rtk.c`/`pinctrl-rtd129x.c` 是寄存器事实来源 |
| https://github.com/jjm2473/BPI-W2-bsp | 同 BSP 的 fork（RTD1296） | 2015.07 | 同上 | 同上（可对比修改） |
| https://github.com/jjm2473/build-raycloud | RTD1296（小睿私人云）固件构建脚本 | —— | MIT（GitHub API 标） | 板级打包/刷机流程参考 |
| https://github.com/jjm2473/BPI-1296-Android6 、`.../BPI-1296-Android7` | BPI-W2 Android BSP | 2015.07 系 | 未标 | 外设初始化参考 |
| 群晖 DS218 GPL 源码（Realtek RTD129x 4.4 内核 + u-boot） | 厂商 BSP | 2015.07 系 | GPL-2.0 | 同族参考；**下载入口未验证/TODO** |
| OpenWrt / Entware | 需核查是否有 RTD129x target | —— | —— | 【未验证/TODO】已知 OpenWrt 的 `realtek` target 是 RTL83xx 交换机，不是 RTD129x；不要期待现成固件 |

**共同结论**：所有可拿到的 Realtek BSP 都停在 **U-Boot 2015.07**，**没有 EFI_LOADER**（§3.1 已证 2015.07 无 `lib/efi_loader`）。它们能提供"寄存器级参考"，但**不能省掉现代 U-Boot 的移植工作**，只能把 eMMC/USB/GMAC 的试错从"猜寄存器"降到"抄寄存器"。

**许可注意**：U-Boot 是 GPL-2.0+，基于它修改/分发（尤其刷进产品）必须提供对应源码；Realtek 的 Linux 驱动同样是 GPL-2.0。若计划闭源分发固件，这条要提前和法律确认。

---

## 7. 工作量汇总（人周）

| 路线 | 乐观 | 现实 | 说明 |
|---|---|---|---|
| ③ 保留现有 U-Boot，不碰 UEFI | 0 | 0 | 继续用 `booti`/`bootm`；装 fnOS 够用 |
| ② 现代 U-Boot + EFI_LOADER | **6 人周** | **13.5 人周** | 前提：拿到 BPI-W2 BSP 源码 + eMMC 是 DW MSHC 兼容；若 eMMC 不兼容 +2～4 周 |
| ① 纯 EDK2 | **12 人周**（3 人月） | **36 人周**（9 人月） | 含 ACPI/DT 与 eMMC/USB 专属 DXE；不含"EDK2 崩溃后无 JTAG 的排查时间" |

含"上板等待/救砖演练"时，② 建议按 **3 个月**、① 按 **6～9 个月**做项目排期【推断】。

---

## 8. 风险与回滚

### 8.1 不可逆/高风险操作清单

1. **写低区（LBA 0～0x12FFF，38 MiB）**：全板唯一砖区。写坏 = 需要串口 ROM Monitor（Ctrl+Q + YMODEM）补最小集合约 1.2 MB（hwsetting 3 KB + bootcode 515 KB + FSBL 72 KB + BL31 25 KB + u-boot 604 KB），本仓库已实测走通（[`docs/04-recovery.md`](../../04-recovery.md)、[`firmware/RECOVERY.md`](../../../firmware/RECOVERY.md)）。
2. **改 hwsetting**：它是 ROM 上电执行的硬件初始化脚本（DRAM/时钟/引脚），改错 = 连 FSBL 都进不去；且必须来自实测 dump，不能拿厂商包拼（[`firmware/README.md`](../../../firmware/README.md) §1）。
3. **写 SPI NOR**：8 MiB 已用 ~90.6%，**禁止写入**（[`docs/01-hardware-and-boot.md`](../../01-hardware-and-boot.md) §4）。
4. **没有 JTAG**：所有调试只能靠串口输出 + 反复刷/重启；现代 U-Boot 早期崩溃可能"零输出"，排查成本极高。

### 8.2 回滚方案（按风险从低到高）

| 阶段 | 回滚方式 | 前提 |
|---|---|---|
| 只改 p1 内核/DTB | 覆盖回旧文件（保留 `.bak`） | 系统能起或 u-boot 能进 |
| 只换 bootcode 槽（低区局部） | 用原始低区 dump 整块写回（md5 `22dc832126b42cd1b2f77e305e13c76b`） | 低区备份在手 + 串口可用 |
| 整条低区被改（hwsetting 也动） | ROM Monitor YMODEM 恢复最小集合 | 已演练过 ROM Monitor 流程 |
| 彻底变砖 | Windows USB MP Tool（Kylin 量产工具）/ 串口 ROM Monitor | 厂商工程配置；**本仓库缺配置，未验证**（[`docs/10`](../../10-vendor-usb-mp-tool-package.md) §4） |

**建议的推进纪律**（与仓库既有纪律一致）：

1. 动低区前**先整段 dump 并核对 md5**；
2. 新 U-Boot 先在 RAM 里跑（ROM Monitor `h/s/d/g` 或 TFTP 载入后 `go`）**验证串口/EFI 能起来**，再考虑写低区；
3. 低区镜像与 hwsetting 的改动单独走一次"演练模式"（内容不变的写回，验证流程）；
4. 全程不写 SPI。

---

## 9. 分级结论（回答用户原问题）

### ① 纯 EDK2 替代 U-Boot：**不可行（成本极高，不建议）**

- tianocore 无 Realtek 平台，EDK2 需要为每个 SoC 写 4,000～10,000 行专属 DXE/平台代码，本板无 datasheet、无 JTAG；
- 需要自写：eMMC host DXE（DW MSHC 兼容未证）、USB3 dwc3/PHY、变量存储（无 NVRAM）、RTC、ACPI 表；
- 与本板内核（vendor DT 驱动）存在 **ACPI vs DT** 路线冲突，即使 EDK2 能启动 Linux，装好的系统也可能找不到 eMMC/网卡；
- 量化：**3～9 人月**，失败模式多且难调试。

### ② 现代 U-Boot + EFI_LOADER：**可行，但属于"重移植项目"**

- 上游 U-Boot **无 RTD129x 支持**（§2），必须新建 board/defconfig/DTS 并移植 eMMC/USB/GMAC/串口；
- EFI_LOADER 自 **v2016.05** 起可用、v2016.11 起有 bounce buffer，建议直接用 2024/2025 版本；
- 工作量 **6～13.5 人周**（乐观/现实），最大风险：**eMMC 控制器兼容性 + FSBL/BL31 handoff + bootcode 槽位只有 574 KiB + 无 JTAG**；
- 成功后的收益：能 `bootefi` 启动 GRUB/`bootaa64.efi`、UEFI arm64 安装镜像；
- 前提：先拿到 BPI-W2 BSP 的 U-Boot 2015.07 源码当寄存器参考（§6），并接受低区改造的砖风险。

### ③ 保留现有 U-Boot 2015.07：**能做/不能做**

- **不能**：启动 UEFI 安装镜像（无 `bootefi`/EFI_LOADER，且 2015.07 早于 EFI 支持）；
- **能**：`booti` 裸 arm64 Image、`bootm` legacy uImage/FIT、TFTP/U 盘/`loady`、`ext4load`、`mmc`/`usb`/`sata`、`fastboot`（含 Realtek OEM）；
- **对"装 fnOS"这个真实目标**：现有 U-Boot 已经够用（本仓库就是靠它 + legacy uImage 跑通的）；**UEFI 不是装 fnOS 的必要条件**。

### 建议

1. **如果目标只是"把 UEFI arm64 安装镜像跑起来"**：优先考虑"**不换固件**"的替代路径——用现有 U-Boot 的 `booti` 引导**Linux 安装器内核**（Debian/fnOS 安装器本质也是 Linux），或用 U 盘里的 `bootaa64.efi` 之外的传统引导方式；这比移植现代 U-Boot 便宜两个数量级。
2. **如果必须"真 UEFI 固件"**（例如要做通用 arm64 镜像启动、efibootmgr 维护启动项）：走 ②，按"先 RAM 验证、再局部低区、最后 hwsetting"的顺序，预留 3 个月。
3. **不建议**投入 ①（纯 EDK2）。

---

## 10. 证据索引（全部 URL）

### 10.1 本仓库内证据

| 事实 | 位置 |
|---|---|
| 启动链、BL31/TEE/BOOTCODE 加载地址与大小、BL31 v1.2、OP-TEE 2.1、EL2 | [`evidence/logs/uboot-rescue-2026-10-05.log`](../../../evidence/logs/uboot-rescue-2026-10-05.log) 第 1～70 行 |
| 低区偏移（hwsetting 0x20000、bootcode 0x20E00、TEE 0xB0600、BL31 0x12C400、u-boot 0x7F300）、env 双副本 | [`firmware/RECOVERY.md`](../../../firmware/RECOVERY.md) §二/§四·五 |
| bootcode 大小字段 0x7DC00/0x7DC20、hwsetting 字段在 +0x004..+0x010、3100 B | [`firmware/README.md`](../../../firmware/README.md) §1、[`firmware/RECOVERY.md`](../../../firmware/RECOVERY.md) §二、[`docs/10`](../../10-vendor-usb-mp-tool-package.md) §5 |
| U-Boot `help` 全表（有 booti/ext4load/setenv/saveenv，无 bootefi）、内存加载地址、`rtkspi/go all` | [`docs/reports/stage0-complete-report.md`](../stage0-complete-report.md) |
| 主线 Linux 对 RTD1296 的支持现状（无 eMMC/GMAC 驱动、只有串口/GIC/timer/watchdog） | [`docs/reports/driver-inventory.md`](../driver-inventory.md) |
| 禁止写 SPI、低区纪律、ROM Monitor 救砖 | [`docs/01-hardware-and-boot.md`](../../01-hardware-and-boot.md)、[`docs/04-recovery.md`](../../04-recovery.md) |

### 10.2 外部证据（本次直接访问，HTTP 200/404 已校验）

| 结论 | URL |
|---|---|
| U-Boot mainline 无 `board/realtek`（404） | https://api.github.com/repos/u-boot/u-boot/contents/board/realtek |
| U-Boot mainline board 树（4,139 文件，无 realtek） | https://github.com/u-boot/u-boot/tree/master/board |
| U-Boot mainline configs（1,563 文件，无 rtd129x） | https://github.com/u-boot/u-boot/tree/master/configs |
| `rtd1296_defconfig` 不存在（404） | https://github.com/u-boot/u-boot/blob/master/configs/rtd1296_defconfig |
| U-Boot MAINTAINERS 无 Realtek/RTD 条目 | https://github.com/u-boot/u-boot/blob/master/MAINTAINERS |
| lore `<u-boot>` 搜 `rtd1295` 仅 3 条 dts/upstream 同步 | https://lore.kernel.org/u-boot/?q=rtd1295 |
| U-Boot v2015.07 无 `lib/efi_loader`（目录页） | https://github.com/u-boot/u-boot/tree/v2015.07/lib |
| EFI_LOADER 首次出现于 v2016.05，ARM64/ARM + OF_LIBFDT，help 点名 GRUB | https://github.com/u-boot/u-boot/blob/v2016.05/lib/efi_loader/Kconfig |
| v2016.11 新增 EFI_LOADER_BOUNCE_BUFFER | https://github.com/u-boot/u-boot/blob/v2016.11/lib/efi_loader/Kconfig |
| master EFI_LOADER 依赖（BLK/128KiB 栈/LMB）、变量存储四选一、EFI_RT_VOLATILE_STORE | https://github.com/u-boot/u-boot/blob/master/lib/efi_loader/Kconfig |
| UEFI on U-Boot 文档（EBBR、GRUB 示例、SetVariable runtime 限制、fdtcontroladdr） | https://github.com/u-boot/u-boot/blob/master/doc/develop/uefi/uefi.rst |
| U-Boot ARM `POSITION_INDEPENDENT`（ARM64 支持） | https://github.com/u-boot/u-boot/blob/master/arch/arm/Kconfig |
| 可复用通用驱动：ns16550 / dw_mmc / xhci-dwc3 / rtl8169(PCI) | https://github.com/u-boot/u-boot/blob/master/drivers/serial/ns16550.c 、https://github.com/u-boot/u-boot/blob/master/drivers/mmc/dw_mmc.c 、https://github.com/u-boot/u-boot/blob/master/drivers/usb/host/xhci-dwc3.c 、https://github.com/u-boot/u-boot/blob/master/drivers/net/rtl8169.c |
| U-Boot GPL-2.0 许可文本 | https://github.com/u-boot/u-boot/blob/master/Licenses/gpl-2.0.txt |
| edk2-platforms 无 Realtek 平台（Platform 列表） | https://github.com/tianocore/edk2-platforms/tree/master/Platform |
| DW MSHC eMMC DXE（可复用件） | https://github.com/tianocore/edk2-platforms/blob/master/Silicon/Synopsys/DesignWare/Drivers/DwEmmcDxe/DwEmmcDxe.inf |
| EDK2 作为 BL33 的平台先例（Juno / LX2160A / RPi4 / Marvell / Sophgo） | https://github.com/tianocore/edk2-platforms/blob/master/Platform/ARM/JunoPkg/ArmJuno.dsc 、https://github.com/tianocore/edk2-platforms/blob/master/Platform/NXP/LX2160aRdbPkg/LX2160aRdbPkg.dsc 、https://github.com/tianocore/edk2-platforms/blob/master/Platform/RaspberryPi/RPi4/RPi4.dsc |
| EDK2 通用件：SerialDxe / TimerDxe / ArmGicDxe / Fat / PartitionDxe / VariableRuntimeDxe / MmcDxe | https://github.com/tianocore/edk2/blob/master/MdeModulePkg/Universal/SerialDxe/SerialDxe.inf 、https://github.com/tianocore/edk2/blob/master/ArmPkg/Drivers/TimerDxe/TimerDxe.inf 、https://github.com/tianocore/edk2/blob/master/ArmPkg/Drivers/ArmGicDxe/ArmGicDxe.inf 、https://github.com/tianocore/edk2/blob/master/FatPkg/EnhancedFatDxe/Fat.inf 、https://github.com/tianocore/edk2/blob/master/MdeModulePkg/Universal/Disk/PartitionDxe/PartitionDxe.inf 、https://github.com/tianocore/edk2/blob/master/MdeModulePkg/Universal/Variable/RuntimeDxe/VariableRuntimeDxe.inf 、https://github.com/tianocore/edk2/blob/master/EmbeddedPkg/Universal/MmcDxe/MmcDxe.inf |
| BPI-W2 BSP（U-Boot 2015.7 + Linux 4.9.119，README 原文） | https://github.com/BPI-SINOVOIP/BPI-W2-bsp |
| jjm2473 BSP fork / raycloud 构建脚本 / Android BSP | https://github.com/jjm2473/BPI-W2-bsp 、https://github.com/jjm2473/build-raycloud 、https://github.com/jjm2473/BPI-1296-Android6 |

---

## 11. 未验证 / TODO 清单（后续研究项）

> **2026-10-22 追加**：§12 的 Armbian 线索已解决其中若干项（eMMC 确认为 DW MSHC 兼容、上游无支持的定性、lore 检索）；未解决项在 §12 之后仍然有效。§4.5/§7 的旧工作量估算以 §12.3 为准。

1. **hwsetting 字段精确布局**：`+0x004..+0x010` 各长度字段的准确偏移/顺序、bootcode 长度字段能否安全增大、TEE/BL31 偏移字段是否可后移。**这是能否装下现代 U-Boot 的关键**。
2. **FSBL → BL31 → BL33 handoff**：BL31 v1.2 传给 BL33 的 x0/x1 是什么、是否带 FDT；现代 U-Boot 的 `CONFIG_OF_*` 如何拿到 CM360 DTB。
3. **eMMC 控制器是否 DW MSHC 兼容**：对比厂商 `rtkemmc.c` 寄存器与 `dw_mmc.c`；若兼容，U-Boot/EDK2 都能省 1～3 人周。
4. **U-Boot 的 `dts/upstream` 是否已包含 `arch/arm64/boot/dts/realtek/rtd1296*`**：若包含，DT 可直接借用；本次未核实。
5. **lore/patchwork 的 `rtd1195`、`rtd1296`、`bpi-w2`、`realtek` 检索**：本次只完成 `rtd1295`（lore 3 条、无板级支持），patchwork API 404，需换页面/搜索方式复核。
6. **群晖 DS218 GPL 源码入口与许可**：Realtek u-boot/内核源码的下载 URL 未验证。
7. **OpenWrt/Entware 是否有 RTD129x target**：未验证；已知 OpenWrt `realtek` target 是 RTL83xx。
8. **EDK2 BL33 在本板 BL31 v1.2 下的实际可启动性**：未上板验证（本任务禁止上板/刷写）。
9. **EFI 变量存储落点**：FAT 文件（ESP 内）是否可靠、安装器行为；未实测。
10. **EFI memory map 中 BL31/TEE 的 reserved 描述**：需要 DT `reserved-memory` 或 U-Boot 内存节点补；未实测。

---

## 12. ★ 追加研究（2026-10-22）：Armbian 的 RTD129x 外挂补丁 —— "事实上的下游支持"

> 本节是对 Lead 提供的线索的直接核实结果，**推翻/修正了 §2 与 §4.5 的"工作量"判断，但不改变"上游无支持"的定性**。

### 12.1 事实清单（全部外部已验证，URL 见每行）

| 项 | 内容 | URL |
|---|---|---|
| 家族配置 | `ARCH=arm64`、`LINUXFAMILY=realtek-rtd129x`、`SERIALCON=ttyS0:115200`、`BOOTBRANCH="tag:v2026.10-rc5"`、`BOOTPATCHDIR="v2026.10-rtd129x"`、`UBOOT_TARGET_MAP=";;u-boot.bin rtd129x-emmc-boot.bin"`、`ATF_COMPILE="no"` | https://github.com/armbian/build/blob/main/config/sources/families/realtek-rtd129x.conf |
| 关键注释 | "**No ATF: U-Boot and Linux start at EL3/EL2 from the Realtek loader**"；eMMC boot area 由 `mkbootarea.py` 用出厂 blobs + 本 U-Boot 拼装，写到 eMMC 0x20000 | 同上 |
| 补丁目录（17 个） | `patch/u-boot/v2026.10-rtd129x/0001..0017`（2026-10-12/13/17，作者 Igor Pecovnik） | https://github.com/armbian/build/tree/main/patch/u-boot/v2026.10-rtd129x |
| tag 存在性 | `v2026.10-rc5` 在 U-Boot 仓库中存在（该 tag 下 raw 文件 200） | https://github.com/u-boot/u-boot/tree/v2026.10-rc5 |
| 上游无 | `bananapi-w2_defconfig` 在 U-Boot master **404**（该 defconfig 是补丁 0001 新建的）；`board/realtek` 404；MAINTAINERS 无条目 | https://github.com/u-boot/u-boot/blob/master/configs/bananapi-w2_defconfig |
| 出厂 blobs | `hwsetting.bin` 1,856 B、`fsbl.bin` 72,452 B、`tee.bin` 507,524 B、`bl31.bin` 25,156 B；README 原文："**FSBL, TEE and BL31 are encrypted by Realtek**"；"mkbootarea.py puts them together with a U-Boot into the boot area that the BPI-W2 SPI loader reads from **eMMC byte 0x20000**" | https://github.com/armbian/build/tree/main/packages/blobs/rtd129x |
| 拼装脚本 | boot area = 8×u32 尺寸表 + SHA-256，然后 hwsetting、**U-Boot（固定部分上限 `UBOOT_DATA=0x93780`）**、FSBL、TEE、BL31；每段后跟 SHA-256 padding/digest；输出写到 eMMC 0x20000 | https://github.com/armbian/build/blob/main/packages/blobs/rtd129x/mkbootarea.py |

补丁内容分组（本次逐个下载原文核对，文件与 Subject 一一对应）：

| 组 | 补丁 | 关键事实 |
|---|---|---|
| 板/SoC 骨架 | 0001 | 新增 `ARCH_RTD129X`（**select ARM64/DM/DM_SERIAL/OF_CONTROL**）、`board/bananapi/bpi-w2/`、`arch/arm/mach-rtd129x/`、`configs/bananapi-w2_defconfig`、`rtd1296-bananapi-w2.dts`；commit message 原文："Serial console, generic timer and DRAM from the device tree. **Loaded by the Realtek bootcode at 0x10000000; runs at EL3.**"；`TEXT_BASE=0x10000000`、`ENV_IS_NOWHERE=y`、`# CONFIG_NET is not set` |
| SD + watchdog | 0002 | SD host 驱动 `drivers/mmc/rtd129x_sdmmc.c`（627 行，polled + bounce DMA，4-bit 25 MHz，移植自 JalenLin 的 Linux 驱动）；`reset_cpu()` 走 ISO watchdog |
| **eMMC（DW MSHC）** | 0004、0009、0010 | eMMC host = `drivers/mmc/rtd129x_dw_mmc.c`（**231 行胶水**）+ 对 `drivers/mmc/dw_mmc.c` 的 28 行 hook：**DesignWare IDMAC 需要 bus-bridge sync、每次传输 DMAC reset、等最后读数据、描述符链收尾**；0010 修好 eMMC **写**（`busy_stuck`、单传输） |
| SMP | 0003、0008、0011 | **不用 PSCI**：boot ROM 把从核停在 EL3，U-Boot 设 GIC 后降到 EL2，Linux 用 **spin-table**（`cpu-release-addr`）；0008 处理"SD 路径从核在 0x20000 重新跑 U-Boot"的问题 |
| EL/MMU | 0007 | vendor U-Boot `go` 起来时 MMU 是开的，U-Boot 在 `arch_cpu_init()` 里关掉重设页表 |
| 启动 | 0005、0012、0014、0015 | 切 `TEXT_BASE=0x20000`（"vendor loader puts U-Boot from the SD card"）+ `POSITION_INDEPENDENT=y` + `BOOTSTD_DEFAULTS`（boot.scr，**不用 EFI**）；initrd 0x30000000；image-fdt 的 reserved 区 `-EEXIST` 修正；0015 原文："**Disable the EFI loader: Armbian boots with boot.scr**" → `# CONFIG_EFI_LOADER is not set` |
| DRAM | 0016 | eMMC boot area 只初始化一个 DRAM controller，上 1 GiB 会别名 → eMMC 启动时**限 1 GiB**；SD 启动才 2 GiB |
| 其他 | 0006/0013 | audio CPU 启动命令/桩；0017 eth1 LED |

### 12.2 回答 Lead 的 5 个问题

**Q1：17 个补丁是否包含 eMMC/SD、串口、定时器、PSCI？有没有 USB（dwc3/xhci）？**

| 能力 | 有无 | 证据 |
|---|---|---|
| **eMMC** | ✅ 有 | 0004（DW MSHC host + glue）、0009（eMMC pin function）、0010（eMMC 写可用） |
| **SD 卡** | ✅ 有 | 0002（`rtd129x_sdmmc.c` 627 行，实测 FAT/ext4 读 7.5 MiB/s） |
| **串口** | ✅ 有 | 0001：`DM_SERIAL` + `CONFIG_SYS_NS16550` + DTS `snps,dw-apb-uart`、`skip-init`（沿用 bootcode 的 115200）、`DEBUG_UART_BASE=0x98007800` |
| **定时器** | ✅ 有 | 0001：DTS `arm,armv8-timer` + `CONFIG_COUNTER_FREQUENCY=27000000`（generic timer，无 SoC 驱动） |
| **PSCI** | ❌ **没有** | 0003/0008 明确用 **spin-table**（"Linux cannot run at EL3, so U-Boot releases them here"），补丁全文无 `PSCI` 字样；因为设计上 **没有 ATF** |
| **USB（dwc3/xhci）** | ❌ **完全没有** | 17 个补丁中 `dwc3`/`xhci`/`usb` **0 命中**；defconfig 也没有 USB；NET 也被显式关闭 |

→ **打开 EFI_LOADER 后能否从 FAT 起 GRUB**：
- **从 eMMC 的 FAT/ESP：可以**（eMMC 块设备 + FAT + 写都已具备；EFI 变量文件存储需要 FAT 写，0010 已修好 eMMC 写）。
- **从 SD 卡 FAT：可以**。
- **从 U 盘：不行**——这块板/这套 U-Boot **没有 USB 驱动**，EFI_LOADER 打开也没法从 U 盘读 `bootaa64.efi`；要补 dwc3 host + xHCI + PHY（估 1～2 人周，可参考 Linux 主线 `dwc3-rtk.c`/`phy-rtk-usb3.c`）。

**Q2：这套 U-Boot 预期运行在哪个 EL？是"替代 BL31+U-Boot 整条链（EL3 起）"还是"BL31 之后的 BL33"？**

- **eMMC boot area 路径（Armbian 主路径）**：补丁 0001 原文 "Loaded by the Realtek bootcode at **0x10000000**; **runs at EL3**"；conf 的 `ATF_COMPILE="no"` + 注释 "**No ATF**"；SMP 用 spin-table 从 EL3 放从核到 EL2（0003）。⇒ **它是"BL31 替代 + BL33"合一**：设计意图是**不经过 ATF/BL31**，U-Boot 自己在 EL3 接管，Linux 的从核用 spin-table 而非 PSCI。
- **SD 路径（0005/0007）**：`TEXT_BASE=0x20000` + PIE，"vendor loader puts U-Boot from the SD card"；0007 处理 **vendor U-Boot `go` 启动它时 MMU 是开的**。⇒ 这一模式是"**已有 vendor 链之后的二级 payload（BL33 位置）**"。
- **对本板（CM360）**：我们的链条是 **FSBL → BL31(v1.2) → BL33@0x20000/EL2**，FSBL 按 hwsetting **必定加载并跳转 BL31**（[证据：本机日志](../../../evidence/logs/uboot-rescue-2026-10-05.log)）。所以：
  - Armbian 的 **EL3/无 ATF 模式在本板直接不可用**——BL31 已经占了 EL3；除非能让 FSBL 不加载/不跳 BL31（hwsetting/FSBL 都是厂商加密件，不可控，风险极高）。
  - 结构上**可复用的是 SD 路径模式**：把 U-Boot 编成 PIE/TEXT_BASE=0x20000，作为 **BL31 之后的 BL33 在 EL2 运行**；但必须**删掉/关闭补丁 0003/0008 的 EL3 spin-table SMP 逻辑**（本板由 BL31 管从核，Linux DTS 应继续用 PSCI 或 vendor 的 rtk-spin-table），并重新验证 EFI runtime 在 EL2 下的行为。
  - 另有一条硬事实：Armbian README 明说 **FSBL/TEE/BL31 是 Realtek 加密的**，这三段**不能重编**；能替换的只有 U-Boot 段。我们板子的低区正是这五段结构（hwsetting + bootcode + TEE + BL31 + u-boot），所以"只换 U-Boot 段"与 Armbian 的做法一致。

**Q3：上游 mainline 是否确实没有 ARCH_RTD129X/board realtek？**

**是，确认无上游。** `board/realtek` → 404；`configs/bananapi-w2_defconfig` → 404（该文件由 Armbian 补丁 0001 新建）；`MAINTAINERS` 无 Realtek/RTD 条目；lore `<u-boot>` 搜 `rtd1295` 仅 3 条 2024 年 `dts/upstream` 同步。
定性：**"上游无、Armbian 外挂补丁"**——Armbian 在 **tag `v2026.10-rc5`** 上叠加 **17 个补丁**（`BOOTPATCHDIR=v2026.10-rtd129x`），补丁 URL 见 §12.1。这套补丁不是 upstream RFC，也不会自动进 mainline；**上游支持仍然为零**。

**Q4：EFI_LOADER 从哪个版本成熟/默认开启？开它需要哪些 CONFIG？arm64 已知限制？**

- 引入 **v2016.05**（`lib/efi_loader/Kconfig` 首次出现，`depends on (ARM64 || ARM) && OF_LIBFDT`，help 点名 GRUB2）；**v2016.11** 加 `EFI_LOADER_BOUNCE_BUFFER`。
- **默认开启**：现代 U-Boot Kconfig 是 `default y if !ARM || SYS_CPU = armv7 || SYS_CPU = armv8`，且依赖 `BLK`、`STACK_SIZE >= 0x20000`、`OF_LIBFDT`、`LMB`；但**具体板仍要**显式 `CONFIG_CMD_BOOTEFI=y` 和可用块设备/文件系统。Armbian 这套 defconfig 反而**显式关掉**（0015）。
- **"成熟"时间点**：v2019.07～v2020.10 起 `efidebug`/`CMD_NVEDIT_EFI`/自测齐备；但 U-Boot 官方文档明说 **v2020.10 时 runtime `SetVariable` 仍不支持**；现代（2024+）才有 `EFI_VARIABLE_FILE_STORE`（FAT 文件）/`EFI_VARIABLE_SF_STORE`/`EFI_MM_COMM_TEE`、`EFI_RT_VOLATILE_STORE`。
- **arm64 已知限制**：必须 64 位 + `BLK` + 128 KiB 栈；DMA 受限设备需要 `EFI_LOADER_BOUNCE_BUFFER`；给 OS/GRUB 的 DT 默认取自 `fdtcontroladdr`（U-Boot 自己的控制 DT，需显式传 CM360 DTB）；无 GOP 时只有串口控制台；runtime 变量写入受限（Linux 里 `efibootmgr` 可能失败）；OP-TEE 变量后端要求 OP-TEE 侧有 StandAloneMM（本板 OP-TEE 2.1 太老，几乎不可能）。

**Q5：EDK2 侧一句话定性。**

**无 Realtek 平台、无可复用 BSP**：`edk2-platforms` 的 `Platform/` 21 个目录里没有 Realtek；每个 ARM 平台都要自带 SoC 包 + eMMC/USB/串口/RTC/变量存储 DXE + ACPI/DT，RTD1296 这些全是零（详见 §5，仍是"不现实/3～9 人月"）。

### 12.3 修正后的工作量（以 Armbian 补丁为起点）

| 项 | 处理 | 估时 |
|---|---|---|
| board/mach/defconfig/DTS、串口、timer | 直接复用 Armbian 0001/0005，改 CM360 硬件参数（2 GiB DRAM、reserved-memory、hwsetting 布局） | 3～5 天 |
| eMMC（DW MSHC） | 直接复用 0004/0009/0010（231 行 glue + dw_mmc hooks）；**eMMC 兼容性疑点已由此解决** | 2～4 天（含上板） |
| SD 卡 | 复用 0002 | 0～2 天 |
| BL33/EL2 适配 | 关掉/绕开 0003/0008 的 EL3 spin-table SMP；确认 BL31 v1.2 → BL33@0x20000 的 handoff、PIE、DT 传递 | 1～2 周（最大不确定项） |
| EFI_LOADER + 变量存储 | 打开 `EFI_LOADER/CMD_BOOTEFI/BLK/PARTITIONS/FAT/FAT_WRITE`，变量用 FAT 文件；确认 0x8F800 槽位放得下 | 1 周 |
| **USB（U 盘启动安装器）** | **没有现成补丁**，需新写 dwc3 host/xHCI/PHY | **1～2 周** |
| 低区 boot area 容器 | 用 `mkbootarea.py` 思路生成 CM360 版 boot area；处理 0x8F800（我们）vs 0x93780（Armbian 固定上限）的差异；刷写/回滚演练 | 1～2 周 |
| **合计** | | **3～6 人周**（乐观 2～3） |

风险提示：**这 17 个补丁非常新（2026-10-12/13/17），非上游、单一作者、测试面仅 BPI-W2**。拿来主义要接受"上游/社区还没长期验证"的风险；且 `v2026.10-rc5` 是 rc，正式 tag 未出。

### 12.4 对总结论的影响

- **② 从"8～14 人周重移植"下调为"3～6 人周适配"**（因为 board/串口/timer/eMMC/SD 都有人写好了），但两条硬限制不变：**(a) 我们的 FSBL/BL31 链决定了 U-Boot 只能在 EL2 当 BL33，Armbian 的 EL3/无 ATF 主路径不可直接用；(b) 没有 USB 驱动，EFI_LOADER 只能从 eMMC/SD 的 FAT 起 GRUB，不能从 U 盘起**。
- **① 纯 EDK2 结论不变**：仍不可行/3～9 人月。
- **③ 保留现有 U-Boot 结论不变**：仍不能 UEFI。
- 新增建议：如果目标是"**UEFI 安装镜像从 eMMC/SD 起**"，② 的现实路径 = **Armbian 17 补丁 + CM360 板级适配 + EL2/BL33 适配 + EFI_LOADER**；如果必须"**从 U 盘起**"，再加 USB 驱动（+1～2 周）。

---

*本报告只写固件侧事实与推断；所有"可行/不可行"判断均给出量化依据或明确标注为推断。未执行任何写 eMMC/串口/刷机操作。*
