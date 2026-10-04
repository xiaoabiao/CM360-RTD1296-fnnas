# 阶段 0 完整实测报告 —— CM360（RTD1296）到底有什么牌

> 设备：小睿 CM360（Realtek RTD1296，4×Cortex-A53，2 GB DDR4，8 GB eMMC，原生双 SATA）
> 现状：正在运行黑群晖 DSM（伪装机型 DS218，`syno_version = "SYNO-DTB-DSM6-1-15157"`）
> 目标：移植飞牛 fnOS（需主线 6.12/6.18 内核）
> 完成日期：2026-10-04
> 数据来源：**全部为真机实测**，无二手推断

---

## 0. 阶段 0 结论：五句话

1. **引导链全通**，且**不需要重新上电**就能进 u-boot —— `Hit Esc or Tab` 抢窗口，两次稳定复现，提示符 `CM360_DS218>`。
2. **u-boot 功能远超预期**：`booti`、`tftp`、`tftpput`、`usb`、`mmc`、`sata`、`fatload`、`ext4load`、`loady`、`fdt`、`go k`、`bootr u/uz` 全都有。**之前担心的「2015.07 没有 booti」被推翻**（Realtek backport 过）。
3. **原厂 DTB 已完整导出**（48,057 字节 → 2,077 行文本），包含**完整时钟树（24 个时钟节点）、73 个电源/门控节点、8 个软复位节点**。这是移植 CCF 最缺的那张图纸。
4. **eMMC 分区表拿到**：7 个 EFI 分区，`uboot` + 三个 8 MiB + 两个 512 MiB（raid1 对）+ 一个 2.2 GiB。
5. **主线侧核出两条硬结论**：RTD129x 设备树里**完全没有 `enable-method`/`psci`/`spin-table`**（多核根本起不来）；`drivers/clk/` 里**没有任何 Realtek 时钟驱动**。加上主线 `drivers/net/ethernet/realtek/` 全部是 PCI-only（无 `of_device_id`）——**三大阻塞点全部被源码证实**。

**阶段 0 完成。阶段 1 的路线已经从「三种可能」收敛为「TFTP 为主、USB 为辅」。**

---

## 1. u-boot 实测能力清单（完整 `help` 输出）

### 1.1 ★ 决定阶段 1 走法的命令

| 命令 | 存在 | 用法 | 意义 |
|---|---|---|---|
| `booti` | ✅ | `booti [addr [initrd[:size]] [fdt]]` | **可以启动主线裸 `Image`** — 最关键的一条 |
| `bootm` | ✅ | — | 也可以走传统 uImage |
| `tftp` | ✅ | `tftp address filename` | **从 TFTP 服务器下载** — 阶段 1 首选通道 |
| `tftpput` | ✅ | `tftpput Address Size [[hostIPaddr:]filename]` | **反向上传任意内存到服务器** — 备份神器，见 §5 |
| `usb` | ✅ | `usb start / tree / info / storage / part / read / write` | 完整 USB 存储支持 |
| `fatload` | ✅ | `fatload <interface> [<dev[:part]> [<addr> [<filename>…]]]` | FAT 分区读文件 |
| `ext4load` | ✅ | `ext4load <interface> [<dev[:part]> [addr [filename…]]]` | ext4 分区读文件 |
| `mmc` | ✅ | `mmc info / read / write / erase / rescan / part / dev / list` | 完整 eMMC 访问 |
| `rtkemmc` | ✅ | `rtkemmc read dma_addr blk_addr byte_size` 等 | Realtek 私有 eMMC 通道 |
| `sata` | ✅ | `sata init / stop / info / device / part / read / write` | **u-boot 里就能访问 SATA 盘** |
| `rtkspi` | ✅ | `rtkspi read/write/erase`、`rtkspi load dtb kernel\|rescure` | SPI NOR 访问（只读用） |
| `loady` | ✅ | `loady [off] [baud]` | 串口 ymodem 传文件，**还能改波特率** — 无网无 U 盘时的兜底 |
| `fdt` | ✅ | `fdt print / list / set / get / chosen / memory / rsvmem …` | **完整设备树操作** — 导出原厂 DTB 靠它 |
| `go` | ✅ | `go [addr/a/v/v1/v2/k] [arg …]` | 私有；**`go k` = 启动 kernel**，`go all` = 全部固件 |
| `bootr` | ✅ | `bootr [u/uz]` | 私有；**`u`/`uz` = 从 USB 启动**（厂商自带的 U 盘启动路径） |
| `goru` | ✅ | `goru` | 从 USB 启动救援 Linux |
| `gosd` / `gosdb` | ✅ | — | 从 SD 卡启动 / 从 SD 卡加载 bootcode |
| `usbboot` | ✅ | — | 从 USB 设备启动 |
| `iminfo` | ✅ | `iminfo addr [addr …]` | 校验镜像头 |
| `ping` / `bootp` | ✅ | — | 网络栈可用（`bootcmd` 里本来就在 ping） |
| `lzmadec` | ✅ | — | LZMA 解压（厂商流程用） |

### 1.2 其它可用命令（备查）

`base` `bdinfo` `cachetest` `cmp` `cp` `dcache` `echo` `editenv` `eeprom` `env` `exit` `ext4ls` `ext4size` `ext4write` `factory` `false` `fastboot` `fatinfo` `fatls` `fatsize` `fatwrite` `flinfo` `gettime` `gictest` `gpio` `gpt` `i2c` `icache` `loadb` `loadx` `loop` `md` `mm` `mmcinfo` `mw` `nm` `pmic` `printenv` `protect` `pwm` `reset` `run` `saveenv` `setenv` `setexpr` `showvar` `sleep` `source` `test` `true` `uart_rw` `uart_write` `version`

> ⚠️ **黑名单**（绝不在提示符下敲）：`erase` `protect` `rtkspi write` `rtkspi erase` `mmc write` `mmc erase` `sata write` `usb write` `fatwrite` `ext4write` `rtkfat` `mw` `mm` `nm` `saveenv` `setenv`（`setenv` 不 `saveenv` 只改内存是安全的，但须明确）
>
> ✅ **已确认没有 `sf` 命令** —— SPI 只有 Realtek 私有的 `rtkspi`。

### 1.3 `bootr` 的隐藏价值

```
bootr [u/uz]
	f   - boot faster of blue logo
	u   - boot from usb
	uz  - boot from usb (use lzma image)
	m   - read fw from flash but boot manually (go all)
```

**厂商自己留了 U 盘启动路径。** `bootr uz` 会从 USB 读 LZMA 压缩镜像启动。
如果 `tftp` 路线遇到网络配置麻烦，`bootr uz` 是最省事的备选（但需要搞清楚它期望的镜像布局）。

### 1.4 `go` 的私有语义

```
go [addr/a/v/v1/v2/k] [arg ...]
	addr - start application at address
	a    - start audio firmware
	k    - start kernel          ← 启动内核
	r    - start rescue linux
	ru   - start rescue linux from usb
	all  - start all firmware
```

`bootcmd` 用的 `go all` 就是最后一条。**它怎么给内核传参仍是未知**（阶段 2 再深挖），但既然 `booti` 存在，我们**不必走这条路**。

---

## 2. 引导链与内存布局（实测）

```
上电 → FSBL（hwsetting 0xBE4, Flash Type 0x02, SVP=N）
     → BOOTCODE（FW Image to 0x00020000, size 0x7CA60）
     → U-Boot 2015.07-00055-g99edeb3-dirty (Sep 07 2024)
         Board: Realtek QA Board（通用参考板配置）
         DRAM 2 GiB / Watchdog Disabled
         SPI: Winbond W25Q64 (JEDEC 0x00ef4017), max capacity 0x00800000 (8 MB)
         eMMC: Samsung 8GTF4, 7.3 GiB, HS200 8-bit, Boot 4 MiB, RPMB 512 KiB
         Net: Realtek PCIe GBE Family Controller, dev->name=r8168#0
     → "Hit Esc or Tab key to enter console mode or rescue linux: 0"
     → CM360_DS218>（进 console 自动 disable watchdog）
```

### 2.1 加载地址（写启动脚本用，**照抄不要改**）

| 变量 | 值 | 用途 |
|---|---|---|
| `fdt_loadaddr` | `0x01f00000` | 设备树 |
| `kernel_loadaddr` | `0x03000000` | 内核（解压后） |
| `rootfs_loadaddr` | `0x02200000` | rootfs / initramfs |
| `audio_loadaddr` | `0x01b00000` | 音频固件 |
| `fdt_high` | `0xffffffffffffffff` | 禁用 fdt 重定位 |
| staging 区 | `0x0b000000` | `rtkspi read` 的临时落脚点 |

> u-boot 把 `0x20000000–0x40000000` 映射为 **non-cached**；`rootfs_loadaddr` 就在里面。
> 我们**沿用原厂地址就继承了这套映射**，最省心。

### 2.2 ★ bdinfo 拿到的 PLL 实测频率（写时钟驱动的一手数据）

```
SCPU   PLL  = 1600 MHz     SCPU  =  800 MHz
ACPU   PLL  =  549 MHz     ACPU  =  549 MHz
VCPU1  PLL  =  594 MHz
VCPU2  PLL  =  675 MHz
DDSA   PLL  =  432 MHz
DDSB   PLL  =  432 MHz
BUS    PLL  =  256 MHz
BUS_H  PLL  =  459 MHz
GPU    PLL  =  449 MHz
VODMA  PLL  =  405 MHz

DDR = 1866 MT/s, DC0 DDR4 4Gb(x16)x2=8Gb, DC1 同上  → 合计 2 GiB
DRAM bank0: start 0x0, size 0x40000000
TLB addr: 0x7FFF0000
```

### 2.3 bootargs（DSM 伪装 + u-boot 默认）

u-boot 侧（`syno_bootargs`）：
```
ip=off console=ttyS0,115200 root=/dev/md0 rw
syno_castrated_xhc=xhci-hcd.5.auto@1
syno_usb_vbus_gpio=102@…,132@…,133@…
syno_hw_version=DS218 hd_power_on_seq=2 ihd_num=2 netif_num=1
audio_version=1012363 syno_fw_version=M.506
```

原厂 DTB 内建（`/chosen`）：
```
earlycon=uart8250,mmio32,0x98007800 console=ttyS0,115200
androidboot.hardware=kylin loglevel=8
linux,initrd-start = <0x02200000>   linux,initrd-end = <0x025ff000>   ← 正好 4 MiB
syno_version = "SYNO-DTB-DSM6-1-15157"
```

---

## 3. ★ 原厂 DTB 完整反解（写自己板级 DTS 的权威底稿）

导出方式（全只读）：
```
rtkspi read 0x0 0x06000000 0x10000     # 从 SPI 偏移 0 读 64 KB 到 RAM
fdt addr 0x06000000
fdt print /                            # 2,077 行
```
产物：`original-dtb.dts.txt`（2,077 行）+ `fdt header` 确认 `totalsize = 0xbbb9 (48,057)`

### 3.1 顶层结构（93 个节点，**全部挂在根节点下，没有 `/soc` 分层**）

```
/  compatible = "Realtek,rtd-1296";  model = "Realtek_RTD1296"
├── pinctrl@9801A000        ├── ehci@98013000 / ohci@98013400
├── irda@98007400           ├── usb2_udc@981E0000
├── soft_reset1/2/3/4       ├── rtk_dwc3_drd@98013200
├── soft_reset@98007088     ├── rtk_dwc3_u2host@98013E00
├── rst1/2/4_init           ├── rtk_dwc3_u3host@98013E00
├── iso_rst_init            ├── dwc3_*_usb2phy / usb3phy（5 个）
├── grouped_soft_reset1/2   ├── rtk_usb_power_manager
├── group_rst_init          ├── usb_phy_rle0599
├── usb_rst / usb_rst_init  ├── dvfs / dvfs-gpio
├── clocks            ★     ├── chosen / cpus / soc / core_control
├── power_control     ★     ├── rbus@98000000 / psci / timer
├── interrupt-controller@FF010000（GIC）
├── pmu                     ├── intc@9801B000        ★ Realtek IRQ mux
├── rtk_misc_gpio@9801b100  ├── rtk_iso_gpio@98007100
├── serial0@98007800        ├── serial1@9801B200
├── aliases                 ├── gmac@98016000
├── timer0/1@9801B000       ├── thermal@0x9801D100
├── pcie@9804E000           ├── pcie2@9803B000
├── sata@9803F000           ├── sdio@98010A00
├── sdmmc@98010400          ├── emmc@98012000
├── refclk@9801b540         ├── scpu_wrapper@9801d000
├── sb2@9801a000            ├── rpc@9801a104
├── rtc@0x9801B600          ├── watchdog@0x98007680
├── rtk-rstctrl@0x98007000  ├── i2c（6 个）
├── spi@9801BD00            ├── pwm@980070D0
├── rtk_fan@9801BC00        ├── mcp@0x98015000
├── power-management        ├── rtk,ion
├── pu_pll@98000000         ├── jpeg@9803e000
├── ve1@98040000 / ve3@98048000
├── md@9800b000 / se@9800c000
├── memory { reg = <0x0 0x80000000> }   ← 2 GiB
└── mem_remap
```

### 3.2 ★ 时钟树（`/clocks`，24 个节点）

```
osc27M  = 27,000,000 Hz (0x019BFCC0)   fixed-rate
  ├── spll          realtek,129x-pll-generic   type=scpu   0x98000504/0x98000030/0x98000500/0x9800051c
  │      scpu,pll,workaround = <0x34055501 0x04038500>
  ├── pll_bus       realtek,129x-pll-generic   type=nf     0x98000524
  │      └── pll_bus_div2  fixed-factor div=2
  ├── pll_bus_h     realtek,129x-pll-generic   type=nf     0x98000544
  │      └── clk_sysh
  ├── pll_ddsa / pll_ddsb
  ├── pll_vodma     → clk_vodma
  ├── pll_ve1 / pll_ve2 → clk_ve1 / clk_ve2 / clk_ve3
  ├── pll_gpu       → clk_gpu
  └── pll_acpu
clk_sys    realtek,129x-clk-composite   mux over (pll_bus | pll_bus_div2) @0x98000030
jpeg_gates realtek,129x-clk-gates
clk_enable@9800000c / @98000010 / @9800708c   realtek,129x-clk-gates
```

compatible 计数（`/clocks` 段）：

| compatible | 个数 | 说明 |
|---|---|---|
| `realtek,129x-pll-generic` | 10 | PLL，`factor,type` 有 `scpu` / `nf` 等 |
| `realtek,129x-clk-composite` | 9 | mux / div / fixed-factor 复合时钟 |
| `realtek,129x-clk-gates` | 4 | 门控组 |
| `realtek,129x-soft-reset` | 8 | 软复位寄存器 |
| `realtek,129x-rstc-init` | 6 | 复位初始化序列 |

### 3.3 ★ 电源/门控树（`/power_control`，**73 个节点**）

门控寄存器三处：`pctrl_clk_en@9800000c`、`@98000010`、`@9800708c`

按 IP 分组的电源域/门控（节选，完整 73 条）：

```
显示/视频：ve1 ve2 ve3 l4_icg_ve1/2/3 jpeg gpu(gpu_core@1/2/3) disp_top l4_icg_vo
音频：      l4_icg_aio audio_dac video_dac mhl3_en
安全/加解密：l4_icg_se l4_icg_md l4_icg_rsa l4_icg_trng? l4_icg_mipi mipi_aphy
存储：      l4_icg_sata l4_icg_nand l4_icg_emmc l4_icg_sdio pctrl_sdio
USB：       usb_p0_mac/phy/iso usb_p0/p1/p2/p3(l4_icg) usb_p3_mac_A/mac_ECO_B/phy/iso
PCIe：      l4_icg_pcie1 l4_icg_pcie2
网络：      etn_gphy               ← 以太网 GPHY 电源
总线/桥：    cbus l4_icg_mis l4_icg_gspi l4_icg_cr pctrl_cr l4_icg_ae l4_icg_sb2 l4_icg_tp
            l4_icg_scpu_wrapper
复位：      pctrl_soft_reset@98000000/04/50/98007088
```

compatible 计数：

| compatible | 个数 |
|---|---|
| `realtek,powerctrl-simple` | 53 |
| `realtek,powerctrl-sram` | 9 |
| `realtek,powerctrl-once` | 7 |
| `realtek,powerctrl-gpu-core` | 3 |

> **这 73 条就是移植 CCF/电源驱动的完整清单** —— 之前只能从 BSP 源码逐行数，现在有了结构化的对照表。

### 3.4 关键外设节点原文

**GIC**（与主线完全一致，只是少了 v2m/vcpu 帧）：
```dts
interrupt-controller@FF010000 {
    compatible = "arm,cortex-a15-gic";
    #interrupt-cells = <3>;
    reg = <0xff011000 0x1000 0xff012000 0x1000>;
};
```
> 主线用 `arm,gic-400`，`reg = <0xff011000 0x1000>, <0xff012000 0x2000>, <0xff014000 0x2000>, <0xff016000 0x2000>`。
> **dist 与 cpu 基址一致 → 主线 GIC 配置对本 SoC 是正确的。** ✓

**CPU（★ 多核启动的关键）**：
```dts
cpus {
    cpu@0 {
        device_type = "cpu";
        compatible = "arm,cortex-a53", "arm,armv8";
        reg = <0x0>;
        enable-method = "rtk-spin-table";        ← Realtek 私有
        cpu-release-addr = <0x0 0x9801aa44>;     ← 注意：MMIO 地址，不是 RAM
        next-level-cache = <&l2>;
    };
    /* cpu@1/2/3 同，reg = 1/2/3 */
};
psci { compatible = "arm,psci-0.2", "arm,psci"; method = "smc"; }
```
> **这是阶段 1 的关键。** 主线 DTS 里**没有 `enable-method`，也没有 `psci` 节点**，
> 所以主线的 RTD129x 内核**只能跑单核**（这说明上游这份 DTS 从来没真正跑通过多核）。
> 我们必须在自己的 DTS 里补上 `enable-method` + `cpu-release-addr`（或改用 PSCI）。
> 好在 vendor 的 release 地址 `0x9801aa44` 是个普通 MMIO 写 —— 主线的 `spin-table` 实现
> 本质上也就是往这个地址写个 64 位值，**大概率可以直接复用**。

**定时器**（与主线一致）：
```dts
timer { compatible = "arm,armv8-timer";
        interrupts = <1 13 0xf08>, <1 14 0xf08>, <1 11 0xf08>, <1 10 0xf08>;
        clock-frequency = <27000000>; };
```

**串口 UART0**：
```dts
serial0@98007800 {
    compatible = "snps,dw-apb-uart";        ← 标准 DesignWare
    interrupt-parent = <&intc>;             ← ★ 走 Realtek IRQ mux，不是直连 GIC
    reg = <0x98007800 0x400 0x98007000 0x100>;
    interrupts-st-mask = <0x4>;
    interrupts = <0x1 0x2>;
    reg-shift = <2>; reg-io-width = <4>;
    clock-frequency = <27000000>;
};
```
> 主线 uart0 用的是 `iso` syscon + 0x800 = **同址 0x98007800**，`clock-frequency = <27000000>` 也对，
> **但主线没有 `interrupts` 属性** → 主线串口只能做轮询 console，没有中断。
> 原因就是厂商把 UART 中断挂在 `intc@9801B000`（`Realtek,rtk-irq-mux`）上。

**★ Realtek IRQ mux（主线完全没有的东西）**：
```dts
intc@9801B000 {
    compatible = "Realtek,rtk-irq-mux";
    Realtek,mux-nr = <2>;
    #interrupt-cells = <2>;
    interrupt-controller;
    reg = <0x9801b000 0x100 0x98007000 0x100>;
    interrupts = <0 0x28 4>, <0 0x29 4>;    ← 只占 GIC SPI 40、41 两条
    intr-status = <0x0c 0x00>;
    intr-en = <0x80 0x40>;
};
```
> **这是一个中断多路复用器**：外围一大堆外设的 IRQ 都汇聚到它，再由它向 GIC 报两条 SPI。
> 移植网卡/SATA/eMMC 时**绕不开它**。之前源码盘点里没有识别出这一层，现在确认了。

**SATA（原生双 SATA 实锤）**：
```dts
sata@9803F000 {
    compatible = "Realtek,ahci-sata";               ← AHCI 兼容
    reg = <0x9803f000 0x1000 0x9801a900 0x100>;    ← 第二段是 SATA PHY/杂项
    interrupts = <0 0x1c 4>;                        ← GIC SPI 28
    gpios = <&gpio 56 1 1>, <&gpio 19 1 1>;         ← ACTIVE_HIGH
    clocks = <&clk 2>, <&clk 7>, <&clk 0x19>, <&clk 0x1a>;   ← 4 个时钟
    hotplug-en = <0x0>;
    tx-driving = <0x09>;                            ← 原厂值 9
    blink-gpios = <&gpio 26 1 0>, <&gpio 21 1 0>;   ← ACTIVE_LOW
    sata-port@0 { reg = <0>; };
    sata-port@1 { reg = <1>; };                     ← 双端口
};
```
> ★ **注意 `tx-driving = <9>`** —— 而 u-boot 的 `mod_fdt` 会在启动前把它**改写成 `<2>`**，
> 同时写入 `rx-sensitivity = <2>`。所以最终内核看到的是 `<2>`。
> 我们自研 DTS 里这两个属性要写 u-boot 覆盖后的值。

**网卡（SoC 内置 GMAC）**：
```dts
gmac@98016000 {
    compatible = "Realtek,r8168";                   ← 不是主线的 realtek,rtl-8168
    reg = <0x98016000 0x1000 0x98007000 0x1000>;    ← 第二段是复位/杂项块
    interrupts = <0 0x16 4>;                        ← GIC SPI 22
    rtl-config = <0x1>;
    mac-version = <0x2a>;                           ← 42
    rtl-features = <0x2>;
    led-cfg = <0x2070>;
    status = "okay";
};
```
> 另有 1 处**属性级交叉引用**（不是第二个网卡节点），在 `power_control` 的以太网 GPHY 门控里：
> ```dts
> /* pctrl_etn_gphy 节点内 */
> is-analog;
> clocks = <&clk 0x09>;
> resets = <&soft_reset1 0x10>;
> ref-status,by-compatible = "Realtek,r8168", "Realtek,rtd1295-hwnat";
> ```
> **含义**：电源控制器会按 `compatible` 字符串去"看"网卡/hwnat 驱动在不在，据此决定
> GPHY 的上下电。→ 移植网卡时**必须一起处理这条联动**，否则 GPHY 可能不上电。
> 这也解释了 DSM 日志里 `pctrl_nat::POWER_OFF` 的来源。

**eMMC / SDMMC / SDIO**：
```dts
emmc@98012000 {
    compatible = "Realtek,rtk1295-emmc";
    reg = <0x98012000 0xa00 0x98000000 0x600 0x9801a000 0x80 0x9801b000 0x150>;  ← 4 段
    interrupts = <0 0x2a 4>;                        ← GIC SPI 42
    speed-step = <0x2>;                             ← HS200
    pddrive_nf_s0 = <1 0x77 0x77 0x77 0x33>;        ← eMMC PHY 调优值
    pddrive_nf_s2 = <1 0xbb 0xbb 0xbb 0x33>;
    phase_tuning = <0 0>;
};
sdmmc@98010400 { compatible = "Realtek,rtk1295-sdmmc";
                 reg = <0x98000000 0x400 0x98010400 0x200 0x9801a000 0x400 0x98012000 0xa00 0x98010a00 0x40>;
                 interrupts = <0 0x2c 4>; };       ← GIC SPI 44
sdio@98010A00  { compatible = "Realtek,rtk1295-sdio";
                 reg = <0x98010a00 0x100 0x98000000 0x50>;
                 interrupts = <0 0x2d 4>; };       ← GIC SPI 45
```

**pinctrl（命名引脚制，与主线风格完全不同）**：
```dts
pinctrl@9801A000 {
    compatible = "rtk119x,rtk119x-pinctrl";
    reg = <0x9801a000 0x97c 0x9804d000 0x10 0x98012000 0x640 0x98007000 0x340>;
    #gpio-range-cells = <3>;
    sdcard_low@0 {
        rtk119x,pins = "mmc_data_3", "mmc_data_2", "mmc_data_1",
                       "mmc_data_0", "mmc_clk", "mmc_cmd";
        rtk119x,function = "sd_card";
        rtk119x,pull_en = <1>;
        rtk119x,pull_sel = <0>;
    };
    /* … 共 13 个 pin group */
};
```
> ⚠️ 厂商用**字符串引脚名**（`"mmc_data_3"`）+ **`rtk119x,function` 名字**的机制，
> 主线 pinctrl 用的是**数字 pinmux**。所以 pinctrl 的移植不是"搬驱动"，而是要
> **重新设计一套引脚编号表 + 功能表**。这比之前估的 933 行要重。

**watchdog / rtc / rstctrl**：
```dts
watchdog@0x98007680 { compatible = "Realtek,rtk-watchdog"; reg = <0x98007680 0x100>; rst-oe = <0x0>; };
rtc@0x9801B600 { compatible = "Realtek,rtk-rtc";
                 reg = <0x9801b600 0x100 0x98000000 0x100 0x98007000 0x100>;
                 rtc-base-year = <0x7e0>; };    ← 0x7e0 = 2016
rtk-rstctrl@0x98007000 { compatible = "Realtek,rtk-rstctrl";
                         reg = <0x98007600 0x100>; rst-reg-offset = <0x40>; };
```
> ✅ 主线 `wd` 在 `iso+0x680` = **0x98007680，地址完全对上**，只是 compatible 名不同
> （主线 `realtek,rtd1295-watchdog`）。**改一行 of_match 就能用。**

**内存重映射窗口**（供参考）：
```dts
mem_remap { compatible = "Realtek,rtk1295-mem_remap";
  reg = <0x98000000 0x200000  0x0001f000 0x1000
         0x01b00000 0x400000  0x02600000 0x600000
         0x01ffe000 0x4000    0x10000000 0x14000
         0x02c00000 0x8c00000 0x11000000 0x8c00000>; };
```

---

## 4. 分区与容量

### 4.1 ★ eMMC 分区表（`mmc part`，EFI/GPT）

起始 LBA 0x8000 = **16 MiB**，所以 **前 16 MiB 未被分区**（GPT + bootloader/bootcode 区）。

| # | Start LBA | End LBA | 名称 | 大小 | 字节偏移范围 |
|---|---|---|---|---|---|
| — | 0 | 0x7FFF | *(未分区)* | 16 MiB | 0 – 16 MiB |
| 1 | 0x8000 | 0xBFFF | `uboot` | **8 MiB** | 16 MiB – 24 MiB |
| 2 | 0xC000 | 0x10BFFF | `primary` | **512 MiB** | 24 MiB – 536 MiB |
| 3 | 0x10C000 | 0x20BFFF | `primary` | **512 MiB** | 536 MiB – 1048 MiB |
| 4 | 0x20C000 | 0x20FFFF | `primary` | 8 MiB | 1048 MiB – 1056 MiB |
| 5 | 0x210000 | 0x213FFF | `primary` | 8 MiB | 1056 MiB – 1064 MiB |
| 6 | 0x214000 | 0x217FFF | `primary` | 8 MiB | 1064 MiB – 1072 MiB |
| 7 | 0x218000 | 0x67F7FF | `primary` | **≈2.20 GiB** | 1072 MiB – 3327 MiB |

- 全部 type GUID = `0fc63daf-8483-4772-8e79-3d69d8477de4`（Linux filesystem）
- 已分区总量 ≈ **3.25 GiB**；eMMC 报 **7.3 GiB** → **尾部约 4 GiB 未分配**
  （很可能是 DSM 装完后才创建的数据卷位置）

**合理推断**：分区 2 + 分区 3 是两个 512 MiB 镜像对 → 正好对应 `root=/dev/md0` 的 **RAID1**。
三个 8 MiB 分区（4/5/6）是 DSM 的辅助分区。分区 1 名为 `uboot`，8 MiB。

> ⚠️ **一个待复查的矛盾点**：`shot_log_01.log` 里那些 `MMC: Initialize eMMC …` 行
> （时间戳 8.618~8.787）是 **U-Boot 自己的输出**，不是内核的（内核 banner 在 7.974 之后就交棒了）。
> 而在**内核阶段**（日志第 237 行往后）**搜不到任何 mmc/emmc 探测日志**，却出现了
> `md: raid1 personality registered for level 1`（kernel time 6.224）。
>
> 也就是说：`root=/dev/md0` 的 RAID1 确实被注册了，但 md 的成员盘来自哪里还不确定 ——
> 可能是 (a) 内核里 mmc 驱动是内建的且静默，(b) initrd 负责组装真正的根，
> 或者 (c) `/dev/md0` 其实建在 **SATA 盘**上。
>
> 这**不影响阶段 1**（我们不依赖它启动），但**备份时会用到**，届时一并查清。

### 4.2 SPI NOR 布局（8 MB，推算）

| 起始 | 大小 | 内容 | 证据 |
|---|---|---|---|
| `0x000000` | 64 KB | **设备树 DTB** | `rtkspi read 0x0000000 $fdt_loadaddr 0x00010000` |
| `0x010000` | 704 KB | ⚠️ 未知盲区（大概率 FSBL/BOOTCODE/u-boot/logo） | 无 env 引用 |
| `0x0C0000` | 256 KB | 音频固件 | `rtkspi read 0x0c0000 … 0x040000` |
| `0x100000` | 2.94 MB | 内核（LZMA） | `rtkspi read 0x100000 … 0x2F0000` |
| `0x3F0000` | 3.996 MB | rootfs / initramfs | `rtkspi read 0x3f0000 … 0x3FF000` |
| `0x7EF000` | 68 KB | 尾余量 | — |

**已知镜像合计 7.25 MiB = 90.6%；加上盲区 99.2%。剩余 68 KB ~ 772 KB。**
→ 主线内核**绝无可能**塞进 SPI。**"不写 SPI" 是硬约束，不是建议。**

---

## 5. ★ 备份策略：不需要 rootfs shell

`tftpput Address Size [[hostIPaddr:]filename]` 的存在让备份变得非常简单：

```
# SPI 全片（8 MB）—— 只读
rtkspi read 0x0 0x06000000 0x800000
tftpput 0x06000000 0x800000 spi-full.bin

# eMMC 分区 1 "uboot"（8 MiB = 16384 块，起始 LBA 0x8000）
mmc dev 0
mmc read 0x06000000 0x8000 0x4000
tftpput 0x06000000 0x800000 emmc-p1-uboot.bin

# eMMC 头部（含 GPT + bootloader，16 MiB）
mmc read 0x06000000 0x0 0x8000
tftpput 0x06000000 0x1000000 emmc-head-16M.bin
```

> 唯一前置条件：PC 上跑一个 TFTP 服务器，且板子能 ping 通它。
> 这比"先装好 DSM 拿到 SSH"要快得多，而且**完全不碰任何写入路径**。

---

## 6. 阶段 1 的路线（已收敛）

### 6.1 三条路的最终裁定

| 路 | 结论 | 依据 |
|---|---|---|
| **A. TFTP + `booti`** | ★ **首选** | `tftp` 与 `booti` **都确认存在**；u-boot 网络栈已活（`bootcmd` 里就在 ping） |
| **B. U 盘 + `bootr uz`** | 备选 | 厂商自带 U 盘启动路径；`fatload`/`ext4load`/`usb` 齐全 |
| **C. `loady` 串口灌** | 兜底 | `loady [off] [baud]` 可改波特率；无网无盘也能救 |

### 6.2 阶段 1 具体动作（TFTP 路线）

```
# PC 侧：把以太网口设为 192.168.1.254/24，起 TFTP 服务，放 Image + cm360.dtb
# 板子侧（全部只改内存，不 saveenv）：
setenv ipaddr 192.168.1.100
setenv serverip 192.168.1.254
ping 192.168.1.254
tftp 0x03000000 Image
tftp 0x01f00000 cm360.dtb
booti 0x03000000 - 0x01f00000
```

### 6.3 ★ 自研 CM360 DTS 必须补的五个点（全部来自本次实测）

| # | 事项 | 来源 |
|---|---|---|
| 1 | **`enable-method` + `cpu-release-addr = <0x0 0x9801aa44>`**（或改用 PSCI） | 原厂 CPU 节点；主线缺失 → 否则单核 |
| 2 | **memory 从 `0x1f000` 起**：`reg = <0x1f000 0x7ffe1000>` | 主线 `rtd1296-ds418.dts` 的写法；低 124 KB 被 boot ROM 占用 |
| 3 | **`/memreserve/ 0x1b00000 0x4be000`**（音频固件区，**不要动**） | 主线 dtsi 与 u-boot `audio_loadaddr` 双向印证 |
| 4 | **SATA 节点带 `tx-driving = <2>; rx-sensitivity = <2>;`** | u-boot `mod_fdt` 会覆盖成 2（原厂 DTB 里是 9） |
| 5 | **总线用 `ranges` 恒等映射覆盖 0x98000000** | 主线 `soc@0` 的 `ranges` **不覆盖 0x98000000**，其 `rbus` 子节点地址翻译实际是坏的 —— 我们自己写干净版 |

---

## 7. 主线 vs 实测：本次新增/修正的结论

| # | 原判断 | 实测结果 | 影响 |
|---|---|---|---|
| 1 | u-boot 2015.07 无 `booti`（早于 2016.05）→ 只能 `bootm` 或引导桩 | **错。`booti` 存在**（Realtek backport） | 阶段 1 简化：直接 `booti` 裸 Image |
| 2 | 主线 rtd1296 能起 4 核 | **可疑**：主线 DTS **无 `enable-method`/`psci`/`spin-table`** | 必须自己补 CPU 启动方式，否则单核 |
| 3 | 时钟驱动缺失 | **确认**：`drivers/clk/` 无任何 Realtek 驱动；但**拿到了完整时钟树（24 节点）+ 73 个门控节点 + PLL 实测频率** | 移植量不变，但**图纸齐了**，风险大降 |
| 4 | 网卡 `r8169soc` 需移植 | **确认**：`drivers/net/ethernet/realtek/` 全部 PCI-only，**零个 `of_device_id`** | 结论不变 |
| 5 | 中断直接接 GIC | **错**：存在 **`Realtek,rtk-irq-mux`**（`intc@9801B000`），大量外设中断汇聚到它 | 移植网卡/SATA/eMMC 必须一并处理 |
| 6 | watchdog 要移植 | **几乎白送**：主线 `realtek,rtd1295-watchdog` 地址 `0x98007680` 与原厂 `Realtek,rtk-watchdog` **完全一致** | 改一行 of_match |
| 7 | 复位控制器要移植 | **大部分白送**：主线 4 个 `snps,dw-low-reset` + iso_reset 与原厂 5 个 `soft_reset*` **一一对应** | 工作量下降 |
| 8 | pinctrl 933 行可搬 | **比预期重**：厂商用**字符串引脚名 + 功能名**，主线用**数字 pinmux**，需重做引脚表 | 工作量上调 |
| 9 | 备份需要设备 shell | **不需要**：`mmc read` + `tftpput` 就能整机导出 | 备份门槛大降 |
| 10 | PCIe 完全没启用 | **部分修正**：原厂 DTB **有** `pcie@9804E000` 和 `pcie2@9803B000` 节点（只是 DSM 内核没枚举日志） | 仍非必需（有原生 SATA） |

---

## 8. 本次会话的产物

| 文件 | 内容 |
|---|---|
| `阶段0-完整实测报告.md` | **本文件** — 阶段 0 的完整整合 |
| `original-dtb.dts.txt` | **原厂 DTB 反解，2,077 行**（写自研 DTS 的底稿） |
| `session02.log` / `session02.raw` | 完整交互会话（help 总表、bdinfo、DTB 导出、mmc part） |
| `session01a.log` / `session01a.raw` | 第一轮会话（含 `help` 总表原始输出） |
| `shot_log_01.log` | 第一次上电的完整启动日志 |
| `shot_uboot_01.log` | u-boot `printenv` 全量 |
| `阶段0-日志分析-shot_log_01.md` | 启动日志分析报告 |
| `阶段0-日志分析-shot_uboot_01.md` | u-boot env 分析报告 |
| `serial_capture.py` | 串口抓取工具（`log`/`uboot`/`keys`/`probe` 四模式） |
| `serial_agent.py` | **常驻串口代理**（跨调用交互，带发送节流） |
| `fix-serial-perm.sh` | 串口权限一次性修复脚本 |
| `selftest_capture.py` / `selftest_agent.py` | 自检（28 项 / 20 项断言） |
| `阶段0-操作单.md` | 操作手册与排错表 |

---

## 9. 下一阶段（阶段 1）的验收标准

- [ ] PC 侧 TFTP 服务就绪，板子 `ping $serverip` 通
- [ ] 编出 `Image` + `cm360.dtb`（基于主线 rtd1296.dtsi，补上 §6.3 的五点）
- [ ] `booti` 启动后能看到 `Starting kernel ...` 以及 earlycon 输出
- [ ] **`uname -a` 出得来**
- [ ] **`dmesg` 看到 4 个 CPU 在线**（`/proc/cpuinfo` 有 4 个 processor）
- [ ] 全程未写 SPI / eMMC —— 随时拔电可恢复
