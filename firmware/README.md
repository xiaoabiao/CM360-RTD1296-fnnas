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

> **✅ 三个镜像齐了**：`low-region-38MiB.img.gz` 随仓库提供（从本板实测 dump 而来）；
> `p1` / `p2` 由本目录脚本在**你自己的电脑上**生成（见第 2 节）。
>
> ⚠️ 低区镜像**仅适用于同型号板**（CM360 / ds218-cm360 同方案）。它里面最关键的是
> **hwsetting**（ROM 上电执行的硬件初始化脚本：DRAM/时钟/引脚）——我们这块板上的
> hwsetting 与原厂升级包里的那份**并不相同**（尺寸字段更贴合实机），所以这一层
> 只能从**实测可用的板子**上 dump，拿原厂文件拼是拼不出来的。
> 不同批次/型号请自行 `dd if=/dev/mmcblk0 bs=512 count=77824 of=low-region.img` 并校验。

| 镜像 | 内容 | 大小 | 从哪来 |
|---|---|---|---|
| `low-region-38MiB.img.gz` | 低区：hwsetting + bootcode + FSBL + BL31 + u-boot + u-boot env | 38 MiB（gz **17.5 MB**） | **本仓库**（本板实测 dump；md5 见同名 `.img.md5`） |
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

低区镜像**无需生成**，直接解压即可，并核对 md5：

```sh
gunzip -k low-region-38MiB.img.gz
md5sum low-region-38MiB.img        # 应为 22dc832126b42cd1b2f77e305e13c76b
```

> 关于 MAC：低区的 u-boot env 里带着**作者板子的 `ethaddr`**。
> 这不会造成局域网冲突 —— fnOS 的 `system_setmac.service` 会按**每块板自己的 eMMC CID**
> 推导出稳定且唯一的 MAC。若你想换掉 u-boot 阶段用的 MAC，刷完在 u-boot 里执行
> `setenv ethaddr 02:00:00:xx:xx:xx; saveenv` 即可。

生成物在 `firmware/images/`（git 忽略）。`p2` 生成器每一步都有输出，最后有**自检**：
重新挂载生成结果，核对 `root` 子卷、默认子卷、fstab、模块元数据、首次开机服务是否就位。

## 2.5 怎么进 u-boot 提示符（关键，先看这段）

低区镜像里的 u-boot env **已经设好 `bootdelay=3`** —— 也就是说：

> **开机后 3 秒内，在串口上按任意键**（Esc / Tab / 空格 / 回车都行），
> 就会停在 `BPI-W2>` 提示符。错过这 3 秒它会直接引导系统。

万一错过了、或者需要强制进入：**让引导失败即可**（u-boot 会掉到提示符）。
最安全的做法是把 p1 里的内核临时改名，例如：

```sh
sudo mount /dev/mmcblk0p1 /mnt/p1
sudo mv /mnt/p1/Image-6.6.uimage /mnt/p1/Image-6.6.uimage.hold
sudo sync && sudo umount /mnt/p1 && sudo reboot
# 此时 u-boot 的 ext4load 失败 → 自动停在 BPI-W2>
# 进去以后可以手工引导改名的内核：
#   ext4load mmc 0:1 0x03000000 Image-6.6.uimage.hold
#   ext4load mmc 0:1 0x02100000 rtd1296-cm360.dtb
#   bootm 0x03000000 - 0x02100000
# 起来后再把文件名改回去
```

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

### 关于 fastboot（USB 线刷）

本板 u-boot 内置 Android Fastboot + Realtek OEM 命令
（`fastboot oem set_flash_bootcode`、`oem set_load_kernel/dtb/rootfs`、`oem go_all` 等），
**x86 上一条 `fastboot oem set_flash_bootcode` 就能把 bootcode 写进低区**。

但注意实测结果：**本机 eMMC 用的是 DOS/MBR 分区表，分区名是通用的 `Boot`**
（`mmc part` 实测），所以 `fastboot flash linuxKernel / system / kernelDT` 这类
**按分区名刷写的命令不适用**；内核与 rootfs 请用第 3 节的 `mmc write`（TFTP/U 盘）。
换句话说：**"从电脑一次刷完"是可行的，但落地方式 = TFTP/U 盘 + `mmc write`（三层都能刷）**，
fastboot 只在你想单独重写 bootcode 时更省事。

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

## 6. fnOS 1.2.x 在 6.6 内核上的坑（本仓库已修）

> 一句话：fnOS 1.2.x 的用户态是按它自带的 **6.18 内核**（含厂商私有补丁）设计的。
> 用自编译内核时，涉及**存储**的地方会连续踩坑。本仓库的做法分两类：
> **用户态兼容层**（脚本安装）与**内核补丁**（`patches/0007`、`0008`）。
> 一键安装：`boards/rtd1296-cm360/board-scripts/fnos-kernel-compat.sh`
>
> ⚠️ **部署内核务必用 uImage**：构建脚本会同时产出裸 `Image-6.6` 和
> `Image-6.6.uimage`。拷**裸 Image** 会让 u-boot 2015.07 的 `bootm` 认不出
> （它只认 legacy uImage / FIT），板子直接掉进 `BPI-W2>` 提示符。
> 判据：uImage 应以 `27051956` 开头、比裸 Image 多 64 字节。

### 6.1 原来写的两个坑

fnOS 1.2.x 的部分用户态是**按 6.18 内核**设计的：

| 现象 | 真因 | 本仓库的处理 |
|---|---|---|
| 面板"创建存储空间"失败；`journalctl -u trim_main` 里是 `mdadm: Fail to create mdN when using /sys/module/md_mod/parameters/new_array` | mdadm 4.5 传 **`--bitmap=lockless`**（6.7+ 内核特性）→ 失败；且每次失败在内核留下 `state=clear` 的同名 md 设备 → 后续重试永远 `File exists` | 在 `/usr/trim/bin/mdadm` 放透明兼容层，`lockless` → 等价的 `internal` |
| 流程走到 mkfs 之后就停住（存储建一半、没挂载、面板报失败） | fnOS 的 `fast_resync_md_raid` 依赖 lockless bitmap 接口，失败会让整个创建流程中止 | 兼容层把新建阵列的首次同步置 idle（931G 全量同步要 95 分钟，面板会超时） |

两处由 `cm360-firstboot.service` 自动安装；脚本与还原方法见
`../boards/rtd1296-cm360/board-scripts/mdadm-lockless-compat.sh`。

### 6.2 内核级：fnOS 的私有挂载选项（存储"未挂载"的真凶）

```
BTRFS error (device dm-0): unrecognized mount option 'trimacl'
ext4: Unknown parameter 'trimacl'
```

fnOS 挂存储卷时带的是它自己的私有选项 `-o trimacl,prjquota`
（`trimacl` = 它的 ACL v2 扩展，`prjquota` 是 ext4 的习惯写法）。
vanilla 6.6 的 btrfs/ext4 不认识就直接拒绝挂载 → 面板永远显示"未挂载"。

- **本仓库的处理**：内核补丁 `patches/0007`（btrfs）、`patches/0008`（ext4）
  接受这些选项（no-op；qgroup 配额仍由 fnOS 经 ioctl 开启）。
- **社区佐证**：这是 fnOS 1.2.0302 自身的 bug —— 官方支持的 OESPlus 升级后同样挂载失败
  （[飞牛论坛](https://club.fnnas.com/forum.php?mod=viewthread&tid=69485#lastpost)），
  判定内核是否能挂载的社区判据是 `grep -w is_trimacl /proc/kallsyms`。
  别人是靠"换一个带补丁的 fnOS 内核"或"手工 mount"绕过；我们是让内核**接受**这些选项，
  于是 fnOS 能**开机自动挂载**。

### 6.3 内核级：`trimafs` 文件系统缺失（面板不开机自启）

`triminit` 还会执行 `mount -o trimacl -t trimafs trimafs /fs` —— 那是 fnOS ACL v2 专用的
**自定义文件系统类型**，vanilla 内核没有 → `triminit` 初始化链中断 → `trim_*` 服务
开机不被拉起（现象：**能 ping 通、SSH 也通，但面板打不开**）。

- **本仓库的处理**：`cm360-trim-boot.service` 开机兜底单元，在 PostgreSQL 就绪后
  幂等拉起 `trim_main/trim_sac/trim_nginx/filestor_service` 等服务；
- **已知功能缺失**：细粒度 ACL（trimacl）不生效，存储/共享/面板均正常。

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
