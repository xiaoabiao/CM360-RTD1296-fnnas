# 阶段 0 日志分析报告（shot_log_01）

> 数据来源：`shot_log_01.log` / `shot_log_01.raw`（48,721 字节原始，934 行，120 秒）
> 抓取方式：`serial_capture.py log -t 120`，TTL @ 115200 8N1，全程只读
> 分析日期：2026-10-04

---

## 一、最重要的发现：这台机器不是原厂系统

日志末尾是 **`DiskStation login:`** —— CM360 **已经刷成了黑群晖**，而且当前处于
**DSM 的 `flash_rd` 模式（安装 / 救援模式）**，不是完整安装状态。

证据链：

```
[   13.029880] r8169 98016000.gmac eth0: link down
[   10.904543] ds218_synobios: loading out-of-tree module taints kernel.
[   10.925825] Brand: Synology
[   10.928687] Model: DS-218
[   41.406] Exit on error [1] DISK NOT INSTALLED...
[   41.594] linuxrc.syno failed on 1
[   51.153] Starting findhostd in flash_rd...
[   52.164] Starting services in flash_rd...
[   52.171] Starting httpd:80 in flash_rd...
[   52.174] Starting httpd:5000 in flash_rd...
[   52.731] starting pid 3077, tty '': '/sbin/getty 115200 console'
[  120.019] DiskStation login:
```

| 项 | 值 |
|---|---|
| 系统 | Synology DSM（`syno_hw_version=DS218`，**伪装成群晖 DS218**） |
| 内核 | `Linux version 4.4.302+ (root@build8) (gcc version 12.2.0) #86009 SMP Wed Nov 26 18:28:01 CST 2025` |
| 状态 | `flash_rd` 安装模式，`DISK NOT INSTALLED` |
| 根文件系统 | `root=/dev/md0 rw`（md0 由 ramdisk 组装） |
| 完整 bootargs | `ip=off console=ttyS0,115200 root=/dev/md0 rw syno_castrated_xhc=xhci-hcd.5.auto@1 syno_usb_vbus_gpio=102@xhci-hcd.2.auto@0,132@xhci-hcd.5.auto@0,133@xhci-hcd.8.auto@0 syno_hw_version=DS218 hd_power_on_seq=2 ihd_num=2 netif_num=1 audio_version=1012363 syno_fw_version=M.506` |

> 含义：**别人已经把 RTD1296 的引导链问题解掉了**（u-boot 是 2024-09 重新编的）。
> 这对我们是重大利好——阶段 1 很可能可以**直接复用这个现成 u-boot**，不用自己碰 bootloader。

---

## 二、引导链全貌（实测）

```
上电
 └─ [FSBL] SVP = N
     └─ ********** FW_TYPE_BOOTCODE **********
         └─ FW Image to 0x00020000, size=0x0007CA60        ← bootcode 在 SPI offset 0x20000
             └─ U-Boot 2015.07-00055-g99edeb3-dirty (Sep 07 2024 - 02:54:21 +0000)
                 ├─ Board: Realtek QA Board
                 ├─ CPU  : Cortex-A53 Quad Core - AARCH64
                 ├─ DRAM : 2 GiB
                 ├─ NOR  : JEDEC 0x00ef4017 (= Winbond W25Q64, 8 MB)
                 ├─ eMMC : RTD1295 eMMC, Samsung 8GTF4, 7.3 GiB, HS200, 8-bit
                 ├─ Net  : r8168#0  (SoC GMAC)
                 ├─ "Hit Esc or Tab key to enter console mode or rescue linux: 0"   ★ 打断键
                 ├─ Using r8168#0 device → ping 192.168.1.254 failed   (网络引导尝试)
                 └─ 从 SPI NOR 加载四个镜像：
                     ┌ DTB      SPI 0x88100000 → DDR 0x01f00000   读取 0x10000   (64 KB)
                     ├ KERNEL   SPI 0x88200000 → DDR 0x0b000000   读取 0x2f0000  (3.07 MB, 解压后 7,767,768 = 7.41 MB)
                     ├ INITRD   SPI 0x881c0000 → DDR 0x0b000000   读取 0x40000   (256 KB, 解压后 767 KB)
                     └ RAMDISK  SPI 0x884f0000 → DDR 0x02200000   读取 0x3ff000  (4 MB)
```

**★ 打断 u-boot 的键是 `Esc` 或 `Tab`，不是回车。**
（我第一版脚本用的是回车，会失效——现已修正为 Esc/Tab 交替连打。）

### 内存 / 加载地址（写板级 DTS 必需）

| 项 | 值 |
|---|---|
| DRAM | 2 GiB |
| 内核线性映射 | `0xffffffc000000000 - 0xffffffc080000000`（物理 0x0 起，2 GiB 连续） |
| kernel `.text` | `0xffffffc000280000` → 物理 **0x280000** |
| DTB 加载地址 | **0x01f00000** |
| zImage 加载地址 | **0x0b000000** |
| ramdisk 加载地址 | **0x02200000** |
| CMA 预留 | 32 MiB @ `0x7e000000` |
| reserved | `438184K`（约 428 MB），cma-reserved 32768K |
| 可用内存 | `1626200K/2097152K` |
| u-boot 重映射 | `mapping memory 0x20000000-0x40000000 non-cached` |

### 固件能力（对阶段 1 关键）

- **`psci: PSCIv0.1 detected in firmware`** —— 固件提供 PSCI，主线理论上可以用
  `enable-method = "psci"` 拉起 4 个核，不必自己写 smp ops。
  （警告：日志同时打了 `psci: Conflicting PSCI version detected.`，需要实测确认）
- CPU 特性：`ARM erratum 845719` workaround 已启用
- `Find sata tx regs and patched to B0` ← **SoC 步进疑似 B0 或更新**（影响 `r8169soc` 的初始化分支，待确认）

---

## 三、硬件实测清单

### 3.1 存储

| 设备 | 实测 |
|---|---|
| SPI NOR | 8 MB，JEDEC `0x00ef4017`（Winbond W25Q64 系列），`max capacity 0x00800000` |
| eMMC | `RTD1295 eMMC`，Manufacturer ID `0x15`，Name **`8GTF4`**（三星 8GB），7.3 GiB，HS200，8-bit，Boot 4 MiB，RPMB 512 KiB |
| **SATA** | **SoC 原生双口**：`ata1`/`ata2` @ MMIO `0x9803f000`，port 0x100/0x180，**IRQ 12** |
| 当前 SATA 状态 | `ata1: SATA link down` / `ata2: SATA link down` → **两个口都没插硬盘** |

SATA 相关的厂商调优日志：
```
[    4.863453] [SATA] spread-spectrum disable
[    4.906687] [SATA] set tx-driving to L (level 2)
[    5.104110] ata1: SATA max UDMA/133 mmio [mem 0x9803f000-0x9803ffff] port 0x100 irq 12
[    5.112288] ata2: SATA max UDMA/133 mmio [mem 0x9803f000-0x9803ffff] port 0x180 irq 12
[    5.469691] ata1: SATA link down (SStatus 0 SControl 300)
[    5.829677] ata2: SATA link down (SStatus 0 SControl 300)
```

> ⚠️ **eMMC 被 DSM 完全忽略**：整份内核日志里**没有任何 mmc 驱动加载记录**
> （`grep -iE "mmc[0-9]|mmcblk|sdhci|rtkemmc"` 只命中 u-boot 段）。
> 说明 eMMC 里现在装的可能是原厂 Android 或其他东西，**没被动过**。有 shell 后值得 dump 头部看看。

### 3.2 网络（★ 重点）

```
[    6.032063] r8169 Gigabit Ethernet driver 2.32.5-LK-NAPI loaded
[    6.050812] r8169 98016000.gmac eth0: RTL8169SOC at 0xffffff8004ca2000, 02:cc:cd:ed:2a:20, XID 10900880 IRQ 11
[    6.061115] r8169 98016000.gmac eth0: jumbo features [frames: 9200 bytes, tx checksumming: ko]
[   13.012059] r8169 98016000.gmac eth0: rtl_csiar_cond == 0 (loop: 100, delay: 10).
[   13.021001] r8169 98016000.gmac eth0: rtl_csiar_cond == 1 (loop: 100, delay: 10).
[   13.029880] r8169 98016000.gmac eth0: link down
[   44.361] eth0      Link encap:Ethernet  HWaddr 00:11:32:8C:E5:1F
```

| 项 | 值 |
|---|---|
| 驱动 | `r8169`，版本 `2.32.5-LK-NAPI`，设备名 **`RTL8169SOC`** |
| 设备形态 | **platform 设备 `98016000.gmac`**，MMIO 基址 **`0x98016000`** |
| IRQ | **11** |
| XID | `10900880` |
| 硬件默认 MAC | `02:cc:cd:ed:2a:20`（本地管理位；DSM 用户态覆盖为群晖 OUI `00:11:32:8C:E5:1F`） |
| MDIO/CSIAR | `rtl_csiar_cond == 1` → 通路正常 |
| **当前状态** | **`link down` —— 没插网线**（`eth0 not RUNNING`，`udhcpc` 空转） |

> ✅ **实锤：网卡是 SoC 内置 MAC（platform 设备 + MMIO），不是 PCIe 独立网卡。**
> u-boot 里那句 `Net: Realtek PCIe GBE Family Controller mcfg = 0024` 只是复用了 RTL8168 的字符串名，
> Linux 侧才是权威：`98016000.gmac`。
> → 这与我们之前"路 A 移植 r8169soc"的判断完全一致，且**基址已拿到**。

**HWNAT 被主动关掉了**：
```
[   20.141938] pctrl-rtk: pctrl_nat::POWER_OFF, ret = 0
[   20.152037] pctrl-rtk: pctrl_l4_icg_nat_wrap::ENABLE_HW_PM, ret = -1
```
→ 连群晖都没用 HWNAT。我们放弃它是正确的，不亏。

### 3.3 USB3（好消息）

**三个 dwc3 控制器全部工作**，而且地址与命名**和主线已有驱动完全对得上**：

| 控制器 | dwc3 core | USB3 PHY | USB2 PHY | 实例名 |
|---|---|---|---|---|
| DRD（双角色） | `0x98020000` | `0x98013210` | `0x98028280` | `98013200.rtk_dwc3_drd` |
| U2 host only | `0x98029000` | — | `0x98031280` | `98013c00.rtk_dwc3_u2host` |
| U3 host only | `0x981f0000` | `0x98013e10` | `0x981f8280` | `98013e00.rtk_dwc3_u3host` |

配套：
- `rtk-usb-power-manager` @ `0x98000000`
- `phy-rtk-rle0599` @ `0x98013824`（USB 2.0 RLE0599 PHY）
- Vbus 由 GPIO 控制：**#102 / #132 / #133**，`ACTIVE_HIGH`
- xhci 总线 2/3/4/5/6/7 全部注册成功
- `usb-storage` 模块加载 OK

驱动名对照（厂商 ↔ 主线）：
```
linux: rtk-dwc3 / rtk-usb2phy / rtk-usb3phy
主线:  drivers/usb/dwc3/dwc3-rtk.c        compatible "realtek,rtd-dwc3"
主线:  drivers/phy/realtek/phy-rtk-usb2.c
主线:  drivers/phy/realtek/phy-rtk-usb3.c compatible "realtek,rtd1295-usb3phy"  ★ 正是本芯片
```
→ **主线的 USB3 驱动就在那儿，地址和命名都能对上。路 B（USB 网卡）可行性很高。**

### 3.4 时钟 / 定时器 / RTC

| 子系统 | 实测 |
|---|---|
| 时钟驱动 | `clk-rtk`，PLL workaround `34055501` / `04038500` |
| 参考时钟 | `rtk_refclk` 27 MHz |
| UART 时钟 | UART0 = **27 MHz**，UART1/2 = **432 MHz** |
| arch timer | `Architected cp15 timer(s) running at 27.00MHz (phys)` |
| sched_clock | 56-bit @ 27 MHz，分辨率 37 ns |
| 厂商私有定时器 | `[RTK-TIMER0]` / `[RTK-TIMER1]` 各自注册 clocksource |
| RTC | `rtc_rtd129x 9801b600.rtc: rtk_rtc already enabled` → **基址 `0x9801b600`** |
| 系统时间 | 起点 2016-01-01（RTC 未对时） |
| 其它时钟域 | VPU（ve1/ve2/ve3）、JPU |

### 3.5 其它

| 项 | 实测 |
|---|---|
| 引脚/电源域控制 | `pctrl-rtk`（如 `pctrl_usb_p0_mac::POWER_ON`、`pctrl_l4_icg_scpu_wrapper::ENABLE_HW_PM`） |
| 串口 | `ttyS0` = 我们的调试口；`ttyS1` = `synobios open /dev/ttyS1 success`（跟板载 MCU 通信） |
| SPI 控制器 | `Realtek SFC Driver is successfully installing.` |
| 中断 | `NR_IRQS:64 nr_irqs:64` |
| PCI 资源 | 内核打印了 `PCI I/O : ... (16 MB)` 资源窗口，但**没有任何 PCIe host bridge 探测日志** |
| 服务 | `httpd:80` / `httpd:5000` / `ssdpd` / `avahi`（avahi 因缺 `libm.so.6` 启动失败） |

---

## 四、★ 对上一版报告的修正

| # | 上一版报告的说法 | 实测结果 | 影响 |
|---|---|---|---|
| 1 | 接硬盘要"PCIe 转双 SATA 卡" | **错**。SoC 有**原生双 SATA**（`ata1`/`ata2` @ `0x9803f000`，IRQ 12） | **阶段 4 的 PCIe 移植可以整个砍掉**，多盘位本来就能满足 |
| 2 | PCIe 是必须打通的一环（1,858 行） | **不需要**。DSM 内核里完全没有 PCIe host bridge，PCIe 总线根本没启用 | 省掉约 1,858 行 + 一堆 DesignWare glue 工作 |
| 3 | 打断 u-boot 用回车 | **错**。提示语是 `Hit Esc or Tab key` | 抓取脚本已修正 |
| 4 | 网卡是"内置 MAC + 外置 RTL8211" | **对**，且拿到实锤：platform `98016000.gmac`、`RTL8169SOC`、IRQ 11 | 路 A 判断成立，基址已得 |
| 5 | HWNAT 无法复刻是个损失 | 影响很小——**群晖自己也把 NAT 块关掉了** | 放弃 HWNAT 不亏 |

### 修正后的工作量

原估 **40,895 行**，减去 PCIe（1,858 行）后约 **39,037 行**；
若 MVP 阶段再跳过 eMMC（16,002 行）、GPIO 复用主线（省 926 行），
**必须先搬的约 2,100 行（时钟 + 复位）+ 933 行（pinctrl）≈ 3,000 行**。

### 修正后的路线图

```
阶段 0  串口摸底              ← 进行中（已完成第一轮）
阶段 1  板级 DTS + 主线内核起到 shell
阶段 2  移时钟 + pinctrl + 接 GPIO/RTC 节点     ← 关键路径
阶段 3  USB3 → USB 网卡 → 首次试装飞牛          ← 网络先走这里
阶段 4  SATA（原生双口！）    ← 从"移植 PCIe+SATA"降级为"点亮已有 SATA"
阶段 5  eMMC + 原生 GMAC（r8169soc）
```

---

## 五、新出现的约束：SPI 已经塞满了

SPI NOR 只有 **8 MB**，而当前四个镜像合计：

```
kernel(压缩) 3.07 MB + initrd 256 KB + dtb 64 KB + ramdisk 4 MB ≈ 7.4 MB
```

**8 MB SPI 已经基本满了。** 我们的主线 6.12 内核塞不进去。

→ **阶段 1 的正确做法：用现成 u-boot 从 USB / SD 加载内核，不往 SPI 里写任何东西。**
好处是顺带把"刷坏 SPI 变砖"的风险完全排除——**全程不碰 SPI，随时可以拔盘恢复原状**。

---

## 六、信息缺口（还需要补）

| # | 缺什么 | 为什么重要 | 怎么拿 |
|---|---|---|---|
| 1 | **u-boot `printenv`** | 最高优先。要 `bootcmd`/`bootargs`/`loadaddr`/`fdt_addr`/`bootdelay`，才能设计"从 U 盘启动主线内核" | 重新上电，抓 `uboot` 模式 |
| 2 | 没插网线 | 看不到 PHY 协商速率，进不了 httpd:5000 | 插一根网线 |
| 3 | 没插硬盘 | 无法验证原生 SATA 能否认盘（NAS 的本体） | 插一块盘到 SATA |
| 4 | eMMC 当前内容 | DSM 完全没碰它，可能还是原厂 Android | 有 shell 后 `dd` 头部几 MB |
| 5 | DSM 登录凭据 | 若知道密码，走 SSH/web 备份比走 u-boot 方便得多 | 你如果知道，直接告诉我 |
| 6 | SoC 实际 revision | `patched to B0` 暗示 B0+，影响 `r8169soc` 初始化分支 | u-boot 里 `md`/寄存器读，或内核日志 |
| 7 | PCIe 是否物理存在 | 既然不用了，降为"顺便确认" | 可跳过 |

---

## 七、下一步（按优先级，全部零风险）

### 1 ★ 抓 u-boot 环境变量（只需重新上电一次）

```bash
cd /home/xiaoabiao/WorkBuddy/2026-10-03-23-33-10/rtd1296-fnnas/stage0
python3 serial_capture.py uboot -t 90 -o shot_uboot_01
```

**回车后立刻上电。** 脚本已修正：前 8 秒交替连打 `Esc`/`Tab` 打断 autoboot，
之后自动发 `printenv`。全程不写入。

这一次的输出会决定阶段 1 的走法：
- 如果 u-boot 提示符能进、且支持 `usb start` / `fatload` / `bootm` → **直接复用现成 u-boot，阶段 1 立刻可做**
- 如果进不去或功能受限 → 再考虑其他加载途径

### 2 插网线，然后重跑一次 `log`

能多看到：PHY 协商速率、`eth0` 拿 IP、DSM 的 httpd 起来。
顺便：浏览器开 `http://<设备IP>:5000` 就能看到 DSM 安装界面。

### 3 插一块硬盘到 SATA，再重跑一次 `log`

验证原生 SATA 认盘。会多出 `ata1: SATA link up ...` 和 `sd 0:0:0:0: [sda] ...` 之类的行。
这一步直接决定 NAS 可行性。

### 4 如果你知道 DSM 的登录密码

告诉我。走 SSH/web 能直接拿到 `/proc/mtd`、`/proc/partitions`、`printenv` 的等价信息，
比反复上电抓日志高效得多，也能顺手把 eMMC 头部 dump 出来。

---

## 附录：本次抓取的原始数据位置

```
rtd1296-fnnas/stage0/
├── shot_log_01.log      带时间戳的文本日志（934 行）
├── shot_log_01.raw      原始字节（48,721 字节）
├── serial_capture.py    抓取工具（已支持 log / uboot / keys 三种模式）
├── selftest_capture.py  自检（17 项断言，全过）
└── 阶段0-日志分析-shotos_01.md   本文件
```

常用检索命令：
```bash
cd rtd1296-fnnas/stage0
grep -n "link down\|SATA link\|Memory:\|Kernel command line" shot_log_01.log
```
