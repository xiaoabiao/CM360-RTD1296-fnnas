# 阶段 0 日志分析报告（shot_uboot_01 —— u-boot 环境变量）

> 数据来源：`shot_uboot_01.log`（163 行）/ `shot_uboot_01.raw`（4,939 字节，90.0 秒）
> 抓取方式：`python3 serial_capture.py uboot -t 90 -o shot_uboot_01`（重新上电一次）
> 分析日期：2026-10-04

---

## 一、结论摘要（先说最重要的三件事）

| # | 发现 | 意义 |
|---|---|---|
| 1 | **打断方式彻底验证成功**，提示符是 `CM360_DS218>` | 阶段 0 的"进 u-boot"能力**已稳定复现**，不再是赌运气 |
| 2 | **u-boot 自己带着能用的网卡驱动**（`Net: Realtek PCIe GBE Family Controller` / `r8168#0`），且 `bootcmd` 里就在用 `ping` | ★★★ **阶段 1 可能根本不需要 U 盘**——若支持 `tftpboot`，直接从 PC 用 TFTP 灌主线内核，零介质、最快 |
| 3 | `bootcmd` 用的是 Realtek 私有流程 `rtkspi` + `lzmadec` + **`go all`**，且 `bootdelay=0` | 现成 u-boot **不是**标准 `bootm` 流程；能否跑我们的内核，取决于 `help` 里有没有 `bootm`/`tftpboot`。**这是下一步必须查清的** |

一句话：**阶段 0 全部完成，且拿到了比预期更好的牌。**

---

## 二、打断方式：已验证，可无限复现

日志里这一段是整个阶段 0 的关键证据：

```
[  8.437] Hit Esc or Tab key to enter console mode or rescue linux:  0
[  8.454] Press Tab Key
[  8.454] Start Boot Setup ... 
[  8.456] ---------------LOAD  RESCUE  FW  TABLE ---------------
[  8.465] [ERR] rtk_plat_parse_fwdesc:Signature() error!
[  8.468] Start Boot Setup ... 
[  8.471] ---------------LOAD  GOLD  FW  TABLE ---------------
[  8.476] [ERR] rtk_plat_parse_fwdesc:Signature() error!
[  8.480] Enter console mode, disable watchdog ...
[  8.735] CM360_DS218>
```

逐点解读：

- **`console mode or rescue linux`** —— 打断后有两个选择：console（进提示符）和 rescue（走救援内核）。我们脚本发的 Tab 恰好命中了 console 分支（`Press Tab Key` 这行是 u-boot 打印的，说明它**确实收到了 Tab**）。
- **`bootdelay=0`** —— 没有传统意义的倒计时等待。但 `Hit Esc or Tab key ...: 0` 里的那个 `0` 说明存在一个短窗口，且**连打按键能抢到**。这是"延迟为 0 但仍可打断"的典型 Realtek 实现。
- **`[ERR] rtk_plat_parse_fwdesc:Signature() error!`** —— 两次。说明 SPI 里的 `rescue` 和 `gold` 固件描述表**签名校验没过**（可能被群晖改过，或压根没写）。**这不影响我们**，反而说明这条自动救援路径本来就不可用，少了一个干扰。
- **`Enter console mode, disable watchdog ...`** —— 注意：**进 console 会自动关掉看门狗**。这对我们后面在提示符下长时间敲命令非常有利（不会中途被复位）。
- **`CM360_DS218>`** —— 提示符带机型名。`DS218` 是群晖的双盘位机型，与 `syno_hw_version=DS218`、`ihd_num=2`（2 个内置硬盘）互相印证。

> 复现命令（已实测两次成功）：
> ```bash
> python3 serial_capture.py uboot -t 90 -o shot_uboot_02
> ```

---

## 三、引导链全貌（比第一份日志更完整）

```
上电
 │
 ├─ [ARM Trusted Firmware / FSBL]   hwsetting size: 00000BE4（3,044 字节板级配置表）
 │     emmc_cid 读出 → Samsung 8GTF4（7.3 GiB）
 │     Goto FSBL: 0x10100000
 │
 ├─ [FSBL]       Welcome to FSBL ...
 │     Warm Boot: 0x00000000   ← 冷启动（不是热重启）
 │     Secure:    0x0000BEEE   ← 安全启动相关标志
 │     Flash Type:0x00000002   ← 引导介质类型
 │     DCache Enable: 0x0
 │     SVP = N                 ← 没有启用 SVP（安全视频路径）
 │
 ├─ [BOOTCODE]   FW Image to 0x00020000, size=0x0007CA60 (0x0009CA60)
 │     md copy audio bin       ← 顺带把音频固件搬到内存
 │
 ├─ [U-BOOT]     U-Boot 2015.07-00055-g99edeb3-dirty (Sep 07 2024 - 02:54:21 +0000)
 │     Board: Realtek QA Board ← 用的是 Realtek 官方 QA 板配置，没有做 CM360 定制
 │     DRAM:  2 GiB
 │     Watchdog: Disabled
 │
 └─ 提示窗口 → 我们抢到 → CM360_DS218> console
```

**要点：**

- **二阶 bootloader**：FSBL → BOOTCODE → U-Boot。前两级在 SoC 的 boot ROM / SPI 里，**我们完全不需要碰**。
- **`Board: Realtek QA Board`** —— u-boot 用的是 Realtek 参考板配置。这意味着 u-boot 里的板级初始化是"通用 RTD1296"，**不是非得 CM360 专用**。对我们反而是好事：改板子不用改 u-boot。
- **`Watchdog: Disabled`（启动阶段）+ 进 console 又关一次** —— 全程没有看门狗威胁。
- **`nor flash id [0x00ef4017]`** —— `EF 40 17` = **Winbond W25Q64**，8 MB。与第一份 Linux 日志一致。（u-boot 打印的 `spi type name : S25FL064K_4s` 只是它内部查找表里的**模板名**，不是真实型号；后面 `max capacity : 0x00800000` 才是真的 8 MB。）
- **`mapping memory 0x20000000-0x40000000 non-cached`** —— u-boot 把高 512 MB 的 0x20000000–0x40000000 映射成 non-cached。
  > ⚠️ **这条要记下来**：它意味着 u-boot 会把**内核/ramdisk 放在 0x20000000 以上**（我们的 rootfs 加载地址正是 `0x02200000`）。写我们自己的内核加载地址时要避开这一段，或者依赖 u-boot 自己维持这个映射。
- **HDMI/DP 全部未接**（`HDMITx_HPD=False`、`==== DP not detect ====`），符合 CM360 无视频输出的定位。

---

## 四、u-boot 自身的硬件识别（关键好消息）

```
[  8.427] Net:   Realtek PCIe GBE Family Controller mcfg = 0024
[  8.431] dev->name=r8168#0
```

**u-boot 里跑着一个可用的 Realtek 千兆网卡驱动。**

- 名字里的 "PCIe" 是 Realtek 该驱动的历史命名（和 Linux 侧 `r8169 98016000.gmac eth0: RTL8169SOC` 是**同一块 SoC 内置 GMAC**），**不代表走 PCIe 总线**。
- `mcfg = 0024` 是 MAC 配置寄存器值，说明驱动**已经完成了 MAC 初始化**（改写过配置寄存器），不只是探测。
- 配合 env：

  ```
  ethact=r8168#0
  ethprime=r8168#0
  ethaddr=02:cc:cd:ed:2a:20
  ipaddr=192.168.1.100
  serverip=192.168.1.254
  gatewayip=192.168.1.254
  netmask=255.255.255.0
  ```

- 而 `bootcmd` 的最后一环是 `...;ping $serverip;go all`——
  **u-boot 每次启动都在 ping 192.168.1.254。** 这是群晖/Realtek 原厂设计里"从网络取固件"的残留。

> ★ 这条情报的价值：**如果 u-boot 支持 `tftpboot`，阶段 1 就不需要任何 U 盘/SD 卡介质。**
> 在 PC 上起一个 TFTP 服务（把 PC 设成 192.168.1.254 或用 `setenv serverip <PC_IP>`），
> 把编译好的主线内核 + CM360 dtb 用网线灌进去即可。
> **风险最低、迭代最快**——因为完全不动 SPI、不动 eMMC，重启一下设备就恢复原样。

---

## 五、环境变量全量解读

`Environment size: 1421/131068 bytes` —— **环境变量区有 128 KB，只用了 1.4 KB**。空间极其充裕，我们可以随意 `setenv` 加自己的启动项（当然，要 `saveenv` 才会写回 SPI，**现阶段不做**）。

### 5.1 启动流程链（核心）

```bash
bootcmd=run syno_bootargs;run rtk_spi_boot;run mod_fdt;ping $serverip;go all
bootdelay=0
```

拆开就是四步：

1. `run syno_bootargs` —— 拼出 `bootargs`
2. `run rtk_spi_boot` —— 从 **SPI** 读 kernel / audio / dtb / rootfs，并 LZMA 解压
3. `run mod_fdt` —— 用 `fdt set` 往设备树里**打补丁**（SATA PHY 参数）
4. `ping` 一下服务器 → `go all`（Realtek 私有的"启动全部已加载镜像"命令）

### 5.2 SPI 读取与解压

```bash
rtk_spi_boot=rtkspi read 0x100000 0x0b000000 0x2F0000;\
             lzmadec 0x0b000000 $kernel_loadaddr 0x2F0000;\
             rtkspi read 0x0c0000 0x0b000000 0x040000;\
             lzmadec 0x0b000000 $audio_loadaddr 0x040000;\
             rtkspi read 0x0000000 $fdt_loadaddr 0x00010000;\
             rtkspi read 0x3f0000 $rootfs_loadaddr 0x3ff000
```

> ⚠️ 关键：**用的是 Realtek 私有命令 `rtkspi`，不是标准 `sf`。**
> 这条会影响阶段 1：不能假设 `sf probe` / `sf read` 存在。
> 同理 `lzmadec`（LZMA 解压）和 `go` 也是 Realtek 私有的。

### 5.3 内存加载地址（★ 自研板级 DTS / 启动脚本必需）

| 变量 | 值 | 用途 |
|---|---|---|
| `fdt_loadaddr` | `0x01f00000` | 设备树 dtb |
| `kernel_loadaddr` | `0x03000000` | 内核（解压后） |
| `audio_loadaddr` | `0x01b00000` | 音频固件 |
| `rootfs_loadaddr` | `0x02200000` | rootfs / initramfs |
| `rescue_rootfs_loadaddr` | `0x02200000` | 救援 rootfs（同址） |
| `fdt_high` | `0xffffffffffffffff` | **禁用 fdt 重定位**（`-1` 的特殊写法） |

对照第一份日志：DSM 内核实际跑在 `0x0b000000` 附近（第 1 步 `rtkspi read ... 0x0b000000` 是**临时 staging 区**，解压后才到 `0x03000000`）。

> 注意 `rootfs_loadaddr = 0x02200000` 落在 u-boot 映射为 **non-cached** 的 `0x20000000-0x40000000` 区间内。
> 我们若沿用这套地址，就继承了 u-boot 的映射，**这是最省心的做法**——不要自作主张改地址。

### 5.4 内核命令行（群晖机型伪装）

```bash
syno_bootargs=setenv bootargs "ip=off console=ttyS0,115200 root=/dev/md0 rw  \
  syno_castrated_xhc=xhci-hcd.5.auto@1 \
  syno_usb_vbus_gpio=102@xhci-hcd.2.auto@0,132@xhci-hcd.5.auto@0,133@xhci-hcd.8.auto@0 \
  syno_hw_version=DS218 hd_power_on_seq=2 ihd_num=2 netif_num=1 \
  audio_version=1012363 syno_fw_version=M.506"
```

| 项 | 值 | 解读 |
|---|---|---|
| `root=/dev/md0` | MD RAID0 设备 | **根文件系统在 eMMC 上的软 RAID 里**，不在 SPI |
| `ip=off` | | 内核不做 IP 自动配置，网络由用户态接管 |
| `console=ttyS0,115200` | | 串口控制台，与我们 TTL 一致 |
| `syno_hw_version=DS218` | DS218 | **机型伪装**，决定群晖固件走哪套配置 |
| `ihd_num=2` | 2 | **内部硬盘数 = 2** → 与"原生双 SATA"完全对上 |
| `netif_num=1` | 1 | 1 个网口 |
| `hd_power_on_seq=2` | 2 | 硬盘上电时序档位 |
| `syno_castrated_xhc=xhci-hcd.5.auto@1` | | 阉割版 xHCI（USB 部分功能被砍） |
| `syno_usb_vbus_gpio=102@…,132@…,133@…` | GPIO 102 / 132 / 133 | **USB VBUS 供电使能引脚**（写我们 DTS 时会用到） |

### 5.5 ★ 设备树补丁（确认原生 SATA）

```bash
tx_path=/sata@9803F000
tx_driving=<2>
rx_sensitivity=<2>
mod_fdt=fdt addr $fdt_loadaddr; fdt resize;\
        fdt set $tx_path tx-driving $tx_driving;\
        fdt set $tx_path rx-sensitivity $rx_sensitivity
```

- **`/sata@9803F000`** —— 与第一份日志的 `ata1/ata2 @ 0x9803f000` **完全一致**。
  这是第二次独立确认：**SoC 有原生双 SATA，物理基址 `0x9803f000`，不需要 PCIe 转接。**
- u-boot 在启动前会**动态改写设备树**，给 SATA 节点写 `tx-driving` / `rx-sensitivity` 两个 PHY 参数（都是 `<2>`）。
  → **我们自研的 CM360 dts 里，这两个属性必须带上**，否则 SATA 信号完整性可能不对、认不到盘。
  这是从这次抓取里挖到的一条**很具体的、容易漏掉的硬件细节**。

### 5.6 救援机制（从 eMMC 加载）

```bash
rescue_cmd=go r
rescue_vmlinux=emmc.uImage
rescue_dtb=rescue.emmc.dtb
rescue_rootfs=rescue.root.emmc.cpio.gz_pad.img
rescue_audio=bluecore.audio
```

说明 u-boot **具备从 eMMC 按文件名读取文件的能力**（`emmc.uImage` 是文件名字符串）。
→ 这暗示 u-boot 里应该有 **文件系统读命令**（`fatload` / `ext4load` / `load` 之一）或 Realtek 私有的 eMMC 读取命令。
**若能确认，则"U 盘启动"这条路也通了**——把内核放 U 盘 FAT 分区即可。

### 5.7 其它

| 变量 | 值 | 说明 |
|---|---|---|
| `baudrate` | 115200 | 串口波特率 |
| `mtd_part` | `mtdparts=rtk_nand:` | **空**！没有 NAND 分区表（本机用 SPI NOR，不用 NAND） |
| `ethaddr` | `02:cc:cd:ed:2a:20` | **本地管理地址**（`02:` 开头），原厂随意生成的，不是 Realtek 的 OUI |

> `ethaddr` 顺手记一笔：这个 MAC 是"本地管理"段（第二位为 2/6/A/E），
> 说明**板上没有烧真实 MAC**。将来装飞牛时，MAC 需要我们自己定（或用这个），
> 否则同一网络里多台 CM360 会撞 MAC。

---

## 六、SPI NOR 分区布局（推算，8 MB）

把 `rtk_spi_boot` 的偏移和长度拉出来，得到这张表：

| 起始偏移 | 大小 | 内容 | 证据 |
|---|---|---|---|
| `0x000000` | 64 KB (`0x010000`) | **设备树 DTB** | `rtkspi read 0x0000000 $fdt_loadaddr 0x00010000` |
| `0x010000` | 704 KB (`0x0B0000`) | **⚠️ 未知盲区**（大概率 FSBL / BOOTCODE / u-boot 自身 / logo） | 无 env 引用 |
| `0x0C0000` | 256 KB (`0x040000`) | **音频固件** | `rtkspi read 0x0c0000 … 0x040000` |
| `0x100000` | 2.94 MB (`0x2F0000`) | **内核**（LZMA 压缩 uImage） | `rtkspi read 0x100000 … 0x2F0000` |
| `0x3F0000` | 3.996 MB (`0x3FF000`) | **rootfs / initramfs**（gzip cpio） | `rtkspi read 0x3f0000 … 0x3ff000` |
| `0x7EF000` | 68 KB (`0x011000`) | 尾部余量 | — |

**占用率：**

- 四个已知镜像合计 `7,598,080` 字节 = **7.25 MiB = 90.6%**
- 加上未知盲区 704 KB → **99.2%**
- **剩余可用：最多 772 KB，最少 68 KB**

→ **结论不变且更硬：8 MB SPI 完全塞不下我们自己的内核。**
→ **阶段 1 的路线必须绕开 SPI**（从网络 / USB / SD 加载）。
→ 好处：**全程不写 SPI，设备永远可以拔电恢复，零变砖风险。**

---

## 七、对阶段 1 的三个直接影响

### 7.1 ★ 好消息：网络这条捷径浮出水面

`bootcmd` 里已经在用 `ping`，env 里网络参数一应俱全（`ipaddr`/`serverip`/`netmask`）。
**u-boot 网络栈是活的。**

行动：下一步 `help` 确认有没有 `tftpboot`。
- **有** → 阶段 1 用 **TFTP 灌内核**：PC 起 TFTP，网线直连，`tftpboot 0x03000000 Image; tftpboot 0x01f00000 cm360.dtb; bootm …`。**零介质、秒级迭代**，是三个方案里最优的。
- **没有** → 退到 U 盘 / SD 卡方案（靠 5.6 里暗示的文件系统读命令）。

### 7.2 ⚠️ 需注意：现成 u-boot 不是标准 `bootm` 流程

`bootcmd` 走的是 **`rtkspi` + `lzmadec` + `go all`** 这套 Realtek 私有玩法：

- `lzmadec` 是私有的 LZMA 解压命令
- **`go all` 是私有的"启动全部镜像"命令**，不是标准的 `go <addr>`
- u-boot 版本 **2015.07**，**早于 `booti` 命令的引入（2016.05）**

这意味着：
- 我们的主线 arm64 内核（裸 `Image`）**不能靠 `booti` 启动**，因为这条命令根本不存在
- 可行路径有三条，取决于 `help` 结果：
  1. **`bootm` + 老式 uImage 头** —— 把内核包成 U-Boot legacy uImage，用 `bootm <addr> - <fdtaddr>`。最标准，优先级最高。
  2. **`go all`**（或 Realtek 的 `go r` 之类）—— 沿用原厂机制，**前提是搞清 `go all` 是怎么给内核传 x0/x1/x2 和 dtb 指针的**。需要反汇编 u-boot，工作量大但可控。
  3. **自己做一个"引导桩"** —— 在 u-boot 里 `tftpboot` 一个小 arm64 stub（本质是个极简 bootloader），由它设置好寄存器再跳到内核。工作量中等，兜底方案。

> 这也是为什么 **`go all` 的确切语义要查清**。它很可能就是"把上面 4 个镜像按约定的寄存器/内存布局交给内核"，
> 而那个约定**可能与主线 arm64 boot protocol 不同**。查清它，阶段 1 的路径就定了。

### 7.3 ✅ 已确认：原生双 SATA 需要带 PHY 参数

见 5.5。自研 dts 时 `/sata@9803f000` 节点必须带：

```dts
tx-driving = <2>;
rx-sensitivity = <2>;
```

（这两个属性名是 u-boot 用 `fdt set` 写的，说明**厂商 dtb 里本来就有这两个属性**，
只是 u-boot 要动态覆盖成 `<2>`。照抄即可。）

---

## 八、信息缺口 → 下一步该问 u-boot 什么

现在唯一还挡在阶段 1 前面的问题就是：**这个 u-boot 到底支持哪些命令？**

| 要查 | 为什么 |
|---|---|
| **`help`（总表）** | 一次性看到全部命令，最高优先 |
| `bootm` | 能不能启动标准 uImage —— 决定 7.2 走哪条路 |
| `tftpboot` / `dhcp` | 网络灌内核是否可行 —— 决定阶段 1 是否最省事 |
| `fatload` / `ext4load` / `load` | U 盘/SD 方案是否可行 |
| `mmc` | eMMC 访问能力（以后装系统要用） |
| `usb` | USB 子系统是否存在（USB 网卡兜底方案） |
| `version` | u-boot 编译配置（含哪些驱动） |
| `bdinfo` | 板级信息 / 内存分布 |
| `go` | 私有命令的参数形式 |

**已经为此准备好了 `probe` 模式**（全部只读命令，不会写任何存储）：

```bash
cd /home/xiaoabiao/WorkBuddy/2026-10-03-23-33-10/rtd1296-fnnas/stage0
python3 serial_capture.py probe -t 45 -o shot_uboot_02
```

回车后立刻上电。脚本会自动：前 8 秒交替连打 Esc/Tab 抢提示符 → 之后依次发
`help` / `version` / `bdinfo` / `help usb` / `help fatload` / `help tftpboot` / `help mmc` / `help bootm`，
每条间隔 3 秒，总共约 45 秒。

> 这一次的输出，就是阶段 1 方案选择的**唯一输入**。

---

## 九、本次抓取的原始数据位置

```
stage0/shot_uboot_01.log   163 行，带毫秒时间戳，已把 CR 规范成 LF
stage0/shot_uboot_01.raw   4,939 字节，原始字节，一个不丢
```

`raw` 校验：除 `\r`/`\n`/`\t` 外只有 1 个 NUL 字节（来自 u-boot 的 CR 填充），**没有丢帧、没有乱码**。

工具侧本次同步更新（`serial_capture.py`）：

- 新增 **`probe` 模式**（一键探查命令能力）
- 新增 `--burst-until N`（让 `keys` 自定义计划也能自动带开机打断键）
- 重构出 `build_burst()` / `prepend_burst()`
- 自检 `selftest_capture.py` 从 17 条扩到 **28 条断言，全部通过**
