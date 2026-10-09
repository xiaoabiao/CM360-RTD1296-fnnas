# 刷入方式总览：每条路怎么走、各自依赖什么

本文把本项目**目前所有刷机方式**讲清楚，重点是**每种方式各自的依赖关系**——尤其是
「`dd` 直刷到底依不依赖 u-boot」这个问题。所有数据都来自本机实测，未实测的部分会明确标注。

---

## 0. 选哪条路（先看这张表）

| 路线 | 适用场景 | 实测耗时 | 需要 u-boot 在跑？ | 能写低区？ | 砖板能用？ |
|---|---|---|---|---|---|
| **A. `dd` 直刷**（Linux 内） | 板子**能进系统** | **约 5 分钟**（三层合计） | ✗ 不需要（但要先启动过） | ✔ 能 | ✗ 不能 |
| **B. u-boot + TFTP** | 进得去 u-boot 提示符 | 低区 38MiB ≈ 40 s；p1 256MiB ≈ 8 min；p2 7GiB ≈ **78 min**（实测 TFTP ≈ 1.5 MB/s） | ✔ **需要** | ✔ 能 | ✗ 不能 |
| **C. u-boot + U 盘** | 同 B，但没有网络 | 预期 3~6 分钟（`fatload` 约 20~30 MB/s） | ✔ **需要** | ✔ 能 | ✗ 不能 |
| **D. 串口 ROM Monitor** | **连 u-boot 都没有**（真砖） | 分钟级（只需补 1.2 MB 最小集合） | ✗ **不需要**（走 SoC 自带 ROM） | ✔ 能 | ✔ **唯一能** |

一句话：

> **进得去系统用 `dd`，进得去 u-boot 用 TFTP，两样都没有用串口 ROM Monitor。**

---

## 1. eMMC 布局与三个镜像

| 层 | 位置 | 大小 | 内容 |
|---|---|---|---|
| **低区** | LBA `0` ~ `0x12FFF` | **38 MiB**（39,845,888 B） | hwsetting + bootcode + FSBL + BL31 + u-boot + u-boot env |
| **p1** | LBA `0x13000` ~ `0x92FFF` | **256 MiB**（268,435,456 B） | ext4：内核 `Image-6.6.uimage` + 板级 DTB（含 `.bak` 兜底） |
| **p2** | LBA `0x93000` ~ 末尾 | **7,508,852,736 B**（≈6.993 GiB） | btrfs：fnOS rootfs（子卷 `root`）+ 本仓库适配 |

低区各段的实测偏移（`wget` 式核对过，见第 6 节）：

```
@0x20000   hwsetting（ROM 读它做 DRAM/时钟/引脚等上电初始化）
@0x20E00   bootcode
@0xB0600   TEE / BL32
@0x12C400  BL31
@0x7F300   u-boot 本体（版本串 U-Boot 2015.07、提示符 BPI-W2>）
@0x220000  u-boot env（**生效副本**，含我们的 bootcmd 与 bootdelay=3）
@0x420000  u-boot env 旧副本（失效，仅作回退）
```

> ⚠️ p2 的大小必须用**目标分区实际值**（7,508,852,736），
> 不能按整数 7 GiB 生成 —— 否则会大 7 MB，`dd` 直接写不进去（见第 6 节）。

---

## 2. 路线 A：`dd` 直刷（已实测，最快）

### 怎么用

在板子上（能进系统时）：

```sh
# 四件套放到同一目录
sudo ./dd-flash.sh --check              # 只校验镜像与目标尺寸，不写
sudo ./dd-flash.sh --yes --reboot       # 刷三层 + 写后校验 + 自动重启
sudo ./dd-flash.sh --layers p1 --yes    # 只刷某一层
```

脚本做的事：**尺寸检查 → 二次确认（可 `--yes` 跳过）→ 停 fnOS 服务并 sync → 三层 `dd`
→ 写后回读校验 → SysRq 重启**。工具：`firmware/dd-flash.sh`。

### 实测结果（2026-10-09，真实刷机）

```
低区 38 MiB  : dd 写入 3.7 s
p1  256 MiB  : dd 写入 1.7 s（约 155 MB/s）
p2  7 GiB    : dd 写入 146 s（约 51 MB/s，日志 7,508,852,736 bytes copied）
```

刷完后：

- 新系统**完整启动**：systemd 全部拉起、`eth0 link up`、postgresql / smbd / ssh 正常
- 镜像里的 `cm360-firstboot.service` 执行了（`depmod` + 安装 fnOS 1.2 内核兼容层）
- **用旧账号在控制台登录 → `Login incorrect`** ✔ 证明 fnOS 配置（账号/共享/设置）确实被清空
- 板子重新拿到 DHCP 地址，面板 `:5666` 返回 HTTP 200（处于初始化向导状态）
- **两块硬盘上的存储空间全程未被触碰**（脚本只按设备名写 `mmcblk0` 的三个区域）

### 依赖什么

- Linux 用户态：`dd`、`md5sum`、`sync`、`blockdev`、`systemctl`、`stat`
- 内核：块设备层 + **SysRq**（`echo b > /proc/sysrq-trigger` 用于重启）
- **不需要 u-boot 参与**（详见第 5 节）

### 优缺点

- ✔ 快（比 TFTP 快 30 倍以上）；命令简单；带尺寸检查与写后校验
- ✗ p2 覆盖的是**正在运行的 rootfs** → 写入过程中 `/usr/bin` 会失效，
  因此 **p2 的回读校验无法现场完成**（应在重启后的新系统里核对）
- ✗ 板子必须已经能启动（砖板用不了）

---

## 3. 路线 B：u-boot + TFTP（已实测）

### 怎么用

```sh
# 电脑端（需要 python3-serial；TFTP 用 69 端口，需要 sudo）
python3 firmware/flash-from-pc.py --layers low,p1 --ssh-user <板子用户>
python3 firmware/flash-from-pc.py --layers p1,p2 --ssh-user <板子用户> --yes
python3 firmware/flash-from-pc.py --dry-run            # 只检查
python3 firmware/flash-from-pc.py --backup-only        # 只备份低区
```

脚本流程：内置只读 TFTP（`tools/tftp-server.py`）→ 备份低区 → 重启并**自动抢进 u-boot 提示符**
→ `tftp` + `mmc write`（大镜像自动按 64 MiB 分片）→ `run bootcmd` → SSH 复核。
也可以手打：见 `firmware/flash-uboot.cmd`。

### 实测结果

- **低区 38 MiB**：TFTP 载入 + `mmc write` 成功，重启后系统正常，面板 200 ✔
- **p1 256 MiB**：4 个分片逐片写入 ✔，启动正常 ✔
- **硬验证**：板上 `dd if=/dev/mmcblk0p1 | md5sum` = `020e0bac91d6bb01b9ff7eaa86591c49`
  = 镜像 md5，**逐字节一致** ✔
- **p2 未走 TFTP**（按实测 1.5 MB/s 推算需约 78 分钟），最终改用 dd 路线

### 本板 u-boot 的命令差异（照网上教程会失败）

| 事项 | 实测 |
|---|---|
| 网络加载 | 是 **`tftp`**，**没有 `tftpboot`** |
| 引导 | **没有 `boot`** → 用 **`run bootcmd`** |
| 校验 | **没有 `crc32` / `cmp`** → 回读校验改在启动后用 SSH 做 |
| 其他缺失 | `echo`、`dhcp`、`nfs` 都没有；有 `ping`/`bootm`/`mmc`/`md`/`mw`/`run`/`fastboot` |

### 依赖什么

- **u-boot 必须在跑**（`tftp`/`mmc write`/`run bootcmd` 都是它的命令）
- 串口（用于进入 u-boot 提示符；`bootdelay=3` 给了 3 秒窗口，按任意键即可）
- 主机侧：python3 + pyserial、TFTP 69 端口（需 root）

### 优缺点

- ✔ 不需要板子能进系统；低区与 p1 已实测；镜像走网络，不用插 U 盘
- ✗ **慢**（≈1.5 MB/s）；p2 需要分片且耗时长
- ✗ 中途掐断 TFTP 服务端会让 u-boot 卡在等响应的重试里且**不理会 Ctrl-C**（只能断电复位）

---

## 4. 路线 C / D

### C. u-boot + U 盘（设计好、**未实测**）

```text
usb start
fatload usb 0 0x20000000 low-region.img
mmc dev 0
mmc write 0x20000000 0x0 0x13000
# p1/p2 同理；FAT32 单文件 ≤4GB，p2 需切成 ≤2GiB 分片
run bootcmd
```

预期比 TFTP 快得多（`fatload` 约 20~30 MB/s），且不依赖网络。**尚未实测**。

### D. 串口 ROM Monitor（保底，救砖用）

不依赖 u-boot，走 SoC 自带 ROM + YMODEM（稀疏 Ctrl+Q 进入）。
只需要补**最小集合约 1.2 MB**：hwsetting 3 KB + bootcode 515 KB + FSBL 72 KB + BL31 25 KB + u-boot 604 KB。
完整流程见 `firmware/RECOVERY.md` 与 `docs/04-recovery.md`。

---

## 5. ★ 依赖关系分析：`dd` 刷入依赖 u-boot 吗？

**结论：`dd` 本身不依赖 u-boot，但有三条连带关系需要说清楚。**

### 5.1 为什么不依赖

`firmware/dd-flash.sh` 里用的全部是 Linux 用户态工具与内核接口：

```
dd(16) echo(13) cut(5) md5sum(4) sync(3) reboot(3) systemctl(2) blockdev(2) stat(1)
```

**没有出现任何一条 u-boot 命令**（可自行核对：`grep -inE "uboot|tftp|bootm|mmc " firmware/dd-flash.sh`
只会命中注释里的说明文字）。

实测也印证了这点：那次真实刷机**连低区 38 MiB 都是在 Linux 里 `dd` 进去的**，
全程 u-boot 没有参与。

### 5.2 但有三条连带关系

| # | 连带关系 | 说明 |
|---|---|---|
| 1 | **要能跑 `dd`，板子必须先启动过** | 启动链是 `Mask ROM → bootcode → FSBL → BL31 → u-boot → 内核 → rootfs`，其中 u-boot 负责加载内核。所以**真砖板（连 u-boot 都没有）用不了 dd** |
| 2 | **`dd` 写的低区镜像里"装着" u-boot** | u-boot 本体在低区 `@0x7F300`、env 在 `@0x220000`。`dd` 是**搬运**它，不是**使用**它 |
| 3 | **刷完能否启动，仍取决于低区里那份 u-boot 是否正确** | 包括 `bootcmd`（`ext4load … Image-6.6.uimage … bootm …`）与 `bootdelay=3` |

### 5.3 对比其他路线

| 路线 | 需要 u-boot 在跑？ | 能写低区？ | 砖板能用？ |
|---|---|---|---|
| `dd`（Linux 内） | ✗ 不需要（但要先启动过） | ✔ 能 | ✗ 不能 |
| TFTP | ✔ **需要**（命令由 u-boot 执行） | ✔ 能 | ✗ 不能 |
| U 盘 `fatload` | ✔ **需要** | ✔ 能 | ✗ 不能 |
| 串口 ROM Monitor | ✗ 不需要（走 SoC ROM） | ✔ 能 | ✔ **唯一能** |

---

## 6. 实测证据与踩过的坑

### 6.1 镜像尺寸与偏移核对

- 低区镜像 38 MiB：`@0x7F300` 有 `U-Boot 2015.07`、`@0x806C2` 有 `BPI-W2>`、
  `@0x2204C2` 有我们的 `bootcmd`、`@0x22055D` 有 `bootdelay=3` ✔
- p1 整块 md5 与镜像逐字节一致（见第 3 节）
- p2 镜像大小 = 分区实际大小 7,508,852,736 ✔

### 6.2 踩过的坑（都已修）

| 坑 | 后果 | 修法 |
|---|---|---|
| **TFTP 加载地址 `0x02000000`** | 256 MiB 会写到 `0x12000000`，**撞上 BL31(0x10120000)/TEE(0x10200000) 保留区** → u-boot 把自己写坏、传输到约 60~70 MB 卡死（复现两次，只能断电） | 改用 `0x20000000` + 大镜像 64 MiB 分片 |
| **p2 镜像按整数 7 GiB 生成** | 比真实分区大 7 MB → `dd` 被尺寸检查拦下（拦得对） | 生成器改用目标分区实际值 |
| **校验脚本"空 md5 == 空 md5"** | p2 覆盖运行中 rootfs 后命令全部失败，两个 md5 都是空串，被误判成"一致" | 要求 md5 非空才比较 |
| **`dd` 覆盖运行中 rootfs 后 `/usr/bin` 失效** | `sync`/`reboot` 全部 `Input/output error`，重启没成 | 重启改用 **SysRq**（`echo b > /proc/sysrq-trigger`） |
| **`losetup -P` 后立刻挂载** | 报"坏超级块"（分区表就绪有时差） | 生成器重试 12 次 |
| **导出 image 时 `git add -A`** | 会连带提交别人正在进行的工作 | 只用明确路径提交 |

### 6.3 一个操作细节

`dd` 覆盖 p2 时系统仍在运行（内核与 `dd` 都在内存里），但 **p2 上的用户态会随之损坏**：
服务逐个退出、`/usr/bin` 报 I/O 错误、SSH 拒绝连接。**这是预期现象**，
只要写入已经完成，重启一次就会进入新系统。

---

## 7. 附：USB fastboot 调查结论（**暂停使用**）

本板 u-boot 里有 `fastboot - use USB Fastboot protocol`，实测：

- 电脑能识别到设备（`18d1:4e40 Google Inc. Nexus 7 (fastboot)`），`fastboot devices` 可见 ✔
- `fastboot oem help` 能打印厂商命令清单 ✔：

```
fastboot flash img          install.img
fastboot flash linuxKernel  emmc.uImage
fastboot flash kernelDT     android.emmc.dtb
fastboot flash kernelRootFS android.root.emmc.cpio.gz_pad.img
fastboot flash system/data/cache/vendor …
```

**但这条路暂时走不通**：

- `fastboot oem get_part_info` / `get_fw_info` / `get_emmc_layout` 一律返回
  `unknown oem command`（帮助文本有、实现没有）
- 从 u-boot 二进制里挖出的机制表明，这些目标名对应的是**厂商原始的 GPT 命名分区**
  （`read_part_info_from_mbr`、`sdcard_V1 / monarch layout, total 10 / 24 GPT partitions`）
- 而本板 eMMC 现在是 **MBR**（`Disklabel type: dos`，分区名是通用的 `Boot`）

**后续可能**：若能拿到**原厂线刷包**（含分区表定义 + fwdesc），可据此重建 GPT 命名分区布局，
然后把本项目的固件打成同样格式 —— 那才是真正的"一条 USB 线刷完"。
调查工具：`tools/fastboot-probe.sh`（只读，不写入）。

---

## 8. 镜像从哪来

| 镜像 | 来源 |
|---|---|
| `low-region-38MiB.img` | **随仓库提供**（`firmware/low-region-38MiB.img.gz`，含 `bootdelay=3`，md5 见同名 `.md5`） |
| `p1.img` | 用 `firmware/build-images.sh p1` 生成（内核 + DTB + `.bak`，几秒） |
| `p2.img` | 用 `firmware/build-images.sh p2 <官方 fnOS ARM 镜像>` 生成（**不转发 fnOS 的版权镜像**，请自行下载） |

生成器会自检：重新挂载生成结果，核对 `root` 子卷、默认子卷、fstab、模块元数据、
首次开机服务是否就位。

---

## 9. 相关文档

| 文档 | 内容 |
|---|---|
| `firmware/README.md` | 给使用者的刷机指南（含"怎么进 u-boot 提示符"） |
| `firmware/RECOVERY.md` | 低区布局、hwsetting 说明、灾难恢复与救援 |
| `docs/04-recovery.md` | 串口 ROM Monitor 救砖完整实录 |
| `docs/07-fnos-upgrade.md` | fnOS 升级（整块替换 rootfs 子卷）与回滚 |
| `CHANGELOG.md` | 各阶段变更与实测证据索引 |
