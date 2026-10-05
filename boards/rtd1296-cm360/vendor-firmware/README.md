# 原厂固件（RTD1296 / CM360，与 DS218 同款板）

这批文件是**用户提供的原厂固件包**（`cm360(1)/`），是本项目最重要的"外部权威资料"：
本板所有"驱动要什么属性、寄存器在哪、引脚怎么复用"的答案，都是从这里取的。
有了它，风扇 / 温度 / SD / USB3 这些节点才有可能写对。

## 文件清单

| 文件 | 是什么 | 本项目怎么用 |
|---|---|---|
| `ds218-cm360-1020.dtb` | **原厂完整设备树（权威）** | 主要依据：外设节点、寄存器、pinctrl 群组全在里面 |
| `死机专用ds218-cm360-1022.dtb` | 原厂另一份 DTB 变体 | 交叉对照（差异极小） |
| `2.4rtd129x_syno_dtb.bin` | 原厂 DTB（2.4 版，Synology 命名） | 交叉对照 |
| `hw_setting.bin` | ROM 在 eMMC `blk#0x100` 读的 hwsetting（3200 字节） | 2026-10-05 事故复盘里"hwsetting 到底存了什么"的答案 |
| `fsbl.bin` | FSBL（第二级引导） | 救砖参考；本项目走 ROM Monitor + 自编内核，未直接使用 |
| `bl31.bin` | ARM Trusted Firmware (BL31) | 同上 |
| `tee.bin` | OP-TEE (BL32) | 同上 |
| `uboot.bin` | 原厂 u-boot | 同上（板上现用 BPI-W2 的 u-boot，见 `tools/uboot/`） |

## 从 `ds218-cm360-1020.dtb` 里取到的关键信息（正文已落地）

- **风扇**：`pwm@980070D0`（`Realtek,rtd1295-pwm`，4 通道）、
  `rtk_fan@9801BC00`（`Realtek,rtd129x-fan`，`pwms = <&pwm 0 0x93f6>`，GIC SPI 29 测速）、
  pinctrl 群组 `pwm0_0` = `iso_gpio_21`、测速输入 `dc_fan_sensor` = `gpio_9`
  （注意：原厂把它写成 `status = "disabled"`）
- **温度**：`thermal@0x9801D100`（`Realtek,rtd1295-thermal`，`reg = <0x9801d100 0x70>`）
- **SD / SDIO**：`sdmmc@98010400`（`gpio 0x63`）、`sdio@98010A00`
- **USB**：`ehci@98013000` / `ohci@98013400`、`rtk_dwc3_drd@98013200`、
  `rtk_dwc3_u2host`、`rtk_dwc3_u3host@98013E00` + USB2/USB3 PHY 寄存器
- **SATA**：`sata@9803F000`，两个盘位的供电脚 `misc_gpio 56 / 19`
  （本项目已实测生效：两块盘都能上电识别）
- **以太网**：`gmac@98016000` 的 `led-cfg = <0x00002070>`（这是网口灯，不是系统灯）

## 复原方式

把这批文件放回板子对应位置（**危险操作，先读 `docs/04-recovery.md`**）：
`fsbl/bl31/tee/uboot` 属于启动链（eMMC 低区），`hw_setting.bin` 对应 `blk#0x100`；
`ds218-cm360-1020.dtb` 可直接当内核 DTB 用（但本项目用的是自己的
`boards/rtd1296-cm360/rtd1296-cm360.dts`，已按本板实测改过）。
