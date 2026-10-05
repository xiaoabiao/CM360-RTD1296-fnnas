# 变更记录

本项目按"阶段"推进，每个阶段都有对应的实测证据留在 `evidence/`。
格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)。

---

## [未发布]

### 待办

- **风扇 / LED 板级支持**：为本板编写 `board.json` + 内核开 `CONFIG_GPIO_SYSFS`。
  `pwm-fancontrol` 目前静默退出，**风扇未受控**（`sda` 实测 49 °C）。
- **ZFS 型存储空间**：为 6.6.54 交叉编译 OpenZFS 2.4.1 模块
  （板上用户态即 2.4.1，fnOS 把它作为独立模块发布）。
- SDMMC / SDIO、USB3：驱动已在 `.config`，缺 DTS 节点（USB3 还需 PHY 时序）。
- 清理与移植无关的 fnOS 服务（`nut-*` / `exim4` / `wsdd2` / `trim_raid_check`）。

---

## [0.3.0] — 2026-10-05 · 存储与服务可用

### 修复

- **第二块硬盘不被识别**：`ata2: SATA link down` → 第二个盘位没上电。
  给 `sata-port@1` 补 `sata-gpios`（引脚号取原厂 DTB 的 `misc_gpio 19`，
  而非官方参考 dtsi 的 `iso_gpio 15`）。
- **fnOS 创建存储空间失败**：内核缺 mdraid personality
  （`md: personality for level 1 is not loaded!`）。
  补 `MD_RAID0/1/10`、`MD_LINEAR`、`DM_THIN_PROVISIONING/SNAPSHOT/RAID/CRYPT`、
  `QFMT_V1/V2`、全套 dm-crypt 相关 crypto。
  修后：双盘 RAID1 → LVM → ext4，挂 `/vol1`。
- **`ovs-vswitchd` / `ovsdb-server` 失败**：缺 `CONFIG_OPENVSWITCH`。
- **`zramswap` 失败、无 swap**：缺 `CRYPTO_LZ4`（zram0 只提供 lzo/zstd）。
  修后 941 MB swap。
- **`docker` 每次开机必挂**：fnOS 自带 `ExecStop` 在无容器时报错 +
  `dockerd` 关闭时 `docker stop` 会挂住。用 systemd drop-in 覆盖（不改原单元）。
- **`modprobe` 对内置模块一律失败**：全内置内核没有模块目录。
  新增 `scripts/deploy-modmeta.sh`（拷元数据 + **板上 depmod**）。

### 新增

- `boards/rtd1296-cm360/files/docker-override.conf`
- `scripts/queue` 中的 `deploy-modmeta.sh`

---

## [0.2.0] — 2026-10-05 · 救砖 + 独立启动 + reboot

### 新增

- **ROM Monitor 救砖全流程**（`tools/recovery/`）：稀疏 Ctrl+Q（33 B/s）
  + YMODEM + 长度/CRC 校验。实测一次成功，把板子从"卡 FSBL"救回。
- **eMMC 独立启动**：u-boot 换成 BPI-W2 的，`bootcmd`/`bootargs` 已 `saveenv`。
- `patches/0004-wdt-restart.patch`：修 `reboot` 挂死。

### 关键发现（都是实测/反汇编所得）

- **Ctrl+Q 必须稀疏**：33 B/s 成功、4000 B/s 洪流失败。
  ROM 轮询前会清 RX FIFO，且要求 **≥3 个连续 `0x11`**。
- **串口必须真独占**：第二个读者会偷走板子的应答 ——
  上一轮 YMODEM "全废"的真因是手动开的 `screen` 与脚本同抢 tty，
  与洪流是**两个独立原因**（早期复盘把它们混为一谈，已更正）。
- **`reboot` 挂死的根因是"一个 restart handler 都没有"**：
  PSCI / rtk-rstctrl / 看门狗回调三者皆无。

### 证据

`evidence/logs/phoenix2-*.log`（进 monitor 与传输全过程）、
`evidence/logs/mon-g-*.log`（烧写）、`evidence/logs/bootcap-*.log`（恢复后干净启动）。

---

## [0.1.0] — 2026-10-04 · 板子点亮

### 新增

- Linux 6.6.54 在这块板上跑起来：串口 / GIC / 时钟 / eMMC(HS200) / SATA / GMAC。
- **SMP 四核**（`patches/0003`）：从核释放寄存器必须 `ioremap` + 32 位写。
- 板级 DTS 从上游极简骨架写到可用（节点注释含证据来源）。
- `evidence/reports/` 里的阶段性技术报告。
