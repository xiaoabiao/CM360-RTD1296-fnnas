# CM360（RTD1296）→ fnOS 移植：可行性与下一步方案

**日期**：2026-10-05
**结论先行**：**可以开始移植了**。硬件 bring-up 已全线打通（含 SMP），
剩下的不是"能不能跑起来"，而是"把这套内核做成能装 fnOS 的发行形态"。

---

## 一、硬件 bring-up 完成度（实测）

| 子系统 | 状态 | 证据 |
|---|---|---|
| 串口 / 内存 / GIC / 时钟 | ✅ | 早已通过 |
| **SMP 四核** | ✅ | `Brought up 1 node, 4 CPUs`；`online=0-3`、`nproc=4` |
| **SATA（12TB）** | ✅ | `ata1: SATA link up 6.0 Gbps`、`sda` 23437770752 扇区 |
| **eMMC（HS200）** | ✅ | `mmcblk0` 7.28 GiB、HS200、健康度全新 |
| **eth0（原生 GMAC）** | ✅ | ping 0% 丢包、31.5MB 传输 md5 一致 |
| SDMMC / SDIO | ⬜ | 驱动已在（`MMC_RTK_SDMMC=y`），**只缺 DTS 节点** |
| USB3 | ⬜ | 驱动已在（`USB_DWC3_RTK=y`），**只缺 DTS 节点 + PHY 时序** |
| PCIe | ⬜ | 非必需（SATA 已原生通） |
| VPU 转码 | ⬜ | 可选，且是 fnOS 之外的加分项 |

**关键点：SDMMC/USB 不是"缺驱动"，是"缺 DTS 节点"。** 这是低成本项
（见第三节，已有现成模板）。

---

## 二、对照原路线图：进度远超预期

原盘点报告（`RTD1296-主线驱动现状盘点.md`）的路线图基于 **6.12/6.18 主线**，
且当时预估需移植 ~39,037 行。实际我们走了 **XpressReal 6.6.54 vendor 树**这条
"驱动全、DTS 空"的捷径，把工作量压掉了绝大部分：

| 原路线图阶段 | 原预估 | 实际 |
|---|---|---|
| 阶段 1 最小启动 | 需自补 5 处 DTS + booti | ✅ 完成 |
| 阶段 2 时钟移植 | **最难**，~1,650 行 | ✅ **已通**（CCF 正常，eMMC 分频算得出） |
| 阶段 3 USB3 + 网络 | 需移植 dwc3/phy | ✅ 网络已通（**原生 GMAC**，比 USB 网卡更好） |
| 阶段 4 PCIe + SATA | 需移植 pcie 驱动 | ✅ **原生双 SATA 直接通了**（不用 PCIe 转接） |
| 阶段 5 eMMC 启动 | ~10,828 行 | ✅ **eMMC 已通**（直接放 rtkemmc.c） |

**换句话说：原报告认为最难的时钟、最长的工作量（eMMC）、最不确定的 PCIe，
现在都已不是问题。**

---

## 三、可以立即启动的三件事（按性价比排序）

### A. 补 SDMMC / SDIO / USB DTS 节点（低风险，1~2 轮上板）

现成模板有两份：
1. **同 SoC 参考**：`~/.cache/rtd1296/jjm2473-emmc/arch_arm64_boot_dts_realtek_rtd1296-saola.dts`
   （RTD1296 板，含 `&sdmmc`/`&sdio`/`&pcie1,2`/`&sata0,1`/`&emmc`/`&i2c_0` 全节点）
2. **同树模板**：`arch/arm64/boot/dts/realtek/rtd13xx-usb.dtsi`（USB 结构）

节点定义（`compatible` / `reg` / `clocks` / `pinctrl`）在 jjm2473 的
`arch_arm64_boot_dts_realtek_rtd129x.dtsi` 里是**完整的**，我们的 6.6 树 dtsi 里没有
—— 需要把节点定义搬过来 + 加板级参数。

⚠️ **已从原厂 DTB 取到关键参数**（`stage0/original-dtb.dts.txt:1788`）：

```dts
sdmmc@98010400 {
    compatible = "Realtek,rtk1295-sdmmc";
    gpios = <0x36 0x63 0x01 0x00>;      /* phandle=54(gpio) 99 脚 GPIO_ACTIVE_HIGH */
    reg = <0x98000000 0x400>, <0x98010400 0x200>, <0x9801a000 0x400>,
          <0x98012000 0xa00>, <0x98010a00 0x40>;
    interrupts = <0x0 0x2c 0x4>;        /* SPI 44 */
};
```

- **卡检测脚 = 99**（`0x63`），`GPIO_ACTIVE_HIGH`。
  巧的是 **saola 参考板用的也是 99** —— 说明 99 是 RTD1296 的通用 SD 卡检测脚，
  两板可直接复用（不必再逐板确认）。
- pinctrl 组名：`sdcard_low`（`mmc_data_3..0`/`mmc_clk`/`mmc_cmd`）+ `sdcard_high`（`mmc_cd`/`mmc_wp`），
  function = `"sd_card"`。**注意原厂是拆成 low/high 两组**（对应不同 pull 配置），
  这与 jjm2473 dtsi 里 `sdmmc_pins`/`sdmmc_down_pins`/`sdmmc_clk_pin` 的拆法不同，
  移植时以**我们的 6.6 树 pinctrl 驱动实际支持的组名**为准（先 grep 再写）。
- SDIO：`sdio@98010a00`，`compatible = "Realtek,rtk1295-sdio"`，SPI 45。

⚠️ **另注意寄存器段序**：原厂 `sdmmc` 是**五段 reg**（`0x98000000` 在前），
而 eMMC 是四段。段序在 RTD129x 上有历史包袱（我们已在 SATA 的 `misc_gpio` 上踩过
——vendor `of_iomap(node,0)` 取的是**中断**段）。移植时必须核对目标驱动
`of_iomap/resource` 的**实际序号语义**，不能照搬原厂顺序。

### B. 做 fnOS 安装介质的适配（核心工作量所在）

fnOS ARM 侧的真实约束（已核对内核 config）：

| 需求 | 当前 | 动作 |
|---|---|---|
| btrfs | `CONFIG_BTRFS_FS=m` | ✅ 有，但**是模块** → 必须进 initramfs，否则装不上根 |
| POSIX ACL | `FS_POSIX_ACL=y` + `BTRFS_FS_POSIX_ACL=y` | ✅ |
| fanotify（FilesACL） | `CONFIG_FANOTIFY=y` + `FANOTIFY_ACCESS_PERMISSIONS=y` | ✅ |
| overlayfs（Docker） | `CONFIG_OVERLAY_FS=m` | ✅ 需进 initramfs |
| user namespace | `CONFIG_USER_NS=y` | ✅ |
| initramfs | `CONFIG_BLK_DEV_INITRD=y` | ✅ |
| ext4 | `CONFIG_EXT4_FS=y` | ✅ |

**要做的**：
1. 把 `BTRFS_FS` / `OVERLAY_FS` 由 `=m` 改成 `=y`（或确保进 initramfs），
   避免"根文件系统挂不上"这类启动期死锁。
2. 做 **CM360 专用 initramfs**：至少含 btrfs / overlay / 存储驱动 / udev，
   负责找到 eMMC 或 SATA 上的 fnOS 根分区。
3. 按 **ophub 的 `renas` 打包格式**做自定义镜像（原报告已指明这条路），
   替换其中的内核 + dtb 为我们的产物。

### C. 决定引导与落盘策略（有变砖风险，必须先想清楚）

**硬约束（来自原报告实测）**：
- SPI NOR 只有 **8 MB**，已被原厂四个镜像占 **90.6%**（含盲区 99.2%），
  剩余 68 KB ~ 772 KB → **绝对不能写 SPI**。
- u-boot 的 `bootcmd` 走 Realtek 私有 `rtkspi + lzmadec + go all`，
  但 **`booti` 可用**（Realtek 自己 backport 了），所以走 TFTP/介质引导没问题。

**因此推荐路线**：
```
阶段 1（现在）：TFTP 引导 —— 已在用，零风险
阶段 2：把系统装进 eMMC（8 GB 够放 fnOS 系统盘）—— 用我们的 rtkemmc
阶段 3：u-boot 改为从 eMMC 引导（需要改 SPI 里的 u-boot 环境或镜像）
        ⚠️ 到这一步才需要动 SPI，且必须先完整备份 SPI
```

**`saveenv` 禁令**：在原厂 u-boot 里执行 `saveenv` 会写 SPI 环境区，
在空间只剩 ~68KB 的前提下有变砖风险 → **全程只用 RAM 内环境变量，不 saveenv**。

---

## 四、建议的执行顺序

```
① 补 SDMMC / USB DTS 节点           ← 低风险，立刻可做
   └─ 原厂 DTB 取卡检测脚号，别照抄 saola
② 内核 config 调整（btrfs/overlay 改 y）
③ 做 CM360 initramfs（含 btrfs 支持）
④ 试装 fnOS rootfs 到 eMMC（TFTP 引导 + eMMC root）
   └─ 验收：能进 fnOS 面板
⑤ 最后才动 SPI 引导（先完整备份 SPI）
```

**① 和 ② 可以现在就开始**，都不涉及 SPI、不涉及破坏性写操作。

---

## 五、待确认（阻塞 ③ 之后的步骤）

1. **fnOS ARM 安装包/rootfs 从哪来？** 本地工作区当前**没有**任何 fnOS 素材
   （已搜过 `*.img` / `*.iso` / `fnos*`）。需要用户提供 fnOS ARM 版镜像或
   ophub 的构建产物。
2. **fnOS 对内核版本的硬性要求**：原报告写"要求 6.12.y / 6.18.y + FilesACL 补丁"。
   我们是 **6.6.54** —— 需要确认 fnOS 是否允许 6.6，或接受打补丁后的 6.6。
   这是**唯一的重大未知项**。
3. CM360 SD 卡槽的卡检测 / 写保护脚号（从原厂 DTB 取）。
