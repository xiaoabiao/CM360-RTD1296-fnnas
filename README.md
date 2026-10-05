# rtd1296-fnnos

**CM360（Realtek RTD1296）上的 Linux 6.6 + 飞牛 fnOS 板级支持**

把一台小睿 CM360 NAS 盒子（4×Cortex-A53 / 2 GiB DDR4 / 8 GiB eMMC / 双 SATA / 千兆网口）
从原厂 QNAP 固件换成 **Linux 6.6.54 + fnOS**，并把这个过程固化成可复现的板级支持包：
**板级 DTS + 内核补丁 + 内核配置叠加 + 部署/救砖工具链**。

本仓库不含内核源码（`scripts/setup-deps.sh` 按锁定 commit 拉取），
只放"这块板子需要什么"——每一条改动都有实测证据和失败症状记录。

```
./scripts/setup-deps.sh      # 拉内核树（锁定 commit）+ 打补丁
./scripts/build-kernel.sh    # 编内核 + 板级 DTB
./scripts/deploy-modmeta.sh  # 装模块元数据到板子（换内核后必做）
```

---

## 状态

| 子系统 | 状态 | 关键证据 |
|---|---|---|
| 串口 / 内存 / GIC / 时钟 | ✅ | |
| SMP 四核 | ✅ | `smp: Brought up 1 node, 4 CPUs`、`nproc=4` |
| SATA 双盘（6 Gbps） | ✅ | `ata1`/`ata2` 均 `SATA link up 6.0 Gbps` |
| eMMC（HS200） | ✅ | `mmcblk0` 7.28 GiB、HS200 |
| eth0（原生 GMAC） | ✅ | 0% 丢包、31.5 MB 传输 md5 一致 |
| **eMMC 独立启动** | ✅ | u-boot 从 eMMC 取内核/根，不依赖 TFTP / SATA |
| **fnOS 运行** | ✅ | `fnOS v1.1.31`，SSH / Web UI 在线 |
| `reboot` | ✅ | 内核补 restart 回调 + DTS 开看门狗，实测可自动复位 |
| 存储空间（mdraid+LVM） | ✅ | 双盘 RAID1 → LVM → ext4，挂 `/vol1` |
| docker / OVS / zram swap / SMART | ✅ | 见 `docs/05-storage-and-fnos.md` |
| ZFS 型存储空间 | ⬜ | 需为 6.6.54 交叉编译 OpenZFS 模块 |
| 风扇 / LED 板级控制 | ⬜ | 缺厂商板级描述文件；**风扇目前未受控** |
| SDMMC / SDIO、USB3 | ⬜ | 驱动已就绪，缺 DTS 节点 |

---

## 硬件

| 项 | 值 |
|---|---|
| SoC | Realtek RTD1296（4× Cortex-A53，2 GiB DDR4） |
| 存储 | 8 GiB eMMC（Samsung 8GTF4，HS200）+ 2× SATA |
| 网络 | 内嵌 GPHY 千兆 |
| 引导 | eMMC 低区（hwsetting + bootcode/FSBL/BL31）+ SPI NOR 8 MiB |
| 串口 | UART0 @ 115200 8N1（需 USB-TTL，CH340 即可） |

> ⚠️ **动闪存前必读**：RTD1296 把 `hwsetting`（DRAM/eMMC 启动配置）放在 eMMC
> **`blk# 0x100`（偏移 128 KiB）**，分区表之外 ≠ 空的。
> 本项目曾因清空 eMMC 前 1 MiB 把板子打成砖 —— 完整事故与救回记录见
> **`docs/incident-2026-10-05-emmc-recovery.md`**。

---

## 快速开始

### 0. 依赖

```bash
# Debian / Ubuntu
sudo apt install build-essential git flex bison bc libssl-dev \
                 gcc-aarch64-linux-gnu
# Fedora
sudo dnf install @development-tools git flex bison bc openssl-devel \
                 gcc-aarch64-linux-gnu
```

本机差异（内核树位置、工具链前缀、串口设备）写在仓库根的 `local.conf`
（模板 `local.conf.example`，该文件不入库）。**不用改任何源码**。

### 1. 构建

```bash
./scripts/setup-deps.sh            # 首次：拉内核树 + 打补丁
./scripts/build-kernel.sh          # 编内核 + DTB → build/
make help                          # 或者用 Makefile 目标
```

产物：`build/Image-6.6`（内核）、`build/rtd1296-cm360.dtb`（板级设备树）。

### 2. 装到板子

见 **`docs/03-build-and-install.md`**（eMMC 安装 / 更新内核 / 从零刷机的完整步骤）。

### 3. 板砖了？

见 **`docs/04-recovery.md`** —— SoC 的 ROM Monitor（Ctrl+Q）恢复流程，
本项目实测走通过，**不需要编程器**。

---

## 仓库结构

```
├── boards/<board>/         板级文件：DTS、板上执行脚本、拷进 rootfs 的文件
├── patches/                内核补丁（每个补丁对应一个实测问题）
├── scripts/                主机侧流水线：拉依赖 → 构建 → 部署 → 验证
│   ├── lib/env.sh          统一环境（路径全部可配置）
│   └── verify/             上板体检脚本
├── tools/                  交互与诊断工具
│   ├── brd-ssh.sh          上板 SSH 助手（run / sudo / put / get）
│   ├── serial/             串口采集与嗅探
│   ├── recovery/           ROM Monitor 救砖（稀疏 Ctrl+Q + YMODEM）
│   ├── uboot/              u-boot 命令行交互
│   └── upgrade/            fnOS 整块换 rootfs（复制 / 适配 / 预检 / 切换回滚）
├── artifacts/              可直接落盘的构建产物（内核/DTB/.config/ZFS 模块，可恢复用）
├── docs/                   文档（先看 01 → 03；出事看 04/06）
├── evidence/               实测证据：原始串口日志、启动日志、构建记录
└── build/                  构建产物（gitignore）
```

---

## 文档

| 文档 | 内容 |
|---|---|
| [`docs/01-hardware-and-boot.md`](docs/01-hardware-and-boot.md) | 硬件、启动链、串口、原厂固件结构 |
| [`docs/02-kernel-and-dts.md`](docs/02-kernel-and-dts.md) | 内核树选型、补丁清单、配置叠加（含"不配的后果"） |
| [`docs/03-build-and-install.md`](docs/03-build-and-install.md) | 构建、安装到 eMMC、更新内核、验证 |
| [`docs/04-recovery.md`](docs/04-recovery.md) | **救砖**：ROM Monitor 进不去/进得去的完整流程 |
| [`docs/05-storage-and-fnos.md`](docs/05-storage-and-fnos.md) | 存储空间创建、fnOS 服务适配、已知缺口 |
| [`docs/06-troubleshooting.md`](docs/06-troubleshooting.md) | 故障排查速查（症状 → 根因 → 修法） |
| [`docs/07-fnos-upgrade.md`](docs/07-fnos-upgrade.md) | **fnOS 升级**：整块替换 rootfs 子卷（含回滚与救砖） |
| [`docs/incident-2026-10-05-emmc-recovery.md`](docs/incident-2026-10-05-emmc-recovery.md) | 事故复盘：变砖与救回全过程 |
| [`docs/reports/`](docs/reports/) | 各阶段技术报告（可行性评估、外设摸底、驱动盘点…） |

---

## 几个值得单独说的结论

这些是踩过的坑里最"反直觉"的几个，每条都有实测证据（详见对应文档）：

1. **`cpu-release-addr` 在这颗 SoC 上不是内存，是硬件寄存器。**
   主线 `smp_spin_table.c` 按规范用 8 字节缓存写 → 打到设备寄存器 → **总线挂死、零报错**。
   → `patches/0003-smp-rtk-spin-table.patch`

2. **原厂 DTB 里"缺失的属性"是语义，不是遗漏。** 它表示"用驱动默认值"，
   而默认值往往就是这台机器的正确硬件模式。我们"好心补上"一个属性曾经导致网口 RX 恒 0。

3. **`modprobe` 失败 ≠ 模块缺失。** 全内置内核没有 `/lib/modules/<版本>/`，
   于是 `modprobe zram` 这种判断可用性的脚本必然失败。
   只拷 `modules.builtin` 文本还不够 —— kmod 只认 `.bin` 索引，**必须在板上跑 `depmod`**。
   → `scripts/deploy-modmeta.sh`

4. **`reboot` 挂死的根因是"一个 restart handler 都没有"**，不是内核坏了。
   arm64 会走 `pr_emerg("Reboot failed -- System halted")` + 死循环。
   这块板子上 PSCI / rtk-rstctrl / 看门狗回调**三者皆无** → 只能自己补。
   → `patches/0004-wdt-restart.patch`

5. **串口必须真独占。** Linux 允许多进程打开同一 tty，但**每个字节只投递给一个读者**；
   第二个读者（哪怕是手动开的 `screen`）会**偷走板子的应答**，
   症状是"发送端一直收不到 ACK"，极易误判成协议或速率问题。

---

## 交流群
<img width="700" height="900" alt="357ee3153b5a5f72c8b16e9b9f9d008a" src="https://github.com/user-attachments/assets/644433a0-0d62-44db-9963-93a84c616131" />

---
## 如果您觉得项目对您有帮助，麻烦打赏一点AI Token费用，最近面临失业已经付不起AI使用费
<img width="600" height="800" alt="二合一收款码_1791190303167" src="https://github.com/user-attachments/assets/d25f97e8-51ea-41d5-9715-3da3d20b2d59" />

---

## 许可

GPL-2.0-only。内核补丁源自 Linux 内核（GPL-2.0），本仓库其余部分同许可。
第三方文档引用在 `docs/reports/` 中注明来源。
