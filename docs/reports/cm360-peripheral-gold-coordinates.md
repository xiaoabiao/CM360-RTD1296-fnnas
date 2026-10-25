# CM360 外设金坐标与阻塞点（离线提取）

> 生成时间：2026-10-11
> 数据源：`boards/rtd1296-cm360/vendor-firmware/ds218-cm360-1020.dts`（原厂 DTB 反编译，行号即该文件行号）
> 与 `artifacts/kernel-6.6.54/rtd1296-cm360.dtb`（我方现役 DTB）
> 目的：把 `README.md` 状态表里剩下两项 ⬜（**风扇/LED/温度**、**SDMMC/SDIO/USB3**）
> 从"缺信息、不知道从哪下手"变成"坐标齐全 + 阻塞点明确 + 上板按序验证"。
>
> **本文不含任何未经核实的功能声明。** 每条都标了 `[实测]`（有原始输出/二进制可查）
> 或 `[推断]`（有理由但未直接证实）。

---

## 0. 方法：没有内核树也能核对

本次工作环境**没有网络、没有 sudo、没有交叉工具链、没有内核源码树**，
因此无法 `make dtbs` 编译验证。改用两条纯离线路径取证：

| 要回答的问题 | 手段 | 工具 |
|---|---|---|
| 现役 DTB 里到底有什么节点？ | 直接解析 `.dtb` 二进制 | `tools/fdt-dump.py`（本次新增，零依赖） |
| 原厂外设的寄存器/引脚/中断？ | 解析原厂 DTB 反编译源码 | 直接读 `vendor-firmware/*.dts` |
| ZFS 模块能不能装进板上内核？ | 解析 `.ko` 的 `.modinfo` 段取 vermagic | `modinfo -F vermagic`（或 `strings x.ko \| grep '^vermagic='`） |

```bash
# 现役 DTB 的节点清单（本文 §1 的表就是这么来的）
python3 tools/fdt-dump.py artifacts/kernel-6.6.54/rtd1296-cm360.dtb --paths
# 原厂 DTB 里 USB 相关节点
python3 tools/fdt-dump.py boards/rtd1296-cm360/vendor-firmware/ds218-cm360-1020.dtb --grep usb
# 某个节点的全部属性
python3 tools/fdt-dump.py <file.dtb> --node sdmmc
```

---

## 1. 现役 DTB 的实际状态 `[实测]`

`artifacts/kernel-6.6.54/rtd1296-cm360.dtb`（8828 字节，version 17，**65 个节点**）解析结果：

| 节点 | 状态 | 说明 |
|---|---|---|
| `/soc/bus@98000000/sdmmc@10400` | **disabled** | 节点在、属性齐，但没使能 |
| `sdio@*` | **不存在** | 连节点都没有 |
| 任何 USB 节点 | **不存在** | dwc3 / phy 全无 |
| `gpio-leds` | **不存在** | 没有软件可控 LED |
| `/soc/bus@98000000/pwm@70d0` | okay | 4 个子通道 `pwm_0`..`pwm_3` |
| `/soc/bus@98000000/pinctrl@1a000` | okay | 只有一组 `pwm0-pins` |
| `/soc/bus@98000000/rtk_fan@1bc00` | okay | 已 probe |
| `/soc/bus@98000000/thermal-sensor@1d100` | okay | 已 probe（但读数恒 0，见 §6） |
| `/thermal-zones/cpu-thermal` | 有 | 只有 `passive` 触发点（刻意无 `critical`） |

> 这张表与 `README.md` 状态表的 ⬜ 完全吻合 —— 说明 ⬜ 描述的是**事实**，不是没更新。

---

## 2. SD 卡（SDMMC）`[实测]`

### 原厂节点（`ds218-cm360-1020.dts:2004-2009`）

```dts
sdmmc@98010400 {
    compatible = "Realtek,rtk1295-sdmmc";
    gpios = <0x36 0x63 0x01 0x00>;
    reg = <0x98000000 0x400 0x98010400 0x200 0x9801a000 0x400
           0x98012000 0xa00 0x98010a00 0x40>;
    interrupts = <0x00 0x2c 0x04>;      /* GIC SPI 44 */
};
```

- **`0x36` 是哪个 GPIO 控制器** `[实测]`：`rtk_misc_gpio@9801b100`
  （`compatible = "Realtek,rtk-misc-gpio-irq-mux"`，`gpio_base = 0`，
  `gpio_numbers = 0x65 = 101`，`interrupt-parent = <0x15>` 即 irq-mux）。见 `:1838-1853`。
- **卡检测脚 = misc_gpio 第 `0x63 = 99` 脚，`GPIO_ACTIVE_HIGH`** `[实测]`。
  与 `docs/reports/feasibility-assessment.md` §A 的结论一致，且该文已指出
  **saola 参考板用的也是 99** → 99 是 RTD1296 的通用卡检测脚。
- ⚠ 原厂 `#gpio-cells = <3>`（Realtek 私有驱动）；**我方 6.6 树是主线风格 `<2>`**
  → 换算成我方写法应为 `<&misc_gpio 99 GPIO_ACTIVE_HIGH>`。

### 原厂 SD 引脚复用（两组，`ds218-cm360-1020.dts:28-44`）

```dts
sdcard_low@0  { rtk119x,pins = "mmc_data_3\0mmc_data_2\0mmc_data_1\0mmc_data_0\0mmc_clk\0mmc_cmd";
                rtk119x,function = "sd_card"; rtk119x,pull_en = <1>; rtk119x,pull_sel = <0>; };
sdcard_high@0 { rtk119x,pins = "mmc_cd\0mmc_wp";
                rtk119x,function = "sd_card"; rtk119x,pull_en = <1>; rtk119x,pull_sel = <1>; };
```

**两组都在原厂的 `pinctrl-0` default 状态里**（`:24`）→ 原厂开机就把 SD 引脚 mux 好了。
注意原厂把数据线组（low）与 `mmc_cd`/`mmc_wp`（high）**拆成两组**，
且 `pull_sel` 不同（0 / 1）—— 移植时不能合并成一组。

### 阻塞点（两条，都在驱动侧）

1. **驱动把三个 GPIO 当必需资源**：`rtk-sdmmc.c` 的 probe 里 `sd-power` / `sd-wp` / `sd-cd`
   走 `devm_gpiod_get()`，失败即 probe 失败。而原厂只给了**一个** `gpios`（卡检测）。
   ⇒ 要么确认这三个脚、要么**给驱动加容错**（照 `patches/0005` 给 `rtk_fan` 加容错的同一套路）。
2. **GPIO 控制器挂在 irq-mux 上**：1296 的 GPIO 中断要经 `irq-mux`，
   而 irq-mux 的 129x 语义尚未在硬件上验证过（见 `rtd1296-cm360.dts:612-619` 的原始分析）。
   我方 DTS 已启用 `iso_irq_mux` 与 `misc_irq_mux`（含一个驱动侧的复制粘贴 bug 修复），
   但 `iso_gpio`（0x98007000/0x98007100，35 脚）**尚未补** —— 见 §7 待办。

---

## 3. SDIO `[实测]`

### 原厂节点（`ds218-cm360-1020.dts:1998-2002`）

```dts
sdio@98010A00 {
    compatible = "Realtek,rtk1295-sdio";
    reg = <0x98010a00 0x100 0x98000000 0x50>;
    interrupts = <0x00 0x2d 0x04>;      /* GIC SPI 45 */
};
```

引脚复用（`:46-49`，原厂 default 状态里也有）：

```dts
sdio@0 { rtk119x,pins = "sdio_cmd\0sdio_data_0\0sdio_data_1\0sdio_data_2\0sdio_data_3\0sdio_clk";
         rtk119x,function = "sdio"; };
```

### 我方现状与注意点

- **节点完全不存在** —— 这是三项里最"干净"的一处：补节点即可，没有历史包袱。
- ⚠ **compatible 必须按我方 6.6 树核对**：原厂写 `Realtek,rtd1295-sdio`（大小写敏感！），
  而我方树的 SDIO 驱动是 `drivers/mmc/host/sdhci-rtk.c`（SDHCI 变体，见
  `docs/reports/peripherals-sata-gmac-emmc.md:108`）。**先 grep 驱动的 `of_match_table` 再写**，
  不要照抄原厂字符串。
- ⚠ **寄存器段序有历史包袱**：原厂是 `<0x98010a00 0x100>, <0x98000000 0x50>`（控制器在前）。
  我方 SD 节点（`rtd1296-cm360.dts:624-628`）刻意把 `0x98000000` 放在**前面**，
  因为"vendor `of_iomap(node,0)` 取的是**中断**段"（`docs/reports/feasibility-assessment.md:81-84`）。
  ⇒ 补 SDIO 时必须先确认目标驱动取的是 `resource[0]` 还是别的序号。

---

## 4. USB3 —— 原厂完整控制器树 `[实测]`

原厂 DTB 里 USB 是**四个独立控制器 + 各自 PHY**（`ds218-cm360-1020.dts:1502-1699`）：

| 控制器节点 | compatible（原厂） | reg | 中断 | 子 dwc3 core | PHY |
|---|---|---|---|---|---|
| `rtk_dwc3_drd@98013200` | `Realtek,rtd129x-dwc3-drd` | `0x98013200 0x200` | SPI 21 | `dwc3_drd@98020000` (`0x98020000 0x9000`) | `dwc3_drd_usb3phy` + `dwc3_drd_usb2phy` |
| `rtk_dwc3_u2host@98013E00` | `Realtek,rtd129x-dwc3-u2h` | `0x98013c00 0x200` | SPI 21 | `dwc3_u2host@98029000` (`0x98029000 0x9000`) | `dwc3_u2host_usb2phy` |
| `rtk_dwc3_u3host@98013E00` | `Realtek,rtd129x-dwc3-u3h` | `0x98013e00 0x200` | SPI 21 | `dwc3_u3host@981F0000` (`0x981f0000 0x9000`) | `dwc3_u3host_usb3phy` + `dwc3_u3host_usb2phy` |
| `ehci@98013000` / `ohci@98013400` | `Realtek,rtd129x-ehci` / `-ohci` | `0x98013000` / `0x98013400` | SPI 21 | — | `usb_phy_rle0599` |

**PHY 节点与寄存器**：

| PHY 节点 | compatible | reg |
|---|---|---|
| `dwc3_drd_usb3phy` | `Realtek,rtd129x-usb3phy` | `0x98013210 0x04` |
| `dwc3_drd_usb2phy` | `Realtek,rtd129x-usb2phy` | `0x98028280 0x04 0x98013214 0x04` |
| `dwc3_u2host_usb2phy` | `Realtek,rtd129x-usb2phy` | `0x98031280 0x04 0x98013c14 0x04` |
| `dwc3_u3host_usb3phy` | `Realtek,rtd129x-usb3phy` | `0x98013e10 0x04` |
| `dwc3_u3host_usb2phy` | `Realtek,rtd129x-usb2phy` | `0x981f8280 0x04 0x98013e14 0x04` |
| `usb_phy_rle0599` | `Realtek,rtd129x-usb_phy_rle0599` | `0x98013824 0x04 0x980130a4 0x04 0x980171cc 0x04` |

**上电管理**（`:1502-1513`）：`rtk_usb_power_manager`
（`Realtek,rtd129x-usb-power-manager`，`reg = <0x98000000 0x10>`）
—— 里面有**关键 GPIO**：

```
realtek,type_c-power-gpio  = <&iso_gpio 0x01 ...>     /* iso_gpio 1  */
realtek,u2host-power-gpio  = <&iso_gpio 0x1f ...>     /* iso_gpio 31 */
realtek,u3host-power-gpio  = <&iso_gpio 0x20 ...>     /* iso_gpio 32 */
```

> `0x48` = `rtk_iso_gpio@98007100`（`Realtek,rtk-iso-gpio-irq-mux`，`gpio_base = 0x65`，35 脚）。

### ★ 关键阻塞点：原厂 compatible 与主线驱动**不是一套** `[实测]`

原厂用的是 Realtek **私有**驱动（`Realtek,rtd129x-dwc3-*`）。
我方 6.6 树里能用的是**主线**驱动：

| 功能 | 我方 6.6 树驱动 | 主线 compatible |
|---|---|---|
| USB3 控制器 | `drivers/usb/dwc3/dwc3-rtk.c` | `realtek,rtd-dwc3` |
| USB3 PHY | `drivers/phy/realtek/phy-rtk-usb3.c` | `realtek,rtd1295-usb3phy` |
| USB2 PHY | `drivers/phy/realtek/phy-rtk-usb2.c` | `realtek,rtd1295-usb2phy` |

（依据 `docs/reports/driver-inventory.md:232-246`）

⇒ **USB3 不是"把原厂节点抄过来"就能通**：要按**主线驱动**的 compatible 与必需属性重写，
而主线 PHY 驱动需要自己的**寄存器初始化序列表**（原厂那份 `phy_data_revA` 有 102 字节，
是给私有驱动用的，不能直接喂给主线驱动）。
原厂 `phy_data_size = 0x33 = 51` / `phy_data_revA`（102 字节）等表在 `:1557-1568`、`:1647-1660`。

> 这也解释了为什么仓库自己的评估写"**风险**：USB3 依赖 pinctrl 和时钟，
> 恰好是主线最弱的两块"（`docs/reports/driver-inventory.md:244`）。

---

## 5. ★ 风扇 / PWM —— 找到了"用错通道"的强证据 `[实测]`

### 原厂 PWM 节点（`:2190-2225`）

```dts
pwm@980070D0 {
    compatible = "Realtek,rtd1295-pwm";
    #pwm-cells = <0x02>;
    reg = <0x980070d0 0x0c>;
    status = "okay";
    pwm_0 { enable = <0x00>; clkout_div = <0xff>; clksrc_div = <0x01>; duty_rate = <0x32>; };
    pwm_1 { enable = <0x00>; ... };
    pwm_2 { enable = <0x00>; ... };
    pwm_3 { enable = <0x01>; ... };      /* ★ 只有通道 3 是使能的 */
};
```

**注意：这个节点没有任何 `pinctrl-*` 属性** —— 引脚复用不在这里做。

### 原厂在哪里做引脚复用（`:19-26`）

```dts
pinctrl@9801A000 {
    compatible = "rtk119x,rtk119x-pinctrl";
    pinctrl-names = "default";
    pinctrl-0 = <0x02 0x03 0x04 0x05 0x06 0x07 0x09 0x0a 0x0d 0x11 0x13 0x14>;
    ...
};
```

其中（`:263-273`）：

```dts
pwm3_1@0 { rtk119x,pins = "nat_led_1"; rtk119x,function = "pwm"; phandle = <0x13>; };
```

⇒ **原厂 default 状态把 PWM 通道 3 复用到 `nat_led_1` 引脚**，
并且 PWM 节点里也只有通道 3 使能。**两处证据互相印证**。

### 与我方现状的对比 —— 这就是"风扇对占空比无响应"的头号嫌疑

| | 原厂（实际生效） | 我方（`rtd1296-cm360.dts:879-898`） |
|---|---|---|
| 使能的通道 | **3** | 0 |
| 复用到哪个引脚 | `nat_led_1` | `iso_gpio_21`（`pinctrl-0 = <&pwm0_pins>`） |
| 引脚复用写在哪 | pinctrl 节点 default 状态 | PWM 节点自己的 `pinctrl-0` |
| 风扇节点 | `status = "disabled"` | `status = "okay"` |

**即：我们一直在通道 0 / `iso_gpio_21` 上做文章，而原厂唯一使能的是通道 3 / `nat_led_1`。**
`CHANGELOG.md` 的"待办"里第 ② 条建议"把 `pwm_1..3` 也 mux 到 iso_gpio_22/23/24 后逐通道扫"
方向是对的，但**扫的引脚集合少了 `nat_led_1` / `etn_led_link` 这一族**。

### 另一个线索：`dc_fan_sensor` 在 `gpio_9`（`:228-231`）

```dts
dc_fan_sensor@0 { rtk119x,pins = "gpio_9"; rtk119x,function = "dc_fan_sensor"; };
```

原厂有个 **DC 风扇测速输入**的引脚复用组，落在 `gpio_9`。
（该组**不在**原厂 default 的 `pinctrl-0` 里。）而我方是把测速接在
`rtk_fan@1bc00` 的 **GIC SPI 29 中断**上（`rtd1296-cm360.dts:946`）。
⇒ 值得核对：风扇测速线到底接在 `gpio_9` 还是 SoC 的 fan 硬件块输入。

### 原厂风扇节点（`:2227-2236`）—— 它是 disabled

```dts
rtk_fan@9801BC00 {
    compatible = "Realtek,rtd129x-fan";
    reg = <0x9801bc00 0x14 0x9801a910 0x04>;
    interrupts = <0x00 0x1d>;                 /* SPI 29 */
    status = "disabled";                      /* ★ 原厂没启用它 */
    pwms = <0x4a 0x00 0x93f6>;                /* 通道 0 */
    timer_target = <0x100000>;
    fan_debounce = <0x00>;
};
```

> **这条很重要**：原厂固件里风扇控制器是 **disabled** 的 ——
> 说明原厂自己也**不用软件调速**。这与 `CHANGELOG.md` 的结论
> （"本板风扇的 PWM 线大概率不在这几个引脚上，或者它根本不受软件控速"）**互相支持**。
> 所以"风扇不响应"**未必是我们的 bug**；但也**不能就此结案**，
> 因为通道 3 / `nat_led_1` 这条线还没试过（见下）。

### 上板建议（按代价从小到大）

1. **先量再改**：`iso_gpio_21` 在 `fan_ctrl_speed` 10% / 100% 下有没有 ~26 kHz PWM。
   有 → 引脚不对；无 → pinctrl/寄存器写错位。**这一步不用重编内核。**
2. **试通道 3**：把 `pwm_3` 的 `enable` 置 1、pinctrl 换成 `nat_led_1`（function `pwm`），
   在 `fan_ctrl_speed` 变化时听/量。这是**原厂唯一使能的通道**，优先级应高于
   目前 CHANGELOG 里"扫 iso_gpio_22/23/24"的方案。
3. **核对测速**：确认风扇测速线接 `gpio_9`（`dc_fan_sensor`）还是 SPI 29 那条。

---

## 6. SoC 温度 —— 可疑根因：少了一个可选属性 `[推断]`

### 原厂节点（`:1925-1936`）

```dts
thermal@0x9801D100 {
    compatible = "Realtek,rtd1295-thermal";
    reg = <0x9801d100 0x70>;
    thermal0-disable = <0x00>;
    thermal1-disable = <0x00>;
    thermal-polling-ms = <0x1f4>;       /* 500 ms */
    thermal-trend-urgent = <0x00>;
    trip-points = <0x73 0x03 0x00 0x00  0x7d 0x03 0x00 0x01
                   0x78 0x07 0x01 0x02  0x82 0x00 0x03 0x00>;
    cpufreq,freqs = <0x13d620 0xc3500 0xaae60 0x493e0>;
    cpu-core,cpu-list = <0x43 0x44>;
    status = "okay";
};
```

并且原厂**另有**一个 SCPU wrapper 节点（`:2026-2030`）：

```dts
scpu_wrapper@9801d000 {
    compatible = "Realtek,rtk-scpu_wrapper";
    reg = <0x9801d000 0x500>;
    interrupts = <0x00 0x2e 0x04>;      /* SPI 46 */
};
```

### 我方节点（`rtd1296-cm360.dts:963-968`）

```dts
thermal: thermal-sensor@1d100 {
    compatible = "realtek,rtd129x-thermal-sensor";
    reg = <0x1d100 0x70>;
    #thermal-sensor-cells = <0>;
    status = "okay";
};
```

我方 DTS 注释（`:959-960`）写着："probe 只强制要 `reg`：`realtek,scpu-wrapper` 是**可选**属性
（`sensor.c` 里先 `of_find_property` 判断），故这里不写"。

### `[推断]` 为什么这可能是读数恒 0 的原因

原厂把温度传感器（`0x9801d100`）与 SCPU wrapper（`0x9801d000`）**相邻且成对出现**：
`0x9801d000 + 0x500` 覆盖了 `0x9801d100`。SCPU wrapper 很可能是**给传感器块做复位/上电**的寄存器块。

如果主线驱动"可选"的含义是"不给我也能跑，但**拿不到数据**"（而不是"给我我就多做一步"），
那么省略它就正好解释"probe 成功、寄存器能读、但 `temp` 恒为 0"。

**上板验证顺序**（不用改内核，只改 DTS）：

1. 先 dump `0x9801d100 ~ 0x9801d170` 的原始寄存器值（`devmem`/`busybox devmem`），
   与"读数为 0"对照 —— 若寄存器本身是 0，就是没使能；若有值而 sysfs 为 0，则是驱动换算问题。
2. 给 thermal 节点补 `realtek,scpu-wrapper = <&scpu_wrapper>`（phandle 名字需按我方
   `rtd1296.dtsi` 里 `syscon@1d000` 的实际 label 定），只重编 DTB 试。
3. 对照原厂 `trip-points` 的阈值语义（`0x73 = 115`、`0x7d = 125`、`0x78 = 120`、`0x82 = 130`），
   但**在读数可信之前不要加 `critical`** —— 这条我方 DTS 已经刻意遵守了。

> ⚠ 我**没有**改动 DTS：没有内核树就无法确认 `realtek,scpu-wrapper` 的准确拼写与
> `syscon@1d000` 的 label，盲写会产出编译不过或行为错误的 DTB。

---

## 7. LED —— 结论：板上没有可软件控制的"系统灯"节点 `[实测]`

对原厂 DTB 全文搜 `led`，只得到三类结果：

| 出现处 | 内容 | 性质 |
|---|---|---|
| `:189-194` | pinctrl 组 `etn_led@0`：pins `etn_led_link`, `etn_led_rxtx`；function `etn_led` | **以太网指示灯**（走 MAC 的 LED 逻辑） |
| `:238-273` | `pwm0_1`→`etn_led_link`、`pwm1_1`→`etn_led_rxtx`、`pwm2_1`→`nat_led_0`、`pwm3_1`→`nat_led_1`（function 均为 `pwm`） | 这些脚可被 PWM 驱动（做呼吸灯之类） |
| `:1908` | GMAC 节点里的 `led-cfg = <0x2070>` | **以太网 LED 配置寄存器**，不是 GPIO LED |

**全文没有任何 `gpio-leds` 节点，也没有 `linux,default-trigger`。**

⇒ 结论：**CM360 的 LED 是"以太网口指示灯"性质**（由 GMAC 的 `led-cfg` 或 PWM 通道 2/3 驱动），
**不存在一个可以挂 `leds-gpio` 的"系统状态灯"**。
因此 `led-set.service` 失败是**预期行为**，不是缺陷 ——
它读 `/boot/board.json` 找厂商定义的 LED GPIO，而这块板本来就没有这种定义。

**建议**：与其继续修 `led-set.service`，不如
（a）在文档里明确"本板无系统灯"，或
（b）若确实想让某个灯受控，用 PWM 通道 2/3（`nat_led_0`/`nat_led_1`）做。

---

## 8. 上板验证清单（按性价比排序）

| # | 目标 | 动作 | 是否需重编内核 |
|---|---|---|---|
| 1 | 温度 | dump `0x9801d100~0x9801d170`；给 thermal 补 `realtek,scpu-wrapper` 只重编 DTB | 否 |
| 2 | 风扇 | 量 `iso_gpio_21` 有无 PWM；改试**通道 3 / `nat_led_1`** | 否（只改 DTS） |
| 3 | 风扇测速 | 核对测速线接 `gpio_9`（`dc_fan_sensor`）还是 SPI 29 | 否 |
| 4 | SDIO | 补 `sdio@10a00` 节点 + 引脚组（先 grep 驱动 `of_match_table` 确认 compatible） | 否 |
| 5 | SD 卡 | 确认 `sd-power`/`sd-wp`/`sd-cd` 三脚，或给驱动加容错补丁 | **是**（驱动补丁） |
| 6 | SD 卡前置 | 补 `iso_gpio`（`0x98007000`/`0x98007100`，35 脚，挂 iso irq-mux） | 否 |
| 7 | USB3 | 按**主线** compatible 重写 dwc3 + phy 节点（含 PHY 初始化表） | 否（但要内核树核对） |
| 8 | LED | 按 §7 结论：本板无系统灯，不必再修 `led-set.service` | — |

### 完成 1~7 需要的前提

本机环境**无网络、无 sudo、无交叉工具链、无内核源码树**，
所以本次只能做到"离线取证 + 不依赖编译的修复"（ZFS 镜像链那一条）。
要把 4~7 写对（尤其是 compatible 字符串、必需属性、PHY 表），需要下面任一条件：

1. 能 `scripts/setup-deps.sh` 拉到 `XpressReal/linux` @ `be79582cb`（网络）；
2. 或把已有的内核树放到 `build/kernel`（`local.conf` 里改 `KTREE` 也行）；
3. 或至少提供 `arch/arm64/boot/dts/realtek/` 下的 dtsi/dts 与
   `drivers/{mmc,phy,usb,thermal}/realtek/` 的驱动源码。

有了内核树，`DTB_ONLY=1 ./scripts/build-kernel.sh` 几秒钟就能出 DTB 并做硬断言校验
（该脚本自带 uart/SATA 的断言段，可照样式给 sdio/usb 加）。

---

## 附：本次新增的可复用工具

| 路径 | 用途 |
|---|---|
| `tools/fdt-dump.py` | 零依赖解析 `.dtb`：列节点/status、按关键字搜、打印某节点属性。没有 dtc 时的替代品 |

vermagic 快速核对（判断 `.ko` 能不能装进板上内核）：

```bash
modinfo -F vermagic artifacts/zfs-2.4.1/zfs.ko
# 或没有 kmod 时：
strings artifacts/zfs-2.4.1/zfs.ko | grep -m1 '^vermagic='
# → 6.6.54-gbe79582cba58-dirty SMP preempt mod_unload aarch64   （与板上内核一致）
```
