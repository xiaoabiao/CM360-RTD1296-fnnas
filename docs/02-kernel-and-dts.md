# 02 · 内核与设备树

## 1. 为什么用这棵树

**基线**：`github.com/XpressReal/linux` @ `be79582cb`（**6.6.54**，Realtek 全家桶 vendor 树）
+ 本仓库的**板级 DTS** + **补丁** + **内核配置叠加**。

选它的理由：这棵树已经把 RTD119x/129x/139x/13xx/16xx 的驱动都挪到 6.6 了
（CCF 时钟、pinctrl、gpio、eMMC/SD/SATA/GMAC 全在），
但 **129x 的板级 DTS 仍是上游极简骨架** —— 也就是「**驱动齐、DTS 空**」。
于是工作量从"移植几万行驱动"压成"写一份 DTS + 少量驱动修正 + 一份配置"。

对比：早期基于 6.12/6.18 主线的评估预估需移植约 **39,037 行**
（其中时钟 1,650 行、eMMC 10,828 行被认为最难）——这条路把它们全省了。

---

## 2. 补丁清单（`patches/`）

每个补丁对应一个**实测问题**，补丁头部都写了症状与证据。

| 补丁 | 解决的问题 |
|---|---|
| `0000-preexisting-driver-patches.patch` | `irq-realtek-mux.c` 的 `.data` 复制 bug；`phy-rtk-sata.c` 的 SATA 供电 |
| `0001-emmc-rtd1296.patch` | eMMC 时钟/驱动早期适配 |
| `0002-emmc-rtkemmc.patch` | ★ 移植 jjm2473 的 `rtkemmc.c`（17 文件）→ eMMC 一次点亮到 HS200 |
| `0003-smp-rtk-spin-table.patch` | ★ **SMP 四核**：从核释放寄存器必须用 `ioremap` + `writel_relaxed` |
| `0004-wdt-restart.patch` | ★ **修 `reboot`**：给 `rtd119x_wdt` 加 `.restart`，把看门狗当整机复位源 |

### 补丁 0003 的坑（很值钱）

ARM 官方 spin-table 规范说 `cpu-release-addr` 指向**内存**，主线按此用
`ioremap_cache()` + `writeq_relaxed()`（8 字节缓存写）。
但 RTD129x 把它接到了 `pinctrl@9801A000` 区间的**握手寄存器**（`0x9801aa44`）——
一次缓存的 8 字节突发写打到设备寄存器 → **总线挂死，且没有任何报错**。

```
症状：日志停在 "Mountpoint-cache hash table entries" 之后，
     本该出现的 "RCU Tasks: Setting shift to 0 ..." 不再打印
修法：ioremap() + writel_relaxed()（32 位），去掉 dcache 维护
```

### 补丁 0004 的坑（reboot 挂死）

`reboot` 后系统关得干净（systemd 打完 "All filesystems unmounted"），
然后**什么都不发生**：串口静默、网络消失。

根因是 arm64 在**没有任何 restart handler** 时走兜底分支：

```c
	do_kernel_restart(cmd);
	mdelay(1000);
	pr_emerg("Reboot failed -- System halted\n");
	while (1);
```

而这块板子**四方皆空**：

- CPU 用 `enable-method = "spin-table"`（**不是 PSCI**），设备树里也没有 `psci` 节点；
- 内核树里没有 Realtek 的 `rtk-rstctrl` / SoC restart 驱动；
- `rtd119x_wdt` 原本没有 `.restart` 回调；
- DTS 里 `&wdt` 还被显式关掉了。

修法是**两层**：补 `.restart`（设 1 s 超时 → 清计数 → 使能 → 不再喂狗，让硬件拉整机复位）
+ 把 `&wdt` 打开。看门狗核心只要 `ops->restart` 非空就注册 restart handler，
且**不检查 watchdog 是否 active**，所以没人打开 `/dev/watchdog` 也照样生效。

---

## 3. 内核配置叠加（`scripts/build-kernel.sh`）

基线是 arm64 defconfig，**下列每一项都是因为实测某个功能失败、反查出来的**。
全部 `=y` 而不是 `=m`：本树只跑 `make Image`，`.ko` 产出为 0；
板上也没有本内核的模块目录，`=m` 等于"编出来但装不上"。

| 分组 | 符号 | 不配的后果（实测症状） |
|---|---|---|
| 平台 | `ARCH_REALTEK` `ARCH_RTD129x` `COMMON_CLK_RTD1295` | DTB 编不出 / 平台驱动不上 |
| | `MMC_RTK_EMMC` `REALTEK_EMMC_LOCKAPI` | eMMC 认不到（旧驱动写的 pad 寄存器在 1296 上是 `deadbeef`） |
| | `MMC_RTK_SDMMC` `AHCI_RTK` `PHY_RTK_SATA` `R8169SOC` | SD / SATA / 网口不工作 |
| 存储 | `MD_RAID0` `MD_RAID1` `MD_RAID10` `MD_LINEAR` | `md: personality for level 1 is not loaded!` → **fnOS 建存储空间必失败** |
| | `DM_SNAPSHOT` `DM_THIN_PROVISIONING` `DM_RAID` `DM_CRYPT` `DM_CACHE` `DM_WRITECACHE` | LVM 精简置备/快照/加密空间不可用 |
| | `QFMT_V1` `QFMT_V2` | fnOS 的 `makefs_ext4_with_quota` 建卷失败 |
| | `CRYPTO_XTS` `CRYPTO_CBC` `CRYPTO_ESSIV` `CRYPTO_USER_API_*` | dm-crypt / LUKS |
| 网络 | `OPENVSWITCH`(+`_GRE`/`_VXLAN`/`_GENEVE`) | `modprobe openvswitch` not found → `ovs-vswitchd`/`ovsdb-server` 全挂 |
| 内存 | `ZRAM` `CRYPTO_LZ4` `CRYPTO_LZ4HC` `CRYPTO_LZO` `ZRAM_DEF_COMP_LZ4` | zram0 只提供 `lzo lzo-rle zstd`，fnOS 设 lz4 报 `Invalid argument` → **无 swap** |
| 文件系统 | `BTRFS_FS` `XFS_FS` `EXFAT_FS` `NTFS3_FS` `F2FS_FS` `CIFS` `NFSD` | 存储池/共享不可用 |
| 容器 | `OVERLAY_FS` `BRIDGE` `VETH` `VXLAN` `NF_TABLES` `NFT_*` `IP_NF_*` | docker / OVS 网络起不来 |

> ★ 符号名要先在 Kconfig 里确认：写错的名字 `scripts/config` 会**静默失败**
> （例如 NTFS 正确符号是 `NTFS3_FS`，不是 `NTFS3`）。
> `build-kernel.sh` 末尾会逐项复核并打印，别只看"我加了配置"。

---

## 4. 板级设备树（`boards/rtd1296-cm360/rtd1296-cm360.dts`）

DTS 里几乎每个节点都写了"为什么这么写"的注释和证据来源。几条要点：

### 原厂 DTB 是"圣旨"

原厂固件 DTB 的反编译文本留档在 `evidence/stage0/original-dtb.dts.txt`。
两个反复救命的经验：

1. **原厂 DTB 里"缺失的属性"是语义，不是遗漏** —— 它表示"用驱动默认值"，
   而默认值往往就是这台机器的正确硬件模式。
   实例：网口 gmac 原厂**没给** `output-mode` → 驱动默认内嵌 GPHY。
   我们"好心补上" `output-mode = <2>`（外置 PHY）→ 链路能协商、TX 能出、**RX 恒 0**。
2. **原厂双段 `reg` 的段序可能与主线驱动相反** ——
   写反的后果是寄存器全打空，读回全是 `0xdeadbeef`（Realtek SoC 上"地址不存在"的信号）。

### SATA 两个盘位是**分别**供电的

`hd_power_on_seq=2`、`ihd_num=2`（原厂 bootargs）说明两盘独立上电。
DTS 里每个 `sata-port@N` 都要给 `sata-gpios`，否则**盘不转**：

```dts
sata-port@0 { sata-gpios = <&misc_gpio 56 GPIO_ACTIVE_HIGH>; };
sata-port@1 { sata-gpios = <&misc_gpio 19 GPIO_ACTIVE_HIGH>; };
```

引脚号有个坑：**官方 Realtek 参考 dtsi 与这块板子的原厂 DTB 不一致** ——
官方说 port1 用 `iso_gpio 15`，原厂说用 `misc_gpio 19`。
判据：port0 两边都给 `misc_gpio 56`，而它**实测可用**；
既然原厂值在 port0 被证实正确，port1 就信原厂。
（原厂 DTB 里 `blink-gpios` 才用 `rtk_iso_gpio`，那是盘位指示灯，不是供电 ——
具体引脚与接法见下面「盘位指示灯」。）

### USB / Type-C 口必须显式写 DTS 节点

驱动全都在 6.6 树里（`rtk_usb_manager`、`dwc3-rtk`、`dwc3`、`phy-rtk-usb2/usb3`、`xhci-plat`），
但 129x 的 dtsi **一个 USB 节点都没有** —— 原厂是 U-Boot 直接按物理地址初始化 USB 再 hand-off，
所以换内核后 `lsusb` 空、`/sys/bus/usb/devices` 空、`clk_en_usb` 计数恒 0（时钟门没人开）。

DTS 里按原厂拓扑补齐（`&rbus`，reg = 物理地址 − `0x98000000`）：

| 节点 | 作用 | 寄存器 | 中断 |
| --- | --- | --- | --- |
| `usb-manager@7088` | `rtk_usb_manager`，管 VBUS / 复位 / 时钟 | `0x7088` | — |
| `usb-port0@13200` | Type-C（DRD 控制器，本轮 `dr_mode="host"`）| wrap `0x13200`，dwc3 `0x20000` | GIC SPI 21 |
| `usb-port1@13c00` | USB-A #1（纯 USB2，`maximum-speed="high-speed"`）| wrap `0x13c00`，dwc3 `0x29000` | GIC SPI 21 |
| `usb-port2@13e00` | USB-A #2（USB3）| wrap `0x13e00`，dwc3 `0x1f0000` | GIC SPI 21 |

配套改动：

1. **VBUS 使能脚**（原厂 `type_c/u2host/u3host-power-gpio`）= `iso_gpio 1 / 31 / 32`，
   所以必须先实例化 `iso_gpio` 控制器（`gpio-rtd.c`，`realtek,rtd1295-iso-gpio`）。
2. `iso_gpio` 必须带 `gpio-ranges = <&pinctrl 0 0 35>;` ——
   否则 `pinctrl_gpio_request()` 不会把引脚从默认功能（`i2c_sda_6` / `pwm_0`）切成 GPIO。
3. 两个 USB PHY 原来配置是 `=m` 且树里没编出 `.ko`，必须改
   `CONFIG_PHY_RTK_RTD_USB2PHY=y` / `CONFIG_PHY_RTK_RTD_USB3PHY=y`
   （`scripts/build-kernel.sh` 已加）。
4. **VBUS 极性 = 高电平有效**（`GPIO_ACTIVE_HIGH`）。原厂 4-cell 里的 `0x01`
   不是标准 `GPIO_ACTIVE_LOW`，按低有效编译会让三个口**完全没有 5V**，
   表现为"插 U 盘没反应、系统也不识别"（详见下面盘位灯一节的「极性」）。

验证结果（2026-10-26，`build/usb-fix/` 的 Image+DTB 上板）：

- dmesg：`rtk-usb-manager 98007088.usb-manager: port0/1/2 mapping gpio_num=513/543/544`
  + `Realtek USB init OK`，随后 `__gpio_on_off to set power on ... OK`；
  `/sys/kernel/debug/gpio` 里三个 `usb-power-gpio` 都是 `out hi`。
- 总线：`usb1/2` = Type-C（DRD，`98020000.dwc3`）、`usb3` = USB-A #1（纯 USB2）、
  `usb4/5` = USB-A #2（USB3，`981f0000.dwc3`）；USB3 根 hub 速率 `5000`。
- 实测：Type-C 上的 U 盘识别为 `usb 1-1`（`090c:2320`），USB-A 上的 1TB 移动盘
  识别为 `sdb`（`usb-storage` → `scsi host2/3`）。
- 排查端口状态用 `/sys/kernel/debug/usb/xhci/*/ports/portNN`
  （看 `Powered / Connected / Enabled / Link`），比 `lsusb` 更早看到物理层状态。

### 盘位指示灯（HDD LED）

现象：两块盘读写正常，前面板两颗盘位灯全黑，`/sys/class/leds` 为空。

根源：原厂内核的 SATA 驱动按 DTS 里的 `blink-gpios` **自己驱动灯**：

```dts
sata@9803F000 {
	blink-gpios = <&rtk_iso_gpio 26 GPIO_ACTIVE_LOW>,
	              <&rtk_iso_gpio 21 GPIO_ACTIVE_LOW>;
};
```

（`vendor-firmware/ds218-cm360-1020.dts:1987`；同样两脚也出现在原厂
`power-management` 的 `gpio-output-change-list`，即"休眠时要保持输出的脚"。）

而 6.6 的 `drivers/ata/ahci_rtk.c` **只解析 `sata-gpios`，不认 `blink-gpios`**，
DTS 里也没有 leds 节点 ⇒ 两颗灯没人拉电平。

修法：根节点加标准 `gpio-leds`（**高电平点亮**，见下面「极性」），
默认 trigger 用 `disk-activity` 作兜底：

```dts
/ {
	leds {
		compatible = "gpio-leds";
		hdd1-led { gpios = <&iso_gpio 26 GPIO_ACTIVE_HIGH>; linux,default-trigger = "disk-activity"; };
		hdd2-led { gpios = <&iso_gpio 21 GPIO_ACTIVE_HIGH>; linux,default-trigger = "disk-activity"; };
	};
};
```

配套：

1. 同一个 `iso_gpio` 控制器 + `gpio-ranges`（USB 段已要求）。
2. **必须去掉 pwm 节点的 `pinctrl-0 = <&pwm0_pins>`** ——
   旧版 DTS 把 `iso_gpio_21` mux 成 `pwm_0` 给风扇用，而这根脚其实是 **HDD2 指示灯**；
   原厂 `rtk_fan` 节点本身就 `status="disabled"`（DSM 里风扇走硬件自动），
   那个 mux 既没帮上风扇、还会让 HDD2 灯永远不亮。现在 pwm 节点保留寄存器配置
   （`rtk_fan` 的 `pwm_config()` 还能写），但不占任何引脚。
3. `CONFIG_LEDS_GPIO=y` + `CONFIG_LEDS_TRIGGERS=y` + `CONFIG_LEDS_TRIGGER_DISK=y`
   （当前 defconfig 里本来就有）。

极性（2026-10-26 实机验证）：**高电平点亮**，即 `GPIO_ACTIVE_HIGH`。

原厂 DTB 的 4-cell 写法 `<0x48 0x1a 0x01 0x00>` 第 3 个值 `0x01` **不是**
标准 `GPIO_ACTIVE_LOW`。对照同一份 DTB 里已证实可用的 SATA 供电写法
`gpios = <0x36 0x38 0x01 0x01>`（pin 56，我们在 DTS 里写成 `GPIO_ACTIVE_HIGH`
能正常给盘上电）可知：第 3 个 cell 恒为 `0x01`，真正区分的是第 4 个 cell（=默认电平）。

实测反证：按 `GPIO_ACTIVE_LOW` 编译时，两脚已被拉成输出低
（`0x98007100 dir=0x84200002`、`0x98007104 dato=0x0`，mux 也已切到 gpio），
面板灯仍全黑；改成 `GPIO_ACTIVE_HIGH` 后灯立即点亮。同理，USB VBUS 三个脚
（iso GPIO 1/31/32）也是高电平有效，一起修好了（见上一节）。

#### 闪烁与按盘区分：用户态守护 `cm360-hdd-led`

内核自带的 `disk-activity` trigger 只能"有 IO 闪 30ms、空闲全灭"，而且
**两颗灯共用同一个全局 trigger**，分不出是哪块盘在动。所以常态由一个小守护
按 ATA 端口分别统计 `/proc/diskstats`，实现：

| 状态 | 灯 |
|---|---|
| 盘在位、无 IO | **常亮** |
| 有 IO | 6 Hz 闪烁 |
| 该端口无盘 | 灭 |

映射（物理位置，不随 `/dev/sdX` 重排变化）：

| 灯 | iso GPIO | SATA 端口 | ata 端口 |
|---|---|---|---|
| hdd1 | 26 | port0 | ata1 |
| hdd2 | 21 | port1 | ata2 |

安装（已在板上验证，kernel DTB 里的 `disk-activity` 只是没装守护时的兜底）：

```bash
# 仓库里的安装包
bash boards/rtd1296-cm360/board-scripts/cm360-hdd-led/install.sh
# 卸载：bash install.sh --uninstall ；单次调试：bash install.sh --test
```

守护 = `/usr/local/bin/cm360-hdd-led.py` + `cm360-hdd-led.service`（`enable --now`）。
注意：fnOS 升级/重刷镜像后要补装一次（`/usr/local/bin` 在 rootfs，镜像重建会丢）。

> 另外：fnOS 的 `led-set.service` / `set_gpio-init.service` 读 `/boot/board.json`，
> 但脚本**只能配置已存在的 `/sys/class/leds` class，不能创建 LED** ——
> 所以内核 DTS 是前提，`board.json` 只是"接口"。若之后想让面板 UI 控制灯光，
> 再补 `board.json`（格式见 `docs/reports/cm360-led-gpio-re.md` §6）；
> 注意它会和本守护抢同一个 brightness，二者只留一个。

### 看门狗地址

`&wdt` 在 `&iso`（`syscon@7000`，父总线 `rbus` 基址 `0x98000000`）下 `reg = <0x680>`，
⇒ 实际 `0x98007680`，与原厂 DTB 一致；运行时 sysfs 也印证：

```
/sys/class/watchdog/watchdog0 -> .../98000000.bus/98007000.syscon/98007680.watchdog/...
```

---

## <a name="为什么需要-modmeta"></a>5. 为什么换内核后必须跑 `deploy-modmeta.sh`

内核是**全内置**构建（`.ko` 产出为 0），所以板子上原本**没有 `/lib/modules/<版本>/`**。
于是 `modprobe <内置模块>` 一律失败：

```
modprobe: FATAL: Module zram not found in directory /lib/modules/6.6.54-...
```

而 fnOS 的多个脚本正是**靠 `modprobe` 的返回值判断模块可用性**的
（zramswap、ovs 等）。结果就是：模块明明已经编进内核，服务照样起不来。

`scripts/deploy-modmeta.sh` 把 `modules.builtin` / `modules.builtin.modinfo`
拷到板上，并在**板上**跑 `depmod`。

> ★ **实测教训**：只拷文本文件**不够** —— kmod 只认 `.bin` 索引，
> 必须在板上跑一次 `depmod` 才会生成 `modules.builtin.bin` 等。
> 只拷文本时 `modprobe` 依旧失败，白查一轮。

---

## 6. 构建产物

| 文件 | 说明 |
|---|---|
| `build/Image-6.6` | 裸 arm64 内核（u-boot 用 legacy uImage 壳，见 `make-uimage.py`） |
| `build/rtd1296-cm360.dtb` | 板级设备树 |
| `build/Image-6.6.uimage` | 套好壳的 uImage（load/entry = `0x03000000`） |

只改 DTS 时用 `DTB_ONLY=1 ./scripts/build-kernel.sh`（几秒钟）。
改 `.config` 相关（即 `build-kernel.sh` 里的配置叠加）时**不要**用这个开关。
