# 12 · 能不能用 UEFI 替代 U-Boot，直接启动 ARM 安装镜像？

> 面向问题："给这块 CM360（Realtek RTD1296）做一个 UEFI 替代 U-Boot，直接插 U 盘启动
> UEFI ARM 安装镜像（Debian/Ubuntu arm64 netinst）装系统。"
>
> **结论先行**：拆成两件事看——
> 1. **"做一个 UEFI 固件"**：真·EDK2 不可行（没有任何上游/厂商平台可复用，3~9 人月）；
>    但 **"现代 U-Boot + `EFI_LOADER`"** 在 2026 年已经**从"没路"变成"可复用补丁 + 板级适配"**——
>    Armbian 给同 SoC（BPI-W2/RTD1296）维护着 mainline U-Boot v2026.10-rc5 + 17 个 RTD129x 补丁，
>    只是 defconfig 没开 EFI、也没有 USB。代价是动 eMMC 引导区（有砖风险）或做"双级引导"；
>    复用补丁约 **3~6 人周**，U 盘启动再补 USB **1~2 周**。
> 2. **"直接启动 UEFI 安装镜像装完系统"**：**这条路无论如何都走不通**，卡点不在固件，
>    而在**安装器的内核里没有 RTD1296 的 eMMC/SATA/网卡驱动**。就算 UEFI 固件完美、GRUB 菜单完美，
>    Debian/Ubuntu 的通用 arm64 安装器也会在"找不到磁盘/找不到网卡"这一步停死。
>
> **真正能落地的**：不动固件，用现有 U-Boot 已经实测跑通的 `bootm` 路线，引导一个
> **带本项目 6.6 内核 + 板级 DTB 的安装器/救援系统**（1~2 周），或者继续用仓库现成的
> `dd` 三层刷写链（天级）。详见 §5 的路线 A。

---

## 1. 先把"三层"拆开：固件 ≠ 安装器 ≠ 内核驱动

| 层 | 这块板现在是什么 | 通用 arm64 发行版给的是什么 | 换 UEFI 能改变哪一层 |
|---|---|---|---|
| ① 固件/引导 | Mask ROM → hwsetting → FSBL → BL31+TEE → **U-Boot 2015.07（BL33）** | UEFI 固件（放在 BL33 位置的 EDK2 或 U-Boot `EFI_LOADER`） | **只换这一层** |
| ② 安装器用户态 | 无（本项目直接 dd 写 rootfs） | Debian installer / Ubuntu subiquity | 不变 |
| ③ 安装器内核 | 本项目的 **Linux 6.6.54（vendor 树）+ 8 个补丁 + 板级 DTS** | 发行版主线的 `linux-image-*-arm64-di` | **不变（关键卡点）** |

**这张表就是全部答案**：换固件只动第①层；而"装完系统"取决于第③层有没有驱动。
主线 Linux 对 RTD1296 的支持到 2026-10 仍然只有：

```
arch/arm64/boot/dts/realtek/rtd129x.dtsi   uart / gic / timer / watchdog / reset / gpio（+ 保留内存）
arch/arm64/boot/dts/realtek/rtd1296.dtsi   4×CPU + PMU（无 psci/enable-method）
drivers/mmc/host/                          无 Realtek RTD 驱动
drivers/net/ethernet/realtek/              整族 depends on PCI（SoC 内嵌 GMAC 无驱动）
drivers/ata/                               只有 snps,dwc-ahci（缺 DT 节点/时钟/PHY）
drivers/clk/                               无 Realtek CCF
```

→ **eMMC 在主线完全没有驱动；SATA/USB 只有通用框架（`snps,dwc-ahci`、dwc3/PHY）但缺
DT 节点、时钟和 PHY 初始化；内嵌 GMAC 完全没有驱动**。它们只存在于本项目的 vendor 6.6 树
（`patches/`）和 Armbian 的 RTD129x 内核补丁集里。Debian d-i 用的内核是
`6.12.107+deb13-arm64-di`，模块集就是主线，**没有任何 RTD 驱动可加载** →
分区工具 `partman` 会看到 0 块盘。

> 安装器侧的一手证据（Debian 13.7.0 arm64 netinst 解包、d-i 内核版本、主线驱动矩阵）见
> [`docs/reports/uefi/installer-options.md`](reports/uefi/installer-options.md)。

---

## 2. 启动链允许换到哪一步？（本板实测）

可以换，而且位置很明确。本板低区布局（用 `tools/uefi/lowregion.py info` 可复现，见 §6）：

```
eMMC 偏移      内容                                     长度来源
0x0002_0000    hwsetting（ROM 在 blk#0x100 读）          3200 B + 0xFF 到 0xE00
0x0002_0E00    bootcode（Realtek 容器，内含 U-Boot）     hwsetting[1] + 0x20
0x0009_EC00    FSBL                                     hwsetting[2] + 0x20
0x000B_0600    TEE / BL32                               hwsetting[3] + 0x20
0x0012_C400    BL31（ATF v1.2）                          hwsetting[4] + 0x20
0x0013_2800    未知固件块（≈972 KiB，ARM64 代码）        ★ 无长度字段，含义未定
0x0022_0000    u-boot 环境（生效副本，blk#0x1100）      0x20A00
0x0042_0000    u-boot 环境（旧副本）
```

四段镜像按 hwsetting 的 4 个长度字段**顺序排布、0x200 对齐、段间 0xFF 填充**。
FSBL 日志（`evidence/logs/uboot-rescue-2026-10-05.log`，与本板现役低区同版本）直接印证：

```
[FSBL] ********** FW_TYPE_GOLD_TEE **********   FW Image to 0x10200000, size=0x0007BDA0  fr 0x000B0600
[FSBL] ********** FW_TYPE_GOLD_BL31 **********  FW Image to 0x10120000, size=0x000062A0   fr 0x0012C400
[FSBL] ********** FW_TYPE_BOOTCODE **********   FW Image to 0x00020000, size=0x0007DC20   fr 0x00020E00
```

即 **bootcode（U-Boot）是被 FSBL 拷到 RAM `0x20000` 执行的 BL33**。BL31 的日志还写明
`bl31 jumps to EL2`——**BL33 运行在 EL2**（不是 EL3、也不是 EL1）。换掉 bootcode = 换掉 BL33，
机制上成立。注意三点：

1. **bootcode 不是裸 `u-boot.bin`**，是 Realtek 私有容器（`0x28` 字节头 + 载荷 + 尾部，
   头里带加载地址 `0x20000` 和长度字段，语义只逆向到一部分）。**手搓容器 = 高风险**，
   要么用 Realtek BSP 的打包工具（BPI-W2 BSP 的 `u-boot-rtk` 2015.07 里就有 flash_writer/
   dvrboot 那一套），要么再逆向到位。
   好消息：同族的 **Armbian `packages/blobs/rtd129x/mkbootarea.py` 已经把 BPI-W2 的 boot area
   容器格式公开了**（8×u32 尺寸表 + SHA-256 + hwsetting/U-Boot/FSBL/TEE/BL31 各段 + 每段
   digest，写到 eMMC `0x20000`），可以作为打包/逆向的参照实现——但 CM360 的 hwsetting 是
   3200 B（BPI-W2 是 1856 B）、字段数也不同，仍要逐字段核对。
   另：Armbian README 明确 **FSBL/TEE/BL31 是 Realtek 加密件、不可重编**，能替换的只有
   U-Boot 这一段——这和我们低区的五段结构一致。
2. **"还剩多少空间"目前没有安全答案**（网上/报告里常见的两种算法都不对）：
   - 按"TEE 偏移 − bootcode 偏移"直接相减得 `0x8F800`（≈574 KiB）是**错的**——它漏掉了
     `0x9EC00` 的 FSBL 段（`lowregion.py` 已实测，`selftest` 逐字节重建通过）；
   - 按"bootcode 后面紧贴 FSBL"算，只剩 `0x7DE00 − 0x7DC20 = 0x1E0`（480 B）；
   - 但四段镜像是**按 hwsetting 长度字段顺序排布**的，bootcode 变长后 FSBL/TEE/BL31 会
     顺移，链尾正贴着 `0x132800` 起的**约 972 KiB 未知固件块**（含 mbedTLS/SHA256 字符串，
     疑为 TEE/FSBL_OS 类镜像），而它的偏移由谁计算**未确认**。
   → 结论：顺序布局"理论上能长"，但最坏情况余量是 0；**在未知块语义查清前，不把"空间够"当理由**。
3. **写坏低区的后果**：只能靠串口 ROM Monitor（`docs/04-recovery.md`，本项目实测走通过）或
   Windows USB MP Tool 救砖；没有 JTAG，也没有 SPI 可退。

> 所以：**"能不能换"= 能；"值不值得直接换低区"= 在双级引导验证充分之前，不值。**

---

## 3. 2026 年的新变量：Armbian 已经有 RTD129x 的 64 位 U-Boot 移植

先定两个基线事实：

- **上游 U-Boot 没有 RTD129x**：`u-boot/u-boot` master 的 `arch/arm/Kconfig`（2026-10 抓取）
  没有 `ARCH_RTD129X`，`board/realtek` 也不存在 → GitHub API 404。
- **EFI_LOADER 从 U-Boot v2016.05 才开始有**（`lib/efi_loader/Kconfig` 明确
  "run EFI applications (like grub2)"，`depends on (ARM64 || ARM) && OF_LIBFDT`），
  v2016.11 加 bounce buffer；实用上建议直接用 2024/2025 版本。

Armbian 的补丁把"从零写板级"降成"复用补丁 + 改配置"：

| 资产 | 内容 | 对本板的意义 |
|---|---|---|
| `armbian/build` 家族配置 `realtek-rtd129x` | `BOOTBRANCH=tag:v2026.10-rc5`、`BOOTPATCHDIR=v2026.10-rtd129x`（17 个 U-Boot 补丁，`ARCH_RTD129X select ARM64`）；"No ATF: U-Boot and Linux start at EL3/EL2 from the Realtek loader" | 同 SoC（BPI-W2）已有 64 位 U-Boot 板级支持：`0001` 串口（ns16550 skip-init）/timer、`0002` SD（627 行）、`0004` eMMC（DW MSHC glue 231 行）、`0009/0010` pin/写保护 |
| 但 **没有 PSCI、没有 USB** | `0003/0008` 用 **spin-table**（设计上无 ATF）；`dwc3/xhci/usb` 在 17 个补丁里 **0 命中** | 本板固定是 `FSBL → BL31 v1.2 → BL33@0x20000/EL2`，所以只能复用它的 **SD/EL2 二级 payload 模式**，且必须关掉 spin-table SMP；U 盘启动要自己补 USB（+1~2 周） |
| `configs/bananapi-w2_defconfig` | 仅 20 行；`CONFIG_ENV_IS_NOWHERE=y`、`# CONFIG_NET is not set`、并且 **`# CONFIG_EFI_LOADER is not set`**（`0015` 仍走 `boot.scr`）；无 `CMD_BOOTEFI`/`BLK`/`PARTITIONS` | **UEFI 能力是"改 defconfig 重编"级别的活**，不是驱动级移植；但当前 Armbian 产物没有 UEFI |
| EL 定位（关键） | eMMC 路径：U-Boot 由 Realtek bootcode 装到 **`0x10000000`、在 EL3 跑**，是"BL31 替代 + BL33 合一"（`ATF_COMPILE=no`）；SD 路径：**`0x20000`/PIE 的二级 payload**（`0007` 修 vendor U-Boot `go` 的 MMU） | 与**本板现状冲突**（本板 BL33 在 `0x20000`、EL2、BL31 常驻）→ 只能走 SD/EL2 模式 + 关 EL3 补丁；这是路线 B 的最大不确定性 |
| `packages/blobs/rtd129x/mkbootarea.py` | 拼 eMMC boot area；`UBOOT_DATA=0x93780`（Armbian 自己那份 U-Boot 已经比我们现役的 `0x7DC20` 大） | 提供了"写进 eMMC 引导区"的打包路径（也就是 §2 的 bootcode 槽）；也说明"空间"这关要过 |
| Armbian 内核 `realtek-rtd129x-6.18` | 29 个补丁：SD/eMMC host、内嵌 GMAC、SATA PHY、irqchip、SMP、CLK、USB、Thermal… | 除了 vendor 6.6，多了一个**可维护的 mainline 6.18 内核来源**（CM360 仍需新写板级 DTS） |
| FSBL/TEE/BL31 | 没有可重建源码（Armbian 的 blobs README 把它们当不可重建件） | **能换的只有 U-Boot 这一段**；BL31 v1.2 + TEE v2.1 是固定前提 |

> 全部 URL 与逐条证据见 [`docs/reports/uefi/firmware-options.md`](reports/uefi/firmware-options.md)
> §2/§12 与 [`docs/reports/uefi/installer-options.md`](reports/uefi/installer-options.md) §2.4/§4.3。
>
> **工作量以固件报告的最终修正为准**：路线 B 从初稿的 8~14 人周下调为 **3~6 人周**（乐观 2~3），
> 前提是复用 Armbian 的 board/串口/timer/eMMC/SD 补丁；**再加 USB 补丁 1~2 周**（若要从 U 盘启动）。
> 最大风险不再是"从零写驱动"，而是 **EL3 vs EL2/BL33 handoff** 与低区 bootcode 槽位。

---

## 4. "直接跑 UEFI 安装镜像"到底卡在哪（逐项）

| 阶段 | 通用安装器 + 完美 UEFI（假设） | 说明 |
|---|---|---|
| 进 GRUB 菜单 | 🟡 需要 UEFI 固件 + 串口输入协议（`SIMPLE_TEXT_INPUT`）；U-Boot `EFI_LOADER` 是否提供未验证 | 只能靠超时自动引导，菜单可能点不了 |
| GRUB 加载内核 | 🟡 GRUB arm64 的 `linux` **只吃带 EFI stub 的 PE/COFF Image**（源码原文：`plain image kernel not supported - rebuild with CONFIG_(U)EFI_STUB enabled`） | vendor 6.6 内核若没开 `CONFIG_EFI` 连 GRUB 都过不了 |
| 起安装器 UI | 🟡 内核没有 CM360 的 DTB（主线只有极简 rtd1296-ds418 之类） | 可能只有单核、中断不通 |
| 找安装介质 | 🟡 UEFI 固件读 ISO/FAT 是固件的事；但还要内核 `isofs`/`usb-storage` | d-i 的 `hd-media` initrd 才有 iso-scan 那套 |
| **识别磁盘（eMMC/SATA）** | ❌ **主线无驱动** | **硬阻塞 1** |
| **识别网卡** | ❌ **主线无 SoC GMAC 驱动** | **硬阻塞 2**（netinst 必须联网） |
| 装引导器 | ❌ d-i 默认装 `grub-efi-arm64` 到 ESP，与本板 `booti` + p1 链不符 | 要 preseed 跳过（`nobootloader`）或改成写 p1 |

**结论：能进安装器界面已经很难，装完并首启基本不可能。** 这不是"再努力一点"的问题，
是发行版内核里根本没有这些驱动，而你无法给 d-i 的官方内核"插驱动"。

> 安装器侧完整拆解（Debian/Ubuntu ISO 引导链、d-i 内核版本、hd-media/netboot/u-boot 三套形态、
> GRUB EFI stub 要求）见 [`docs/reports/uefi/installer-options.md`](reports/uefi/installer-options.md)。

---

## 5. 四条路线：代价、效果、风险

| 路线 | 做什么 | 能达成的效果 | 工作量 | 风险 | 结论 |
|---|---|---|---|---|---|
| **A. 不动固件 + 自建安装器**（推荐） | 用现有 U-Boot 实测跑通的 `bootm`（legacy uImage + initrd）引导"本项目 6.6 内核 + 板级 DTB + 安装器 initramfs/live rootfs" | 插 U 盘 → 跑安装器 → 分区/格式化 p1/p2/写 rootfs，装完用现有 `bootcmd` 首启 | **1~2 人周** | 低（只写 p1/p2，低区不碰） | ✅ **先做这个** |
| **B. 双级引导 + 现代 U-Boot(EFI_LOADER)** | 保留现有 U-Boot 当 BL33（不刷低区）；把现代 U-Boot 编成第二级（Armbian 的 SD/EL2 payload 模式），放 eMMC p1 / TFTP，`mmc read`/`tftp` + `go` 起；开发期全程 RAM 试验 | 能进 UEFI Shell/GRUB、能跑 `bootaa64.efi`；**装系统仍要接 A 的定制内核 payload** | **3~6 人周**（复用 Armbian 补丁，乐观 2~3；不用补丁则 8~14）+ **USB 1~2 周**（要从 U 盘起才需要） | 中（不碰低区 → 可回滚；EL3↔EL2/BL33 handoff、无 USB、低区槽位是主要不确定性） | 🟡 想要 UEFI 体验再走 |
| **C. 直接换低区 bootcode** | 把 B 的产物打包成 Realtek 容器，写 0x20E00，改 hwsetting 长度字段，处理未知块位移 | 同 B，少一级引导 | B 的 3~6 周 + 打包/逆向 1 周 | **高（砖）**：写坏只能串口救；未知块偏移未确认 | ❌ 除非 B 完全验证，否则不做 |
| **D. 真 EDK2（替代 U-Boot）** | 给 RTD1296 写 EDK2 平台：串口/定时器/GIC/MMU + DXE 驱动（eMMC、USB、FAT、GOP、变量存储…） | 真 UEFI 固件 | **3~9 人月** | 极高：无上游平台、无 SoC 文档、无 JTAG；`edk2-platforms` 里没有 Realtek | ❌ 不推荐 |

> 补充一条"经济性"判断：如果目标是"有一台能跑 UEFI 装 Debian 的 ARM 小机器"，
> 同样预算下买一块支持 UEFI 的板子（或 x86 小主机）比给这颗 SoC 补 UEFI 便宜一个数量级。
> 这块板的价值在于"它已经能跑 fnOS/Linux 6.6"，而不是"把它变成 PC"。

---

## 6. 推荐执行顺序（如果目标是"能装系统"，不是"造固件"）

### 阶段 0（半天）：先验证"能启动 ≠ 能装完"这个判断

不需要刷机、不需要 U 盘：

```sh
# 1) 校验低区布局模型（只读，不写设备）
python3 tools/uefi/lowregion.py info
python3 tools/uefi/lowregion.py check
python3 tools/uefi/lowregion.py selftest      # 应输出 PASS

# 2) 复核本板 U-Boot 能力（串口）
#    help            → 确认无 bootefi；有 booti/bootm/fatload/usb/mmc/tftp
#    printenv        → kernel_loadaddr/fdt_loadaddr/rootfs_loadaddr
```

### 阶段 1（1~3 天）：在 RAM/TFTP 里起一个"安装器"

复用仓库已实测的配方（`tools/uboot/board.sh` 的 `bootgo`）：

```
# 关键点（全部来自 evidence，不是推测）：
#   - 内核必须套 legacy uImage（booti 对裸 Image 会报 Wrong Image Format；bootm 才认）
#   - uImage 头 64 B，所以装载地址 = 0x03000000 - 0x40 = 0x02ffffc0
#   - initrd 走 bootargs 的 initrd=0x02200000,<size>（并同时写 DTB /chosen 兜底）
setenv bootargs 'console=ttyS0,115200 earlycon=uart8250,mmio32,0x98007800,115200,27000000 \
                 initrd=0x02200000,0x<initrd_size> <你的安装器 cmdline>'
bootm 0x02ffffc0 - 0x01f00000
```

安装器 initramfs 里至少要能：`lsblk` 看到 `mmcblk0`/`sda`、`parted`/`fdisk` 分区、
`mkfs.ext4`/`mkfs.btrfs`、`tar` 解 rootfs、`dd` 写引导链。
本仓库的 `scripts/build-initramfs.sh`（busybox-static + gen_init_cpio，已验证）可以直接当底座。

### 阶段 2（3~5 天）：把 rootfs + 内核落到 eMMC/SATA

- 复用 `scripts/emmc-prepare.sh` / `scripts/emmc-write.sh` 的分区/写入逻辑（**但不要碰低区**）；
- 保持现有布局：`p1` ext4 放 `Image-6.6.uimage` + `rtd1296-cm360.dtb`，`p2` btrfs 放 rootfs；
  这样现有 `bootcmd` 不用改；换内核要留 `.bak` 兜底（`firmware/RECOVERY.md` 的纪律）。
- 验收：拔掉 TFTP/串口，冷启动能进系统；`uname -r` 对得上；`lsblk` 有 `mmcblk0`/`sda`/`sdb`。

### 阶段 3（可选，1~2 周）：做成"U 盘 live 安装盘"

FAT32 U 盘放：`Image-6.6.uimage` + `rtd1296-cm360.dtb` + 安装器 initramfs（或 live rootfs 压缩包）
+ 一个 `installer.cmd`（上面那组 `bootm` 命令）。体验接近"插盘装系统"，但仍不是 UEFI/GRUB。

### 阶段 4（可选，3~6 周）：如果确实要 UEFI

按路线 B 做双级引导，**先不写低区**：

1. 用 Armbian 的 `v2026.10-rtd129x` 补丁 + `CONFIG_EFI_LOADER=y` / `CMD_BOOTEFI=y` / `BLK` /
   `PARTITIONS` 编出 `u-boot.bin`（先确认 EL/驱动问题，见 §3 两个未决项）；
2. 选一个不被占用的 RAM 地址（**≥0x20000000**，避开 BL31 `0x10120000`、TEE `0x10200000`、
   本级 U-Boot `0x20000`~）作为二级 U-Boot 的 TEXT_BASE；
3. 把 `u-boot.bin` 放 TFTP 或 eMMC 的一个原始区，U-Boot 里 `tftp`/`mmc read` + `go` 起；
4. 验证能进 UEFI Shell / 跑 `bootaa64.efi`（GRUB）后，再考虑是否值得写进低区（路线 C）。

---

## 7. 还需要确认的事（按优先级）

1. **未知固件块 @0x132800（≈972 KiB，含 mbedTLS/SHA256 字符串）是什么、偏移由谁计算**
   → 决定低区 bootcode 能不能靠"顺序顺移"扩容（能不能走 C）。做法：对照 BPI-W2 BSP 的
   flash_writer/layout，或再抓一份原厂 eMMC dump 对比。它同时决定了"bootcode 槽位上限"
   （固件报告 §1.2 按 TEE−bootcode 算出 574 KiB，漏了中间的 FSBL 段，本文件 §2 已更正）。
2. **Armbian RTD129x U-Boot 怎么落到本板的 EL2/BL33 结构上**（已定位，未验证）
   → 它的 eMMC 主路径是"U-Boot 装到 `0x10000000`、EL3 跑、替代 BL31"（`ATF_COMPILE=no`），
   与本板"BL31 v1.2 常驻、BL33@0x20000/EL2"冲突。要用它的 **SD/EL2 二级 payload 模式**，
   并关掉 `0003/0008` 的 spin-table SMP（改回 BL31 的 PSCI）。这一步不验证清楚，路线 B 起不来。
3. **USB 主机/PHY 驱动缺失**：17 个补丁里 `dwc3/xhci/usb` 零命中 → 从 U 盘跑 UEFI 安装器要
   先补 1~2 周 USB 驱动；否则 UEFI 只能从 eMMC/SD 的 FAT 分区起 GRUB。
4. **bootcode 容器 0x28 头 + 尾部字段的完整语义**
   → 决定能不能用 BSP 之外的方式重新打包（`tools/uefi/lowregion.py plan` 只做尺寸推演，不做打包）。
   起点：先读 Armbian `mkbootarea.py`（公开的 BPI-W2 boot area 打包脚本，8×u32 尺寸表 + SHA-256），
   再逐字段对齐 CM360 的 3200 B hwsetting。
5. **CM360 的板级 DTS 进 Armbian mainline 6.18**
   → 如果走"新内核"路线（1~2 周），顺带解决 "d-i 自定义内核" 的维护性问题。
6. **双级 U-Boot 的 RAM 布局/重定位**
   → 二级 U-Boot 要从 `TEXT_BASE` 自搬移到 RAM 顶，且不能踩 BL31（`0x10120000`）、
   TEE（`0x10200000`）与本级 U-Boot（`0x20000`~）；需要真机试。

---

## 8. 本文件配套的东西

| 文件 | 作用 |
|---|---|
| `tools/uefi/lowregion.py` | 低区布局解析/校验/解包/换 bootcode 的**纸面推演**（只读；`check` 全绿、`selftest` 逐字节重建 PASS 才算模型可信） |
| [`docs/reports/uefi/firmware-options.md`](reports/uefi/firmware-options.md) | 固件侧研究：U-Boot/EDK2 支持现状、EFI_LOADER 要求、Armbian RTD129x 补丁、移植工作量 |
| [`docs/reports/uefi/installer-options.md`](reports/uefi/installer-options.md) | 安装器侧研究：Debian/Ubuntu ISO 引导链、d-i 内核驱动矩阵、hd-media/booti 路径、方案对比 |
| `tools/uboot/board.sh` | 已经实测跑通的 `bootm`/initrd/uImage 配方（路线 A 的基础） |
| `scripts/build-initramfs.sh` | aarch64 static busybox initramfs 构建（可当安装器底座） |
| `scripts/emmc-prepare.sh` / `emmc-write.sh` | eMMC 分区/写入逻辑（阶段 2 复用；**注意别让它们碰低区**） |
| `firmware/RECOVERY.md`、`docs/04-recovery.md` | 低区纪律与串口救砖（任何低区操作前必读） |

---

## 9. 一句话给不同诉求的人

| 你的目标 | 建议 |
|---|---|
| "我想在这块板上装 Debian/Ubuntu，能跑就行" | 走 A/阶段 2：x86 上 debootstrap 做 arm64 rootfs（1~3 天）+ 现有 dd 链；或做安装器（1~2 周） |
| "我要像 PC 一样插 U 盘跑 UEFI 安装器" | **不建议**：UEFI 只是壳，装不完；除非你愿意先做 B（3~6 人周 + USB 1~2 周）+ A 的定制内核 |
| "我就是要这块板有 UEFI 固件（研究/折腾）" | 走 B（双级引导，不碰低区）；C 只在 B 完全验证后再做；D 直接放弃 |
| "我要一个稳定的 UEFI ARM 小机器" | 换硬件。给 RTD1296 补 EDK2 的成本 > 买一台 x86/支持 UEFI 的 ARM 板 |
