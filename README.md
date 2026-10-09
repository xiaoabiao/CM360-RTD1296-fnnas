# CM360 → Linux 6.6 + 飞牛 fnOS

**把小睿 CM360（Realtek RTD1296）NAS 盒子刷成飞牛 fnOS 的完整板级支持包：可下载的刷机镜像 + 可复现的构建链 + 实测过的救砖路线。**

[![构建刷机镜像](https://github.com/xiaoabiao/CM360-RTD1296-fnnas/actions/workflows/release.yml/badge.svg)](https://github.com/xiaoabiao/CM360-RTD1296-fnnas/actions/workflows/release.yml)
[![Release](https://img.shields.io/github/v/release/xiaoabiao/CM360-RTD1296-fnnas?label=最新刷机镜像)](https://github.com/xiaoabiao/CM360-RTD1296-fnnas/releases/latest)
[![License](https://img.shields.io/badge/license-GPL--2.0--only-blue.svg)](#许可)

> 板子：4×Cortex-A53 / 2 GiB DDR4 / 8 GiB eMMC / 双 SATA / 千兆网口 / 串口 UART0 @115200
> 系统：**fnOS 1.2.0302** + 自编译 **Linux 6.6.54**（板级 DTS + 6 个内核补丁 + fnOS 1.2 兼容层）

---

## 一、只想刷机？三步

| 步骤 | 做什么 |
|---|---|
| 1 | 到 **[Releases](https://github.com/xiaoabiao/CM360-RTD1296-fnnas/releases/latest)** 下载 `dd-set-cm360-<版本>.tar.gz` |
| 2 | 解压后整个目录拷到板子（板子需能进系统；从原厂固件开始刷请看下面"路线 C"） |
| 3 | 板端 `sudo ./dd-flash.sh --check` 看一遍校验，然后 `sudo ./dd-flash.sh` |

刷完重启即可，全程约 **5 分钟**（实测：低区 3.7 s / 内核分区 1.7 s / 根分区 146 s）。

> ⚠️ 刷 p2（根分区）= **清空 fnOS 的账号/共享/设置**，这就是"重装系统"的定义。
> 两块硬盘上的存储空间（RAID / LVM / btrfs）**不受影响** —— 脚本只按设备名写 eMMC。

---

## 二、Release 里有哪几个文件，分别怎么刷

| 资产 | 是什么 | 怎么刷 | 状态 |
|---|---|---|---|
| `low-region-38MiB.img.gz` | **引导链**：hwsetting + bootcode + FSBL + BL31 + **u-boot** + env | dd 写 `/dev/mmcblk0` 起始 38 MiB；线刷包已内置 | ✅ 实测 |
| `p1-256MiB.img.gz` | **内核分区**（ext4：`Image-6.6.uimage` + 板级 DTB，带 `.bak` 兜底） | dd 写 `/dev/mmcblk0p1` | ✅ 实测 |
| `dd-set-cm360-<版本>.tar.gz` | dd 套装：低区 + p1 + `dd-flash.sh` + 说明 | 板端 `sudo ./dd-flash.sh` | ✅ 实测 |
| `p2.img.gz[.partNN]` | **根分区**（fnOS rootfs，btrfs 子卷 `root`） | dd 写 `/dev/mmcblk0p2`（先 `cat *.part* > p2.img.gz` 再解压） | ✅ 实测 |
| `install-…-boot-sysonly.img.gz` | **线刷包**（含引导链，不含 p2）：低区 + MBR + p1 | Windows USB MP Tool（SW5 进下载模式） | ⚠️ 格式逆向自厂商包，**工具接受度未实测** |
| `install-…-boot-full.img.gz` | **线刷包**（含引导链 + 完整 p2） | 同上（一次连 u-boot 一起刷） | ⚠️ 同上 |
| `install-…-boot-compact-full.img.gz` | 线刷包（含引导链 + **精简 p2**，体积约 1/2.4） | 同上；首启自动把 rootfs 扩回满分区 | ⚠️ 同上 |
| `MD5SUMS.txt` / `SHA256SUMS.txt` | 校验清单 | `md5sum -c MD5SUMS.txt` | ✅ |

> 文件名带 `.partNN` 的是**分卷**（GitHub 单文件上限 2 GiB）：
> 先下全所有分卷，再 `cat 文件名.part* > 文件名` 合并即可。

---

## 三、三条刷机路线，怎么选

| 路线 | 适用场景 | 需要什么 | 状态 |
|---|---|---|---|
| **A. dd（板内直刷）** | 板子能进系统（哪怕系统坏了但能进 u-boot 之后的 Linux） | dd 套装 | ✅ **端到端实测通过** |
| **B. u-boot（TFTP / U 盘）** | 系统起不来，但 u-boot 还在（开机 3 秒窗口） | 串口 USB-TTL + TFTP 或 U 盘 | ✅ 实测通过 |
| **C. Windows USB MP Tool（线刷）** | **板砖了 / 从原厂固件开始** | Windows + USB 线 + 按住 SW5 | ⚠️ 包已生成，**工具接受度未实测** |

### 路线 A：dd 直刷（推荐）

```sh
# 板端（root）
sudo ./dd-flash.sh --check                 # 只校验：镜像大小 / md5 / 目标设备
sudo ./dd-flash.sh                         # 三层全刷
sudo ./dd-flash.sh --layers p1             # 只换内核（不动系统与配置）
sudo ./dd-flash.sh --layers low-region     # 只刷引导链（含 u-boot）
```

- 前提：板子能进 Linux（`sudo` 可用）。
- 安全性：脚本先验 md5 与目标分区大小，**写前需确认**（`--yes` 跳过）。
- 详情：[`firmware/dd-flash.sh`](firmware/dd-flash.sh) 头部注释、[`docs/08-flashing-approaches.md`](docs/08-flashing-approaches.md)

### 路线 B：u-boot + TFTP / U 盘

开机 3 秒窗口进 `BPI-W2>`（低区里已写 `bootdelay=3`），然后：

```sh
# 电脑端起一个只读 TFTP（纯标准库）
python3 tools/tftp-server.py --root firmware/images --port 69
# u-boot 端
setenv serverip 192.168.2.2; setenv ipaddr 192.168.2.200
tftp 0x20000000 p1.img          # ⚠️ 必须 ≥0x20000000：BL31 占 0x10120000 / TEE 占 0x10200000
mmc dev 0; mmc write 0x20000000 0x13000 0x80000
```

一次最多 64 MiB（分块续写），7 GiB 的 p2 走 TFTP 约 78 分钟 → **能用 dd 就别用 TFTP**。
详情：[`firmware/README.md`](firmware/README.md)、[`firmware/flash-from-pc.py`](firmware/flash-from-pc.py)（电脑端一键：自动进 u-boot + TFTP + 写后回读校验）

### 路线 C：Windows USB MP Tool（线刷整包）

1. 工具目录放**纯 ASCII 路径**（别放中文路径/桌面）
2. 装 `usb_driver`；**按住主板上电源插座旁的 SW5**，只插 Type-C 线（**不接 DC 电源**）约 3 秒
3. 设备管理器出现 `Realtek generic USB Device` → 打开 usb mp tool
4. `flash type = EMMC`、`DDR Type = 4DDR4_2GB`
5. `open` 选 `install-cm360-fnos-*.img` → 点小绿人 → 到 100%

包格式是对厂商包逆向出来的（`layout.txt` / `config.txt` / `fw_tbl.bin` / MBR），
**工具是否接受自定义条目尚未验证** —— 详见 [`docs/10-vendor-usb-mp-tool-package.md`](docs/10-vendor-usb-mp-tool-package.md)。
其中"连 u-boot 一起刷"由 `--with-lowregion` 生成的低区条目实现，所以**不需要先手动刷 u-boot**。

---

## 四、这块板子现在的状态

| 子系统 | 状态 | 关键证据 |
|---|---|---|
| 串口 / 内存 / GIC / 时钟 / SMP 四核 | ✅ | `smp: Brought up 1 node, 4 CPUs` |
| eMMC（HS200，7.28 GiB） | ✅ | `mmcblk0` HS200 |
| SATA 双盘（6 Gbps） | ✅ | `ata1`/`ata2` `SATA link up 6.0 Gbps` |
| eth0（原生 GMAC 千兆） | ✅ | 0% 丢包、31.5 MB 传输 md5 一致 |
| **eMMC 独立启动**（不依赖 TFTP/SATA） | ✅ | u-boot 从 p1 读内核 |
| **fnOS 运行**（面板 / SSH / Docker / SMART / zram） | ✅ | `http://<板子IP>:5666` |
| 存储空间（mdraid + LVM） | ✅ | 双盘 RAID1 → LVM → `/vol1`、`/vol2` |
| `reboot` / 看门狗 | ✅ | 内核补 restart 回调 + DTS 开 wdt |
| ZFS 型存储空间 | ⬜ | 需为 6.6.54 交叉编译 OpenZFS |
| **风扇调速 / LED / SoC 温度读数** | ⬜ | 缺厂商板级描述，**风扇目前不受控** |
| SDMMC / SDIO / USB3 | ⬜ | 驱动就绪，缺 DTS 节点 |

---

## 五、硬件与启动链（动闪存前必读）

| 项 | 值 |
|---|---|
| SoC | Realtek RTD1296（4× Cortex-A53，2 GiB DDR4） |
| 存储 | 8 GiB eMMC（HS200）+ 2× SATA |
| 网络 | 内嵌 GPHY 千兆 |
| 串口 | UART0 @ 115200 8N1（USB-TTL，CH340 即可；进系统后 getty 变 57600） |

启动链：`Mask ROM → bootcode → hwsetting → FSBL → BL31(TEE) → u-boot 2015.07 → 内核(p1) → rootfs(p2)`

eMMC 布局（实测，**别按常规分区思维动手**）：

| 区域 | 位置 | 内容 |
|---|---|---|
| 低区 | LBA 0 – 0x12FFF（38 MiB） | MBR + hwsetting + bootcode + **u-boot** + BL31/TEE + env |
| p1 | LBA 0x13000（38 MiB） | ext4 内核分区 |
| p2 | LBA 0x93000（294 MiB） | btrfs rootfs（子卷 `root`） |

> ⚠️ **`hwsetting`（DRAM/启动配置）就在 `blk# 0x100`（偏移 128 KiB）**，属于"分区表之外 ≠ 空的"。
> 本项目曾因清空 eMMC 前 1 MiB 把板子打成砖 —— 事故与救回全过程：
> [`docs/incident-2026-10-05-emmc-recovery.md`](docs/incident-2026-10-05-emmc-recovery.md)。
> **要清就直接用 `low-region.img` 整块覆盖（38 MiB），不要手写前 1 MiB。**

---

## 六、自己构建（含云端构建）

### 6.1 内核

```sh
./scripts/setup-deps.sh        # 拉内核树（锁定 commit）+ 打补丁（本地不入库源码）
./scripts/build-kernel.sh      # 编内核 + 板级 DTB → build/
./scripts/deploy-modmeta.sh    # 换内核后必做：装模块元数据（板上 depmod）
```

本机差异（内核树位置、工具链前缀、串口设备）写在仓库根 `local.conf`（模板 `local.conf.example`，不入库）。

### 6.2 刷机镜像

```sh
cd firmware
./build-images.sh p1                                   # 内核分区（几秒）
./build-images.sh p2 ~/downloads/fnos_arm_1.2.0302_xxx.img.gz   # rootfs（10~20 分钟，需 sudo）
./shrink-p2.sh                                         # 可选：精简 rootfs（6.99 → 2.75 GiB）
```

### 6.3 一键出全部 Release 资产（CI 用的就是这条）

```sh
./tools/build-release-assets.sh --p2 firmware/images/p2.img --out /mnt/out
./tools/build-release-assets.sh --no-p2 --out /mnt/out      # 不含 p2（引导链 + p1 + 救援线刷包）
```

### 6.4 云端构建 / 发布

[`.github/workflows/release.yml`](.github/workflows/release.yml) 会在**打 tag（`v*`）时自动构建并发布 Release**；
也可以在 Actions 页面手动触发（`Run workflow`），并可传官方 fnOS 镜像直链，把 p2 与完整线刷包一起构建。

> **版权提示**：fnOS 官方镜像与 rootfs 属于 fnOS 版权物，本仓库默认**不随公开发布分发 p2**。
> 用官方镜像构建出来的 p2 资产只上传到 Actions artifact（不公开），除非你自己确认有权分发。

---

## 七、砖了怎么办

按"代价从小到大"试：

1. **能进 u-boot** → 路线 B（TFTP 写 p1/低区）
2. **能进 Linux** → 路线 A（dd，最快）
3. **什么都进不去** → 路线 C（Windows 线刷包）或 **SoC ROM Monitor 串口救砖**（Ctrl+Q + YMODEM，本项目实测走通过，**不需要编程器**）
   → [`docs/04-recovery.md`](docs/04-recovery.md)、[`firmware/RECOVERY.md`](firmware/RECOVERY.md)

---

## 八、仓库结构

```
├── boards/<board>/         板级文件：DTS、板上脚本、拷进 rootfs 的文件
├── patches/                内核补丁（每个补丁对应一个实测问题）
├── scripts/                主机侧流水线：拉依赖 → 构建 → 部署 → 验证
├── firmware/               刷机镜像：生成（build-images / shrink-p2）/ 刷入（dd-flash / flash-from-pc）
├── tools/                  交互与诊断 + 发布：release-assets / lineflash / tftp / serial
├── artifacts/              现役内核 uImage + DTB + .config + 模块元数据（可直接落盘）
├── dist/                   发布产物（gitignore，由 tools/build-release-assets.sh 生成）
├── docs/                   文档（先看 01 → 03；出事看 04/06）
├── evidence/               实测证据：原始串口日志、启动日志、构建记录
└── .github/workflows/      云端构建与发布
```

## 九、文档索引

| 文档 | 内容 |
|---|---|
| [`docs/01-hardware-and-boot.md`](docs/01-hardware-and-boot.md) | 硬件、启动链、串口、原厂固件结构 |
| [`docs/02-kernel-and-dts.md`](docs/02-kernel-and-dts.md) | 内核树选型、补丁清单、配置叠加 |
| [`docs/03-build-and-install.md`](docs/03-build-and-install.md) | 构建、装到 eMMC、更新内核、验证 |
| [`docs/04-recovery.md`](docs/04-recovery.md) | **救砖**：ROM Monitor 完整流程 |
| [`docs/05-storage-and-fnos.md`](docs/05-storage-and-fnos.md) | 存储空间创建、fnOS 服务适配 |
| [`docs/06-troubleshooting.md`](docs/06-troubleshooting.md) | 故障排查速查（症状 → 根因 → 修法） |
| [`docs/07-fnos-upgrade.md`](docs/07-fnos-upgrade.md) | fnOS 升级：整块替换 rootfs 子卷（含回滚） |
| [`docs/08-flashing-approaches.md`](docs/08-flashing-approaches.md) | 四条刷入路线对比与抉择 |
| [`docs/10-vendor-usb-mp-tool-package.md`](docs/10-vendor-usb-mp-tool-package.md) | **线刷包**：厂商包结构 / `fw_tbl.bin` 格式 / 生成器 / 精简 p2（7.32 → 3.07 GiB） |
| [`docs/11-release-and-ci.md`](docs/11-release-and-ci.md) | **发布流程与云端构建**：一键出全部资产 / 分卷规则 / CI 触发方式 / 资产对照 / 版权边界 |
| [`firmware/README.md`](firmware/README.md) | **给别人用的刷机指南**：镜像怎么生成、怎么刷、首启做什么 |
| [`firmware/RECOVERY.md`](firmware/RECOVERY.md) | 低区布局与灾难恢复 |
| [`docs/incident-2026-10-05-emmc-recovery.md`](docs/incident-2026-10-05-emmc-recovery.md) | 事故复盘：变砖与救回全过程 |
| [`总结.md`](总结.md) | 交接文档：交付物地图 / 未完成事项 / 一键复现命令 |

---

## 十、几个反直觉的坑（都有实测证据）

1. **`cpu-release-addr` 在这颗 SoC 上不是内存，是硬件寄存器** —— 主线按规范做 8 字节缓存写会打到设备寄存器，
   症状是**总线挂死、零报错**。→ `patches/0003-smp-rtk-spin-table.patch`
2. **原厂 DTB 里"缺失的属性"是语义，不是遗漏** —— 它表示"用驱动默认值"。我们"好心补上"曾导致网口 RX 恒 0。
3. **`modprobe` 失败 ≠ 模块缺失** —— 全内置内核没有 `/lib/modules/<版本>/`；kmod 只认 `.bin` 索引，
   **必须在板上跑 `depmod`**。→ `scripts/deploy-modmeta.sh`
4. **`reboot` 挂死的根因是"一个 restart handler 都没有"** —— arm64 会 `System halted` + 死循环。
   本板 PSCI / rtk-rstctrl / 看门狗回调三者皆无。→ `patches/0004-wdt-restart.patch`
5. **串口必须真独占** —— 多进程打开同一 tty，**每个字节只投递给一个读者**，第二个手开的 `screen` 会偷走应答。
6. **tar 不保留稀疏性** —— dd 出来的 7 GiB p2 有 67.5% 是空洞，但打成 tar 就是 7 GiB；
   厂商包之所以小，是因为它只带"装得下内容的最小镜像"。→ `firmware/shrink-p2.sh`、`docs/10` §12/§13

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
**本仓库不包含任何厂商版权物**（原厂固件、fnOS 官方镜像、`kylin_usb_mp_tools`），请自行从官方渠道获取。
