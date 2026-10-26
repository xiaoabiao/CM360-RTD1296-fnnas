# CM360 硬盘指示灯（HDD LED）GPIO 映射调查报告

- 调查人：teammate `led-hunter`（task-4）
- 日期：2026-10-26
- 板子：小睿 CM360（Realtek RTD1296，DS218 克隆机箱，2 盘位），fnOS 1.2.0302 / 内核 6.6.54-gbe79582cba58-dirty
- 状态：**证据链已闭合到「引脚」级；电气极性/盘位编号需一次受控写测试确认**（见 §8，需 lead 批准）
- 写作用域：本报告 + `tools/led_probe.sh`；未改动 `boards/rtd1296-cm360/rtd1296-cm360.dts`（该文件当前被 lead 的 USB 工作占用，`git status` 显示已修改，本报告只给**片段**）。

---

## 0. 结论（先看这里）

1. **CM360 的硬盘指示灯不是 fnOS/DSM 的“软件灯”，而是接在 RTD1296 的 ISO GPIO 域**：
   原厂 DTB 的 SATA 控制器节点带 **2 条 `blink-gpios`**（正好 = 2 个盘位），分别指向
   **iso GPIO 26**（`0x48 0x1a 0x01 0x00`，blink-gpios[0] → sata-port@0）
   与 **iso GPIO 21**（`0x48 0x15 0x01 0x00`，blink-gpios[1] → sata-port@1）。
   同一对引脚还出现在原厂 `power-management` 的 `gpio-output-change-list` 里（休眠/关机时翻转），
   这是“盘位活动灯”在 Realtek 原厂 BSP 里的标准写法。
2. **灯不亮的直接原因（三件叠加）**：
   a. 厂商 4.9 的 `ahci_rtk` 用 `blink-gpios` 驱动盘位灯，而本仓库 6.6 树的
      `drivers/ata/ahci_rtk.c` **只支持 `sata-gpios`（硬盘供电），完全没有 `blink-gpios` 解析** ——
      即使引脚接好了也没人驱动它；
   b. 当前运行的板级 DTB（2026-10-25/26 之前编译的那版）**没有实例化 ISO GPIO 控制器**
      （`/sys/kernel/debug/gpio` 里只有 misc 域的 gpiochip512，101 线），所以 26/21 这两根连
      sysfs 线都没有；
   c. 即便有 gpiochip，26/21 的 pinmux 也没切到 `gpio` 功能（`pin 21` 被风扇 `pwm_0` 占用，
      `pin 26` 目前 mux 未定义），需要 `gpio-ranges` 或 pinctrl 状态让 `gpio_request` 自动切 mux。
3. **修复路线（推荐方案 A）**：
   - DT 里给已有的 `iso_gpio` 节点补一行 `gpio-ranges = <&pinctrl 0 0 35>;`，
   - 加一个标准 **`gpio-leds`** 节点，两个 LED 都用 `linux,default-trigger = "disk-activity"`；
   - 写 `/boot/board.json`（`led{}` 两条，`gpio: []`），让 fnOS 的 `led-set.service`/`set_gpio-init.service`不再 failed；
   - 注意 **iso GPIO 21 与现有风扇 PWM（`pwm_0`）抢脚**，需要 lead 决策：确认风扇是否真的用 pwm0
     （历史记录：写 `fan_ctrl_speed` 转速无变化，fan 控制从未被证实有效）。
4. 备选：若不想动风扇 PWM，则先只修 **bay0（iso GPIO 26）**，bay1 等风扇问题解决后再接。
5. 退化方案：若 `disk-activity` 触发条件不满足（例如盘不在活动状态/无块设备统计），可退化为
   `heartbeat`、`timer` 或 `none`（常亮）；board.json 内容见 §6。

> 一句话给用户：**硬盘灯没坏，是系统没给 iso GPIO 26/21 建 LED 设备；我们已经定位到引脚，**
> **补 DTS + board.json 就能亮，还能随硬盘读写闪烁。**

---

## 1. 现象与已知事实复核

在现场（2026-10-26 06:1x，板子在线时段）只读采集，逐条确认了任务背景：

| 检查项 | 实测结果 | 说明 |
|---|---|---|
| `/sys/class/leds` | 空 | 内核没有任何 LED class 设备，fnOS 脚本无从配置 |
| `/sys/class/gpio` | 存在；`gpiochip512`（base=512，label=`9801b100.gpio`，ngpio=101） | `CONFIG_GPIO_SYSFS=y` 确实开了；但只有 misc 域 101 线 |
| `/sys/kernel/debug/gpio` | 仅 `gpiochip0`（GPIOs 512-612，parent `platform/9801b100.gpio`），**没有任何已申请的 line** | iso 域 gpiochip 不存在 → iso 26/21 不可见 |
| `/boot` | 空目录（rootfs btrfs 子卷；eMMC p1 是另一个未挂载的 BOOT 分区） | `board.json` 不存在 |
| `led-set.service` / `set_gpio-init.service` | **failed**（2025-06-26 22:58:47 起，每次开机）：`Error: /boot/board.json not found` | 服务脚本先检查文件，直接 exit 1 |
| `/proc/cmdline` | `root=/dev/mmcblk0p2 rootfstype=btrfs rootflags=subvol=root rootwait rw` | `/boot` 在 rootfs 内，不是 FAT 分区 |
| 运行中 DT | `/proc/device-tree/soc/bus@98000000/` 下只有 misc 域 `syscon@1b000/gpio@0`（`realtek,rtd1295-misc-gpio`），**没有 iso gpio 节点** | 这就是 b 项的根因 |

上述与任务描述完全一致。

> 📌 **现场复核状态（2026-10-26 06:37 起）**：板子 ICMP 可达（ping 2/2），但 TCP 22/80/443/5000/8080
> **全部 closed/timeout** —— 用户侧很可能正在重启/刷机（lead 同时在改 `scripts/build-kernel.sh`）。
> 因此 `tools/led_probe.sh` **尚未在板子上实际跑过**（语法已本地校验），§8 的写测试也未执行。
> 板子恢复 SSH 后第一件事：跑一次 `tools/led_probe.sh` 并把输出归档到 `evidence/logs/`，
> 用于确认 iso gpiochip 是否已随新 DTB 出现、以及 §2.4 里被更正的那组寄存器读数。

补一条容易被误读的点：

> ⚠ **寄存器读数更正**：调查早期我们用 `busybox devmem` 读 `0x98007000` 当作“ISO GPIO 的 DIR/DATO”，
> 结论“iso 21/26 都是输入”是**错的**。依据厂商节点命名与 6.6 驱动段序（见 §2.2/§2.3），
> ISO GPIO 的 DIR/DATO/DATI 在 **`0x98007100`**，`0x98007000` 是它旁边的中断块。
> 所以 iso 21/26 的当前电气状态**尚未实测**，§8 的写测试仍然必要。

---

## 2. 证据链

### 2.1 fnOS 侧：`board.json` 机制与硬约束（首要证据）

板上脚本原文（`/usr/trim/bin/system_setled.sh`，已完整读取）关键行为：

```sh
BOARD_JSON="/boot/board.json"
# 1) start(): [ ! -f "$BOARD_JSON" ] && echo "Error: $BOARD_JSON not found"; exit 1
# 2) led_length=$(jq '.led | length' "$BOARD_JSON")   # 没有 .led 或为空 → "No LED configuration" exit 0
# 3) 逐条 jq 取字段：
#    name sysfs trigger brightness delayon delayoff interval inverted default color mode
# 4) sysfs 缺省 = name
# 5) 关键硬检查：
#    if [ ! -e "/sys/class/leds/${sysfs}/brightness" ]; then
#        echo "Warning: LED '${sysfs}' not found in /sys/class/leds/"; return 1   # 跳过该条
#    fi
# 6) trigger 解析：parse_trigger_type()=第1个词；dev=第2个词；mode=剩余词
#    （如 trigger = "netdev eth0 link tx rx" → type=netdev, dev=eth0, mode="link tx rx"）
# 7) 先 echo 默认亮度 > brightness（default=0 → 0；否则 brightness，缺省 = max_brightness），
#    再 echo "$trigger" > trigger；trigger 写入失败 → 提示缺内核模块并 return 1
# 8) trigger 专项：timer/oneshot → delay_on/delay_off；heartbeat → invert；
#    netdev → device_name + link/tx/rx；gpio → /sys/class/leds/<sysfs>/gpio 写 dev（厂商扩展属性）
```

`/usr/trim/bin/system_setgpio.sh` 关键行为：

```sh
# 逐条 .gpio[]：name / pin / value / delay
# pin 必须是数字（全局 GPIO 号），走 /sys/class/gpio/export，
# 然后 [ "$value" = "0" ] && echo low > direction || echo high > direction
# （direction 不可写时退回写 value 0/1）
```

**由此得到两条硬约束**（决定方案形态）：

1. **`board.json` 只能“配置已存在的 LED class 设备”，不能创建 LED。**
   `sysfs` 名必须已经出现在 `/sys/class/leds/`，否则该条被 skip。
   所以只写 `board.json` 对“点灯”**零作用** —— 必须先在 DT 里创建 LED 设备（`gpio-leds`）。
2. `system_setgpio.sh` 可以不经 LED class、直接把某个 GPIO 拉成静态高/低（一次性），
   适合“常亮灯”退化方案，但**做不到随硬盘活动闪烁**（除非外部反复调用）。

### 2.2 厂商 DTB：`blink-gpios` = 盘位指示灯（核心证据）

文件：`boards/rtd1296-cm360/vendor-firmware/ds218-cm360-1020.dts`
（同内容还有 `死机专用ds218-cm360-1022.dts`、`2.4rtd129x_syno_dtb.dts`，见下）

```dts
/* L1975-2001：SATA/AHCI 控制器 */
sata@9803F000 {
    compatible = "Realtek,ahci-sata";
    reg = <0x9803f000 0x1000 0x9801a900 0x100>;
    gpios = <0x36 0x38 0x01 0x01 0x36 0x13 0x01 0x01>;   /* misc 56 / misc 19：硬盘供电 */
    ...
    blink-gpios = <0x48 0x1a 0x01 0x00 0x48 0x15 0x01 0x00>;  /* ★ 盘位灯：iso 26 / iso 21 */
    sata-port@0 { reg = <0x00>; };
    sata-port@1 { reg = <0x01>; };
};

/* L2244-2255：电源管理（休眠/关机时翻转的 GPIO） */
power-management {
    compatible = "Realtek,power-management";
    wakeup-gpio-enable = <0x01>;
    wakeup-gpio-list = <0x48 0x21 0x00 0x00>;              /* iso 33：电源键唤醒 */
    gpio-output-change-enable = <0x01 0x01>;
    gpio-output-change-list = <0x48 0x15 0x01 0x00 0x48 0x1a 0x01 0x00>;  /* ★ iso 21 / iso 26 */
    gpio-output-change-activity = <0x00 0x00>;
    status = "okay";
};
```

解码：`0x48` 是 `rtk_iso_gpio@98007100` 的 phandle（L1855-1867），
`0x1a`=26、`0x15`=21；每项 4 cell 的 `<phandle pin 0x01 0x00>` 是厂商 4.9 绑定
（`#gpio-cells=3`）的“输出 + 初值低”写法，与供电脚 `gpios = <0x36 0x38 0x01 0x01>`
（misc 56 输出高）格式一致。

同一对引脚既出现在 **AHCI 的 `blink-gpios`**（活动灯语义），又出现在
**`power-management` 的输出翻转表**（休眠时关灯语义）——两处互证：
**iso 26 / iso 21 就是前面板两个盘位 LED 的驱动脚，且是输出、低有效可能性大。**

其它三份厂商 DTB 副本同样有这一对（`1022`：`blink-gpios` L1988、`gpio-output-change-list` L2247），
说明不是 `1020` 单份的笔误。

并且全文搜索 `led|LED|blink` 后，厂商 DTB **只有**这些 LED 相关项：
- `etn_led_link` / `etn_led_rxtx`（pinctrl 组，以太网 PHY 灯，`gmac led-cfg=<0x2070>`，系统不可控）；
- `nat_led_0..3`（pinctrl 组，PWM/网络状态灯用途，未接本板前面板）；
- 上述 `blink-gpios`；
- **没有 `gpio-leds` 节点、没有 `leds` 节点、没有 I2C LED 扩展器、没有单片机**。

旁证（外部资料，`post.smzdm.com/p/a20pn2r2/`，CM360 刷 DSM 教程）：
> “板子没有单片机灯设备，后台报 i2c 错误，影响硬盘休眠和 WOL 灯功能”
> 教程给的修复脚本 `code.imnks.com/cm360/cm360-bug.sh` 内容我们也拿到了：它只是用 `sed`
> 关掉 DSM 的 `support_led_behavior_v2=no`、`support_led_brightness_adjustment=no`、
> `supportsystempwarning=no` 等项，并把 `scemd.log` 重定向到 `/tmp` —— **纯软件关灯/止血，
> 没有任何 GPIO 配置**。这从反面证明：CM360 没有 MCU/I2C 灯控，前面板灯就是 SoC GPIO 直驱。

### 2.3 6.6 内核能力：有 LED 类驱动，但缺 `blink-gpios` 解析、缺 iso gpio 实例

`artifacts/kernel-6.6.54/kernel.config`：

| 配置 | 行 | 值 | 对方案的意义 |
|---|---|---|---|
| `CONFIG_LEDS_CLASS` | 7322 | `y` | LED class 核心已编入 |
| `CONFIG_LEDS_GPIO` | 7344 | `y` | **`gpio-leds` 可直接用** |
| `CONFIG_LEDS_PWM` | 7354 | `y` | （PWM 灯备用） |
| `CONFIG_LEDS_TRIGGER_DISK` | 7393 | `y` | **`disk-activity` 触发器可用** |
| `CONFIG_LEDS_TRIGGER_TIMER` | 7391 | `y` | 退化方案可用 |
| `CONFIG_LEDS_TRIGGER_HEARTBEAT` | 7395 | `y` | 退化方案可用 |
| `CONFIG_LEDS_TRIGGER_DEFAULT_ON` | 7399 | `y` | 常亮默认触发器 |
| `CONFIG_LEDS_TRIGGERS` | 7390 | `y` | |
| `CONFIG_LEDS_TRIGGER_PANIC` | 7406 | `y` | |
| `CONFIG_GPIO_RTD` | 4186 | `y` | Realtek gpio 控制器（misc + iso） |
| `CONFIG_GPIO_SYSFS` | 4153 | `y` | `/sys/class/gpio` 可用 |
| `CONFIG_PINCTRL_RTD` | 4069 | `y` | mux 控制器可用 |
| `CONFIG_OF_GPIO` | 4148 | `y` | |
| `LEDS_TRIGGER_ACTIVITY` / `NETDEV` | — | **未开** | 不要用这两个触发器（脚本会在写 trigger 时失败并 return 1） |

驱动侧关键事实（源码来自 `XpressReal/linux@be79582cb`，6.6.54 树）：

1. **`drivers/ata/ahci_rtk.c` 不支持 `blink-gpios`**：
   8180 字节版本里只出现 `sata-gpios`（`devm_fwnode_gpiod_get(..., "sata-gpios", ...)`，
   行 178/243/297 附近），全文没有 `blink`/`led` 字样。厂商 4.9 那套活动灯逻辑没有移植。
   ⇒ **不写新驱动/不改 DTS 方案，硬盘活动灯不可能自己闪**。

2. **`drivers/gpio/gpio-rtd.c`（`CONFIG_GPIO_RTD`）完整支持 iso 域**：
   - `of_match`：`realtek,rtd1295-iso-gpio` → `rtd1295_iso_gpio_info`
     `{ .name="rtd1295_iso_gpio", .gpio_base=101, .num_gpios=35,
        dir_offset={0x0,0x18}, dato_offset={0x4,0x1c}, dati_offset={0x8,0x20},
        ie_offset={0xc,0x24}, dp_offset={0x10,0x28} ... }`；
   - `probe`（`gpio-rtd.c:528-590`）：**强制** `platform_get_irq(pdev,0)`、`platform_get_irq(pdev,1)`
     （缺一即失败），`reg[0]`=GPIO 寄存器块、`reg[1]`=中断寄存器块，
     `gpio_chip.base=-1`（动态分配），`.request = gpiochip_generic_request` / `.free`。
   - 因此 DT 节点必须给 **2 段 reg + 2 条中断**，与纯 LED 用途无关但 probe 要它们。

3. **`drivers/pinctrl/realtek/pinctrl-rtd.c` 支持 iso pinctrl，且实现 `gpio_request_enable`**：
   - `compatible = "realtek,rtd1295-iso-pinctrl"`；`rtd_pinmux_ops.gpio_request_enable =
     rtd_pinctrl_gpio_request_enable`（`pinctrl-rtd.c:362-374`）：
     `rtd_pinctrl_set_one_mux(pcdev, offset, "gpio")` —— GPIO 被 request 时**自动把该脚切到 gpio 功能**。
   - 但这条路径只有在 **gpiochip 有 `gpio-ranges` 映射到 pinctrl** 时才会生效：
     `pinctrl_gpio_request()`（`pinctrl/core.c:792-817`）先 `pinctrl_get_device_gpio_range()`，
     找不到 range 时走 `pinctrl_ready_for_gpio_range()` 返回成功但**不做任何 mux 编程**。
   - `pinctrl/pinmux.c:265-282` + `:168`：`gpio_request_enable()` 收到的是**绝对 pin 号**，
     而本树 `pinctrl-rtd1295.h` 的 iso pin 编号 0..40 与 gpio offset 一一对应
     （pin 21 = `iso_gpio_21`，pin 26 = `i2c_sda_6`），所以 `gpio-ranges = <&pinctrl 0 0 35>`
     的映射是正确的。
   - `pinmux.c:131`：GPIO range 方式的 request **跳过**“pin 已被 pinctrl state 占用”的 `-EBUSY` 检查，
     `gpio_request_enable()` 会**直接覆盖** mux。⇒ 即使风扇 `pwm0_pins` 仍占着 iso 21，
     申请 GPIO 也会把 mux 抢到 gpio（有“静默抢走风扇 PWM”的副作用，见 §7 冲突）。

4. **iso 21 与 iso 26 的 mux 定义**（`pinctrl-rtd1295.h`）：
   ```c
   [RTD1295_I2C_SDA_6]   = RTK_PIN_MUX(i2c_sda_6,   0x14, GENMASK(3,2), FUNC(0x0,"gpio"), FUNC(0x1,"i2c6"))
   [RTD1295_ISO_GPIO_21] = RTK_PIN_MUX(iso_gpio_21, 0x1c, GENMASK(1,0), FUNC(0x0,"gpio"), FUNC(0x1,"pwm_0"))
   ```
   函数 `gpio` 的 group 列表里同时含 `"iso_gpio_21"` 与 `"i2c_sda_6"`（pin 26），
   所以两个脚都能切回 gpio（这也是它们能被当 LED 用、却仍能当 i2c6/pwm0 用的原因）。

### 2.4 运行中系统的只读实测（2026-10-26 06:1x）

板子在线期间（`python tools/brd.py sudo ...`，SSH 会话有 `Could not chdir to home directory /home/Xiaoabiao`
的无害告警）采集到：

1. `pinctrl` debugfs：`/sys/kernel/debug/pinctrl/9801a000.pinctrl-foo/`，共 41 个 pin（编号 0..40）。
   - `pins`：如 `pin 21 (iso_gpio_21)`、`pin 26 (i2c_sda_6)`、`pin 33 (iso_gpio_33)`；
   - `pinmux-functions`：`function 0: gpio`，组列表含 `iso_gpio_2..7, ir_rx/ir_tx, i2c_*, iso_gpio_21..25,
     i2c_sda_6, etn_led_link/rxtx, nat_led_0..3, iso_gpio_33/34 ...`；
   - `pinmux-pins` 关键行：
     - `pin 21 (iso_gpio_21): 980070d0.pwm pwm_0 group iso_gpio_21` ← **当前被风扇 pwm 占用**；
     - `pin 26 (i2c_sda_6): (MUX UNCLAIMED) (GPIO UNCLAIMED)`；
     - `pin 33/34`: unclaimed。
2. `/sys/class/gpio/gpiochip512/{base,ngpio,label}` = `512 / 101 / 9801b100.gpio`；`/sys/class/gpio/export` 可写。
3. `/proc/device-tree/soc/bus@98000000/syscon@1b000/gpio@0` 存在，`compatible="realtek,rtd1295-misc-gpio"`，
   `#gpio-cells=<2>`；**没有 iso gpio 节点**（与旧 DTB 一致）。
4. 寄存器只读采样（`busybox devmem`）——注意块归属：
   - `0x98007000=0x00000000, 0x98007004=0x00181000, 0x98007008=0xFF3FE27A,
      0x9800700c=0x20000000, 0x98007010=0x00000000`（bank1: `0x98007018=0, 0x9800701c=0xA0002000,
      0x98007020=0, 0x98007024=0, 0x98007028=0x800`）
   - 按 §1 的更正，这是 **iso 中断块**的读数，不是 GPIO DIR/DATO；
     **真正 GPIO 块 `0x98007100` 的 DIR/DATO/DATI 尚未采样**，由 `tools/led_probe.sh` 补采。

### 2.5 仓库文档的既有结论与本报告的关系

- `docs/02-kernel-and-dts.md:112-126`：明确写了
  “原厂 DTB 里 `blink-gpios` 才用 `rtk_iso_gpio`，那是盘位指示灯，不是供电”。
  **本报告把这句话落到了具体引脚（iso 26 / iso 21）与落地配置上。**
- `docs/reports/cm360-peripheral-gold-coordinates.md` §7（L350-378）旧结论
  “板上没有可软件控制的系统灯节点”，其依据是“全文搜 `led` 只找到 etn_led/nat_led/led-cfg”。
  **该结论不完整**：`blink-gpios` 里没有 `led` 字样，被漏掉了。§7 应更新为：
  “没有 `gpio-leds` 节点；但 SATA 节点有 2 条 `blink-gpios` = 盘位指示灯（iso 26/21），
  需要用 `gpio-leds` 显式接出来”。
- `docs/05-storage-and-fnos.md:82,106-122`：确认 `led-set`/`set_gpio-init`/`pwm-fancontrol`
  三个服务都读 `/boot/board.json`，镜像里没有该文件；并提醒 `pwm-fancontrol` 要的是 `hwmon pwm1`
  （本板没有 hwmon pwm），所以 board.json 只补 `led`/空 `gpio` 即可。

### 2.6 当前仓库 DTS 的现状（lead 正在改，勿冲突）

`boards/rtd1296-cm360/rtd1296-cm360.dts` 当前 **已有一份未提交修改**（`git status`: `M`，应属 lead 的 USB 工作），
其中已经新增了两个关键节点（行号按当前工作区）：

- `:363-379` `iso_gpio: gpio@100`（`&iso` 下）：
  ```dts
  iso_gpio: gpio@100 {
      compatible = "realtek,rtd1295-iso-gpio";
      reg = <0x100 0x100>, <0x0 0x100>;   /* 0x98007100=GPIO, 0x98007000=IRQ（段序相对 vendor 交换） */
      syscon = <&iso>;
      interrupt-parent = <&iso_irq_mux>;
      interrupts = <19>, <20>;
      gpio-controller;
      #gpio-cells = <2>;
      interrupt-controller;
      #address-cells = <0>;
      #interrupt-cells = <1>;
  };
  ```
- `:335-349` `iso_irq_mux`（compatible `realtek,rtd129x-iso-irq-mux`，父 GIC SPI41；说明它已被配置）
- `:448-469` `misc_irq_mux` + `misc_gpio`（已有先例，misc 无 `gpio-ranges` 是**故意**的）
- `:862-898` `sata-port@0`（`sata-gpios = <&misc_gpio 56>`）/ `sata-port@1`（`sata-gpios = <&misc_gpio 19>`）
  —— 注意 `:874-885` 的注释也引用了“`blink-gpios` 才用 `rtk_iso_gpio`，那是盘位指示灯”。
- `:919-947` `pwm` 节点：`pwm_0 enable=1 duty_rate=0x32`，`pinctrl-0 = <&pwm0_pins>`，
  `:954-962` `pinctrl` 节点 + `pwm0_pins { pins="iso_gpio_21"; function="pwm_0"; }` ← **LED on 21 的冲突点**
- `:981-996` `fan: rtk_fan@1bc00`（`pwms = <&pwm 0 0x93f6>`，`status=okay`）

**结论：iso gpio 控制器的“管道”已由 lead 铺好（USB 用途），本报告只需在此基础上补
`gpio-ranges` 一行 + `gpio-leds` 节点，不必再重复定义控制器。**

---

## 3. 候选引脚排序表

| # | 引脚 | 置信度 | 证据 | 风险 / 备注 |
|---|---|---|---|---|
| 1 | **iso GPIO 26**（`i2c_sda_6`，ball 26） | **高（85%）** | 厂商 DTB `blink-gpios[0]`（AHCI port0 活动灯）+ `power-management` 输出翻转表；2 盘位 = 2 条 blink-gpios | 当前 mux “未定义”；申请 GPIO 会切 gpio。作为 HDD1（bay0）活动灯 |
| 2 | **iso GPIO 21**（`iso_gpio_21`，ball 21） | **高（85%）** | 厂商 DTB `blink-gpios[1]`（AHCI port1 活动灯）+ `power-management` 输出翻转表 | **与风扇 `pwm_0` 抢脚**：本仓库 DTS 把 iso21 给了风扇 PWM（`pwm0_pins`），且 `pwm_0 enable=1`。**需 lead 决策后可动** |
| 3 | iso GPIO 33 / 34 | 排除 | 33 = `wakeup-gpio-list`（电源键唤醒）；34 = 厂商 DTB `pcie@9804E000 iso-gpios`（PCIe 复位/使能，节点 disabled） | 不是灯，勿碰 |
| 4 | pwm `nat_led_0..3`（pin 29-32 区域） | 低（15%） | pinctrl 组存在，但厂商 DTB 没有把它们接到任何灯节点；`pwm_3 enable=1` 可能只是留用 | 若要修“电源/状态灯”再回来查；与 HDD 灯无关 |
| 5 | misc GPIO（按钮/供电） | 排除 | 57=线刷键，8=U盘刷机键，58=boot sel；56/19=硬盘供电；1/31/32=USB VBUS | 绝对不可当灯写 |
| 6 | I2C / MCU | 排除 | 厂商 DTB 无 I2C LED 控制器；smzdm 教程明确“没有单片机灯设备” | `support_led_*` 被教程脚本关闭即为此因 |

**盘位编号（bay0 ↔ 前面板 HDD1/HDD2）**：`blink-gpios` 顺序对应 `sata-port@0/1`，
但前面板丝印/物理盘位顺序**尚未实测**（可能是 1↔2 对调），§8 的写测试会顺便确认。

**极性**：厂商 4 cell `<phandle pin 0x01 0x00>` 的 `0x01` = 输出、`0x00` = 初值低；
若 LED 从 3.3V 经限流电阻到 pin（低电平点亮），则初值低=亮，与“开机灯不亮”矛盾——
更可能是 **高电平点亮（ACTIVE_HIGH）**，初值低=灭。仍需实测（§8 步骤 2 的 1/0 各试一次）。

---

## 4. 为什么现在灯不亮（机制总结）

```
  原厂固件（4.9 内核）                          本仓库（6.6 内核，现场）
  ─────────────────────                        ──────────────────────
  ahci_rtk 解析 sata 节点的 blink-gpios        6.6 ahci_rtk.c 没有 blink-gpios 代码路径
        │                                             │
        └─ gpiod_set_value(iso_gpio 26/21)            └─ 无人申请/翻转这两根 GPIO
                        │                                      │
   DT: rtk_iso_gpio@98007100 已实例化           DT: 运行版没有 iso gpio 节点
                        │                                      │
   /sys/class/leds 无（厂商也不用 LED class）    /sys/class/leds 空 → board.json 即使存在也 skip
                        │                                      │
   面板 HDD LED 随盘活动闪烁                     面板 HDD LED 恒灭 ✗
```

所以用户看到的“硬盘灯不亮”是**驱动+DT 缺功能**，不是硬件坏、也不是 fnOS 配置漏了一项。

---

## 5. 修复方案

### 方案 A（推荐）：DT 加 `gpio-leds` + `gpio-ranges`，用 `disk-activity` 触发器

优点：零驱动改动、LED 由内核 LED core 统一管理（可被 fnOS board.json 覆盖）、
两盘共用 `disk-activity`（全局块设备活动）即可满足“读写闪、空闲灭”。

**A.1 给已存在的 `iso_gpio` 节点补一行 `gpio-ranges`（必须，否则 mux 不会切 gpio）：**

```dts
/* 现有节点（lead 的 USB 改动里，:363-379）只补这一行： */
&iso {
	iso_gpio: gpio@100 {
		compatible = "realtek,rtd1295-iso-gpio";
		reg = <0x100 0x100>, <0x0 0x100>;	/* GPIO=0x98007100, IRQ=0x98007000 */
		syscon = <&iso>;
		interrupt-parent = <&iso_irq_mux>;
		interrupts = <19>, <20>;
		gpio-controller;
		#gpio-cells = <2>;
		interrupt-controller;
		#address-cells = <0>;
		#interrupt-cells = <1>;

		/* ★ 新增：把 gpio 0..34 映射到 iso pinctrl 的 pin 0..34（pin 21/26 才能自动切 gpio） */
		gpio-ranges = <&pinctrl 0 0 35>;
	};
};
```

> 说明：`gpio-ranges` 会把 **整个 iso gpio chip（0..34）**登记到 `pinctrl@1a000`。
> lead 的 USB VBUS（iso 1/31/32）也会因此获得“request 时自动切 gpio”的能力 —— 对 USB 是**正向收益**，
> 但属于对 lead 文件的修改，请 lead 合并时留意。

**A.2 根节点加 `gpio-leds`（新节点，插在 `/ { ... }` 块里或文件末尾的 `/ { };` 追加块）：**

```dts
/ {
	leds {
		compatible = "gpio-leds";
		status = "okay";

		/* bay0 = 前面板 HDD1，iso GPIO26，暂定 ACTIVE_HIGH */
		hdd1_led: hdd1-led {
			label = "hdd1:green:disk";	/* 决定 /sys/class/leds/hdd1:green:disk */
			gpios = <&iso_gpio 26 GPIO_ACTIVE_HIGH>;
			linux,default-trigger = "disk-activity";
			default-state = "off";
		};

		/* bay1 = 前面板 HDD2，iso GPIO21（⚠ 与风扇 pwm_0 冲突，见 §7） */
		hdd2_led: hdd2-led {
			label = "hdd2:green:disk";
			gpios = <&iso_gpio 21 GPIO_ACTIVE_HIGH>;
			linux,default-trigger = "disk-activity";
			default-state = "off";
		};
	};
};
```

**A.3 预期结果：**
- 启动后 `ls /sys/class/leds/` 出现 `hdd1:green:disk`、`hdd2:green:disk`；
- `cat /sys/kernel/debug/gpio` 里出现第二颗 gpiochip（35 线），lines 26/21 被 `gpio-leds` 申请；
- `pinctrl` 的 `pinmux-pins` 中 pin 26 / pin 21 变成 `(MUX UNCLAIMED) gpio` 且 `gpio-leds` 持有；
- 空闲时两灯灭，`dd if=/dev/sda of=/dev/null bs=1M count=200` 时闪。

**A.4 如果 polarity 反了（测试结果为低电平点亮）：**
只把 `GPIO_ACTIVE_HIGH` 改成 `GPIO_ACTIVE_LOW`（两处），其余不动。

**A.5 如果只想先修 bay0（不碰风扇）：**
删掉 `hdd2-led` 节点即可，`hdd1:green:disk` 独立可用。

### 方案 B（退化/兼容）：`heartbeat` / `timer` / 常亮

若 `disk-activity` 触发器行为不理想（例如 fnOS 的块设备命名/major 变化、或用户想要“有盘就常亮”）：

| 需求 | `trigger` | 额外字段 |
|---|---|---|
| 空闲灭、读写闪（推荐） | `disk-activity` | 无 |
| 常亮 | `none`（或 `default-on`，内核已开 `DEFAULT_ON`） | `default: 1` |
| 慢闪表示“系统在跑” | `heartbeat` | `inverted: 0`（可选） |
| 固定节奏闪 | `timer` | `delayon: 500`, `delayoff: 500` |

**注意：`activity` / `netdev` 触发器本内核未编译（LEDS_TRIGGER_ACTIVITY/NETDEV 未开），
脚本写 trigger 会失败并 `return 1`，不要用。**

### 方案 C（可选，最接近原厂）：给 `ahci_rtk.c` 补 `blink-gpios` 支持

若希望“**每块盘各自的灯只在自己读写时闪**”（原厂 DS218 行为），需要在驱动里把
`blink-gpios` 解析成每 port 的 `gpiod`，并在 ATA 传输/队列活动时 toggle。
工作量：`drivers/ata/ahci_rtk.c` + 一处 `ata_port_operations` 钩子（或 `ledtrig` 自定义），
属于内核改动，**本报告不推荐第一版做**；`disk-activity` 已能满足“硬盘读写时灯闪”的用户感知。

### 方案 D（不推荐）：`system_setgpio.sh` 静态点亮

`board.json` 的 `.gpio[]` 可以把 iso 26 拉高常亮，但：
- 是**一次性**的（服务只在开机跑一次），无活动闪烁；
- 需要自己维护 GPIO 全局号（iso 域 base 由内核动态分配，重启可能变）；
- 与方案 A 相比没有任何优势。

---

## 6. 可直接落地的 `/boot/board.json`

`/boot` 是 rootfs 内目录（不是未挂载的 FAT p1），可直接写。**前置条件：方案 A 的 DT 已生效**，
否则以下 sysfs 名不存在，脚本会 Warning skip（但服务不再 failed）。

**6.1 方案 A 配套（推荐，HDD1+HDD2、disk-activity）：**

```json
{
  "led": [
    {
      "name": "hdd1-led",
      "sysfs": "hdd1:green:disk",
      "trigger": "disk-activity",
      "default": "1"
    },
    {
      "name": "hdd2-led",
      "sysfs": "hdd2:green:disk",
      "trigger": "disk-activity",
      "default": "1"
    }
  ],
  "gpio": []
}
```

**6.2 只修 bay0（不碰风扇）时：**

```json
{
  "led": [
    { "name": "hdd1-led", "sysfs": "hdd1:green:disk", "trigger": "disk-activity", "default": "1" }
  ],
  "gpio": []
}
```

**6.3 退化常亮（不依赖 disk 触发器）：**

```json
{
  "led": [
    { "name": "hdd1-led", "sysfs": "hdd1:green:disk", "trigger": "none", "brightness": 1, "default": "1" },
    { "name": "hdd2-led", "sysfs": "hdd2:green:disk", "trigger": "none", "brightness": 1, "default": "1" }
  ],
  "gpio": []
}
```

**6.4 写入与验证：**

```bash
# 板上执行（root）
cat > /boot/board.json <<'EOF'
{ ... 上面的 JSON ... }
EOF
systemctl restart led-set.service set_gpio-init.service
systemctl status led-set.service --no-pager
ls /sys/class/leds/
cat /sys/class/leds/hdd1:green:disk/trigger
```

注意：
- `default: "1"` 会让脚本先把 brightness 写成 `max_brightness`，再写 trigger；对 `gpio-leds` 合法。
- 加 `board.json` 后 `pwm-fancontrol.service` 也会读到它；该服务本来在找 `hwmon pwm1`（本板没有），
  可能仍失败/打日志，与本修复无关，**不要**为了它往 `board.json` 塞 `fan` 段。
- 未来 fnOS OTA 若重刷 `/boot`，`board.json` 会丢；DTS 的 `default-trigger` 是兜底，两者建议一起用。

---

## 7. 已知冲突与需要 lead/USER 决策的点

1. **iso GPIO 21 ↔ 风扇 PWM（pwm_0）抢脚（必须决策）**
   - 现状：`rtd1296-cm360.dts:919-947` 风扇 `pwm` 节点 `pwm_0 enable=1` + `pinctrl-0=<&pwm0_pins>`
     （`pwm0_pins` 把 **iso_gpio_21** 切成 `pwm_0`）；`:981-996` `fan` 节点 `pwms=<&pwm 0 0x93f6>`。
   - 事实：**风扇 PWM 从未被证实有效**（DTS 注释与历史记录均写“写 fan_ctrl_speed 后转速完全不变”），
     且厂商 DTB 里 `pwm_0 enable=0`、`rtk_fan status=disabled`（只 `pwm_3 enable=1`）。
   - 影响：若把 iso 21 给 LED，则风扇彻底失去 PWM 控制（是否本来就无效待确认）；
     若保留风扇，则 bay1 灯做不了。
   - 建议：**先确认风扇是否真的受 pwm0 控制**（或用户是否在意风扇转速），再决定：
     (a) 放弃 pwm0→iso21（把 `pwm` 节点的 `pinctrl-0` 去掉 / 或 `status="disabled"`，`fan` 节点视情况 disable）→ 两盘灯都能用；
     (b) 保留风扇 → 只修 bay0（26），bay1 暂缺。
   - 另一副作用：按 `pinmux.c:131`，即使不改 pwm 节点，`gpio-leds` 申请 iso21 时也会**静默覆盖 mux**
     把脚从 `pwm_0` 抢到 `gpio` —— 结果同样是风扇丢 PWM，但现场无报错，更隐蔽。**建议显式改，不要依赖覆盖。**
2. **bay 编号**（26 = HDD1 还是 HDD2）需实测确认（§8）。
3. **极性**（ACTIVE_HIGH/LOW）需实测确认（§8）。
4. **`gpio-ranges` 属于对 lead 文件的修改**：本报告只给片段，合并与编译由 lead 做（避免和 USB 工作冲突）。
5. **没有 `disk-activity` 之外的“每盘独立”能力**：若不接受两灯同时闪，需要方案 C（改驱动），
   工作量和回归风险高，建议先按方案 A 交付。

---

## 8. 最小风险板上写测试方案（**需 lead/USER 批准后执行**）

原则：一次只动一根线；每次恢复；优先用 `/sys/class/gpio` 手动 export（不依赖 gpio-leds 是否配对）；
先测 26（无人占用），21 等风扇决策后再测。

前置：刷入含 `iso_gpio`（+`gpio-ranges`）的 DTB 并重启，确认 `ls /sys/class/gpio/` 出现第二颗 iso gpiochip
（`/sys/class/gpio/gpiochipN/label` 形如 `...gpio@100`，`ngpio=35`；建议同时跑 `tools/led_probe.sh` 记录基线）。

**步骤 1（只读）**：`tools/led_probe.sh`，确认：
- iso gpiochip base/ngpio；`/sys/kernel/debug/gpio` 里 iso 26/21 未被占用；
- `pinmux-pins` 里 pin26 mux、pin21 被 pwm 占用；
- `0x98007100` 处 DIR 的 bit21/bit26 当前值。

**步骤 2（写 1 次，测试 bay0/iso26）**：

```bash
BASE=$(cat /sys/class/gpio/gpiochip*/base | ... 选 iso 那颗)   # 或用 gpioinfo 确认
GPIO=$((BASE+26))
echo $GPIO > /sys/class/gpio/export
echo out > /sys/class/gpio/gpio$GPIO/direction
echo 1   > /sys/class/gpio/gpio$GPIO/value    # ← 问用户：前面板某个 HDD 灯亮了吗？
sleep 2
echo 0   > /sys/class/gpio/gpio$GPIO/value    # ← 问用户：灭了吗？
echo in  > /sys/class/gpio/gpio$GPIO/direction
echo $GPIO > /sys/class/gpio/unexport
```

- `value=1 亮` ⇒ ACTIVE_HIGH；`value=0 亮` ⇒ ACTIVE_LOW。
- 记录“亮的是第几个盘位的灯” → 确定 bay 编号；若 26 不亮，则试 21（需先接受风扇风险）。

**步骤 3（写 1 次，测试 iso21）**——仅在 lead 批准“风扇可放弃 pwm0”后：
同步骤 2，pin=21。注意该脚当前 mux 为 `pwm_0`，`export`+`direction=out` 会把 mux 抢到 gpio
（`gpio_request_enable` 覆盖），风扇 PWM 会从此刻失效，unexport 后也不会自动还原 mux；
恢复方式：`echo 0 > export` 后重启，或手动触发 `pwm` 驱动重新 apply（不保证）。**风险：中**（仅风扇）。

**步骤 4（正式方案 A）**：极性/bay 确认后，改 DTS（`GPIO_ACTIVE_*` 与 `hdd1/hdd2` 对调），
刷 DTB → 验证 `ls /sys/class/leds`、空闲灭、`dd` 时闪。

**步骤 5（board.json）**：写 §6.1，`systemctl restart led-set set_gpio-init`，确认两服务 active。

**回滚**：每步结束 `direction=in` + `unexport`；若 LED 常亮不灭，断电重启即可恢复（GPIO 默认输入高阻）。

**风险评估**：iso 26/21 在厂商固件里被声明为 **LED 输出**（`blink-gpios` + `gpio-output-change-list`），
不是电源/使能脚；单次 3.3V 推挽输出到 LED 电路，**风险低**。仍禁止批量/盲扫其它 iso 引脚
（1/31/32 USB VBUS、33 电源键、34 PCIe 等）。

---

## 9. `tools/led_probe.sh` 用法

配套脚本：`tools/led_probe.sh`（**只读**，不 export、不写 devmem、不改 sysfs）。

```bash
# 本地仓库 → 板子
MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' python tools/brd.py push tools/led_probe.sh /tmp/led_probe.sh
export PYTHONIOENCODING=utf-8
python tools/brd.py sudo 'bash /tmp/led_probe.sh' | tee evidence/logs/led-probe-$(date +%Y%m%d-%H%M%S).log
```

脚本输出分 8 段：基本环境 / LED class 与 gpiochip 列表 / debugfs gpio / pinctrl（pins/functions/pinmux-pins/
pinconf）/ 候选 pin 的 mux 与 claim / `0x98007100` GPIO 寄存器（DIR/DATO/DATI 的 bit21/26 解码）/
`0x98007000` 中断块与 pwm 寄存器只读快照 / dmesg 与 board.json、服务状态摘要。
**它不产生任何副作用**，可反复跑。

---

## 10. 参考（文件/行号一览）

| 引用 | 位置 |
|---|---|
| 厂商 DTB SATA `blink-gpios` | `boards/rtd1296-cm360/vendor-firmware/ds218-cm360-1020.dts:1987`（另 `:1988` 于 1022 版） |
| 厂商 DTB `power-management` 输出翻转 | 同上 `:2244-2255`（1022 版 `:2247`） |
| 厂商 DTB `rtk_iso_gpio@98007100`（phandle 0x48） | 同上 `:1855-1867` |
| 厂商 DTB `rtk_misc_gpio@9801b100` | 同上 `:1838-1853` |
| 厂商 DTB pwm（pwm_0..3 enable/duty） | 同上 `:2190-2225` |
| 厂商 DTB fan / wakeup-gpio（iso33） | 同上 `:2227-2237`、`:2249` |
| 仓库 DTS `iso_gpio`（lead 新增，未提交） | `boards/rtd1296-cm360/rtd1296-cm360.dts:363-379` |
| 仓库 DTS `misc_irq_mux`/`misc_gpio` | 同上 `:448-469` |
| 仓库 DTS SATA 两盘供电（misc56/19） | 同上 `:862-898` |
| 仓库 DTS pwm + `pwm0_pins`(iso21) | 同上 `:919-947`、`:954-962` |
| 仓库 DTS fan（pwm ch0） | 同上 `:981-996` |
| “blink-gpios 是盘位指示灯” | `docs/02-kernel-and-dts.md:112-126` |
| 旧结论“无系统灯节点”（需更正） | `docs/reports/cm360-peripheral-gold-coordinates.md:350-378`（§7） |
| board.json 三服务依赖 | `docs/05-storage-and-fnos.md:82,106-122` |
| 内核配置（LED/GPIO/pinctrl） | `artifacts/kernel-6.6.54/kernel.config:4069,4148,4153,4186,7322,7344,7354,7390-7406` |
| 6.6 `gpio-rtd.c` probe/iso info | `XpressReal/linux@be79582cb:drivers/gpio/gpio-rtd.c:161-176,528-590` |
| 6.6 `pinctrl-rtd.c` gpio_request_enable | 同上 `drivers/pinctrl/realtek/pinctrl-rtd.c:362-374` |
| 6.6 `pinctrl-rtd1295.h` pin21/26 mux | 同上 `drivers/pinctrl/realtek/pinctrl-rtd1295.h:78,83,121,126,196,201,232-234,252,263` |
| 6.6 `pinctrl/core.c` range/request 语义 | 同上 `drivers/pinctrl/core.c:286-340,792-817` |
| 6.6 `pinmux.c` owner 覆盖语义 | 同上 `drivers/pinctrl/pinmux.c:111-190,265-282` |
| 6.6 `ahci_rtk.c` 仅 `sata-gpios` | 同上 `drivers/ata/ahci_rtk.c:178,243,297` |
| 外部：CM360 刷 DSM 教程（无单片机灯） | <https://post.smzdm.com/p/a20pn2r2/> |
| 外部：矿神修复脚本（关 DSM LED 支持） | <http://code.imnks.com/cm360/cm360-bug.sh>（1769 B，已解析） |

---

## 11. 未确定点（TODO）

1. iso 26/21 的实际电气电平/极性（等 §8 写测试）。
2. bay0(26)/bay1(21) 与前面板 HDD1/HDD2 丝印的对应关系（写测试时让用户报“哪个灯亮”）。
3. 风扇是否真的由 `pwm_0`/iso21 控制（决定方案 A 能否两盘全上，见 §7.1）。
4. 运行版 DTB 需重新编译/刷入后，`iso_gpio` 的段序/中断是否如 repo DTS 预期工作
   （`usb_manager` 也在用 iso 1/31/32，可与 lead 的 USB 验证合并进行）。
5. 若要做“每盘独立闪烁”，需要方案 C 的驱动改动，另行评估。
