# boards/rtd1296-cm360 —— 小睿 CM360（RTD1296）

这块板的全部板级专属内容。换板子时照着这个目录整体替换即可。

```
rtd1296-cm360/
├── rtd1296-cm360.dts        板级设备树（★ 本项目核心产出）
├── board-scripts/           在**板子上**执行的脚本（eMMC 分区/根迁移等）
├── files/                   要拷进板子 rootfs 的板级文件（systemd drop-in 等）
├── uboot-cmds/              u-boot 脚本（用 source 命令跑）
├── legacy/                 早期版本的 DTS（保留作对照）
└── tools/                  板子专用小工具
```

## 板子事实

| 项 | 值 |
|---|---|
| SoC / 内存 | RTD1296 / 2 GiB DDR4 |
| eMMC | Samsung 8GTF4 7.28 GiB（HS200 8-bit） |
| SATA | 2 端口；**两盘位分别供电**（`misc_gpio` 56 / 19） |
| SPI NOR | S25FL064K_4s 8 MiB |
| 串口 | UART0 115200 8N1 |
| 原厂机型标识 | `syno_hw_version=DS218` |

## 板级要点（写 DTS 时最容易踩的）

1. **`hwsetting` 在 eMMC `blk# 0x100`**（偏移 128 KiB），分区表之外。
   ★ 写闪存前先 dump 前 16 MiB；**绝不要往低区写任何自造数据**。
2. **SATA 两个盘位分别供电**，每个 `sata-port@N` 都要 `sata-gpios`，否则盘不转。
   引脚号以**原厂 DTB** 为准（`misc_gpio 56` / `misc_gpio 19`），
   官方参考 dtsi 的 `iso_gpio 15` 与本板不同 —— 判据见
   [`docs/02-kernel-and-dts.md`](../../docs/02-kernel-and-dts.md)。
3. **CPU 用 `spin-table`**（非 PSCI），且 `cpu-release-addr` 是**硬件寄存器**不是内存，
   必须用 `ioremap` + 32 位写（见 `patches/0003`）。
4. **`reboot` 需要自己提供 restart handler**（见 `patches/0004`）。
5. **原厂 DTB 是"圣旨"**：反编译文本在
   `evidence/stage0/original-dtb.dts.txt`，缺的属性表示"用驱动默认值"。

## 板上脚本（`board-scripts/`）

| 脚本 | 作用 | 风险 |
|---|---|---|
| `emmc-part.sh` | eMMC 分区 + 写引导分区 | ⚠️ 会写闪存低区，先读事故复盘 |
| `emmc-root.sh` | `btrfs send/receive` 迁移运行中的根到 eMMC | 中 |
| `emmc-root-finish.sh` | 补做 set-default / 清理 / 验证（幂等） | 低 |
| `emmc-root-fixro.sh` | 修"收到只读子卷导致整根只读" | 低 |

## 拷进 rootfs 的文件（`files/`）

| 文件 | 目标位置 | 作用 |
|---|---|---|
| `docker-override.conf` | `/etc/systemd/system/docker.service.d/override.conf` | 修 fnOS 自带 ExecStop 导致 docker 开机必挂 |
