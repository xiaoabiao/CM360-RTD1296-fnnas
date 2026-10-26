# CM360（RTD1296）：USB-A / Type-C 与盘位指示灯修复报告

> 现场报告，记录 2026-10-26 那一轮的排查、错误假设、最终方案与实机验收。
> 面向"以后要再动这块的人"：**DTS 是唯一缺口，但极性写错会让 USB 全部不供电**，
> 这两条是本次最贵的经验。
>
> 面向使用的说明在 [`../02-kernel-and-dts.md`](../02-kernel-and-dts.md) §4。

## 1. 结论摘要

| 项目 | 修前 | 修后（实机验证） |
|---|---|---|
| Type-C 口 | 不供电、系统完全不识别 | 供电正常，USB3 5Gbps，插 U 盘枚举为 `/dev/sdb` |
| USB-A 口 #1（u2host） | 同上 | USB2 正常（设计上本就只给 USB2） |
| USB-A 口 #2（u3host） | 同上 | 供电正常，USB3 控制器起来，5000M 根 hub |
| 盘位指示灯 ×2 | 全灭 | 在位常亮 + 有 IO 闪烁（按盘区分，hdd1/hdd2） |

改动只有三处：**DTS 补节点** + **内核开两个 PHY config** + **一个用户态灯守护**。
内核本体没有功能性改动（`Image` 只因为开了 PHY 驱动重编）。

## 2. 现象

板子跑自编译 6.6.54（`docs/02-kernel-and-dts.md`），面板、存储都正常，但：

- 插 U 盘到任意 USB 口：灯不亮（无 VBUS）、`lsusb` 空、`dmesg` 无枚举；
- `/sys/bus/usb/devices` 空，`/sys/bus/platform/devices` 里没有任何 `usb`/`dwc`/`ehci` 设备；
- 盘位指示灯（前面两颗）从来不亮，不管是空闲还是读写。

## 3. 排查：不是驱动缺失，是 DTS 没有节点

1. `/proc/device-tree` 里搜不到任何 `usb` 节点；`soc/bus@98000000` 下只有
   emmc / sata / gmac / pwm / thermal 等。
2. 内核 `.config` 里 USB 栈是全的：
   `USB_XHCI_HCD=y`、`USB_XHCI_PLATFORM=y`、`USB_DWC3=y`、`USB_DWC3_RTK=y`、
   `USB_DWC3_DUAL_ROLE=y`、`RTK_USB_CTRL_MANAGER=y`。
3. 但两个 PHY 驱动没编：`# CONFIG_PHY_RTK_RTD_USB2PHY is not set`、
   `# CONFIG_PHY_RTK_RTD_USB3PHY is not set`（`drivers/phy/realtek/Kconfig:19/31`）。
4. 驱动匹配用的 compatible 串没有一个是"厂商旧式"的：
   - `realtek,usb-manager`（`drivers/soc/realtek/common/rtk_usb_manager.c`）
   - `realtek,rtd-dwc3`（`drivers/usb/dwc3/dwc3-rtk.c`）
   - `realtek,rtd1295-usb2phy` / `realtek,rtd1295-usb3phy`（`drivers/phy/realtek/`）
   - 厂商 DTB 里的 `Realtek,rtd129x-ehci/ohci/usb_phy_rle0599` **主线没有驱动**。

结论：原厂 U-Boot 自己把 USB 控制器初始化后 hand-off，DTS 里从来没有描述过，
所以主线内核完全不知道这些硬件存在。**必须自己在 DTS 里写出来。**

## 4. 硬件拓扑（来自原厂 DTB 反编译）

文件：`boards/rtd1296-cm360/vendor-firmware/ds218-cm360-1020.dts`（USB 段约 1502–1699 行）。

| 端口 | 控制器 | wrapper | 子 dwc3 | IRQ | PHY（usb2 / usb3） | VBUS GPIO |
|---|---|---|---|---|---|---|
| port0 | Type-C（DRD，实际 host） | `0x98013200` | `0x98020000` | SPI 21 | `0x98028280` + `0x98013214` / `0x98013210` | iso GPIO 1 |
| port1 | USB-A #1（u2host） | `0x98013c00` | `0x98029000` | SPI 21 | `0x98031280` + `0x98013c14` / — | iso GPIO 31 |
| port2 | USB-A #2（u3host） | `0x98013e00` | `0x981f0000` | SPI 21 | `0x981f8280` + `0x98013e14` / `0x98013e10` | iso GPIO 32 |
| port3 | EHCI `0x98013000` + OHCI `0x98013400` | — | — | — | `usb_phy_rle0599` | — |

- 三个控制器**共用 SPI 21**（原厂就是这样），host 模式下 IRQ 由 `xhci-plat`
  以 `IRQF_SHARED` 申请，共用没问题。
- port3（EHCI/OHCI，接内部 USB2 hub 或前面板）依赖 `usb_phy_rle0599`，
  主线没有该 PHY 驱动 → **本轮跳过**（也不影响 Type-C 与两个 USB-A）。
- ISO GPIO 控制器在原厂 DTB 里是 `rtk_iso_gpio`（`compatible = "Realtek,rtk-iso-gpio-irq-mux"`，
  `reg = <0x98007000 0x100 0x98007100 0x100>`），主线对应 `realtek,rtd1295-iso-gpio`
  （`drivers/gpio/gpio-rtd.c`，gpio_base 101、35 个引脚）。

## 5. 驱动侧契约（写 DTS 必须踩准的点）

### 5.1 `realtek,usb-manager`（`drivers/soc/realtek/common/rtk_usb_manager.c`）

- 节点自身：`reg`（rbus 内偏移）、可选 `realtek,iso = <&iso>`、
  `clocks`/`clock-names = "usb"`、`resets`/`reset-names = "usb"`。
- 子节点名必须是 `usb-port0/1/2`（现代，要求里面有 `snps,dwc3` 子节点）
  或 `usb-port3`（legacy，要求里面有 `ehci`）。
- 每个 port 可写 `realtek,power-gpio = <&iso_gpio N GPIO_ACTIVE_HIGH>`，
  驱动用 `fwnode_gpiod_get_index(..., "realtek,power", 0, GPIOD_OUT_HIGH|NONEXCLUSIVE)`；
  **取到后立刻设成 prefer-assert**（即"输出高=上电"）——所以极性别写反。
- port 的 PHY 复位不是从 port 节点取，而是从 `dwc3` 子节点的 `phys`/`phy-names`
  反查到 PHY 节点，再读 **PHY 节点自己的 `reset-names`**（`u2phy` / `u3phy` / `u3mdio`）。
- `maximum-speed` 写成 `high-speed` 时该 port 不启用 USB3 PHY。

### 5.2 `realtek,rtd-dwc3`（`drivers/usb/dwc3/dwc3-rtk.c`）

- `reg` 段 0 = wrapper（必需），段 1 = pm_base（可选，写 `0x160` 处的 DBUS 电源控制）。
- 子节点必须 compatible `snps,dwc3`（`of_get_compatible_child`）。
- 驱动自己写 WRAP 寄存器做 USB2 PHY 切 host，并按 `maximum-speed` 关 USB3。

### 5.3 `realtek,rtd1295-usb2phy`（`drivers/phy/realtek/phy-rtk-usb2.c`）

- `reg` **至少两项**，前 n-1 项是 wrap vstatus 寄存器，**最后一项**是 PHY acc 块；
  单口写 `<vstatus 0x4>, <phyacc 0x4>`。顺序写反 = PHY 配置全错位。
- 1295 用驱动内置的 `rtd1295_phy_cfg`（page0/page1 表），不需要额外 `realtek,phy-data-*` 属性。

### 5.4 `realtek,rtd1295-usb3phy`（`drivers/phy/realtek/phy-rtk-usb3.c`）

- 只有 `reg` 段 0（mdio 控制基址）。

### 5.5 iso GPIO 控制器

- `gpio-rtd.c` 的 probe 强制要求 **2 个中断**、2 段 reg：
  段 0 = GPIO 块（`0x98007100`，驱动 `data->base`）、段 1 = 中断块（`0x98007000`）。
  注意顺序与原厂 DTB 相反。
- **必须写 `gpio-ranges = <&pinctrl 0 0 35>`**，否则 `pinctrl_gpio_request`
  不会把复用成 i2c/pwm 的引脚切回 GPIO（见 §7.2）。

## 6. DTS 实现

文件：`boards/rtd1296-cm360/rtd1296-cm360.dts`，末尾「6. USB 控制器」「7. 盘位指示灯」两段。

```dts
/* 时钟/复位都在 CRT 域：ISO 域没有 USB 时钟闸门 */
&rbus {
	usb_manager: usb-manager@7088 {
		compatible = "realtek,usb-manager";
		reg = <0x7088 0x10>;
		realtek,iso = <&iso>;
		clocks = <&cc RTD1295_CRT_CLK_EN_USB>;
		clock-names = "usb";
		resets = <&cc RTD1295_CRT_RSTN_USB>;
		reset-names = "usb";
		#address-cells = <1>;
		#size-cells = <1>;
		ranges;

		usb-port0@13200 {			/* Type-C */
			compatible = "realtek,rtd-dwc3";
			reg = <0x13200 0x200>;
			interrupts = <GIC_SPI 21 IRQ_TYPE_LEVEL_HIGH>;
			realtek,power-gpio = <&iso_gpio 1 GPIO_ACTIVE_HIGH>;
			...
			dwc3@20000 {
				compatible = "snps,dwc3";
				reg = <0x20000 0x9000>;
				phys = <&usb_p0_u2phy &usb_p0_u3phy>;
				phy-names = "usb2-phy", "usb3-phy";
				dr_mode = "host";
				...
			};
			usb_p0_u2phy: usb2-phy@13214 {
				compatible = "realtek,rtd1295-usb2phy";
				reg = <0x13214 0x4>, <0x28280 0x4>;
				resets = <&cc RTD1295_CRT_RSTN_USB_PHY0>;
				reset-names = "u2phy";
			};
		};
		/* port1 = USB-A#1（u2host，maximum-speed="high-speed"）；port2 = USB-A#2（u3host） */
	};
};
```

完整（含注释、坐标来源、每个寄存器为什么这么写）见文件本身，约 300 行。

## 7. 第一版失败：极性写成了 `GPIO_ACTIVE_LOW`

### 7.1 现象

第一版 DTB 里 VBUS GPIO 和盘位灯全写成 `GPIO_ACTIVE_LOW`，上板后：

- 三个 xHCI 控制器、PHY 全部 probe 成功，`dmesg` 一切正常；
- 但插任何设备都没反应，`/sys/kernel/debug/usb/xhci/*/ports/port0X` 显示
  `Powered Not-connected Disabled Link:RxDetect PortSpeed:0` —— **软件自认"已供电"**；
- GPIO 实测：`gpio-513/543/544 (usb-power-gpio) out lo ACTIVE LOW`，
  `gpio-533/538 (hdd1/hdd2) out lo` —— 硬件脚全被拉低。

### 7.2 判定"不是 bug，是极性反了"

1. 原厂 DTB 的 GPIO 四元组是 `<phandle pin flags default>`，`flags = 0x1`。
   本仓库已工作的 SATA 供电用的是 `<&misc_gpio 56 GPIO_ACTIVE_HIGH>`，
   对应原厂写法 `0x36 0x38 0x01 0x01`（第 4 格 = 1）—— 也就是原厂的 `0x1`
   在"第 4 格 = 1"时才等价于高有效；USB 那些是第 4 格 = 0。
2. 更直接的证据：引脚**空闲悬空电平**。iso GPIO 数据寄存器实测
   `0x98007104 = 0x0`（全部为低），而 `0x98007110 = 0xFFFFFFFF`（上拉/输入态）。
   如果低电平是"供电/点亮"，那复位瞬间就会给硬盘供电、灯常亮，不符合硬件设计
   （上电默认关闭，靠软件置位打开）。
3. 改 `GPIO_ACTIVE_HIGH` 后立刻正常：GPIO 变 `out hi`、灯亮、VBUS 有电、
   Type-C 上 U 盘枚举成 `/dev/sdb`。

> 教训：`GPIO_ACTIVE_LOW` 只是"软件视角的取反"，不会改变硬件默认电平；
> 判断极性不要看 DTB 里的 flags 字面值，要看**实测寄存器电平**和**同类已工作外设的写法**。

## 8. 修复后验证（实机）

```
$ lsusb
Bus 001/002: 98020000.dwc3 (Type-C，USB3+USB2 根 hub)
Bus 003:     98029000.dwc3 (USB-A#1，仅 USB2)
Bus 004/005: 981f0000.dwc3 (USB-A#2，USB3+USB2 根 hub)

$ dmesg | grep -E 'rtk_usb|dwc3|xhci'
rtk-usb-manager 98007088.usb-manager: Realtek USB init OK
... 3 个 dwc3 probe、PHY 全部 bind、USB3 根 hub 5000M

$ /sys/class/leds: hdd1 hdd2（gpio-538 / gpio-533，ACTIVE HIGH）
$ /sys/class/gpio: gpio-513/543/544 = usb VBUS（out hi）
```

插 U 盘（Type-C）枚举为 `/dev/sdb`，可正常读写。三个口的 VBUS 都有 5V。

## 9. 盘位指示灯：为什么原来不亮

原厂 DTB 里 SATA 节点写着：

```dts
sata@9803F000 {
	blink-gpios = <0x48 0x1a 0x01 0x00>,	/* iso GPIO 26 = bay0 灯 */
	              <0x48 0x15 0x01 0x00>;	/* iso GPIO 21 = bay1 灯 */
};
```

（`0x48` = `rtk_iso_gpio` 的 phandle；`power-management` 节点的
`gpio-output-change-list` 里也是这两个脚，说明休眠时还要保持输出。）

不亮有三个叠加原因：

1. **驱动不解析**：6.6 的 `drivers/ata/ahci_rtk.c` 只处理 `sata-gpios`，
   `blink-gpios` 没有代码读它（原厂私有内核才有）。
2. **没有 LED class**：旧 DTB 没有 `gpio-leds`，`/sys/class/leds` 为空。
3. **引脚没切 GPIO**：`iso GPIO 21` 被 `pwm@70d0` 的 `pwm0_pins` mux 占着
   （早期风扇实验遗留），`iso GPIO 26` 默认是 `i2c_sda_6`。
   没有 `gpio-ranges` 时申请 GPIO 也不会触发 `pinctrl_gpio_request_enable()`
   去切 `function = "gpio"`。

修法：DTB 里加 `gpio-leds`（`hdd1` = iso 26、`hdd2` = iso 21，**高有效**），
删掉 `pwm@70d0` 的 `pinctrl-0 = <&pwm0_pins>`（风扇是硬件自动调速，
`rtk_fan` 本身 `status="disabled"`，那组 mux 只是白占灯脚），并给 iso_gpio 补
`gpio-ranges = <&pinctrl 0 0 35>`。

## 10. 闪烁：内核 `disk-activity` 不够，加用户态守护

`linux,default-trigger = "disk-activity"` 能用，但语义是
「有 IO 时亮 30ms」（`drivers/ata/libata-core.c` 里 `ledtrig_disk_activity()` 被调用），
表现是"几乎看不见闪"。要「在位常亮 + 读写闪 + 无盘灭」，用一个 60 行的 python 守护：

- 文件：`boards/rtd1296-cm360/board-scripts/cm360-hdd-led/`
  （`cm360-hdd-led.py` + `cm360-hdd-led.service` + `install.sh`）；
- 原理：每 100ms 读 `/proc/diskstats`，按 `hdd1 → ata1 → sdc`、`hdd2 → ata2 → sdd`
  分别累计扇区数；有 IO 时把 LED 拉低 3 个 tick（≈0.3s 可见闪烁），
  最近 1s 有 IO 则常亮，>10s 无 IO 但盘在位则常亮（表示在位），盘消失则灭；
- 安装：板上 `sudo bash install.sh`（或 `--test` 只刷一轮、`--uninstall` 卸载）；
- 验收：`/usr/local/bin/cm360-hdd-led.py --once` 打印 `hdd1: dev=sdc brightness=1`；
  读写时连续采样 `brightness` 能看到 `1/1 0/0 1/1 ...`。

守护进程不是必须的：DTB 的 `disk-activity` 兜底仍然在，只是效果弱。

## 11. 部署与回滚（重要）

- 启动路径：U-Boot `bootcmd` 从 **p1（`/dev/mmcblk0p1`，LABEL=BOOT，256M ext4）**
  读 `Image-6.6.uimage` 和 `rtd1296-cm360.dtb` 到内存后 `bootm`；
  **没有 A/B、没有自动回退**。改内核/DTB = 换这两个文件。
- `kexec` 在本平台不可用（`arch/arm64/kernel/machine_kexec.c` 的
  `cpus_are_stuck_in_kernel()` 拒绝：SMP 走 spin-table、没有 `cpu_die`）。
- 换文件用 `tools/deploy-boot-files.sh`（挂 p1、只做一次 `.bak`、md5 核对、sync）。
- 回滚：把 `.bak` 改回原名重启；彻底失败用 **SW5 按住 + 只插 Type-C 进 USB 下载模式**
  重刷（`docs/10-vendor-usb-mp-tool-package.md`），p2 数据分区不受影响。

## 12. 未做 / 已知限制

- **port3（EHCI/OHCI + `usb_phy_rle0599`）没做**：主线没有该 PHY 驱动，
  要做得移植 RLE0599 的 PHY 驱动；当前不影响 Type-C 与两个 USB-A。
- **USB-A #1 只有 USB2**：原厂硬件就是 u2host（`maximum-speed="high-speed"`）。
- **灯只能按盘区分，不能按分区**（`/proc/diskstats` 粒度到设备）。
- GPU 节点本轮 `status="disabled"`（见 `gpu-panfrost-evaluation.md`），
  等有串口再做 panfrost 上电验证。
- 主板 USB2 PHY 的 `realtek,driving-level` 等微调参数没动（用驱动默认值，
  300MHz 眼图未测）。

## 13. 相关文件

- DTS：`boards/rtd1296-cm360/rtd1296-cm360.dts`（USB 段 + LED 段）
- 构建：`scripts/build-kernel.sh`（开 `PHY_RTK_RTD_USB2PHY/USB3PHY`）
- 灯守护：`boards/rtd1296-cm360/board-scripts/cm360-hdd-led/`
- 部署/验收：`tools/deploy-boot-files.sh`、`tools/verify-usb-leds.sh`
- 镜像集成：`firmware/build-images.sh`、`firmware/shrink-p2.sh`、
  `tools/upgrade/board-adapt-newroot.sh`、`tools/upgrade/board-verify-newroot.sh`
- 使用说明：`docs/02-kernel-and-dts.md` §4
