# CM360 → Linux 6.6 + 飞牛 fnOS

**把小睿 CM360（Realtek RTD1296）NAS 盒子刷成飞牛 fnOS 的完整板级支持包：可一键线刷的镜像 + 可复现的构建链 + 实测过的救砖路线。**

[![Release](https://img.shields.io/github/v/release/xiaoabiao/CM360-RTD1296-fnnas?label=最新刷机镜像)](https://github.com/xiaoabiao/CM360-RTD1296-fnnas/releases/latest)
[![License](https://img.shields.io/badge/license-GPL--2.0--only-blue.svg)](#许可)

> 板子：4×Cortex-A53 / 2 GiB DDR4 / 8 GiB eMMC / 双 SATA / 千兆网口 / 串口 UART0 @115200
> 系统：**fnOS 1.2.0302** + 自编译 **Linux 6.6.54**（板级 DTS + 6 个内核补丁 + fnOS 1.2 私有 ABI 兼容层）

---

## 一、只想刷机？三步

| 步骤 | 做什么 |
|---|---|
| 1 | 到 **[Releases](https://github.com/xiaoabiao/CM360-RTD1296-fnnas/releases/latest)** 下载 `install-cm360-fnos-<版本>-slim-p2.img.gz`（1.05 GiB，推荐）或 `-full-p2.img.gz`（1.66 GiB，功能完整），`gzip -d` 或 7-Zip 解压成 `.img` |
| 2 | 装 **[RTD-Flasher](https://github.com/xiaoabiao/rtd129x-usb-flasher)**（64 位 Rust 重写版线刷工具，Windows 7+，装一次原厂 UMDF 驱动即可） |
| 3 | 板子**断电 → 按住 SW5 插 Type-C**（不接 DC）→ 工具里选镜像、`DDR=4DDR4_2GB` → 开始烧写 → 刷完断电重启 |

**刷完自动进 fnOS**（slim 包约 7 分钟，完整包约 24 分钟）。一次刷入 **低区引导链 + MBR + 内核分区 + rootfs + factory（u-boot env）**，不需要串口、不需要 TFTP、不需要先能进系统。

> ⚠️ 刷 rootfs = **清空 fnOS 的账号/共享/设置**（就是"重装系统"）。两块硬盘上的存储空间（RAID / LVM / btrfs）不受影响——镜像只写 eMMC。
>
> 💡 包内已内置 **trim-compat 兼容层**：面板上传文件、创建共享文件夹、FTP/SMB 进共享目录、删除→回收站→还原 都是修好的，**不需要额外装任何东西**（2026-10-26 修复）。

---

## 二、Releases 里有哪几个文件

| 资产 | 大小 | 是什么 | 怎么用 |
|---|---|---|---|
| **`install-cm360-fnos-1.2.0302-slim-p2.img.gz`** | 1.05 GiB（解压 2.24 GiB） | ★ **推荐**：低区 + MBR + p1 + **精简 rootfs（2.0 GiB）** + factory.tar，首启自动 `btrfs resize max` 扩回 7.0 GiB | 解压后用 RTD-Flasher / 厂商 USB MP Tool 均可（≈7 min） |
| **`install-cm360-fnos-1.2.0302-full-p2.img.gz`** | 1.66 GiB（解压 7.28 GiB） | **功能完整**：低区 + MBR + p1 + **完整 rootfs（7.0 GiB）** + factory.tar | 解压后**只能**用 RTD-Flasher（厂商 32 位工具载入会崩，见 §五）（≈24 min） |
| `cm360-trim-compat-1.2.0302.tar.gz` | 30 KB | **fnOS 私有 ABI 用户态兼容层**（上传/共享/回收站/FTP）。**新镜像已内置**，此包只给「已刷旧镜像」的板子补救 | 板端 `tar xzf … && cd cm360-trim-compat-1.2.0302 && sudo ./trim-compat/install.sh` |
| `cm360-extra-features.tar.gz` | 485 MiB | 精简包中被删掉的组件（`/usr/lib/firmware`、AAVMF、LLVM/gallium、Qt、gcc、文档、locale 等 ≈1.65 GB / 28,190 个文件），给用 slim 包又想要完整功能的板子 | 板端从仓库取 `firmware/install-extra-features.sh`，`sudo ./install-extra-features.sh` |
| `MD5SUMS.txt` | — | 校验清单（与上面 4 个资产一一对应） | `md5sum -c MD5SUMS.txt` |

---

## 三、一键线刷（推荐路线：RTD-Flasher）

[RTD-Flasher](https://github.com/xiaoabiao/rtd129x-usb-flasher) 是原厂 `rtumdfsample.exe` 协议的 **64 位 Rust 重写版**（GUI + CLI），本项目实测刷写 **7.82 GB 完整包**（其中 `p2.img` 单成员 7.0 GB）成功、断电重启正常进 fnOS。

**准备**：Windows 7+ 电脑；原厂 UMDF 驱动（设备管理器显示 `Realtek generic USB Device`，`VID_0BDA&PID_1195`）；
从 [Releases](https://github.com/xiaoabiao/rtd129x-usb-flasher/releases) 下载 `RTD-Flasher-Setup-*.exe` 安装（按用户安装，不需要管理员；`hwsetting\` 会自动与 exe 同目录）。
**绝不能用 Zadig 把驱动换成 WinUSB**，否则读不到板子。

**板子进 USB 下载模式**：断电 → **按住电源插座旁的 SW5** → 只插 Type-C 线（**不接 DC 电源**）约 3 秒。

**图形界面**：选 `install-….img` → `DDR = 4DDR4_2GB` → 加载（核对分区列表）→ 扫描设备 → 开始烧写 → 完成后断电重启。

**命令行（非交互、可脚本化，成功 exit 0 失败非零）**：

```bat
:: 一键线刷 —— Windows 7+，无 Python / 无 .NET 依赖，刷写本身不需要管理员
set TOOL=%LOCALAPPDATA%\Programs\RTD-Flasher
set IMG=D:\images\install-cm360-fnos-1.2.0302-full-p2.img
set DDR=4DDR4_2GB

"%TOOL%\rtd-flash.exe" devices                  :: 列出板子（找 0bda:1195）
"%TOOL%\rtd-flash.exe" inspect "%IMG%"          :: 打印镜像成员 / layout.txt 原文 / 分区匹配
"%TOOL%\rtd-flash.exe" plan    "%IMG%" %DDR%    :: 干跑：打印完整帧序列，不碰设备
"%TOOL%\rtd-flash.exe" burn    "%IMG%" %DDR%    :: 实刷（slim≈7 min，完整≈24 min）
```

> 镜像**不需要解压**：`install-*.img` 是标准 ustar tar，工具直接读。
> `DDR` 只有 DDR3/DDR4 代际影响 hwsetting blob（本板选 `4DDR4_2GB`）；`SYSTEM.ini`（flash type / 写范围）可选，缺省用内置默认值。
> 刷完 **断电重启**；中断后必须冷启动重新进下载模式再刷。

### 备选：厂商 Windows USB MP Tool（只能刷 slim 包）

仓库里 `tools/make-lineflash-official.sh` 生成的包与厂商工具二进制兼容，但厂商工具是 **32 位进程**，载入时把全部载荷读进内存 → 单包总量 ≲2.3 GB，**只能载入 slim 包**：

1. 工具放**纯 ASCII 路径**（别放中文目录）；
2. 装 `usb_driver`，按 SW5 进下载模式；
3. `flash type = EMMC`、`DDR Type = 4DDR4_2GB`；
4. `open` 选 `install-cm360-fnos-1.2.0302-slim-p2.img` → 绿人 → 100% → 断电重启。

---

## 四、包为什么能"一次刷完还能自动引导"

包格式是从厂商 iStoreOS CM360 线刷包逆向出来的（`config.txt` / `layout.txt` / `mbr.bin` / `fw_tbl.bin` / `omv/`），
2026-10-20 起**元数据直接由厂商官方打包工具 `rtd129x_img_gen` 生成**（实测同一份 JSON 能逐字节复现厂商包的 `config/mbr/fw_tbl`）。包内一次包含：

| 写入项 | 内容 | 作用 |
|---|---|---|
| `FW_KERNEL`（offset `0x200`，到 `0x2600000`） | 38 MiB **低区镜像** | hwsetting + bootcode + FSBL + BL31/TEE + **u-boot + u-boot env** |
| `PART0` | p1（256 MiB ext4） | 内核 `Image-6.6` + 板级 DTB（带 `.bak` 兜底） |
| `PART1` | p2 rootfs | fnOS 1.2.0302（btrfs 子卷 `root`，zstd 压缩） |
| `MBR0` | 2 分区表 | LBA `0x13000` / `0x93000` |
| `omv/factory.tar` | `tmp/factory/env.txt` | 刷完工具回写 factory 区 → **u-boot env 自动恢复**（否则停在 `BPI-W2>`） |

也就是说：**哪怕是砖，只要 USB 下载模式还进得去，一个包就能写回引导链 + 系统**，不需要串口、不需要先有可用的系统。

---

## 五、为什么完整包必须用 64 位工具

厂商 `rtumdfsample.exe` 是 PE32 i386：加载完整包时按分区总大小申请 **3.7 GB 虚拟内存**，直接 `GetLastError:8`（内存不足）或 `0xC0000409` 崩溃；把 rootfs 拆成多个 <2 GiB 成员也**没用**（总量不变，实测 `load [PART2] data failed`）。

[RTD-Flasher](https://github.com/xiaoabiao/rtd129x-usb-flasher) 是 64 位实现、从 tar **按 2 MiB 流式读取**，所以 7.82 GB 单包（含 7.0 GB 的 `p2.img`）可以直接刷 —— 刷写日志逐帧 CSW 全 PASS。
因此：**要功能完整 → 用 `-full-p2.img` + RTD-Flasher；只有厂商工具 → 用 `-slim-p2.img`**。
（完整包里的组件与"功能完整"的含义见 `docs/13-lineflash-packaging-guide.md` 与 §二 的 `cm360-extra-features`。）

---

## 六、刷完先验收这几项

| 检查 | 预期 |
|---|---|
| 面板「文件」→ 上传一个文件 | 成功（不再提示"上传失败"） |
| 面板新建共享文件夹 | 成功（不再 `User N has no permission`） |
| 删除文件 → 回收站 → 还原 | 正常（`trim_trashbind` 不再每 5 s 重启） |
| FTP / SMB 进共享目录读写 | 正常（`/fs` 由 `cm360-fake-fs.service` 维护） |
| `df -h /` | slim 包首启后已扩到 ≈6.9 GB |

这几个都是 fnOS 1.2.x 走**厂商私有内核 ABI**（魔数 `faccessat`、xattr `system.trim_acl`、`/fs` trimafs、回收站魔数 `unlinkat`）导致的，
本项目用用户态 `LD_PRELOAD` 兼容层修好并内置进镜像；根因与实测见 [`docs/reports/fnos-acl-compat-layer.md`](docs/reports/fnos-acl-compat-layer.md)。

---

## 七、这块板子现在的状态

| 子系统 | 状态 | 关键证据 |
|---|---|---|
| 串口 / 内存 / GIC / 时钟 / SMP 四核 | ✅ | `smp: Brought up 1 node, 4 CPUs` |
| eMMC（HS200，7.28 GiB） | ✅ | `mmcblk0` HS200 |
| SATA 双盘（6 Gbps） | ✅ | `ata1`/`ata2` `SATA link up 6.0 Gbps` |
| eth0（原生 GMAC 千兆） | ✅ | 0% 丢包、31.5 MB 传输 md5 一致 |
| **eMMC 独立启动**（不依赖 TFTP/SATA） | ✅ | u-boot 从 p1 读内核 |
| **fnOS 运行**（面板 / SSH / Docker / SMART / zram） | ✅ | `http://<板子IP>:5666` |
| 存储空间（mdraid + LVM） | ✅ | 双盘 RAID1 → LVM → `/vol1`、`/vol2` |
| ZFS 型存储空间 | ✅ | OpenZFS 2.4.1 模块（`artifacts/zfs-2.4.1/`，vermagic 与板上内核一致） |
| **面板上传 / 共享文件夹 / FTP / 回收站** | ✅ | trim-compat 兼容层（2026-10-26 实机修复） |
| `reboot` / 看门狗 | ✅ | 内核补 restart 回调 + DTS 开 wdt |
| **风扇调速 / SoC 温度读数** | ⬜ | 软件链路已通；**风扇对占空比无响应、温度恒读 0** —— 属硬件取证，需上板 |
| **USB-A ×2 / Type-C 口** | ✅ | 2026-10-26 上板验证通过：3 个控制器 + 5 条总线、USB3 根 hub 5000M，Type-C 的 U 盘与 USB-A 的 1TB 移动盘都正常识别（`build/usb-fix/`） |
| **盘位指示灯（HDD LED ×2）** | ✅ | 2026-10-26 上板验证：iso GPIO 26/21 **高电平点亮**；`cm360-hdd-led` 守护做「在位常亮 + 有 IO 6Hz 闪烁 + 无盘灭」，按 ATA 端口分盘 |
| SDMMC / SDIO | ⬜ | 驱动就绪，缺 DTS 节点（SD 节点已在但 `disabled`）；金坐标已从原厂 DTB 取全 |

---

## 八、硬件与启动链（动闪存前必读）

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
| 低区 | LBA 0 – 0x12FFF（38 MiB） | MBR + hwsetting + bootcode + **u-boot** + BL31/TEE + env + factory |
| p1 | LBA 0x13000（38 MiB） | ext4 内核分区 |
| p2 | LBA 0x93000（294 MiB） | btrfs rootfs（子卷 `root`，7.0 GiB） |

> ⚠️ **`hwsetting`（DRAM/启动配置）就在 `blk# 0x100`（偏移 128 KiB）**，属于"分区表之外 ≠ 空的"。
> 本项目曾因清空 eMMC 前 1 MiB 把板子打成砖 —— 事故与救回全过程：
> [`docs/incident-2026-10-05-emmc-recovery.md`](docs/incident-2026-10-05-emmc-recovery.md)。
> **不要手写前 1 MiB**；要重写就用线刷包整块覆盖（低区已内置在包里）。

---

## 九、自己构建

### 9.1 内核

```sh
./scripts/setup-deps.sh        # 拉内核树（锁定 commit）+ 打补丁（本地不入库源码）
./scripts/build-kernel.sh      # 编内核 + 板级 DTB → build/
./scripts/deploy-modmeta.sh    # 换内核后必做：装模块元数据（板上 depmod）
```

本机差异（内核树位置、工具链前缀、串口设备）写在仓库根 `local.conf`（模板 `local.conf.example`，不入库）。

### 9.2 rootfs 镜像（p2）

```sh
cd firmware
./build-images.sh p2 ~/downloads/fnos_arm_1.2.0302_xxx.img.gz   # 完整 rootfs（10~20 分钟，需 sudo）
P2_BYTES=7508844544 ./build-images.sh p2 …                      # 指定精确分区尺寸（线刷用）
./slim-p2.sh --src images/p2.img --out images/p2slim.img --size-mib 2000   # 精简版（线刷 slim 包用）
```

`build-images.sh` 的 `adapt()` 会自动做：fstab、清官方内核/源码头、**注入 trim-compat 兼容层**、装 ZFS 模块与内核模块元数据、写 `cm360-firstboot.sh`（首启 `depmod` + `btrfs resize max`）。

### 9.3 线刷包（官方工具链）

```sh
# 低区镜像（38 MiB）与工具：见交付目录/仓库 firmware/low-region-38MiB.img.gz
bash tools/make-lineflash-official.sh \
  --tool /path/rtd129x_img_gen \
  --p1 images/p1.img \
  --p2 images/p2slim.img            \
  --lowregion images/low-region.img \
  --version 1.2.0302 --out out      # 加 --full-p2 出 7.8 GB 完整包
```

完整输入清单、11 条硬约束、打包后自检、故障速查：**[`docs/13-lineflash-packaging-guide.md`](docs/13-lineflash-packaging-guide.md)**。

### 9.4 云端构建 / 发布

[`.github/workflows/release.yml`](.github/workflows/release.yml) 会在打 tag（`v*`）时自动构建并发布 Release，也可在 Actions 页手动触发并传官方 fnOS 镜像直链。

> **版权提示**：fnOS 官方镜像与 rootfs 属 fnOS 版权物，本仓库代码/文档不含厂商版权物；
> Release 中的 rootfs 源自官方 fnOS ARM 镜像，请自行确认使用与分发授权。下载使用即视为你自行确认授权与合规。

---

## 十、砖了怎么办

按代价从小到大：

1. **能进 USB 下载模式**（绝大多数情况）→ 用 §三 的一键线刷，一个包写回引导链 + 系统（**首选**）
2. **能进 u-boot、能进 Linux** → 救砖次要路线：串口 + TFTP / 板内 `dd`（历史方案，见 [`docs/08-flashing-approaches.md`](docs/08-flashing-approaches.md)、[`firmware/flash-from-pc.py`](firmware/flash-from-pc.py)）
3. **什么都进不去** → **SoC ROM Monitor 串口救砖**（Ctrl+Q + YMODEM，本项目实测走通过，**不需要编程器**）
   → [`docs/04-recovery.md`](docs/04-recovery.md)、[`firmware/RECOVERY.md`](firmware/RECOVERY.md)

---

## 十一、仓库结构

```
├── boards/<board>/         板级文件：DTS、板上脚本、trim-compat 兼容层
├── patches/                内核补丁（每个补丁对应一个实测问题）
├── scripts/                主机侧流水线：拉依赖 → 构建 → 部署 → 验证
├── firmware/               镜像生成（build-images / slim-p2）+ 刷入（flash-from-pc / dd-flash）
├── tools/                  lineflash（官方工具链打包）/ make-factory-tar / tftp / serial / 发布
├── artifacts/              现役内核 uImage + DTB + .config + 模块元数据（可直接落盘）
├── docs/                   文档（先看 01 → 03；线刷看 10/13；出事看 04/06）
├── evidence/               实测证据：原始串口日志、启动日志、构建记录
└── .github/workflows/      云端构建与发布
```

## 十二、文档索引

| 文档 | 内容 |
|---|---|
| [`docs/01-hardware-and-boot.md`](docs/01-hardware-and-boot.md) | 硬件、启动链、串口、原厂固件结构 |
| [`docs/02-kernel-and-dts.md`](docs/02-kernel-and-dts.md) | 内核树选型、补丁清单、配置叠加 |
| [`docs/03-build-and-install.md`](docs/03-build-and-install.md) | 构建、装到 eMMC、更新内核、验证 |
| [`docs/04-recovery.md`](docs/04-recovery.md) | **救砖**：ROM Monitor 完整流程 |
| [`docs/05-storage-and-fnos.md`](docs/05-storage-and-fnos.md) | 存储空间创建、fnOS 服务适配 |
| [`docs/06-troubleshooting.md`](docs/06-troubleshooting.md) | 故障排查速查（症状 → 根因 → 修法） |
| [`docs/07-fnos-upgrade.md`](docs/07-fnos-upgrade.md) | fnOS 升级：整块替换 rootfs 子卷（含回滚） |
| [`docs/08-flashing-approaches.md`](docs/08-flashing-approaches.md) | 刷入路线对比（历史 dd/TFTP 方案，现以线刷为主） |
| [`docs/10-vendor-usb-mp-tool-package.md`](docs/10-vendor-usb-mp-tool-package.md) | **线刷包格式**：厂商包结构 / `fw_tbl.bin` / 用官方 `rtd129x_img_gen` 打包 / 九个实测坑 |
| [`docs/11-release-and-ci.md`](docs/11-release-and-ci.md) | 发布流程与云端构建 / 分卷规则 / 资产对照 / 版权边界 |
| [`docs/12-uefi-and-install-media.md`](docs/12-uefi-and-install-media.md) | UEFI 替代 U-Boot？结论、四条路线对比、低区可替换性实测 |
| [`docs/13-lineflash-packaging-guide.md`](docs/13-lineflash-packaging-guide.md) | **线刷包打包交接说明**：输入清单与 md5 / slim 与完整包命令 / 打包后自检 / 11 条约束 / 验收与速查 |
| [`docs/reports/fnos-acl-compat-layer.md`](docs/reports/fnos-acl-compat-layer.md) | **上传/共享/回收站修复**：根因（私有 ABI）、兼容层设计、实机回归 |
| [`firmware/README.md`](firmware/README.md) | 镜像怎么生成、怎么刷、首启做什么 |
| [`firmware/RECOVERY.md`](firmware/RECOVERY.md) | 低区布局与灾难恢复 |
| [`总结.md`](总结.md) | 交接文档：交付物地图 / 未完成事项 / 一键复现命令 |

## 十三、几个反直觉的坑（都有实测证据）

1. **`cpu-release-addr` 在这颗 SoC 上不是内存，是硬件寄存器** —— 主线按规范做 8 字节缓存写会打到设备寄存器，症状是**总线挂死、零报错**。→ `patches/0003-smp-rtk-spin-table.patch`
2. **原厂 DTB 里"缺失的属性"是语义，不是遗漏** —— 它表示"用驱动默认值"。我们"好心补上"曾导致网口 RX 恒 0。
3. **`modprobe` 失败 ≠ 模块缺失** —— 全内置内核没有 `/lib/modules/<版本>/`；kmod 只认 `.bin` 索引，**必须在板上跑 `depmod`**。→ `scripts/deploy-modmeta.sh`
4. **`reboot` 挂死的根因是"一个 restart handler 都没有"** —— arm64 会 `System halted` + 死循环。→ `patches/0004-wdt-restart.patch`
5. **串口必须真独占** —— 多进程打开同一 tty，**每个字节只投递给一个读者**，第二个手开的 `screen` 会偷走应答。
6. **tar 不保留稀疏性** —— dd 出来的 7 GiB p2 有 67.5% 是空洞，打成 tar 就是 7 GiB；厂商包之所以小，是因为它只带"装得下内容的最小镜像"。→ `firmware/slim-p2.sh`、`docs/10` §12/§13
7. **厂商线刷工具是 32 位** —— 载入阶段把全部载荷拉进内存，单包 ≲2.3 GB；完整包必须用 64 位工具（§五）。→ `docs/10` §16.3 ⑨
8. **`omv/` 目录和全 ASCII 成员名是硬要求** —— 缺了 / 中文名会让工具报 `Cannot get untartemp project filename`；`factory.tar` 成员必须根相对 `env.txt`，否则 env 恢复失败停在 `BPI-W2>`。→ `docs/10` §16.3 ④⑧

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
**本仓库的代码与文档不包含厂商版权物**（原厂固件、fnOS 官方镜像、`kylin_usb_mp_tools`）。
Release 里的 rootfs 镜像（p2）源自官方 fnOS ARM 镜像，版权归 fnOS 所有，请自行确认使用与分发授权。
