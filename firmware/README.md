# CM360 刷机指南（把 fnOS 装到你的 RTD1296 板子上）

> 目标：一块 **Xiaorui CM360**（Realtek RTD1296，双盘位，原厂方案与群晖 DS218 同款），
> 在**不用厂商工具、不用 Windows** 的前提下刷成 **fnOS 1.2.0302 + 自编译 Linux 6.6.54**。
> 包里所有文件要么随仓库提供，要么可以用仓库脚本从**官方下载**现场生成。

**⚠️ 只适用于同型号板子**（CM360 / ds218-cm360 同方案）。
DTS 与低区镜像都是照这块板实测出来的，别的机型**不要照搬**。

---

## 0. 你会得到什么 / 需要准备什么

**得到**：fnOS 1.2.0302（面板、SMB、Docker、ZFS 存储空间可用）、自编译 6.6.54 内核
（eMMC/SATA/千兆网/看门狗/风扇/温度等板级支持）、双盘 RAID 存储空间。

**准备**：

| 项 | 说明 |
|---|---|
| 串口线 | CH340 + 115200 8N1。这条链**离不开串口**（进 u-boot、必要时救砖）。必须独占，别同时开 `screen` |
| Linux 主机 | 生成镜像 + 跑 TFTP。需要 `sudo`、`rsync`、`btrfs-progs`、`e2fsprogs`，约 15 GB 临时空间 |
| 网络或 U 盘 | u-boot 里 `tftpboot`（推荐）或 `fatload usb`（无网时）把镜像喂给板子 |
| 时间 | 生成镜像 1~20 分钟（取决于磁盘），刷入 5~15 分钟 |

## 1. 三个镜像分别是什么

> **⚠️ 当前状态**：`p1` / `p2` 两个镜像的**生成器已实测可用**（本仓库提供）；
> `low-region-38MiB.img.gz` 需要从一台**已经在跑这套系统的 CM360** 上 dump 出来
> （`dd if=/dev/mmcblk0 bs=512 count=77824 of=low-region-38MiB.img`），
> 因为低区里装着我们实测可用的 u-boot 与它保存的 env —— 原厂那 5 个文件凑不出这一套。
> 做法与原因见 `RECOVERY.md` 第五节。**在该文件补齐之前，本指南的第 3 步只能刷 p1/p2。**

| 镜像 | 内容 | 大小 | 从哪来 |
|---|---|---|---|
| `low-region-38MiB.img.gz` | 低区：hwsetting + bootcode + FSBL + BL31 + u-boot + u-boot env | 38 MiB（gz 约 15 MB） | **本仓库**（实测可用，见 `RECOVERY.md`） |
| `p1-256MiB.img` | ext4：内核 `Image-6.6.uimage` + 板级 DTB（附 `.bak` 兜底） | 256 MiB（gz 约 40 MB） | `./build-images.sh p1` 生成 |
| `p2-7GiB.img` | btrfs：fnOS rootfs（子卷 `root`）+ 本仓库适配 | 7 GiB（gz 约 2 GB） | `./build-images.sh p2 <官方镜像>` 生成 |

**为什么 rootfs 要自己生成**：fnOS 的 ARM 镜像是**整盘镜像**、自带它自己的内核；
而本板跑的是自编译 6.6.54 内核 + 板级 DTS。所以要把官方 rootfs 取出来、搬进本板的
btrfs 布局（**子卷名必须是 `root`** —— u-boot 的 cmdline 是 `rootflags=subvol=root`），
再施加适配（fstab / 内核模块元数据 / 下面第 6 节的两个兼容层）。

> 我们**不转发** fnOS 的镜像内容（那是他们的版权物）。请自行从
> <https://fnnas.com/download-arm> 下载 ARM 版（1.2.0302 的 MD5 见 `artifacts/README.md`），
> 用脚本现场生成。

## 2. 生成镜像

```sh
cd firmware

# 2.1 内核 + DTB（几秒）
./build-images.sh p1

# 2.2 rootfs（需要 sudo 做 loop 挂载；官方镜像 .gz 或 .img 都行）
./build-images.sh p2 ~/downloads/fnos_arm_1.2.0302_onethingcloud-oes.img.gz

# 2.3 低区镜像：解压仓库里那份
gunzip -k low-region-38MiB.img.gz
```

生成物在 `firmware/images/`（git 忽略）。`p2` 生成器每一步都有输出，最后有**自检**：
重新挂载生成结果，核对 `root` 子卷、默认子卷、fstab、模块元数据、首次开机服务是否就位。

## 3. 刷入（u-boot + TFTP，推荐）

主机开 TFTP 并把 `images/` 放进去；串口进 u-boot（开机按 **Esc 或 Tab**，停在 `BPI-W2>`）：

```
BPI-W2> setenv serverip 192.168.1.10        # 你的主机
BPI-W2> setenv ipaddr   192.168.1.50        # 给板子临时用的地址
BPI-W2> setenv autoload no
BPI-W2> mmc dev 0

# ① 低区 38 MiB（LBA 0 ~ 0x12FFF）
BPI-W2> tftpboot 0x02000000 low-region-38MiB.img
BPI-W2> mmc write 0x02000000 0x0 0x13000

# ② p1 256 MiB（LBA 0x13000 ~ 0x92FFF）
BPI-W2> tftpboot 0x02000000 p1-256MiB.img
BPI-W2> mmc write 0x02000000 0x13000 0x80000

# ③ p2 7 GiB（LBA 0x93000 起）
BPI-W2> tftpboot 0x02000000 p2-7GiB.img
BPI-W2> mmc write 0x02000000 0x93000 0xE00000

BPI-W2> boot
```

完整版（**U 盘路线**、p2 切片写法、只换内核的低风险路线）见 **`flash-uboot.cmd`**。

- **没有网络**：镜像放 **FAT32 U 盘**（单文件 ≤4 GiB，p2 要切片），
  u-boot 里 `usb start` + `fatload usb 0 0x02000000 cm360/p1-256MiB.img`，之后同样 `mmc write`。
- **p2 走 TFTP 不稳**：切 ≤2 GiB 分片逐片写（每片 `0x400000` 扇区，起始 LBA 依次
  `0x93000` → `0x493000` → `0x893000` → `0xC93000`）。

## 4. 刷完第一次开机

1. 串口依次看到 FSBL → u-boot → 内核 → systemd；
2. 首次开机有个一次性服务 `cm360-firstboot.service`：
   - `depmod -a`（**全内置内核的模块索引必须在板上生成**，kmod 只认 `.bin` 索引；
     不做的话 `modprobe zram` 之类会全失败）；
   - 安装第 6 节的两个兼容层；
   - 跑完自动禁用，日志 `/var/log/cm360-firstboot.log`。
3. 网卡 MAC 由 `system_setmac.service` 从 eMMC CID 推导（固定不变）；DHCP 拿到地址后
   浏览器开 `http://<板子IP>` 进面板，按向导建账号。

## 5. 建存储空间（先清旧阵列）

这两块盘若以前组过 RAID（或装过别家系统），**先在面板里删掉/擦除旧存储**，
否则 fnOS 建阵列会因为"盘上有 md 超级块 / 内核里有同名 `state=clear` 的 md 设备残留"而失败。
至少一块空盘即可（两块盘会给 RAID1）。建完在面板能看到存储空间，`df -h` 能看到 `/vol1`。

## 6. fnOS 1.2.x 在 6.6 内核上的两个坑（本仓库已修）

fnOS 1.2.x 的部分用户态是**按 6.18 内核**设计的：

| 现象 | 真因 | 本仓库的处理 |
|---|---|---|
| 面板"创建存储空间"失败；`journalctl -u trim_main` 里是 `mdadm: Fail to create mdN when using /sys/module/md_mod/parameters/new_array` | mdadm 4.5 传 **`--bitmap=lockless`**（6.7+ 内核特性）→ 失败；且每次失败在内核留下 `state=clear` 的同名 md 设备 → 后续重试永远 `File exists` | 在 `/usr/trim/bin/mdadm` 放透明兼容层，`lockless` → 等价的 `internal` |
| 流程走到 mkfs 之后就停住（存储建一半、没挂载、面板报失败） | fnOS 的 `fast_resync_md_raid` 依赖 lockless bitmap 接口，失败会让整个创建流程中止 | 兼容层把新建阵列的首次同步置 idle（931G 全量同步要 95 分钟，面板会超时） |

两处由 `cm360-firstboot.service` 自动安装；脚本与还原方法见
`../boards/rtd1296-cm360/board-scripts/mdadm-lockless-compat.sh`。

## 7. 出问题怎么办

| 现象 | 先看这里 |
|---|---|
| 起不来 / 卡 FSBL | 串口有无输出；低区是否刷对；`docs/04-recovery.md` 走串口救砖 |
| 起来了但没有 fnOS 界面 | `journalctl -b -1`；重刷 p2 |
| `modprobe xxx` 全失败 | 首次开机服务没跑成功 → 手工 `sudo depmod -a $(uname -r)` |
| 存储空间建不了 | 先按第 5 节清旧阵列；再确认第 6 节两个兼容层在不在 |
| 风扇/温度/SD 卡/USB3 不工作 | **已知未完成**：驱动都已就位，缺 DTS 节点与引脚确认，见 CHANGELOG 待办 |
| 彻底变砖（连 u-boot 都没有） | `RECOVERY.md`：串口 ROM Monitor，只补 1.2 MB 最小集合 |

## 8. 本目录文件一览

| 文件 | 作用 |
|---|---|
| `build-images.sh` | 在**你的**电脑上生成 p1 / p2 镜像（含自检） |
| `flash-uboot.cmd` | u-boot 一键刷机脚本（TFTP / U 盘 / 只换内核三条路线） |
| `low-region-38MiB.img.gz` | 低区镜像（随仓库提供） |
| `RECOVERY.md` | 低区布局、hwsetting 说明、灾难恢复与救援 |
| `images/` | 生成物（git 忽略，别提交） |
| `../artifacts/kernel-6.6.54/` | 生成器的输入：内核 uImage、DTB、完整 `.config`、模块元数据 |
| `../boards/rtd1296-cm360/vendor-firmware/` | 原厂固件（DTB + 启动链 + hwsetting），回原厂时用 |
